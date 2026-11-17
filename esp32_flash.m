function [success, buildId] = esp32_flash(filePath, varargin)
%ESP32_FLASH Explicit 12-State Deployment FSM: Injects BOTH web_ui.html + web_ui_agv.html
%   + core0_daemon.cpp + <sketch>.ino, configures Node Role (STANDALONE, MASTER, SLAVE)
%   and Default Web UI (/ude vs /agv), compiles with arduino-cli, and flashes via USB or Wi-Fi OTA.
%
% CLI EXAMPLES:
%   esp32_cli flash firmware/esp32_bridge_ota/green_agv_cockpit.ino --usb COM8 --role master --ui agv
%   esp32_cli flash firmware/esp32_bridge_ota/green_agv_cockpit.ino --usb COM9 --role slave  --ui agv
%   esp32_cli flash firmware/esp32_bridge_ota/esp32_bridge_ota.ino  --wifi --ui ude

    if nargin < 1 || isempty(filePath)
        error('ESP32:FlashPath', 'You must specify the path to the .ino file, sketch folder, or .bin file.');
    end

    filePath = strtrim(char(filePath));
    filePath = regexprep(filePath, '^["'']|["'']$', '');

    if isfolder(filePath)
        [~, folderName] = fileparts(filePath);
        candidate = fullfile(filePath, [folderName '.ino']);
        if isfile(candidate)
            filePath = candidate;
        else
            inos = dir(fullfile(filePath, '*.ino'));
            if ~isempty(inos)
                filePath = fullfile(inos(1).folder, inos(1).name);
            end
        end
    end

    if ~isfile(filePath)
        error('ESP32:FileNotFound', 'File not found: %s', filePath);
    end

    s = esp32_io('state');
    mode = '';
    target = '';
    injectDaemon = true;
    restoreWifiAfterOta = true;
    nodeRole = 'standalone'; % 'standalone' (0), 'master' (1), 'slave' (2)
    uiTemplate = 'auto';     % 'auto', 'ude' (0), 'agv' (1)

    i = 1;
    while i <= numel(varargin)
        arg = strtrim(char(varargin{i}));
        arg = regexprep(arg, '^["'']|["'']$', '');
        argLower = lower(arg);

        if any(strcmp(argLower, {'--wifi', '-w', 'wifi'}))
            mode = 'wifi';
            if i < numel(varargin) && ~startsWith(char(varargin{i+1}), '-')
                target = strtrim(char(varargin{i+1}));
                i = i + 1;
            end
        elseif any(strcmp(argLower, {'--usb', '-u', 'usb', 'serial'}))
            mode = 'usb';
            if i < numel(varargin) && ~startsWith(char(varargin{i+1}), '-')
                target = upper(strtrim(char(varargin{i+1})));
                i = i + 1;
            end
        elseif any(strcmp(argLower, {'--role', '-r'})) && i < numel(varargin)
            nodeRole = lower(strtrim(char(varargin{i+1})));
            i = i + 1;
        elseif any(strcmp(argLower, {'--master', 'master'}))
            nodeRole = 'master';
        elseif any(strcmp(argLower, {'--slave', 'slave'}))
            nodeRole = 'slave';
        elseif any(strcmp(argLower, {'--ui', '--html', '-h'})) && i < numel(varargin)
            uiTemplate = lower(strtrim(char(varargin{i+1})));
            i = i + 1;
        elseif strcmp(argLower, '--raw')
            injectDaemon = false;
        elseif strcmp(argLower, '--keep-wifi')
            restoreWifiAfterOta = false;
        elseif startsWith(upper(arg), 'COM') || startsWith(arg, '/dev/')
            mode = 'usb';
            target = upper(arg);
        elseif ~isempty(regexp(arg, '^\d+\.\d+\.\d+\.\d+$', 'once'))
            mode = 'wifi';
            target = arg;
        end
        i = i + 1;
    end

    if isempty(mode)
        if strcmp(s.Mode, 'wifi')
            mode = 'wifi';
            target = s.Target;
        elseif strcmp(s.Mode, 'serial')
            mode = 'usb';
            target = s.Target;
        else
            mode = 'wifi';
            target = '192.168.4.1';
        end
    end

    acli = find_arduino_cli();

    if strcmp(mode, 'usb')
        release_matlab_serial_ports(target);
    end

    if isempty(target)
        if strcmp(mode, 'wifi')
            target = '192.168.4.1';
        elseif strcmp(s.Mode, 'serial') && ~isempty(s.Target)
            target = s.Target;
        else
            target = detect_usb_com_port(acli);
        end
    end

    [~, sketchBaseName, ext] = fileparts(filePath);
    if strcmp(uiTemplate, 'auto')
        if contains(lower(sketchBaseName), 'agv')
            uiTemplate = 'agv';
        else
            uiTemplate = 'ude';
        end
    end

    fqbn = 'esp32:esp32:esp32:PartitionScheme=min_spiffs';
    shortName = upper(regexprep(sketchBaseName, '[^a-zA-Z0-9]', ''));
    if strlength(shortName) > 10
        shortName = extractBefore(shortName, 11);
    end
    roleTag = upper(extractBefore([nodeRole '   '], 2));
    buildId = sprintf('BLD_%s_%s_%s', shortName, roleTag, char(datetime('now', 'Format', 'HHmmss')));
    rootDir = fileparts(mfilename('fullpath'));

    buildRoot      = fullfile(tempdir, 'esp32_ota_build');
    sketchDir      = fullfile(buildRoot, 'ota_sketch');
    outBinDir      = fullfile(buildRoot, 'bin');
    lastBuildDir   = fullfile(rootDir, 'firmware', 'build_last');
    outInoPath     = fullfile(sketchDir, 'ota_sketch.ino');
    inspectInoPath = fullfile(lastBuildDir, 'ota_sketch.ino');

    % =========================================================================
    % EXPLICIT 12-STATE DEPLOYMENT FSM CONTEXT
    % =========================================================================
    ctx = struct( ...
        'State',        'RESOLVE_INPUT', ...
        'FilePath',     filePath, ...
        'Ext',          ext, ...
        'Mode',         mode, ...
        'Target',       target, ...
        'NodeRole',     nodeRole, ...
        'UiTemplate',   uiTemplate, ...
        'InjectDaemon', injectDaemon, ...
        'RestoreWifi',  restoreWifiAfterOta, ...
        'PrevWifiSsid', get_current_wifi_ssid(), ...
        'WasConnected', strcmp(s.Mode, 'serial') && strcmpi(s.Target, target), ...
        'BuildId',      buildId, ...
        'BinFile',      '');

    if strcmp(ctx.Mode, 'wifi') && ctx.RestoreWifi && ~isempty(ctx.PrevWifiSsid) && ~strcmpi(ctx.PrevWifiSsid, 'ESP32_LAB')
        wifiCleanup = onCleanup(@() restore_wifi_ssid(ctx.PrevWifiSsid)); %#ok<NASGU>
    end

    success = false;
    while ~ismember(ctx.State, {'FLASH_COMPLETE', 'FLASH_ABORTED'})
        switch ctx.State
            case 'RESOLVE_INPUT'
                esp32_io('trace', 'esp32_flash.m', 'FSM: RESOLVE_INPUT', ...
                    sprintf('Input="%s" | Mode=%s | Target=%s | Role=%s | UI=%s | BuildID=%s', ...
                    ctx.FilePath, upper(ctx.Mode), ctx.Target, upper(ctx.NodeRole), upper(ctx.UiTemplate), ctx.BuildId));

                if strcmpi(ctx.Ext, '.ino')
                    if isfolder(buildRoot)
                        try rmdir(buildRoot, 's'); catch, end
                    end
                    if ~isfolder(sketchDir), mkdir(sketchDir); end
                    if ~isfolder(outBinDir), mkdir(outBinDir); end
                    if ~isfolder(lastBuildDir), mkdir(lastBuildDir); end

                    userCode = fileread(ctx.FilePath);
                    alreadyHasDaemon = contains(userCode, '_bgServer') || contains(userCode, 'server.on("/ota"');
                    if ctx.InjectDaemon && ~alreadyHasDaemon
                        ctx = step_flash_fsm(ctx, 'INJECT_CORE0_DAEMON');
                    else
                        fid = fopen(outInoPath, 'w', 'n', 'UTF-8');
                        fwrite(fid, userCode, 'char');
                        fclose(fid);
                        ctx = step_flash_fsm(ctx, 'COMPILE_ARDUINO_CLI');
                    end
                elseif strcmpi(ctx.Ext, '.bin')
                    ctx.BinFile = ctx.FilePath;
                    sketchDir = '';
                    if strcmp(ctx.Mode, 'wifi')
                        ctx = step_flash_fsm(ctx, 'WIFI_SNAPSHOT_AND_SWITCH');
                    else
                        error('ESP32:BinUsbUnsupported', 'To flash a precompiled .bin via USB, pass the .ino file or use --wifi.');
                    end
                else
                    error('ESP32:UnsupportedExt', 'Unsupported file extension (%s). Use .ino or .bin', ctx.Ext);
                end

            case 'INJECT_CORE0_DAEMON'
                esp32_io('trace', 'esp32_flash.m', 'FSM: INJECT_CORE0_DAEMON', ...
                    sprintf('Merging web_ui.html + web_ui_agv.html + core0_daemon.cpp + %s.ino (Role=%s, DefaultUI=%s)', ...
                    sketchBaseName, upper(ctx.NodeRole), upper(ctx.UiTemplate)));
                fprintf('[FLASH] Concatenating Multi-UI Templates (web_ui.html + web_ui_agv.html + core0_daemon.cpp + %s.ino) [Role=%s | UI=%s | ID=%s]...\n', ...
                    sketchBaseName, upper(ctx.NodeRole), upper(ctx.UiTemplate), ctx.BuildId);
                mergedCode = concatenate_daemon_files(rootDir, fileread(ctx.FilePath), ctx.BuildId, ctx.NodeRole, ctx.UiTemplate);
                fid = fopen(outInoPath, 'w', 'n', 'UTF-8');
                fwrite(fid, mergedCode, 'char');
                fclose(fid);
                fid2 = fopen(inspectInoPath, 'w', 'n', 'UTF-8');
                fwrite(fid2, mergedCode, 'char');
                fclose(fid2);
                ctx = step_flash_fsm(ctx, 'COMPILE_ARDUINO_CLI');

            case 'COMPILE_ARDUINO_CLI'
                compileCmd = sprintf('"%s" compile --fqbn %s --build-property "build.partitions=min_spiffs" --build-property "upload.maximum_size=1966080" --output-dir "%s" "%s"', ...
                    acli, fqbn, outBinDir, sketchDir);
                esp32_io('trace', 'esp32_flash.m', 'FSM: COMPILE_ARDUINO_CLI', ...
                    sprintf('Executing: %s', compileCmd));
                fprintf('[FLASH] Compiling with arduino-cli (PartitionScheme=min_spiffs, Max 1.96MB)...\n');
                [status, cmdout] = system(compileCmd);
                if status ~= 0
                    fprintf(2, '%s\n', cmdout);
                    ctx = step_flash_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:CompileFailed', 'Failed to compile the sketch.');
                end
                fprintf('[FLASH] Compilation successful (Merged source saved to firmware/build_last/ota_sketch.ino).\n');
                ctx.BinFile = fullfile(outBinDir, 'ota_sketch.ino.bin');
                if strcmp(ctx.Mode, 'wifi')
                    ctx = step_flash_fsm(ctx, 'WIFI_SNAPSHOT_AND_SWITCH');
                else
                    ctx = step_flash_fsm(ctx, 'USB_RELEASE_HANDLES');
                end

            case 'USB_RELEASE_HANDLES'
                esp32_io('trace', 'esp32_flash.m', 'FSM: USB_RELEASE_HANDLES', ...
                    sprintf('Releasing MATLAB serialport handles on %s (WasConnected=%d)', ctx.Target, ctx.WasConnected));
                if ctx.WasConnected
                    fprintf('[FLASH] Releasing port %s in MATLAB to allow USB flashing...\n', ctx.Target);
                    esp32_io('disconnect');
                end
                release_matlab_serial_ports(ctx.Target);
                ctx = step_flash_fsm(ctx, 'USB_ESPTOOL_UPLOAD');

            case 'USB_ESPTOOL_UPLOAD'
                upCmd = sprintf('"%s" upload -p %s --fqbn %s --input-dir "%s"', acli, ctx.Target, fqbn, outBinDir);
                esp32_io('trace', 'esp32_flash.m', 'FSM: USB_ESPTOOL_UPLOAD', ...
                    sprintf('Executing USB esptool upload: %s', upCmd));
                fprintf('[FLASH] Flashing via USB on %s...\n', ctx.Target);
                [status, cmdout] = system(upCmd);
                if status ~= 0
                    fprintf(2, '%s\n', cmdout);
                    availPorts = serialportlist("available");
                    ctx = step_flash_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:UsbUploadFailed', ...
                        ['Failed uploading via USB on %s.\n' ...
                         'Available ports right now: %s\n' ...
                         'Run "esp32_cli debug" to inspect all USB/Serial hardware drivers.'], ...
                        ctx.Target, strjoin(availPorts, ', '));
                end
                fprintf('[FLASH] USB flashing completed on %s!\n', ctx.Target);
                ctx = step_flash_fsm(ctx, 'USB_RECONNECT_SESSION');

            case 'USB_RECONNECT_SESSION'
                esp32_io('trace', 'esp32_flash.m', 'FSM: USB_RECONNECT_SESSION', ...
                    sprintf('Waiting 2.0s for ESP32 boot and restoring Serial session (WasConnected=%d)', ctx.WasConnected));
                pause(2.0);
                if ctx.WasConnected
                    esp32_io('connect', ctx.Target);
                end
                ctx = step_flash_fsm(ctx, 'FLASH_COMPLETE');

            case 'WIFI_SNAPSHOT_AND_SWITCH'
                esp32_io('trace', 'esp32_flash.m', 'FSM: WIFI_SNAPSHOT_AND_SWITCH', ...
                    sprintf('Previous SSID="%s" | Connecting Windows WLAN to ESP32_LAB (%s)', ctx.PrevWifiSsid, ctx.Target));
                ensure_wifi_ap_connected(ctx.Target);
                binInfo = dir(ctx.BinFile);
                if binInfo.bytes > 1966080
                    ctx = step_flash_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:BinaryTooLarge', 'Binary size (%d bytes) exceeds min_spiffs OTA partition limit (1966080 bytes).', binInfo.bytes);
                end
                ctx = step_flash_fsm(ctx, 'OTA_PREFLIGHT_PREP');

            case 'OTA_PREFLIGHT_PREP'
                esp32_io('trace', 'esp32_flash.m', 'FSM: OTA_PREFLIGHT_PREP', ...
                    sprintf('Sending GET http://%s/cmd?q=OTA_PREP to stop BT SPP radio and free heap', ctx.Target));
                try
                    optsPrep = weboptions('Timeout', 3.0, 'ContentType', 'text');
                    prepResp = strtrim(char(webread(sprintf('http://%s/cmd?q=OTA_PREP', ctx.Target), optsPrep)));
                    fprintf('[FLASH] Pre-flight OTA_PREP on %s -> %s\n', ctx.Target, prepResp);
                    pause(0.25);
                catch
                end
                ctx = step_flash_fsm(ctx, 'OTA_CURL_MULTIPART');

            case 'OTA_CURL_MULTIPART'
                binInfo = dir(ctx.BinFile);
                curlCmd = sprintf('curl.exe -s -S --http1.1 -H "Expect:" --connect-timeout 8 --max-time 120 -F "image=@%s" http://%s/ota 2>&1', ...
                    ctx.BinFile, ctx.Target);
                esp32_io('trace', 'esp32_flash.m', 'FSM: OTA_CURL_MULTIPART', ...
                    sprintf('Streaming %d bytes via HTTP POST /ota: %s', binInfo.bytes, curlCmd));
                fprintf('[FLASH] Uploading binary (%s, %.2f MB) via Wi-Fi OTA to http://%s/ota ...\n', ...
                    ctx.BinFile, binInfo.bytes / 1e6, ctx.Target);

                [status, resp] = system(curlCmd);
                isExpectedRebootDrop = contains(resp, 'Empty reply from server') || ...
                                       contains(resp, 'Recv failure') || status == 52 || status == 56;

                if status ~= 0 && ~contains(resp, 'OTA_OK') && ~isExpectedRebootDrop
                    ctx = step_flash_fsm(ctx, 'FLASH_ABORTED');
                    error('ESP32:OtaFailed', ...
                        ['Wi-Fi OTA upload failed (%s).\n' ...
                         'TIP: Flash the updated base firmware ONCE over USB ("esp32_cli flash <sketch.ino> --usb") ' ...
                         'so the chip gets the fast Core-0 OTA daemon and min_spiffs partition table.'], strtrim(resp));
                end
                fprintf('[FLASH] Wi-Fi OTA completed (%s)! ESP32 is rebooting (waiting 3.5s)...\n', strtrim(resp));
                ctx = step_flash_fsm(ctx, 'OTA_REBOOT_SETTLE');

            case 'OTA_REBOOT_SETTLE'
                esp32_io('trace', 'esp32_flash.m', 'FSM: OTA_REBOOT_SETTLE', ...
                    'Waiting 3.5s for ESP32 bootloader to switch OTA partition and boot new image');
                pause(3.5);
                if ctx.RestoreWifi
                    ctx = step_flash_fsm(ctx, 'WIFI_RESTORE_HOST');
                else
                    ensure_wifi_ap_connected(ctx.Target);
                    ctx = step_flash_fsm(ctx, 'FLASH_COMPLETE');
                end

            case 'WIFI_RESTORE_HOST'
                esp32_io('trace', 'esp32_flash.m', 'FSM: WIFI_RESTORE_HOST', ...
                    sprintf('Restoring host PC Wi-Fi network back to "%s"', ctx.PrevWifiSsid));
                restore_wifi_ssid(ctx.PrevWifiSsid);
                ctx = step_flash_fsm(ctx, 'FLASH_COMPLETE');
        end
    end

    success = strcmp(ctx.State, 'FLASH_COMPLETE');
    esp32_io('trace', 'esp32_flash.m', 'FSM: FLASH_COMPLETE', ...
        sprintf('Deployment finished: Success=%d | BuildID=%s', success, ctx.BuildId));
