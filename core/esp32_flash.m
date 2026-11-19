function [success, buildId] = esp32_flash(sketchOrPath, varargin)
%ESP32_FLASH Manifest-driven 11-State Build & Deployment FSM (USB or Wi-Fi OTA).
%   Resolves sketches by short-name (e.g. 'green_agv_mainboard') or path, injects config-driven
%   macros + modular HTML templates via ui_manifest.json, compiles with arduino-cli, and flashes.
    if nargin < 1 || isempty(sketchOrPath)
        error('ESP32:FlashPath', 'Specify sketch name (e.g. green_agv_mainboard) or .ino/.bin path.');
    end

    cfg   = wb_config('workbench');
    board = wb_config('board');
    uiMan = wb_config('ui_manifest');

    resolved = wb_paths('sketch', regexprep(strtrim(char(sketchOrPath)), '^["'']|["'']$', ''));
    if isfolder(resolved)
        [~, folderName] = fileparts(resolved);
        cand = fullfile(resolved, [folderName '.ino']);
        if isfile(cand), resolved = cand;
        else
            inos = dir(fullfile(resolved, '*.ino'));
            if ~isempty(inos), resolved = fullfile(inos(1).folder, inos(1).name); end
        end
    end
    if ~isfile(resolved)
        error('ESP32:FileNotFound', 'Sketch or binary not found: %s', resolved);
    end

    s = esp32_io('state');
    mode = ''; target = '';
    injectDaemon = true;
    restoreWifiAfterOta = cfg.transport.wifi.restoreHostWifiAfterOta;
    nodeRole = cfg.deploy.defaultRole;
    uiTemplate = cfg.deploy.defaultUi;

    i = 1;
    while i <= numel(varargin)
        arg = regexprep(strtrim(char(varargin{i})), '^["'']|["'']$', '');
        al = lower(arg);
        if any(strcmp(al, {'--wifi', '-w', 'wifi'}))
            mode = 'wifi';
            if i < numel(varargin) && ~startsWith(char(varargin{i+1}), '-')
                target = strtrim(char(varargin{i+1})); i = i + 1;
            end
        elseif any(strcmp(al, {'--usb', '-u', 'usb', 'serial'}))
            mode = 'usb';
            if i < numel(varargin) && ~startsWith(char(varargin{i+1}), '-')
                target = upper(strtrim(char(varargin{i+1}))); i = i + 1;
            end
        elseif any(strcmp(al, {'--role', '-r'})) && i < numel(varargin)
            nodeRole = lower(strtrim(char(varargin{i+1}))); i = i + 1;
        elseif any(strcmp(al, {'--master', 'master'})), nodeRole = 'master';
        elseif any(strcmp(al, {'--slave', 'slave'})),   nodeRole = 'slave';
        elseif any(strcmp(al, {'--ui', '--html', '-h'})) && i < numel(varargin)
            uiTemplate = lower(strtrim(char(varargin{i+1}))); i = i + 1;
        elseif strcmp(al, '--raw'),       injectDaemon = false;
        elseif strcmp(al, '--keep-wifi'), restoreWifiAfterOta = false;
        elseif startsWith(upper(arg), 'COM') || startsWith(arg, '/dev/')
            mode = 'usb'; target = upper(arg);
        elseif ~isempty(regexp(arg, '^\d+\.\d+\.\d+\.\d+$', 'once'))
            mode = 'wifi'; target = arg;
        end
        i = i + 1;
    end

    if isempty(mode)
        if strcmp(s.Mode, 'wifi'), mode = 'wifi'; target = s.Target;
        elseif strcmp(s.Mode, 'serial'), mode = 'usb'; target = s.Target;
        else, mode = 'wifi'; target = cfg.transport.wifi.apIp;
        end
    end

    acli = esp32_io('find_cli');
    if strcmp(mode, 'usb'), release_matlab_serial_ports(target); end

    if isempty(target)
        if strcmp(mode, 'wifi'), target = cfg.transport.wifi.apIp;
        elseif strcmp(s.Mode, 'serial') && ~isempty(s.Target), target = s.Target;
        else, target = esp32_io('detect_port');
        end
    end

    [~, sketchBaseName, ext] = fileparts(resolved);
    if strcmp(uiTemplate, 'auto')
        if contains(lower(sketchBaseName), 'agv'), uiTemplate = 'agv';
        else, uiTemplate = 'ude';
        end
    end

    shortName = upper(regexprep(sketchBaseName, '[^a-zA-Z0-9]', ''));
    if strlength(shortName) > 10, shortName = extractBefore(shortName, 11); end
    roleTag = upper(extractBefore([nodeRole '   '], 2));
    buildId = sprintf('BLD_%s_%s_%s', shortName, roleTag, char(datetime('now', 'Format', 'HHmmss')));

    buildRoot  = wb_paths('buildTemp');
    sketchDir  = fullfile(buildRoot, 'ota_sketch');
    outBinDir  = fullfile(buildRoot, 'bin');
    outInoPath = fullfile(sketchDir, 'ota_sketch.ino');

    ctx = struct( ...
        'State','RESOLVE_INPUT','FilePath',resolved,'Ext',ext,'Mode',mode,'Target',target, ...
        'NodeRole',nodeRole,'UiTemplate',uiTemplate,'InjectDaemon',injectDaemon, ...
        'RestoreWifi',restoreWifiAfterOta,'PrevWifiSsid',esp32_io('get_ssid'), ...
        'WasConnected',strcmp(s.Mode,'serial') && strcmpi(s.Target,target), ...
        'BuildId',buildId,'BinFile','');

    if strcmp(ctx.Mode, 'wifi') && ctx.RestoreWifi && ~isempty(ctx.PrevWifiSsid) && ~strcmpi(ctx.PrevWifiSsid, cfg.transport.wifi.apSsid)
        wifiCleanup = onCleanup(@() esp32_io('restore_ssid', ctx.PrevWifiSsid)); %#ok<NASGU>
    end

    fqbn = cfg.toolchain.fqbn;
    maxBytes = cfg.toolchain.maxAppBytes;
    partScheme = cfg.toolchain.partitionScheme;

    while ~ismember(ctx.State, {'FLASH_COMPLETE', 'FLASH_ABORTED'})
        switch ctx.State
            case 'RESOLVE_INPUT'
                esp32_io('trace', 'esp32_flash.m', 'FSM: RESOLVE_INPUT', ...
                    sprintf('Sketch=%s | Mode=%s | Target=%s | Role=%s | UI=%s | ID=%s', ...
                    ctx.FilePath, upper(ctx.Mode), ctx.Target, upper(ctx.NodeRole), upper(ctx.UiTemplate), ctx.BuildId));

                if strcmpi(ctx.Ext, '.ino')
                    if isfolder(buildRoot), try rmdir(buildRoot, 's'); catch, end; end
                    mkdir(sketchDir); mkdir(outBinDir);
                    userCode = fileread(ctx.FilePath);
                    if ctx.InjectDaemon
                        ctx = step_fsm(ctx, 'INJECT_CORE0_DAEMON');
                    else
                        merged = inject_board_macros(userCode, board);
                        write_utf8_no_bom(outInoPath, merged);
                        ctx = step_fsm(ctx, 'COMPILE_ARDUINO_CLI');
                    end
                elseif strcmpi(ctx.Ext, '.bin')
                    ctx.BinFile = ctx.FilePath;
                    if strcmp(ctx.Mode, 'wifi'), ctx = step_fsm(ctx, 'WIFI_SNAPSHOT_AND_SWITCH');
                    else, error('ESP32:BinUsbUnsupported', 'Pass .ino for USB upload or use --wifi for .bin.');
                    end
                else
                    error('ESP32:UnsupportedExt', 'Unsupported extension: %s', ctx.Ext);
                end

            case 'INJECT_CORE0_DAEMON'
                fprintf('[FLASH] Building %s [Role=%s | UI=%s | ID=%s]...\n', ...
                    sketchBaseName, upper(ctx.NodeRole), upper(ctx.UiTemplate), ctx.BuildId);
                mergedCode = assemble_firmware_from_manifest(fileread(ctx.FilePath), ctx.BuildId, ctx.NodeRole, ctx.UiTemplate, cfg, board, uiMan);
                write_utf8_no_bom(outInoPath, mergedCode);
                ctx = step_fsm(ctx, 'COMPILE_ARDUINO_CLI');

            case 'COMPILE_ARDUINO_CLI'
                compileCmd = sprintf('"%s" compile --fqbn %s --build-property "build.partitions=%s" --build-property "upload.maximum_size=%d" --output-dir "%s" "%s"', ...
                    acli, fqbn, partScheme, maxBytes, outBinDir, sketchDir);
                esp32_io('trace', 'esp32_flash.m', 'FSM: COMPILE_ARDUINO_CLI', compileCmd);
                [status, cmdout] = system(compileCmd);
                if status ~= 0
                    fprintf(2, '%s\n', cmdout);
                    ctx = step_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:CompileFailed', 'arduino-cli compilation failed.');
                end
                ctx.BinFile = fullfile(outBinDir, 'ota_sketch.ino.bin');
                if strcmp(ctx.Mode, 'wifi'), ctx = step_fsm(ctx, 'WIFI_SNAPSHOT_AND_SWITCH');
                else, ctx = step_fsm(ctx, 'USB_RELEASE_HANDLES');
                end

            case 'USB_RELEASE_HANDLES'
                if ctx.WasConnected, esp32_io('disconnect'); end
                release_matlab_serial_ports(ctx.Target);
                ctx = step_fsm(ctx, 'USB_ESPTOOL_UPLOAD');

            case 'USB_ESPTOOL_UPLOAD'
                upCmd = sprintf('"%s" upload -p %s --fqbn %s --input-dir "%s"', acli, ctx.Target, fqbn, outBinDir);
                esp32_io('trace', 'esp32_flash.m', 'FSM: USB_ESPTOOL_UPLOAD', upCmd);
                fprintf('[FLASH] Flashing USB -> %s...\n', ctx.Target);
                [status, cmdout] = system(upCmd);
                if status ~= 0
                    fprintf(2, '%s\n', cmdout);
                    ctx = step_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:UsbUploadFailed', 'USB upload failed on %s.', ctx.Target);
                end
                ctx = step_fsm(ctx, 'USB_RECONNECT_SESSION');

            case 'USB_RECONNECT_SESSION'
                pause(2.0);
                if ctx.WasConnected, esp32_io('connect', ctx.Target); end
                ctx = step_fsm(ctx, 'FLASH_COMPLETE');

            case 'WIFI_SNAPSHOT_AND_SWITCH'
                if strcmp(ctx.Target, cfg.transport.wifi.apIp)
                    esp32_io('ensure_ap', ctx.Target);
                end
                binInfo = dir(ctx.BinFile);
                if binInfo.bytes > maxBytes
                    ctx = step_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:BinaryTooLarge', 'Binary (%d B) exceeds %s limit (%d B).', binInfo.bytes, partScheme, maxBytes);
                end
                ctx = step_fsm(ctx, 'OTA_PREFLIGHT_PREP');

            case 'OTA_PREFLIGHT_PREP'
                try
                    optsPrep = weboptions('Timeout', 3.0, 'ContentType', 'text');
                    webread(sprintf('http://%s/cmd?q=OTA_PREP', ctx.Target), optsPrep);
                    pause(0.25);
                catch
                end
                ctx = step_fsm(ctx, 'OTA_CURL_MULTIPART');

            case 'OTA_CURL_MULTIPART'
                binInfo = dir(ctx.BinFile);
                curlCmd = sprintf('curl.exe -s -S --http1.1 -H "Expect:" --connect-timeout 8 --max-time %d -F "image=@%s" http://%s/ota 2>&1', ...
                    cfg.transport.wifi.otaTimeoutSec, ctx.BinFile, ctx.Target);
                fprintf('[FLASH] Streaming %.2f MB via OTA -> http://%s/ota ...\n', binInfo.bytes/1e6, ctx.Target);
                [status, resp] = system(curlCmd);
                isRebootDrop = contains(resp, 'Empty reply') || contains(resp, 'Recv failure') || status == 52 || status == 56;
                if status ~= 0 && ~contains(resp, 'OTA_OK') && ~isRebootDrop
                    ctx = step_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:OtaFailed', 'Wi-Fi OTA failed: %s', strtrim(resp));
                end
                ctx = step_fsm(ctx, 'OTA_REBOOT_SETTLE');

            case 'OTA_REBOOT_SETTLE'
                pause(cfg.transport.wifi.otaRebootSettleSec);
                if ctx.RestoreWifi, ctx = step_fsm(ctx, 'WIFI_RESTORE_HOST');
                else
                    if strcmp(ctx.Target, cfg.transport.wifi.apIp), esp32_io('ensure_ap', ctx.Target); end
                    ctx = step_fsm(ctx, 'FLASH_COMPLETE');
                end

            case 'WIFI_RESTORE_HOST'
                esp32_io('restore_ssid', ctx.PrevWifiSsid);
                ctx = step_fsm(ctx, 'FLASH_COMPLETE');
        end
    end
    success = strcmp(ctx.State, 'FLASH_COMPLETE');
    fprintf('[FLASH] Done: Success=%d | BuildID=%s\n', success, ctx.BuildId);
