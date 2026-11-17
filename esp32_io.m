function [out, latencyMs] = esp32_io(action, varargin)
%ESP32_IO Low-level non-blocking transport layer & Explicit FSM (USB Serial / Bluetooth SPP / Wi-Fi HTTP).
%   Supports actions:
%     'state'      - Return full FSM state struct
%     'connect'    - Run Connection FSM for COMx, bt:Name, or IPv4
%     'disconnect' - Transition FSM to DISCONNECTED and release OS handles
%     'cmd'        - Execute atomic request-response transaction across active transport
%     'verbose'    - Enable/disable live backend FSM & wire-protocol logging ('on'|'off'|true|false)
%     'trace'      - Internal/External structured logger: esp32_io('trace', fileTag, fsmTag, msg)
%     'history'    - Print or return the ring buffer of recent backend trace lines

    s = get_state();
    out = '';
    latencyMs = 0;

    if nargin < 1 || isempty(action)
        action = 'state';
    end

    act = lower(strtrim(char(action)));

    switch act
        case 'state'
            out = s;

        case 'verbose'
            if ~isempty(varargin)
                arg = varargin{1};
                if islogical(arg) || isnumeric(arg)
                    s.Verbose = logical(arg);
                else
                    s.Verbose = any(strcmpi(strtrim(char(arg)), {'on', 'true', '1', 'yes'}));
                end
                set_state(s);
            end
            fprintf('[esp32_io.m] Backend Verbose FSM & Wire Tracing: %s\n', ternary_str(s.Verbose, 'ENABLED (ON)', 'DISABLED (OFF)'));
            out = s.Verbose;

        case 'trace'
            % Usage: esp32_io('trace', 'esp32_cli.m', 'RESOLVE_SFR', 'Resolved GPIO_OUT_REG -> 0x3FF44004')
            if numel(varargin) >= 3
                s = log_fsm_event(s, char(varargin{1}), char(varargin{2}), char(varargin{3}));
            end
            out = true;

        case 'history'
            fprintf('\n=== ESP32 Workbench Backend FSM Trace History (%d entries) ===\n', numel(s.TraceHistory));
            for k = 1:numel(s.TraceHistory)
                fprintf('%s\n', s.TraceHistory(k));
            end
            fprintf('==============================================================\n\n');
            if nargout > 0, out = s.TraceHistory; end

        case 'connect'
            if isempty(varargin) || isempty(varargin{1})
                target = auto_pick_serial_port(s);
            else
                target = strtrim(char(varargin{1}));
            end

            forceBt = false;
            if numel(varargin) >= 2 && (ischar(varargin{2}) || isstring(varargin{2})) && ...
                    any(strcmpi(char(varargin{2}), {'--bt', 'bt', 'bluetooth'}))
                forceBt = true;
            end

            isSerialPort = startsWith(upper(target), 'COM') || startsWith(target, '/dev/');
            isIpv4       = ~isempty(regexp(target, '^(https?://)?\d+\.\d+\.\d+\.\d+', 'once'));
            isBtMac      = ~isempty(regexp(target, '^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$', 'once'));
            hasBtPrefix  = startsWith(lower(target), 'bt:') || startsWith(lower(target), 'bluetooth:');

            % =================================================================
            % BRANCH A: USB SERIAL / VIRTUAL COM CONNECTION FSM
            % =================================================================
            if isSerialPort && ~forceBt
                s = transition_fsm(s, 'REUSE_SERIAL_CHECK', ...
                    sprintf('Checking if Serial handle on %s is already open (DTR auto-reset protection)', upper(target)));

                if strcmp(s.Mode, 'serial') && strcmpi(s.Target, target) && ...
                        ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                    try
                        s = transition_fsm(s, 'HANDSHAKING', sprintf('Reusing existing %s handle; probing STATUS', upper(target)));
                        [resp, latencyMs] = execute_wire_transaction(s, 'STATUS');
                        if contains(resp, 'ESP32_READY')
                            s = get_state();
                            s = transition_fsm(s, 'READY_IDLE', sprintf('Serial handle %s verified alive (%.1f ms)', s.Target, latencyMs));
                            out = true;
                            return;
                        end
                    catch
                        s = get_state();
                    end
                end

                esp32_io('disconnect');
                s = get_state();
                baud = 115200;
                if numel(varargin) >= 2 && isnumeric(varargin{2}) && ~isempty(varargin{2})
                    baud = double(varargin{2});
                end

                s = transition_fsm(s, 'OPENING_TRANSPORT', ...
                    sprintf('Opening OS serialport("%s", %d) with LF terminator (pulsing DTR/RTS)', upper(target), baud));
                release_existing_port(target);

                try
                    sp = serialport(target, baud, 'Timeout', 2.0);
                    configureTerminator(sp, "LF");
                    pause(0.35);
                    flush(sp);
                    s.Mode      = 'serial';
                    s.Target    = upper(target);
                    s.SerialObj = sp;
                    set_state(s);
                catch ME
                    s = transition_fsm(s, 'FAULT_RECOVERY', sprintf('Failed opening serialport %s: %s', target, ME.message));
                    rethrow(ME);
                end

                s = transition_fsm(s, 'HANDSHAKING', sprintf('Probing Core-0 daemon on %s with "STATUS" (max 3 attempts)', s.Target));
                resp = '';
                for attempt = 1:3
                    try
                        [resp, latencyMs] = execute_wire_transaction(s, 'STATUS');
                        if contains(resp, 'ESP32_READY')
                            break;
                        end
                    catch
                        pause(0.5);
                    end
                end

                s = get_state();
                if contains(resp, 'ESP32_READY')
                    s = transition_fsm(s, 'READY_IDLE', sprintf('Handshake OK on %s (%.1f ms) -> %s', s.Target, latencyMs, resp));
                else
                    s = transition_fsm(s, 'READY_IDLE', sprintf('Serial opened on %s ( non-standard banner: %s )', s.Target, resp));
                end
                fprintf('[ESP32] Connected via Serial on %s (%.1f ms) -> %s\n', s.Target, latencyMs, resp);
                out = true;

            % =================================================================
            % BRANCH B: BLUETOOTH CLASSIC SPP CONNECTION FSM
            % =================================================================
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

                s = transition_fsm(s, 'OPENING_TRANSPORT', ...
                    sprintf('Opening Bluetooth RFCOMM/SPP socket to "%s" (Channel %d)', btTarget, channel));
                fprintf('[ESP32] Connecting via Bluetooth SPP to "%s" (Channel %d)...\n', btTarget, channel);
                try
                    btObj = bluetooth(btTarget, channel, 'Timeout', 3.0);
                catch ME
                    s = transition_fsm(s, 'FAULT_RECOVERY', sprintf('Bluetooth SPP connect failed: %s', ME.message));
                    error('ESP32:BluetoothConnectFailed', ...
                        ['Could not connect via Bluetooth to "%s" (%s).\n' ...
                         'Note: If OTA_PREP was recently run, reboot the ESP32 to re-enable Bluetooth SPP.'], ...
                        btTarget, ME.message);
                end
                configureTerminator(btObj, "LF");
                flush(btObj);
                pause(0.15);
                flush(btObj);

                s.Mode      = 'bluetooth';
                s.Target    = btTarget;
                s.SerialObj = btObj;
                set_state(s);

                s = transition_fsm(s, 'HANDSHAKING', sprintf('Sending STATUS handshake over BT SPP to %s', s.Target));
                [resp, latencyMs] = execute_wire_transaction(s, 'STATUS');
                s = get_state();
                s = transition_fsm(s, 'READY_IDLE', sprintf('Bluetooth SPP Ready (%s, %.1f ms)', s.Target, latencyMs));
                fprintf('[ESP32] Connected via Bluetooth SPP (%s, %.1f ms) -> %s\n', s.Target, latencyMs, resp);
                out = true;

            % =================================================================
            % BRANCH C: WI-FI SOFTAP HTTP CONNECTION FSM
            % =================================================================
            else
                esp32_io('disconnect');
                s = get_state();
                ip = regexprep(target, '^https?://', '');
                ip = regexprep(ip, '/.*$', '');

                s = transition_fsm(s, 'OPENING_TRANSPORT', ...
                    sprintf('Preparing Wi-Fi HTTP transport to http://%s', ip));
                if strcmp(ip, '192.168.4.1') && ispc
                    ensure_esp32_lab_wifi_connected(s);
                end
                s.Mode      = 'wifi';
                s.Target    = ip;
                s.SerialObj = [];
                set_state(s);

                s = transition_fsm(s, 'HANDSHAKING', sprintf('Sending HTTP GET /cmd?q=STATUS to http://%s', s.Target));
                [resp, latencyMs] = execute_wire_transaction(s, 'STATUS');
                s = get_state();
                s = transition_fsm(s, 'READY_IDLE', sprintf('Wi-Fi HTTP Ready at http://%s (%.1f ms)', s.Target, latencyMs));
                fprintf('[ESP32] Connected via Wi-Fi at http://%s (%.1f ms) -> %s\n', s.Target, latencyMs, resp);
                out = true;
            end

        case 'disconnect'
            if ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                s = log_fsm_event(s, 'esp32_io.m', 'CLOSING_HANDLE', ...
                    sprintf('Flushing and deleting active %s handle on %s', s.Mode, s.Target));
                try
                    flush(s.SerialObj);
                    delete(s.SerialObj);
                catch
                end
            end
            s.Mode      = 'none';
            s.Target    = '';
            s.SerialObj = [];
            s.Busy      = false;
            s = transition_fsm(s, 'DISCONNECTED', 'All transport handles released; state reset to DISCONNECTED');
            out = true;

        case {'cmd', 'send', 'raw', 'exec'}
            if isempty(varargin)
                error('ESP32:MissingCommand', 'Usage: esp32_io(''cmd'', ''<COMMAND>'')');
            end
            rawCmd = strtrim(char(strjoin(string(varargin), ' ')));
            if strcmp(s.Mode, 'none') || strcmp(s.Phase, 'DISCONNECTED')
                error('ESP32:NotConnected', ...
                    'No active connection (FSM Phase=%s). Run first: esp32_cli connect COM8 or esp32_cli connect 192.168.4.1', s.Phase);
            end
            if s.Busy
                s = log_fsm_event(s, 'esp32_io.m', 'MUTEX_REJECT_BUSY', ...
                    sprintf('Rejected concurrent command "%s" because FSM is in Phase=%s (Busy=1)', rawCmd, s.Phase));
                out = 'BUSY';
                return;
            end

            [out, latencyMs] = execute_wire_transaction(s, rawCmd);

        otherwise
            error('ESP32:UnknownIoAction', ...
                'Unknown esp32_io action "%s". Valid actions: state, connect, disconnect, cmd, verbose, trace, history.', char(action));
    end