end

function ctx = step_flash_fsm(ctx, nextState)
    esp32_io('trace', 'esp32_flash.m', sprintf('FSM: %s -> %s', ctx.State, nextState), ...
        sprintf('Transitioning deployment state machine to %s', nextState));
    ctx.State = nextState;
end

function merged = concatenate_daemon_files(rootDir, userCode, buildId, nodeRole, uiTemplate)
    if isempty(strtrim(userCode))
        error('ESP32:EmptySketch', 'The specified .ino file is empty (0 bytes).');
    end
    modifiedUser = regexprep(userCode, '\<void\s+setup\s*\(\s*(void)?\s*\)', 'void user_setup()', 'once');
    if ~contains(modifiedUser, 'user_setup')
        modifiedUser = [modifiedUser newline 'void user_setup() {}' newline];
    end
    if isempty(regexp(modifiedUser, '\<void\s+loop\s*\(\s*(void)?\s*\)', 'once'))
        modifiedUser = [modifiedUser newline 'void loop() { delay(100); }' newline];
    end

    daemonDir  = fullfile(rootDir, 'firmware', 'core0_daemon');
    htmlUdePath = fullfile(daemonDir, 'web_ui.html');
    htmlAgvPath = fullfile(daemonDir, 'web_ui_agv.html');
    cppPath     = fullfile(daemonDir, 'core0_daemon.cpp');

    if ~isfile(htmlUdePath) || ~isfile(cppPath)
        error('ESP32:MissingDaemonFiles', ...
            'Modular daemon files not found in %s. Please ensure web_ui.html and core0_daemon.cpp exist.', daemonDir);
    end

    webUdeHtml = strrep(fileread(htmlUdePath), '{{FW_BUILD_ID}}', char(buildId));
    if isfile(htmlAgvPath)
        webAgvHtml = strrep(fileread(htmlAgvPath), '{{FW_BUILD_ID}}', char(buildId));
    else
        webAgvHtml = webUdeHtml;
    end

    roleId = '0';
    if strcmpi(nodeRole, 'master'), roleId = '1';
    elseif strcmpi(nodeRole, 'slave'), roleId = '2';
    end

    uiId = '0';
    if any(strcmpi(uiTemplate, {'agv', 'cockpit', '1'})), uiId = '1'; end

    cppTemplate = fileread(cppPath);
    merged = strrep(cppTemplate, '{{FW_BUILD_ID}}', char(buildId));
    merged = strrep(merged, '{{NODE_ROLE_ID}}', roleId);
    merged = strrep(merged, '{{DEFAULT_UI_ID}}', uiId);
    merged = strrep(merged, '{{WEB_UI_UDE_HTML}}', webUdeHtml);
    merged = strrep(merged, '{{WEB_UI_AGV_HTML}}', webAgvHtml);
    % Backwards compatibility if {{WEB_UI_HTML}} placeholder is present
    merged = strrep(merged, '{{WEB_UI_HTML}}', ternary_str(strcmp(uiId, '1'), webAgvHtml, webUdeHtml));
    merged = strrep(merged, '{{USER_SKETCH_CODE}}', modifiedUser);
