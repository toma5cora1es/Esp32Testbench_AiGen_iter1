function [success, buildId] = esp32_flash(sketchOrPath, varargin)
%ESP32_FLASH Generic Build & Flash FSM.
%   Zero project/pin hardcoding: pass optional '--board <name>' (injects macros from config/boards/*.json),
%   '--ui-file <html_path>', '--radio <ap_now|sta_now|off>', '--role <standalone|master|slave>', '--bt'.
    cfg = wb_config('workbench');
    resolved = wb_paths('sketch', sketchOrPath);
    if isfolder(resolved)
        [~, fn] = fileparts(resolved); cand = fullfile(resolved, [fn '.ino']);
        if isfile(cand), resolved = cand; else, inos = dir(fullfile(resolved,'*.ino')); resolved = fullfile(inos(1).folder, inos(1).name); end
    end
    if ~isfile(resolved), error('ESP32:NoSketch', 'Sketch not found: %s', resolved); end

    s = esp32_io('state');
    mode = ''; target = ''; role = 'standalone'; radio = 'ap_now'; enableBt = false;
    boardName = ''; customUiPath = ''; injectDaemon = true; restoreWifi = cfg.transport.wifi.restoreHostWifiAfterOta;

    i = 1;
    while i <= numel(varargin)
        a = regexprep(strtrim(char(varargin{i})), '^["'']|["'']$', ''); al = lower(a);
        if any(strcmp(al, {'--usb','-u','usb'})), mode='usb'; if i<numel(varargin)&&~startsWith(char(varargin{i+1}),'-'), target=upper(strtrim(char(varargin{i+1}))); i=i+1; end
        elseif any(strcmp(al, {'--wifi','-w','wifi'})), mode='wifi'; if i<numel(varargin)&&~startsWith(char(varargin{i+1}),'-'), target=strtrim(char(varargin{i+1})); i=i+1; end
        elseif strcmp(al, '--role') && i<numel(varargin), role=lower(strtrim(char(varargin{i+1}))); i=i+1;
        elseif strcmp(al, '--radio') && i<numel(varargin), radio=lower(strtrim(char(varargin{i+1}))); i=i+1;
        elseif strcmp(al, '--board') && i<numel(varargin), boardName=strtrim(char(varargin{i+1})); i=i+1;
        elseif strcmp(al, '--ui-file') && i<numel(varargin), customUiPath=strtrim(char(varargin{i+1})); i=i+1;
        elseif strcmp(al, '--bt'), enableBt = true;
        elseif strcmp(al, '--no-bt'), enableBt = false;
        elseif strcmp(al, '--keep-wifi'), restoreWifi = false;
        elseif strcmp(al, '--raw'), injectDaemon = false;
        elseif startsWith(upper(a),'COM') || startsWith(a,'/dev/'), mode='usb'; target=upper(a);
        elseif ~isempty(regexp(a,'^\d+\.\d+\.\d+\.\d+$','once')), mode='wifi'; target=a;
        end
        i = i + 1;
    end

    if isempty(mode)
        if strcmp(s.Mode,'wifi'), mode='wifi'; target=s.Target;
        elseif strcmp(s.Mode,'serial'), mode='usb'; target=s.Target;
        else, mode='usb'; target=esp32_io('detect_port');
        end
    end
    if isempty(target), target = iif(strcmp(mode,'wifi'), cfg.transport.wifi.apIp, esp32_io('detect_port')); end

    [~, baseName, ext] = fileparts(resolved);
    short = upper(regexprep(baseName, '[^a-zA-Z0-9]', ''));
    if strlength(short) > 10, short = extractBefore(short, 11); end
    buildId = sprintf('BLD_%s_%s', short, char(datetime('now','Format','HHmmss')));

    buildRoot = wb_paths('buildTemp'); sketchDir = fullfile(buildRoot,'ota_sketch'); outBinDir = fullfile(buildRoot,'bin');
    outIno = fullfile(sketchDir, 'ota_sketch.ino');
    if isfolder(buildRoot), try rmdir(buildRoot,'s'); catch, end; end
    mkdir(sketchDir); mkdir(outBinDir);

    macroHdr = build_board_macro_header(boardName);
    userCode = fileread(resolved);
    if injectDaemon && strcmpi(ext, '.ino')
        merged = build_daemon_sketch(userCode, macroHdr, buildId, role, radio, enableBt, cfg, customUiPath);
        write_utf8(outIno, merged);
    else
        write_utf8(outIno, [macroHdr newline userCode]);
    end

    acli = esp32_io('find_cli');
    cmdCompile = sprintf('"%s" compile --fqbn %s --build-property "build.partitions=%s" --build-property "upload.maximum_size=%d" --output-dir "%s" "%s"', ...
        acli, cfg.toolchain.fqbn, cfg.toolchain.partitionScheme, cfg.toolchain.maxAppBytes, outBinDir, sketchDir);
    wb_log('fsm', 'FLASH', 'COMPILE', sprintf('%s | Role=%s | Radio=%s | BT=%d | ID=%s', baseName, upper(role), upper(radio), enableBt, buildId));
    [st, cout] = system(cmdCompile);
    if st ~= 0, fprintf(2, '%s\n', cout); error('ESP32:CompileFail', 'arduino-cli compile failed.'); end
    binFile = fullfile(outBinDir, 'ota_sketch.ino.bin');

    if strcmp(mode, 'usb')
        wasConn = strcmp(s.Mode,'serial') && strcmpi(s.Target, target);
        if wasConn, esp32_io('disconnect'); end
        try objs = serialportfind('Port', upper(string(target))); for k=1:numel(objs), delete(objs(k)); end; catch, end
        wb_log('fsm', 'FLASH', 'USB_UPLOAD', target);
        [st, uout] = system(sprintf('"%s" upload -p %s --fqbn %s --input-dir "%s"', acli, target, cfg.toolchain.fqbn, outBinDir));
        if st ~= 0, fprintf(2, '%s\n', uout); error('ESP32:UploadFail', 'USB upload failed on %s.', target); end
        pause(1.8);
        if wasConn || ~strcmp(radio,'off'), esp32_io('connect', target); end
    else
        prevSsid = esp32_io('get_ssid');
        if restoreWifi && ~isempty(prevSsid), g = onCleanup(@() esp32_io('restore_ssid', prevSsid)); end %#ok<NASGU>
        if strcmp(target, cfg.transport.wifi.apIp), esp32_io('ensure_ap', target); end
        try webread(sprintf('http://%s/cmd?q=OTA_PREP', target), weboptions('Timeout',3.0,'ContentType','text')); pause(0.25); catch, end
        wb_log('fsm', 'FLASH', 'OTA_STREAM', sprintf('POST http://%s/ota', target));
        [st, resp] = system(sprintf('curl.exe -s -S --http1.1 -H "Expect:" --connect-timeout 8 --max-time %d -F "image=@%s" http://%s/ota 2>&1', cfg.transport.wifi.otaTimeoutSec, binFile, target));
        if st ~= 0 && ~contains(resp,'OTA_OK') && ~contains(resp,'Empty reply') && st ~= 52 && st ~= 56
            error('ESP32:OtaFail', 'OTA failed: %s', strtrim(resp));
        end
        pause(cfg.transport.wifi.otaRebootSettleSec);
    end
    success = true;
    wb_log('pass', 'FLASH', 'COMPLETE', sprintf('BuildID=%s flashed via %s (%s)', buildId, upper(mode), target));
end

function hdr = build_board_macro_header(boardName)
    hdr = '';
    if isempty(boardName), return; end
    b = wb_config('board', boardName);
    if ~isfield(b, 'macros'), return; end
    fns = fieldnames(b.macros);
    lines = strings(numel(fns), 1);
    for k = 1:numel(fns)
        v = b.macros.(fns{k});
        if isnumeric(v), vs = num2str(v); elseif islogical(v), vs = num2str(double(v)); else, vs = char(v); end
        lines(k) = sprintf('#define %s %s', fns{k}, vs);
    end
    hdr = char(strjoin(lines, newline));
end

function merged = build_daemon_sketch(userCode, macroHdr, buildId, role, radio, enableBt, cfg, customUiPath)
    modUser = regexprep(userCode, '\<void\s+setup\s*\(\s*(void)?\s*\)', 'void user_setup()', 'once');
    if ~contains(modUser,'user_setup'), modUser = [modUser newline 'void user_setup() {}' newline]; end
    if isempty(regexp(modUser,'\<\s*void\s+loop\s*\(\s*(void)?\s*\)','once')), modUser = [modUser newline 'void loop() { delay(100); }' newline]; end

    dDir = wb_paths('daemon');
    cpp  = fileread(fullfile(dDir, 'core0_daemon.cpp'));
    udeHtml = strrep(fileread(fullfile(dDir, 'web_ui.html')), '{{FW_BUILD_ID}}', buildId);
    appHtml = udeHtml; hasAppUi = '0';
    if ~isempty(customUiPath)
        cp = customUiPath;
        if ~isfile(cp), cp = fullfile(wb_paths('root'), customUiPath); end
        if ~isfile(cp), error('ESP32:NoUiFile', 'Custom UI HTML not found: %s', customUiPath); end
        appHtml = strrep(fileread(cp), '{{FW_BUILD_ID}}', buildId);
        hasAppUi = '1';
    end

    roleId = '0';
    if strcmpi(role,'master'), roleId = '1'; elseif strcmpi(role,'slave'), roleId = '2'; end
    radioId = '0'; % 0=AP+ESP-NOW, 1=STA+ESP-NOW, 2=OFF(USB-only)
    if strcmpi(radio,'sta_now') || strcmpi(role,'slave'), radioId = '1';
    elseif strcmpi(radio,'off') || strcmpi(radio,'usb'), radioId = '2'; end

    tokens = {
        '{{FW_BUILD_ID}}',       buildId;
        '{{NODE_ROLE_ID}}',      roleId;
        '{{RADIO_MODE_ID}}',     radioId;
        '{{ENABLE_BT}}',         iif(enableBt,'1','0');
        '{{HAS_APP_UI}}',        hasAppUi;
        '{{WB_AP_SSID}}',        cfg.transport.wifi.apSsid;
        '{{WB_AP_PASS}}',        cfg.transport.wifi.apPassword;
        '{{WB_BT_NAME}}',        cfg.transport.bluetooth.deviceName;
        '{{WB_ESPNOW_CH}}',      num2str(cfg.transport.wifi.espNowChannel);
        '{{WEB_UI_UDE_HTML}}',   udeHtml;
        '{{WEB_UI_APP_HTML}}',   appHtml;
        '{{USER_SKETCH_CODE}}',  [macroHdr newline modUser]
    };
    merged = cpp;
    for k = 1:size(tokens,1), merged = strrep(merged, tokens{k,1}, tokens{k,2}); end
end

function write_utf8(p, txt), f=fopen(p,'w','n','UTF-8'); fwrite(f,txt,'char'); fclose(f); end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