end

%% ========================================================================
%  CORE WIRE TRANSACTION & EXPLICIT FSM ENGINE
%% ========================================================================

function [out, latencyMs] = execute_wire_transaction(s, rawCmd)
    s = transition_fsm(s, 'EXECUTING_CMD', ...
        sprintf('Transport=%s (%s) | Mutex Locked (Busy=1) | Wire Tx -> "%s"', upper(s.Mode), s.Target, rawCmd));

    tStart = tic;
    try
        if any(strcmp(s.Mode, {'serial', 'bluetooth'}))
            if isempty(s.SerialObj) || ~isvalid(s.SerialObj)
                error('ESP32:PortClosed', 'The %s connection (%s) closed unexpectedly.', s.Mode, s.Target);
            end
            flush(s.SerialObj);
            writeline(s.SerialObj, rawCmd);

            s = transition_fsm(s, 'DRAINING_BOOT_LOG', ...
                sprintf('Awaiting LF-terminated response on %s from Core-0 daemon...', s.Target));
            [out, skippedCount] = drain_boot_banners_fsm(s.SerialObj);
            latencyMs = toc(tStart) * 1000.0;

            s = transition_fsm(s, 'READY_IDLE', ...
                sprintf('Wire Rx <- "%s" (Boot lines skipped=%d) | Round-Trip=%.1f ms | Mutex Unlocked', ...
                out, skippedCount, latencyMs));

        elseif strcmp(s.Mode, 'wifi')
            opts = weboptions('Timeout', 4.0, 'ContentType', 'text');
            url = sprintf('http://%s/cmd?q=%s', s.Target, urlencode(rawCmd));
            try
                out = strtrim(char(webread(url, opts)));
                latencyMs = toc(tStart) * 1000.0;
                s = transition_fsm(s, 'READY_IDLE', ...
                    sprintf('HTTP GET "%s" -> Rx <- "%s" | Round-Trip=%.1f ms | Mutex Unlocked', url, out, latencyMs));
            catch
                s = transition_fsm(s, 'WIFI_LEGACY_FALLBACK', ...
                    sprintf('Endpoint /cmd?q= failed on %s; falling back to legacy JSON endpoints', s.Target));
                out = fallback_legacy_wifi(s.Target, rawCmd, opts);
                latencyMs = toc(tStart) * 1000.0;
                s = transition_fsm(s, 'READY_IDLE', ...
                    sprintf('Legacy Wi-Fi Rx <- "%s" | Round-Trip=%.1f ms | Mutex Unlocked', out, latencyMs));
            end
        end
    catch ME
        s = transition_fsm(s, 'FAULT_RECOVERY', ...
            sprintf('Transaction error on "%s": %s (Unlocking Busy mutex)', rawCmd, ME.message));
        rethrow(ME);
    end