end

function out = ternary_str(cond, a, b)
    if cond, out = a; else, out = b; end
end

function ssid = get_current_wifi_ssid()
    ssid = '';
    if ~ispc, return; end
    [~, wOut] = system('netsh wlan show interfaces');
    tok = regexp(wOut, 'Profile\s*:\s*([^\r\n]+)', 'tokens', 'once');
    if isempty(tok)
        tok = regexp(wOut, 'SSID\s*:\s*([^\r\n]+)', 'tokens', 'once');
    end
    if ~isempty(tok)
        ssid = strtrim(tok{1});
    end
end

function restore_wifi_ssid(prevSsid)
    if isempty(prevSsid) || strcmpi(prevSsid, 'ESP32_LAB') || ~ispc
        return;
    end
    curr = get_current_wifi_ssid();
    if strcmpi(curr, prevSsid)
        return;
    end
    fprintf('[WIFI] Restoring Windows Wi-Fi back to "%s"...\n', prevSsid);
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prevSsid));
    for k = 1:8
        pause(1.0);
        if strcmpi(get_current_wifi_ssid(), prevSsid)
            fprintf('[WIFI] Reconnected to "%s"!\n', prevSsid);
            return;
        end
        system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prevSsid));
    end
end

function ok = is_esp32_ap_pingable(target)
    [st, pOut] = system(sprintf('ping -n 1 -w 600 %s', target));
    ok = (st == 0) && contains(pOut, 'TTL=', 'IgnoreCase', true);
