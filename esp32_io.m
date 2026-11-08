function out = esp32_io(action, varargin)
%ESP32_IO Low-level non-blocking transport layer (USB Serial / Bluetooth SPP / Wi-Fi HTTP).
%   Internal use by esp32.m and esp32_gui.m, or directly accessible if needed.
%
%   SUPPORTED TARGET FORMATS FOR 'connect':
%     - 'COM9' or '/dev/ttyUSB0'     -> Serial port (USB or OS-mapped Bluetooth Virtual COM)
%     - 'bt:ESP32_BT_BRIDGE'         -> Native MATLAB Bluetooth SPP connection by device name
%     - 'ESP32_BT_BRIDGE'            -> Auto-detected as Bluetooth SPP device name
%     - 'AA:BB:CC:DD:EE:FF'          -> Auto-detected as Bluetooth MAC address
%     - '192.168.4.1'                -> Wi-Fi HTTP Bridge

    s = get_state();

    switch lower(action)
        case 'state'
            out = s;

        case 'connect'
            target = strtrim(char(varargin{1}));
            esp32_io('disconnect'); % Clean up any previous session
            s = get_state();

            % Check if user explicitly passed '--bt' flag or 'bt:' prefix or Bluetooth MAC/Name
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
                pause(0.15); % Brief non-blocking settle delay
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
                         'or connect using its Virtual COM port (e.g., esp32 connect COM10).'], ...
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
                    'No active connection. Run first: esp32 connect COM9, esp32 connect ESP32_BT_BRIDGE, or esp32 connect 192.168.4.1');
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
                    % Ignore ESP32 ROM boot messages if it just restarted
                    while startsWith(out, 'ets ') || startsWith(out, 'rst:') || ...
                          startsWith(out, 'mode:') || startsWith(out, 'load:') || ...
                          startsWith(out, 'entry ') || strcmp(out, 'ESP32_READY')
                        out = strtrim(char(readline(s.SerialObj)));
                    end
                elseif strcmp(s.Mode, 'wifi')
                    opts = weboptions('Timeout', 1.2, 'ContentType', 'text');
                    url = sprintf('http://%s/cmd?q=%s', s.Target, urlencode(rawCmd));
                    try
                        out = strtrim(char(webread(url, opts)));
                    catch
                        % Fallback to legacy /reg endpoint if running older firmware
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

function out = fallback_legacy_wifi(ip, rawCmd, ~)
    % Backward compatibility if the chip still runs the legacy /reg firmware
    optsJson = weboptions('Timeout', 1.2, 'ContentType', 'json');
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