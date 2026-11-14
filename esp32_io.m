function [out, latencyMs] = esp32_io(action, varargin)
%ESP32_IO Low-level non-blocking transport layer (USB Serial / Bluetooth SPP / Wi-Fi HTTP).
%   Supports actions: 'state', 'connect', 'disconnect', 'cmd' (aliases: 'send', 'raw', 'exec')

    s = get_state();
    out = '';
    latencyMs = 0;

    if nargin < 1 || isempty(action)
        action = 'state';
    end

    switch lower(strtrim(char(action)))
        case 'state'
            out = s;

        case 'connect'
            if isempty(varargin) || isempty(varargin{1})
                target = auto_pick_serial_port();
            else
                target = strtrim(char(varargin{1}));
            end

            forceBt = false;
            if numel(varargin) >= 2 && (ischar(varargin{2}) || isstring(varargin{2})) && ...
                    any(strcmpi(char(varargin{2}), {'--bt', 'bt', 'bluetooth'}))
                forceBt = true;
            end

            isSerialPort = startsWith(upper(target), 'COM') || startsWith(target, '/dev/');
            isIpv4 = ~isempty(regexp(target, '^(https?://)?\d+\.\d+\.\d+\.\d+', 'once'));
            isBtMac = ~isempty(regexp(target, '^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$', 'once'));
            hasBtPrefix = startsWith(lower(target), 'bt:') || startsWith(lower(target), 'bluetooth:');

            if isSerialPort && ~forceBt
                % Reuse existing open Serial handle if already connected to the same COM port
                % (Prevents CH340 DTR auto-reset from rebooting the ESP32 and dropping Wi-Fi SoftAP!)
                if strcmp(s.Mode, 'serial') && strcmpi(s.Target, target) && ...
                        ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                    try
                        s.Busy = false;
                        set_state(s);
                        [resp, latencyMs] = esp32_io('cmd', 'STATUS');
                        if contains(resp, 'ESP32_READY')
                            out = true;
                            return;
                        end
                    catch
                    end
                end

                esp32_io('disconnect');
                s = get_state();
                baud = 115200;
                if numel(varargin) >= 2 && isnumeric(varargin{2}) && ~isempty(varargin{2})
                    baud = double(varargin{2});
                end
                release_existing_port(target);
                sp = serialport(target, baud, 'Timeout', 2.0);
                configureTerminator(sp, "LF");
                pause(0.35);
                flush(sp);
                s.Mode = 'serial';
                s.Target = upper(target);
                s.SerialObj = sp;
                set_state(s);

                resp = '';
                for attempt = 1:3
                    try
                        [resp, latencyMs] = esp32_io('cmd', 'STATUS');
                        if contains(resp, 'ESP32_READY')
                            break;
                        end
                    catch
                        pause(0.5);
                    end
                end
                fprintf('[ESP32] Connected via Serial on %s (%.1f ms) -> %s\n', s.Target, latencyMs, resp);
                out = true;

            elseif hasBtPrefix || isBtMac || forceBt || (~isIpv4 && ~contains(target, '.'))
                esp32_io('disconnect');
                s = get_state();
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
                         'Note: If OTA_PREP was recently run, reboot the ESP32 to re-enable Bluetooth SPP.'], ...
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
                [resp, latencyMs] = esp32_io('cmd', 'STATUS');
                fprintf('[ESP32] Connected via Bluetooth SPP (%s, %.1f ms) -> %s\n', s.Target, latencyMs, resp);
                out = true;

            else
                % Switching to Wi-Fi mode: keep Serial handle closed ONLY if we are not preserving it,
                % or close Serial cleanly without pulsing DTR if possible.
                esp32_io('disconnect');
                s = get_state();
                ip = regexprep(target, '^https?://', '');
                ip = regexprep(ip, '/.*$', '');
                if strcmp(ip, '192.168.4.1') && ispc
                    ensure_esp32_lab_wifi_connected();
                end
                s.Mode = 'wifi';
                s.Target = ip;
                s.SerialObj = [];
                set_state(s);
                [resp, latencyMs] = esp32_io('cmd', 'STATUS');
                fprintf('[ESP32] Connected via Wi-Fi at http://%s (%.1f ms) -> %s\n', s.Target, latencyMs, resp);
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

        case {'cmd', 'send', 'raw', 'exec'}
            if isempty(varargin)
                error('ESP32:MissingCommand', 'Usage: esp32_io(''cmd'', ''<COMMAND>'')');
            end
            rawCmd = strtrim(char(strjoin(string(varargin), ' ')));
            if strcmp(s.Mode, 'none')
                error('ESP32:NotConnected', ...
                    'No active connection. Run first: esp32_cli connect COM8 or esp32_cli connect 192.168.4.1');
            end
            if s.Busy
                out = 'BUSY';
                return;
            end
            s.Busy = true;
            set_state(s);

            tStart = tic;
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
                          startsWith(out, 'entry ') || startsWith(out, 'configsip:') || ...
                          startsWith(out, 'clk_drv:') || startsWith(out, 'ho 0 ') || ...
                          strcmp(out, 'ESP32_READY')
                        out = strtrim(char(readline(s.SerialObj)));
                    end
                elseif strcmp(s.Mode, 'wifi')
                    opts = weboptions('Timeout', 4.0, 'ContentType', 'text');
                    url = sprintf('http://%s/cmd?q=%s', s.Target, urlencode(rawCmd));
                    try
                        out = strtrim(char(webread(url, opts)));
                    catch
                        out = fallback_legacy_wifi(s.Target, rawCmd, opts);
                    end
                end
                latencyMs = toc(tStart) * 1000.0;
            catch ME
                s.Busy = false;
                set_state(s);
                rethrow(ME);
            end

            s.Busy = false;
            set_state(s);

        otherwise
            error('ESP32:UnknownIoAction', ...
                'Unknown esp32_io action "%s". Valid actions: state, connect, disconnect, cmd, send.', char(action));
    end