end

function ctx = step_fsm(ctx, nextState)
    esp32_io('trace', 'esp32_flash.m', sprintf('FSM: %s -> %s', ctx.State, nextState), 'Deployment transition');
    ctx.State = nextState;
end

function merged = assemble_firmware_from_manifest(userCode, buildId, nodeRole, uiTemplate, cfg, board, uiMan)
    if isempty(strtrim(userCode)), error('ESP32:EmptySketch', 'Empty .ino sketch.'); end
    modifiedUser = regexprep(userCode, '\<void\s+setup\s*\(\s*(void)?\s*\)', 'void user_setup()', 'once');
    if ~contains(modifiedUser, 'user_setup'), modifiedUser = [modifiedUser newline 'void user_setup() {}' newline]; end
    if isempty(regexp(modifiedUser, '\<void\s+loop\s*\(\s*(void)?\s*\)', 'once'))
        modifiedUser = [modifiedUser newline 'void loop() { delay(100); }' newline];
    end
    modifiedUser = inject_board_macros(modifiedUser, board);

    daemonDir = wb_paths('daemon');
    cppPath   = fullfile(daemonDir, uiMan.daemonSource);
    udePath   = fullfile(daemonDir, uiMan.templates.ude.file);
    agvPath   = fullfile(daemonDir, uiMan.templates.agv.file);
    if ~isfile(cppPath) || ~isfile(udePath) || ~isfile(agvPath)
        error('ESP32:MissingDaemonFiles', 'Daemon or HTML manifest files missing in %s', daemonDir);
    end

    udeHtml = strrep(fileread(udePath), '{{FW_BUILD_ID}}', char(buildId));
    agvHtml = strrep(fileread(agvPath), '{{FW_BUILD_ID}}', char(buildId));
    if contains(udeHtml, uiMan.rawDelimiterUde) || contains(agvHtml, uiMan.rawDelimiterAgv)
        error('ESP32:RawDelimiterCollision', 'HTML content contains C++ raw string delimiter!');
    end

    roleId = '0';
    if strcmpi(nodeRole, 'master'), roleId = '1';
    elseif strcmpi(nodeRole, 'slave'), roleId = '2';
    end
    uiId = num2str(uiMan.templates.ude.id);
    if any(strcmpi(uiTemplate, {'agv', 'cockpit', '1'})), uiId = num2str(uiMan.templates.agv.id); end

    merged = fileread(cppPath);
    tokens = {
        '{{FW_BUILD_ID}}',         char(buildId);
        '{{NODE_ROLE_ID}}',        roleId;
        '{{DEFAULT_UI_ID}}',       uiId;
        '{{WB_AP_SSID}}',          cfg.transport.wifi.apSsid;
        '{{WB_AP_PASS}}',          cfg.transport.wifi.apPassword;
        '{{WB_BT_NAME}}',          cfg.transport.bluetooth.deviceName;
        '{{WB_ESPNOW_CH}}',        num2str(cfg.transport.wifi.espNowChannel);
        '{{WB_MASTER_RTT_PIN}}',   num2str(board.pins.masterRttStrobe);
        uiMan.templates.ude.token, udeHtml;
        uiMan.templates.agv.token, agvHtml;
        '{{USER_SKETCH_CODE}}',    modifiedUser
    };
    for k = 1:size(tokens, 1)
        merged = strrep(merged, tokens{k,1}, tokens{k,2});
    end