end

function ensure_wifi_ap_connected(target)
    if ~strcmp(target, '192.168.4.1') || ~ispc
        return;
    end
    [~, wlanInfo] = system('netsh wlan show interfaces');
    if contains(wlanInfo, 'ESP32_LAB') && is_esp32_ap_pingable(target)
        return;
    end
    fprintf('[FLASH] Switching Windows WLAN to "ESP32_LAB" (192.168.4.1)...\n');
    xmlProfile = [ ...
        '<?xml version="1.0"?>' newline ...
        '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">' newline ...
        '  <name>ESP32_LAB</name>' newline ...
        '  <SSIDConfig><SSID><name>ESP32_LAB</name></SSID></SSIDConfig>' newline ...
        '  <connectionType>ESS</connectionType>' newline ...
        '  <connectionMode>manual</connectionMode>' newline ...
        '  <MSM><security><authEncryption>' newline ...
        '    <authentication>WPA2PSK</authentication>' newline ...
        '    <encryption>AES</encryption>' newline ...
        '    <useOneX>false</useOneX>' newline ...
        '  </authEncryption><sharedKey>' newline ...
        '    <keyType>passPhrase</keyType>' newline ...
        '    <protected>false</protected>' newline ...
        '    <keyMaterial>12345678</keyMaterial>' newline ...
        '  </sharedKey></security></MSM>' newline ...
        '</WLANProfile>'];
    xmlPath = fullfile(tempdir, 'esp32_lab_profile.xml');
    fid = fopen(xmlPath, 'w');
    fwrite(fid, xmlProfile, 'char');
    fclose(fid);
    system(sprintf('netsh wlan add profile filename="%s" >nul 2>&1', xmlPath));
    system('netsh wlan connect name="ESP32_LAB" >nul 2>&1');
    for k = 1:10
        pause(1.0);
        [~, wOut] = system('netsh wlan show interfaces');
        if contains(wOut, 'ESP32_LAB') && is_esp32_ap_pingable(target)
            fprintf('[FLASH] Connected to "ESP32_LAB" (192.168.4.1 reachable with TTL)!\n');
            return;
        end
        system('netsh wlan connect name="ESP32_LAB" >nul 2>&1');
    end
    warning('ESP32:WiFiNotReachable', 'Could not ping 192.168.4.1. Make sure ESP32 is powered and broadcasting "ESP32_LAB".');