end

function release_existing_port(targetPort)
    try
        if exist('serialportfind', 'file') || exist('serialportfind', 'builtin')
            objs = serialportfind('Port', upper(string(targetPort)));
            for k = 1:numel(objs)
                try delete(objs(k)); catch, end
            end
        end
    catch
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

function ok = is_esp32_ap_pingable()
    [st, pOut] = system('ping -n 1 -w 600 192.168.4.1');
    ok = (st == 0) && contains(pOut, 'TTL=', 'IgnoreCase', true);
end

function ensure_esp32_lab_wifi_connected()
    [~, wlanInfo] = system('netsh wlan show interfaces');
    if contains(wlanInfo, 'ESP32_LAB') && is_esp32_ap_pingable()
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
    for attempt = 1:10
        pause(1.0);
        [~, wOut] = system('netsh wlan show interfaces');
        if contains(wOut, 'ESP32_LAB') && is_esp32_ap_pingable()
            pause(0.5);
            return;
        end
        system('netsh wlan connect name="ESP32_LAB" >nul 2>&1');
    end
    warning('ESP32:WifiNotConnected', ...
        'Windows did not automatically reach 192.168.4.1. Please select "ESP32_LAB" (Password: 12345678) in the Windows Wi-Fi tray.');
end

function out = fallback_legacy_wifi(ip, rawCmd, ~)
    optsJson = weboptions('Timeout', 3.5, 'ContentType', 'json');
    tokens = strsplit(strtrim(rawCmd));
    op = upper(tokens{1});
    if strcmp(op, 'STATUS')
        res = webread(sprintf('http://%s/?json=1', ip), optsJson);
        out = sprintf('%s|IP:%s', res.status, res.ip);
    elseif any(strcmp(op, {'R', 'REG'})) && numel(tokens) >= 2
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