end

function txt = inject_board_macros(txt, board)
    p = board.pins;
    k = board.kinematics;
    pairs = {
        '{{PIN_MOT_L_A}}',   num2str(p.motorLeftA);
        '{{PIN_MOT_L_B}}',   num2str(p.motorLeftB);
        '{{PIN_MOT_R_A}}',   num2str(p.motorRightA);
        '{{PIN_MOT_R_B}}',   num2str(p.motorRightB);
        '{{PIN_ENC_L}}',     num2str(p.encoderLeft);
        '{{PIN_ENC_R}}',     num2str(p.encoderRight);
        '{{PIN_US_TRIG}}',   num2str(p.ultrasonicTrig);
        '{{PIN_US_ECHO}}',   num2str(p.ultrasonicEcho);
        '{{PIN_LINE_L}}',    num2str(p.lineSensorLeft);
        '{{PIN_LINE_M}}',    num2str(p.lineSensorMid);
        '{{PIN_LINE_R}}',    num2str(p.lineSensorRight);
        '{{PIN_BTN_T1}}',    num2str(p.buttonT1);
        '{{PIN_BTN_T2}}',    num2str(p.buttonT2);
        '{{PIN_LED_F}}',     num2str(p.frontLights);
        '{{PIN_LED_R}}',     num2str(p.rearLights);
        '{{PIN_BUZZER}}',    num2str(p.buzzer);
        '{{PWM_FREQ_HZ}}',   num2str(board.pwm.motorFreqHz);
        '{{PWM_RES_BITS}}',  num2str(board.pwm.resolutionBits);
        '{{WHEEL_DIAM_MM}}', sprintf('%.4ff', k.wheelDiameterMm);
        '{{WHEEL_BASE_MM}}', sprintf('%.4ff', k.wheelBaseMm);
        '{{TICKS_PER_REV}}', num2str(k.encoderTicksPerRev)
    };
    for idx = 1:size(pairs, 1)
        txt = strrep(txt, pairs{idx,1}, pairs{idx,2});
    end
end

function write_utf8_no_bom(fpath, content)
    fid = fopen(fpath, 'w', 'n', 'UTF-8');
    fwrite(fid, content, 'char');
    fclose(fid);
end

function release_matlab_serial_ports(targetPort)
    try
        objs = serialportfind('Port', upper(string(targetPort)));
        for k = 1:numel(objs), try delete(objs(k)); catch, end; end
    catch
    end
end