end

function release_matlab_serial_ports(targetPort)
    try
        if exist('serialportfind', 'file') || exist('serialportfind', 'builtin')
            if isempty(targetPort)
                objs = serialportfind();
            else
                objs = serialportfind('Port', upper(string(targetPort)));
            end
            for k = 1:numel(objs)
                try
                    fprintf('[FLASH] Closing open MATLAB serial handle on %s...\n', objs(k).Port);
                    delete(objs(k));
                catch
                end
            end
        end
    catch
    end
end

function acli = find_arduino_cli()
    [st, ~] = system('where arduino-cli >nul 2>&1');
    if st == 0
        acli = 'arduino-cli';
        return;
    end
    defaultPath = 'C:\Program Files\Arduino CLI\arduino-cli.exe';
    if isfile(defaultPath)
        acli = defaultPath;
    else
        error('ESP32:NoArduinoCLI', 'arduino-cli was not found. Please verify your installation.');
    end
end

function usbPort = detect_usb_com_port(acli)
    [~, out] = system(sprintf('"%s" board list 2>nul', acli));
    lines = splitlines(string(strtrim(out)));
    for k = 1:numel(lines)
        if contains(lines(k), "Serial Port (USB)", "IgnoreCase", true)
            tok = split(strtrim(lines(k)));
            usbPort = char(tok(1));
            fprintf('[FLASH] Auto-detected physical USB ESP32 port (via arduino-cli): %s\n', usbPort);
            return;
        end
    end
    avail = serialportlist("available");
    if ~isempty(avail)
        usbPort = char(avail(1));
    else
        error('ESP32:NoUsbPortDetected', 'No physical ESP32 USB UART port was detected!');
    end
end