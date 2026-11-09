function out = esp32_io(action, varargin)
%ESP32_IO Low-level non-blocking transport layer (USB Serial / Bluetooth SPP / Wi-Fi HTTP).
%   Internal use by esp32_cli.m, esp32.m, and esp32_gui.m.
%
%   SUPPORTED TARGET FORMATS FOR 'connect':
%     - 'COM9' or '/dev/ttyUSB0'     -> Serial port (USB or OS-mapped Bluetooth Virtual COM)
%     - 'bt:ESP32_BT_BRIDGE'         -> Native MATLAB Bluetooth SPP connection by device name
%     - 'ESP32_BT_BRIDGE'            -> Auto-detected as Bluetooth SPP device name
%     - 'AA:BB:CC:DD:EE:FF'          -> Auto-detected as Bluetooth MAC address
%     - '192.168.4.1'                -> Wi-Fi HTTP Bridge (auto-connects Windows WLAN to ESP32_LAB)

    s = get_state();

    switch lower(action)
        case 'state'
            out = s;

        case 'connect'
            if isempty(varargin) || isempty(varargin{1})
                target = auto_pick_serial_port();
            else
                target = strtrim(char(varargin{1}));
            end
            esp32_io('disconnect'); % Clean up any previous session
            s = get_state();

            forceBt = false;
            if numel(varargin) >= 2 && ischar(varargin{2}) && any(strcmpi(varargin{2}, {'--bt', 'bt', 'bluetooth'}))
                forceBt = true;
            end

            isSerialPort = startsWith(upper(target), 'COM') || startsWith(target, '/dev/');
            isIpv4 = ~isempty(regexp(target, '^(https?://)?\d+\.\d+\.\d+\.\d+', 'once'));
            isBtMac = ~isempty(regexp(target, '^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$', 'once'));
            hasBtPrefix = startsWith(lower(target), 'bt:') || startsWith(lower(target), 'bluetooth:');

            if isSerialPort && ~forceBt
                % --- 1. Serial Connection (USB Cable or Bluetooth Virtual COM Port) ---
                baud = 115200;
                if numel(varargin) >= 2 && isnumeric(varargin{2}) && ~isempty(varargin{2})
                    baud = double(varargin{2});
                end
                sp = serialport(target, baud, 'Timeout', 1.5);
                configureTerminator(sp, "LF");
                flush(sp);
                pause(0.15);
                flush(sp);
                s.Mode = 'serial';
                s.Target = upper(target);
                s.SerialObj = sp;
                set_state(s);
                resp = esp32_io('cmd', 'STATUS');
                fprintf('[ESP32] Connected via Serial on %s -> %s\n', s.Target, resp);
                out = true;

            elseif hasBtPrefix || isBtMac || forceBt || (~isIpv4 && ~contains(target, '.'))
                % --- 2. Native Bluetooth Classic (SPP) Connection ---
                btTarget = regexprep(target, '^(?i)(bt:|bluetooth:)', '');
                btTarget = strtrim(btTarget);
                if isempty(btTarget)
                    btTarget = 'ESP32_BT_BRIDGE';
                end
                channel = 1;
                if numel(varargin) >= 2 && isnumeric(varargin{2}) && ~isempty(varargin{2})
                    channel = double(varargin{2});
                end

                fprintf('[ESP32] Connecting via Bluetooth SPP to "%s" (Channel %d)...\n', btTarget, channel);
                try
                    btObj = bluetooth(btTarget, channel, 'Timeout', 3.0);
                catch ME
                    error('ESP32:BluetoothConnectFailed', ...
                        ['Could not connect via Bluetooth to "%s" (%s).\n' ...
                         'Make sure the ESP32 is powered on, paired in your OS Bluetooth settings,\n' ...
                         'or connect using its Virtual COM port (e.g., esp32_cli connect COM11).'], ...
                        btTarget, ME.message);
                end
                configureTerminator(btObj, "LF");
                flush(btObj);
                pause(0.15);
                flush(btObj);

                s.Mode = 'bluetooth';
                s.Target = btTarget;
                s.SerialObj = btObj;
                set_state(s);
                resp = esp32_io('cmd', 'STATUS');
                fprintf('[ESP32] Connected via Bluetooth SPP (%s) -> %s\n', s.Target, resp);
                out = true;

            else
                % --- 3. Wi-Fi HTTP Connection ---
                ip = regexprep(target, '^https?://', '');
                ip = regexprep(ip, '/.*$', '');
                if strcmp(ip, '192.168.4.1') && ispc
                    ensure_esp32_lab_wifi_connected();
                end
                s.Mode = 'wifi';
                s.Target = ip;
                s.SerialObj = [];
                set_state(s);
                resp = esp32_io('cmd', 'STATUS');
                fprintf('[ESP32] Connected via Wi-Fi at http://%s -> %s\n', s.Target, resp);
                out = true;
            end

        case 'disconnect'
            if ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                try
                    flush(s.SerialObj);
                    delete(s.SerialObj);
                catch
                end
            end
            s.Mode = 'none';
            s.Target = '';
            s.SerialObj = [];
            s.Busy = false;
            set_state(s);
            out = true;

        case 'cmd'
            rawCmd = strtrim(char(varargin{1}));
            if strcmp(s.Mode, 'none')
                error('ESP32:NotConnected', ...
                    'No active connection. Run first: esp32_cli connect COM9, esp32_cli connect ESP32_BT_BRIDGE, or esp32_cli connect 192.168.4.1');
            end
            if s.Busy
                out = 'BUSY';
                return;
            end
            s.Busy = true;
            set_state(s);

            try
                if any(strcmp(s.Mode, {'serial', 'bluetooth'}))
                    if isempty(s.SerialObj) || ~isvalid(s.SerialObj)
                        error('ESP32:PortClosed', 'The %s connection (%s) closed unexpectedly.', s.Mode, s.Target);
                    end
                    flush(s.SerialObj);
                    writeline(s.SerialObj, rawCmd);
                    out = strtrim(char(readline(s.SerialObj)));
                    while startsWith(out, 'ets ') || startsWith(out, 'rst:') || ...
                          startsWith(out, 'mode:') || startsWith(out, 'load:') || ...
                          startsWith(out, 'entry ') || strcmp(out, 'ESP32_READY')
                        out = strtrim(char(readline(s.SerialObj)));
                    end
                elseif strcmp(s.Mode, 'wifi')
                    opts = weboptions('Timeout', 2.0, 'ContentType', 'text');
                    url = sprintf('http://%s/cmd?q=%s', s.Target, urlencode(rawCmd));
                    try
                        out = strtrim(char(webread(url, opts)));
                    catch
                        out = fallback_legacy_wifi(s.Target, rawCmd, opts);
                    end
                end
            catch ME
                s.Busy = false;
                set_state(s);
                rethrow(ME);
            end

            s.Busy = false;
            set_state(s);
    end
