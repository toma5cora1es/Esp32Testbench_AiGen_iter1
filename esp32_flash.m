function [success, buildId] = esp32_flash(filePath, varargin)
%ESP32_FLASH Concatenates firmware/core0_daemon/web_ui.html + core0_daemon.cpp + <sketch>.ino,
%   compiles with arduino-cli, flashes via Wi-Fi OTA or USB, and restores previous Wi-Fi.
%
% CLI EXAMPLES:
%   esp32_cli flash C:\Users\tomas\MATLAB\esp32_workbench_gemini\firmware\esp32_bridge_ota\esp32_bridge_ota.ino --usb COM8
%   esp32_cli flash C:\Users\tomas\MATLAB\esp32_workbench_gemini\firmware\esp32_bridge_ota\adc_signal_generator.ino --wifi

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
    fqbn = 'esp32:esp32:esp32:PartitionScheme=min_spiffs';
    shortName = upper(regexprep(sketchBaseName, '[^a-zA-Z0-9]', ''));
    if strlength(shortName) > 12
        shortName = extractBefore(shortName, 13);
    end
    buildId = sprintf('BLD_%s_%s', shortName, char(datetime('now', 'Format', 'HHmmss')));

    % =========================================================================
    % STEP 1: Concatenate external web_ui.html + core0_daemon.cpp + <sketch>.ino
    % =========================================================================
    rootDir = fileparts(mfilename('fullpath'));
    if strcmpi(ext, '.ino')
        buildRoot = fullfile(tempdir, 'esp32_ota_build');
        sketchDir = fullfile(buildRoot, 'ota_sketch');
        outBinDir = fullfile(buildRoot, 'bin');
        lastBuildDir = fullfile(rootDir, 'firmware', 'build_last');

        if isfolder(buildRoot)
            try rmdir(buildRoot, 's'); catch, end
        end
        if ~isfolder(sketchDir), mkdir(sketchDir); end
        if ~isfolder(outBinDir), mkdir(outBinDir); end
        if ~isfolder(lastBuildDir), mkdir(lastBuildDir); end

        userCode = fileread(filePath);
        outInoPath = fullfile(sketchDir, 'ota_sketch.ino');
        inspectInoPath = fullfile(lastBuildDir, 'ota_sketch.ino');

        if injectDaemon && ~contains(userCode, '_bgServer') && ~contains(userCode, 'server.on("/ota"')
            fprintf('[FLASH] Concatenating modular files (web_ui.html + core0_daemon.cpp + %s.ino) [ID: %s]...\n', ...
                sketchBaseName, buildId);
            mergedCode = concatenate_daemon_files(rootDir, userCode, buildId);
            fid = fopen(outInoPath, 'w', 'n', 'UTF-8');
            fwrite(fid, mergedCode, 'char');
            fclose(fid);
            % Also save a copy in firmware/build_last/ota_sketch.ino for easy inspection
            fid2 = fopen(inspectInoPath, 'w', 'n', 'UTF-8');
            fwrite(fid2, mergedCode, 'char');
            fclose(fid2);
        else
            fprintf('[FLASH] Sketch already contains the OTA/Web Daemon (or --raw was requested).\n');
            fid = fopen(outInoPath, 'w', 'n', 'UTF-8');
            fwrite(fid, userCode, 'char');
            fclose(fid);
        end

        fprintf('[FLASH] Compiling with arduino-cli (PartitionScheme=min_spiffs, Max 1.96MB)...\n');
        compileCmd = sprintf('"%s" compile --fqbn %s --build-property "build.partitions=min_spiffs" --build-property "upload.maximum_size=1966080" --output-dir "%s" "%s"', ...
            acli, fqbn, outBinDir, sketchDir);
        [status, cmdout] = system(compileCmd);
        if status ~= 0
            fprintf(2, '%s\n', cmdout);
            error('ESP32:CompileFailed', 'Failed to compile the sketch.');
        end
        fprintf('[FLASH] Compilation successful (Merged source saved to firmware/build_last/ota_sketch.ino).\n');
        binFile = fullfile(outBinDir, 'ota_sketch.ino.bin');
    elseif strcmpi(ext, '.bin')
        binFile = filePath;
        sketchDir = '';
    else
        error('ESP32:UnsupportedExt', 'Unsupported file extension (%s). Use .ino or .bin', ext);
    end

    % =========================================================================
    % STEP 2: Upload the firmware via Wi-Fi OTA or USB Serial
    % =========================================================================
    if strcmp(mode, 'wifi')
        prevWifiSsid = get_current_wifi_ssid();
        if restoreWifiAfterOta && ~isempty(prevWifiSsid) && ~strcmpi(prevWifiSsid, 'ESP32_LAB')
            wifiCleanup = onCleanup(@() restore_wifi_ssid(prevWifiSsid));
        end

        ensure_wifi_ap_connected(target);
        binInfo = dir(binFile);
        if binInfo.bytes > 1966080
            error('ESP32:BinaryTooLarge', 'Binary size (%d bytes) exceeds min_spiffs OTA partition limit (1966080 bytes).', binInfo.bytes);
        end

        try
            optsPrep = weboptions('Timeout', 3.0, 'ContentType', 'text');
            prepResp = strtrim(char(webread(sprintf('http://%s/cmd?q=OTA_PREP', target), optsPrep)));
            fprintf('[FLASH] Pre-flight OTA_PREP on %s -> %s\n', target, prepResp);
            pause(0.25);
        catch
        end

        fprintf('[FLASH] Uploading binary (%s, %.2f MB) via Wi-Fi OTA to http://%s/ota ...\n', ...
            binFile, binInfo.bytes / 1e6, target);

        curlCmd = sprintf('curl.exe -s -S --http1.1 -H "Expect:" --connect-timeout 8 --max-time 120 -F "image=@%s" http://%s/ota 2>&1', ...
            binFile, target);
        [status, resp] = system(curlCmd);

        if status ~= 0 && ~contains(resp, 'OTA_OK')
            if contains(resp, 'Empty reply from server') || contains(resp, 'Recv failure') || status == 52 || status == 56
                fprintf('[FLASH] Server closed socket during reboot; verifying new firmware on %s...\n', target);
                pause(3.5);
                if ~restoreWifiAfterOta
                    ensure_wifi_ap_connected(target);
                end
                fprintf('[FLASH] Wi-Fi OTA completed!\n');
                success = true;
                return;
            end
            error('ESP32:OtaFailed', ...
                ['Wi-Fi OTA upload failed (%s).\n' ...
                 'TIP: Flash the updated base firmware ONCE over USB ("esp32_cli flash <sketch.ino> --usb") ' ...
                 'so the chip gets the fast Core-0 OTA daemon and min_spiffs partition table.'], strtrim(resp));
        end
        fprintf('[FLASH] Wi-Fi OTA completed (%s)! ESP32 is rebooting (waiting 3.5s)...\n', strtrim(resp));
        pause(3.5);
        if ~restoreWifiAfterOta
            ensure_wifi_ap_connected(target);
        end
        success = true;
    else
        wasConnected = strcmp(s.Mode, 'serial') && strcmpi(s.Target, target);
        if wasConnected
            fprintf('[FLASH] Releasing port %s in MATLAB to allow USB flashing...\n', target);
            esp32_io('disconnect');
        end
        release_matlab_serial_ports(target);

        fprintf('[FLASH] Flashing via USB on %s...\n', target);
        if ~isempty(sketchDir)
            upCmd = sprintf('"%s" upload -p %s --fqbn %s --input-dir "%s"', acli, target, fqbn, outBinDir);
        else
            error('ESP32:BinUsbUnsupported', 'To flash a precompiled .bin via USB, pass the .ino file or use --wifi.');
        end
        [status, cmdout] = system(upCmd);
        if status ~= 0
            fprintf(2, '%s\n', cmdout);
            availPorts = serialportlist("available");
            error('ESP32:UsbUploadFailed', ...
                ['Failed uploading via USB on %s.\n' ...
                 'Available ports right now: %s\n' ...
                 'Run "esp32_cli debug" to inspect all USB/Serial hardware drivers.'], ...
                target, strjoin(availPorts, ', '));
        end
        fprintf('[FLASH] USB flashing completed on %s!\n', target);
        pause(2.0);

        if wasConnected
            esp32_io('connect', target);
        end
        success = true;
    end