end

function [payload, skippedCount] = drain_boot_banners_fsm(serialObj)
    % Explicit sub-FSM that filters ESP32 ROM bootloader & reset lines on UART0
    bootPrefixes = ["ets ", "rst:", "mode:", "load:", "entry ", "configsip:", "clk_drv:", "ho 0 "];
    skippedCount = 0;
    while true
        lineStr = strtrim(char(readline(serialObj)));
        isBootNoise = any(startsWith(string(lineStr), bootPrefixes)) || strcmp(lineStr, 'ESP32_READY');
        if ~isBootNoise
            payload = lineStr;
            return;
        end
        skippedCount = skippedCount + 1;
    end
end

function s = transition_fsm(s, nextPhase, reasonMsg)
    prevPhase = s.Phase;
    s.Phase   = nextPhase;
    switch nextPhase
        case 'DISCONNECTED'
            s.Busy = false;
        case {'REUSE_SERIAL_CHECK', 'OPENING_TRANSPORT', 'HANDSHAKING', 'EXECUTING_CMD', 'DRAINING_BOOT_LOG', 'WIFI_LEGACY_FALLBACK'}
            s.Busy = true;
        case 'READY_IDLE'
            s.Busy = false;
        case 'FAULT_RECOVERY'
            s.Busy      = false;
            s.LastError = reasonMsg;
    end
    s.LastTransition = sprintf('%s -> %s', prevPhase, nextPhase);
    s = log_fsm_event(s, 'esp32_io.m', sprintf('FSM: %s -> %s', prevPhase, nextPhase), reasonMsg);
    set_state(s);