end

function port = auto_pick_serial_port()
    [~, out] = system('arduino-cli board list 2>nul');
    lines = splitlines(string(strtrim(out)));
    for k = 1:numel(lines)
        if contains(lines(k), "Serial Port (USB)", "IgnoreCase", true)
            tok = split(strtrim(lines(k)));
            port = char(tok(1));
            return;
        end
    end
    avail = serialportlist("available");
    if ~isempty(avail)
        port = char(avail(1));
    else
        error('ESP32:NoPort', 'Usage: esp32_cli connect <COMx | 192.168.4.1 | ESP32_BT_BRIDGE>');
    end
end

function ensure_esp32_lab_wifi_connected()
    [~, wlanInfo] = system('netsh wlan show interfaces');
    if contains(wlanInfo, 'ESP32_LAB')
        return;
    end
    fprintf('[ESP32] Switching Windows Wi-Fi to "ESP32_LAB" (Password: 12345678)...\n');
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
    for attempt = 1:8
        pause(1.0);
        [~, wOut] = system('netsh wlan show interfaces');
        if contains(wOut, 'ESP32_LAB')
            pause(1.0);
            return;
        end
        system('netsh wlan connect name="ESP32_LAB" >nul 2>&1');
    end
    warning('ESP32:WifiNotConnected', ...
        'Windows did not automatically switch to "ESP32_LAB". Please select "ESP32_LAB" (Password: 12345678) in the Windows Wi-Fi tray.');
end

function out = fallback_legacy_wifi(ip, rawCmd, ~)
    optsJson = weboptions('Timeout', 2.0, 'ContentType', 'json');
    tokens = strsplit(strtrim(rawCmd));
    op = upper(tokens{1});
    if strcmp(op, 'STATUS')
        res = webread(sprintf('http://%s/', ip), optsJson);
        out = sprintf('%s|IP:%s', res.status, res.ip);
    elseif strcmp(op, 'R') && numel(tokens) >= 2
        res = webread(sprintf('http://%s/reg?addr=%s', ip, tokens{2}), optsJson);
        out = char(res.value);
    elseif strcmp(op, 'W') && numel(tokens) >= 3
        res = webread(sprintf('http://%s/reg?addr=%s&val=%s', ip, tokens{2}, tokens{3}), optsJson);
        out = char(res.value);
    else
        error('ESP32:WifiTimeout', 'Wi-Fi communication failed with %s for command "%s".', ip, rawCmd);
    end
end

function s = get_state()
    if isappdata(0, 'ESP32_WORKBENCH_STATE')
        s = getappdata(0, 'ESP32_WORKBENCH_STATE');
    else
        s = struct('Mode', 'none', 'Target', '', 'SerialObj', [], 'Busy', false);
        setappdata(0, 'ESP32_WORKBENCH_STATE', s);
    end
end

function set_state(s)
    setappdata(0, 'ESP32_WORKBENCH_STATE', s);
end