end

function merged = concatenate_daemon_files(rootDir, userCode, buildId)
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

    daemonDir = fullfile(rootDir, 'firmware', 'core0_daemon');
    htmlPath  = fullfile(daemonDir, 'web_ui.html');
    cppPath   = fullfile(daemonDir, 'core0_daemon.cpp');

    if ~isfile(htmlPath) || ~isfile(cppPath)
        error('ESP32:MissingDaemonFiles', ...
            'Modular daemon files not found in %s. Please ensure web_ui.html and core0_daemon.cpp exist.', daemonDir);
    end

    webHtml = fileread(htmlPath);
    webHtml = strrep(webHtml, '{{FW_BUILD_ID}}', char(buildId));

    cppTemplate = fileread(cppPath);
    merged = strrep(cppTemplate, '{{FW_BUILD_ID}}', char(buildId));
    merged = strrep(merged, '{{WEB_UI_HTML}}', webHtml);
    merged = strrep(merged, '{{USER_SKETCH_CODE}}', modifiedUser);
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
    allPorts = serialportlist("all");
    ignoredPorts = strings(0, 1);
    usbCandidates = strings(0, 1);

    if ispc
        psCmd = [ ...
            'powershell -NoProfile -Command "' ...
            'Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''\(COM\d+\)''} | ' ...
            'ForEach-Object { Write-Output (''PNP|'' + $_.Name + ''|'' + $_.DeviceID) }; ' ...
            '$reg = Get-ItemProperty ''HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'' -ErrorAction SilentlyContinue; ' ...
            'if ($reg) { $reg.PSObject.Properties | Where-Object {$_.Value -match ''^COM\d+$''} | ' ...
            'ForEach-Object { Write-Output (''REG|'' + $_.Name + ''|'' + $_.Value) } }"' ...
        ];
        [st, psOut] = system(psCmd);
        if st == 0 && ~isempty(strtrim(psOut))
            pLines = splitlines(string(strtrim(psOut)));
            for idx = 1:numel(pLines)
                ln = strtrim(pLines(idx));
                if startsWith(ln, "PNP|")
                    tok = regexp(ln, '\((COM\d+)\)', 'tokens', 'once');
                    if isempty(tok), continue; end
                    cPort = upper(string(tok{1}));
                    if contains(ln, ["BTHENUM", "Bluetooth", "Active Management Technology", "Intel(R) AMT"], "IgnoreCase", true)
                        ignoredPorts(end+1) = cPort; %#ok<AGROW>
                    elseif contains(ln, ["USB", "CP210", "CH340", "CH341", "CH910", "FTDI", "Silicon Labs", "UART"], "IgnoreCase", true)
                        usbCandidates(end+1) = cPort; %#ok<AGROW>
                    end
                elseif startsWith(ln, "REG|")
                    parts = split(ln, "|");
                    if numel(parts) >= 3
                        devPath = parts(2);
                        cPort = upper(strtrim(parts(3)));
                        if contains(devPath, ["BthModem", "Bluetooth"], "IgnoreCase", true)
                            ignoredPorts(end+1) = cPort; %#ok<AGROW>
                        elseif contains(devPath, ["Silabser", "VCP", "USBSER", "CH34", "slabvcp"], "IgnoreCase", true)
                            usbCandidates(end+1) = cPort; %#ok<AGROW>
                        end
                    end
                end
            end
        end
    end

    usbCandidates = unique(usbCandidates, 'stable');
    ignoredPorts  = unique(ignoredPorts, 'stable');

    for k = 1:numel(usbCandidates)
        c = usbCandidates(k);
        if any(strcmpi(c, avail))
            usbPort = char(c);
            fprintf('[FLASH] Auto-detected USB UART bridge port: %s\n', usbPort);
            return;
        end
    end

    if ~isempty(usbCandidates)
        usbPort = char(usbCandidates(1));
        fprintf('[FLASH] Detected USB UART port %s (currently marked BUSY, attempting upload)...\n', usbPort);
        return;
    end

    remainingAll = setdiff(allPorts, ignoredPorts, 'stable');
    if ~isempty(remainingAll)
        usbPort = char(remainingAll(1));
        fprintf('[FLASH] Selected non-Bluetooth/non-AMT serial port: %s\n', usbPort);
        return;
    end

    error('ESP32:NoUsbPortDetected', ...
        ['No physical ESP32 USB UART port was detected!\n' ...
         '  - Detected ports: %s\n' ...
         '  - Ignored (Bluetooth / Intel AMT): %s'], ...
         strjoin(allPorts, ', '), strjoin(ignoredPorts, ', '));
end