end

function s = log_fsm_event(s, fileTag, fsmTag, msg)
    ts = char(datetime('now', 'Format', 'HH:mm:ss.SSS'));
    entry = sprintf('[TRACE %s] [%-18s] [%-36s] %s', ts, fileTag, fsmTag, msg);
    s.TraceHistory(end+1) = string(entry);
    if numel(s.TraceHistory) > 150
        s.TraceHistory = s.TraceHistory(end-149:end);
    end
    if s.Verbose
        fprintf('%s\n', entry);
    end
    set_state(s);
end

%% ========================================================================
%  OS PORT & WLAN HELPERS
%% ========================================================================

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

function port = auto_pick_serial_port(s)
    log_fsm_event(s, 'esp32_io.m', 'AUTO_PICK_PORT', 'Querying "arduino-cli board list" to auto-select USB Serial port');
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

function ensure_esp32_lab_wifi_connected(s)
    [~, wlanInfo] = system('netsh wlan show interfaces');
    if contains(wlanInfo, 'ESP32_LAB') && is_esp32_ap_pingable()
        log_fsm_event(s, 'esp32_io.m', 'WIFI_AP_READY', 'Windows WLAN is already connected to ESP32_LAB (192.168.4.1 reachable)');
        return;
    end
    log_fsm_event(s, 'esp32_io.m', 'WIFI_AP_SWITCH', 'Provisioning WLAN XML profile and connecting Windows Wi-Fi to "ESP32_LAB"');
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
        if ~isfield(s, 'Phase'),          s.Phase = 'DISCONNECTED'; end
        if ~isfield(s, 'Verbose'),        s.Verbose = true; end
        if ~isfield(s, 'LastTransition'), s.LastTransition = 'INIT -> DISCONNECTED'; end
        if ~isfield(s, 'LastError'),      s.LastError = ''; end
        if ~isfield(s, 'TraceHistory'),   s.TraceHistory = strings(0, 1); end
    else
        s = struct( ...
            'Phase',          'DISCONNECTED', ...
            'Mode',           'none', ...
            'Target',         '', ...
            'SerialObj',      [], ...
            'Busy',           false, ...
            'Verbose',        true, ... % Default ON so user sees backend FSM actions clearly
            'LastTransition', 'INIT -> DISCONNECTED', ...
            'LastError',      '', ...
            'TraceHistory',   strings(0, 1));
        setappdata(0, 'ESP32_WORKBENCH_STATE', s);
    end
end

function set_state(s)
    setappdata(0, 'ESP32_WORKBENCH_STATE', s);
end

function out = ternary_str(cond, a, b)
    if cond, out = a; else, out = b; end
end