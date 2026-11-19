function [out, latencyMs] = esp32_io(action, varargin)
%ESP32_IO Explicit Transport & Wire-Protocol FSM (USB Serial, Bluetooth SPP, Wi-Fi HTTP).
%   Zero hardcoded endpoints, SSIDs, or legacy fallbacks (reads config/workbench_config.json).
    s = get_state();
    out = '';
    latencyMs = 0;
    if nargin < 1 || isempty(action), action = 'state'; end
    cfg = wb_config('workbench');
    act = lower(strtrim(char(action)));

    switch act
        case 'state'
            out = s;

        case 'timeout'
            if ~isempty(varargin) && isnumeric(varargin{1})
                tVal = double(varargin{1});
                if ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                    s.SerialObj.Timeout = tVal;
                end
                s.CmdTimeoutSec = tVal;
                set_state(s);
            end
            out = s.CmdTimeoutSec;

        case 'verbose'
            if ~isempty(varargin)
                arg = varargin{1};
                if islogical(arg) || isnumeric(arg), s.Verbose = logical(arg);
                else, s.Verbose = any(strcmpi(strtrim(char(arg)), {'on', 'true', '1', 'yes'}));
                end
                set_state(s);
            end
            fprintf('[esp32_io] Verbose FSM & Wire Tracing: %s\n', ternary_str(s.Verbose, 'ON', 'OFF'));
            out = s.Verbose;

        case 'trace'
            if numel(varargin) >= 3
                s = log_fsm_event(s, char(varargin{1}), char(varargin{2}), char(varargin{3}));
            end
            out = true;

        case 'history'
            fprintf('\n=== ESP32 Workbench Backend FSM Trace (%d events) ===\n', numel(s.TraceHistory));
            for k = 1:numel(s.TraceHistory), fprintf('%s\n', s.TraceHistory(k)); end
            fprintf('=====================================================\n\n');
            if nargout > 0, out = s.TraceHistory; end

        case 'get_ssid'
            out = get_active_wifi_ssid();

        case 'ensure_ap'
            ip = ternary_str(~isempty(varargin), char(varargin{1}), cfg.transport.wifi.apIp);
            out = ensure_ap_connected(s, cfg, ip);

        case 'restore_ssid'
            if ~isempty(varargin), restore_wifi_ssid(char(varargin{1}), cfg.transport.wifi.apSsid); end
            out = true;

        case 'find_cli'
            out = find_arduino_cli(cfg);

        case 'detect_port'
            out = auto_pick_serial_port(s, cfg);

        case 'connect'
            if isempty(varargin) || isempty(varargin{1})
                target = auto_pick_serial_port(s, cfg);
            else
                target = strtrim(char(varargin{1}));
            end

            forceBt = numel(varargin) >= 2 && (ischar(varargin{2}) || isstring(varargin{2})) && ...
                      any(strcmpi(char(varargin{2}), {'--bt', 'bt', 'bluetooth'}));
            isSerial = startsWith(upper(target), 'COM') || startsWith(target, '/dev/');
            isIpv4   = ~isempty(regexp(target, '^(https?://)?\d+\.\d+\.\d+\.\d+', 'once'));
            isBtMac  = ~isempty(regexp(target, '^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$', 'once'));
            hasBtTag = startsWith(lower(target), 'bt:') || startsWith(lower(target), 'bluetooth:');

            if isSerial && ~forceBt
                s = transition_fsm(s, 'REUSE_SERIAL_CHECK', sprintf('Probing active handle on %s', upper(target)));
                if strcmp(s.Mode, 'serial') && strcmpi(s.Target, target) && ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                    try
                        s = transition_fsm(s, 'HANDSHAKING', sprintf('Reusing %s; sending STATUS', upper(target)));
                        [resp, latencyMs] = execute_wire_transaction(s, cfg, 'STATUS');
                        if contains(resp, 'ESP32_READY')
                            s = get_state();
                            transition_fsm(s, 'READY_IDLE', sprintf('Reused %s (%.1f ms)', s.Target, latencyMs));
                            out = true; return;
                        end
                    catch
                        s = get_state();
                    end
                end

                esp32_io('disconnect');
                s = get_state();
                baud = cfg.transport.serial.defaultBaud;
                if numel(varargin) >= 2 && isnumeric(varargin{2}) && ~isempty(varargin{2})
                    baud = double(varargin{2});
                end

                s = transition_fsm(s, 'OPENING_TRANSPORT', sprintf('Opening serialport("%s", %d)', upper(target), baud));
                release_existing_port(target);
                try
                    sp = serialport(target, baud, 'Timeout', cfg.transport.serial.connectTimeoutSec);
                    configureTerminator(sp, "LF");
                    pause(cfg.transport.serial.bootDrainWaitSec);
                    flush(sp);
                    s.Mode = 'serial'; s.Target = upper(target); s.SerialObj = sp;
                    s.CmdTimeoutSec = cfg.transport.serial.connectTimeoutSec;
                    set_state(s);
                catch ME
                    transition_fsm(s, 'FAULT_RECOVERY', sprintf('Serial open failed on %s: %s', target, ME.message));
                    rethrow(ME);
                end

                s = transition_fsm(s, 'HANDSHAKING', sprintf('Sending STATUS on %s', s.Target));
                resp = '';
                for attempt = 1:3
                    try
                        [resp, latencyMs] = execute_wire_transaction(s, cfg, 'STATUS');
                        if contains(resp, 'ESP32_READY'), break; end
                    catch
                        pause(0.25);
                    end
                end
                s = get_state();
                if ~contains(resp, 'ESP32_READY')
                    esp32_io('disconnect');
                    error('ESP32:HandshakeFailed', ...
                        'No ESP32_READY response on %s. Flash Core-0 firmware first: esp32_cli flash green_agv_mainboard --usb %s', ...
                        upper(target), upper(target));
                end
                transition_fsm(s, 'READY_IDLE', sprintf('Serial ready on %s (%.1f ms)', s.Target, latencyMs));
                fprintf('[ESP32] Connected Serial %s (%.1f ms) -> %s\n', s.Target, latencyMs, resp);
                out = true;

            elseif hasBtTag || isBtMac || forceBt || (~isIpv4 && ~contains(target, '.'))
                esp32_io('disconnect');
                s = get_state();
                btTarget = strtrim(regexprep(target, '^(?i)(bt:|bluetooth:)', ''));
                if isempty(btTarget), btTarget = cfg.transport.bluetooth.deviceName; end
                ch = cfg.transport.bluetooth.rfcommChannel;
                if numel(varargin) >= 2 && isnumeric(varargin{2}) && ~isempty(varargin{2})
                    ch = double(varargin{2});
                end
                s = transition_fsm(s, 'OPENING_TRANSPORT', sprintf('Connecting BT SPP "%s" ch %d', btTarget, ch));
                try
                    btObj = bluetooth(btTarget, ch, 'Timeout', cfg.transport.bluetooth.connectTimeoutSec);
                catch ME
                    transition_fsm(s, 'FAULT_RECOVERY', sprintf('BT SPP connect failed: %s', ME.message));
                    rethrow(ME);
                end
                configureTerminator(btObj, "LF");
                flush(btObj); pause(0.15); flush(btObj);
                s.Mode = 'bluetooth'; s.Target = btTarget; s.SerialObj = btObj;
                s.CmdTimeoutSec = cfg.transport.bluetooth.connectTimeoutSec;
                set_state(s);

                s = transition_fsm(s, 'HANDSHAKING', sprintf('Sending STATUS over BT to %s', s.Target));
                [resp, latencyMs] = execute_wire_transaction(s, cfg, 'STATUS');
                s = get_state();
                transition_fsm(s, 'READY_IDLE', sprintf('BT SPP ready %s (%.1f ms)', s.Target, latencyMs));
                fprintf('[ESP32] Connected BT SPP "%s" (%.1f ms) -> %s\n', s.Target, latencyMs, resp);
                out = true;

            else
                esp32_io('disconnect');
                s = get_state();
                ip = regexprep(regexprep(target, '^https?://', ''), '/.*$', '');
                s = transition_fsm(s, 'OPENING_TRANSPORT', sprintf('Preparing Wi-Fi HTTP http://%s', ip));
                if strcmp(ip, cfg.transport.wifi.apIp) && ispc
                    ensure_ap_connected(s, cfg, ip);
                end
                s.Mode = 'wifi'; s.Target = ip; s.SerialObj = [];
                s.CmdTimeoutSec = cfg.transport.wifi.httpTimeoutSec;
                set_state(s);

                s = transition_fsm(s, 'HANDSHAKING', sprintf('HTTP GET /cmd?q=STATUS on %s', ip));
                [resp, latencyMs] = execute_wire_transaction(s, cfg, 'STATUS');
                s = get_state();
                transition_fsm(s, 'READY_IDLE', sprintf('Wi-Fi HTTP ready http://%s (%.1f ms)', ip, latencyMs));
                fprintf('[ESP32] Connected Wi-Fi http://%s (%.1f ms) -> %s\n', ip, latencyMs, resp);
                out = true;
            end

        case 'disconnect'
            if ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                log_fsm_event(s, 'esp32_io.m', 'CLOSING_HANDLE', sprintf('Releasing %s handle (%s)', s.Mode, s.Target));
                try flush(s.SerialObj); delete(s.SerialObj); catch, end
            end
            s.Mode = 'none'; s.Target = ''; s.SerialObj = []; s.Busy = false;
            transition_fsm(s, 'DISCONNECTED', 'Transport released; FSM DISCONNECTED');
            out = true;

        case {'cmd', 'send', 'raw', 'exec'}
            if isempty(varargin), error('ESP32:MissingCommand', 'Usage: esp32_io(''cmd'', ''<CMD>'')'); end
            rawCmd = strtrim(char(strjoin(string(varargin), ' ')));
            if strcmp(s.Mode, 'none') || strcmp(s.Phase, 'DISCONNECTED')
                error('ESP32:NotConnected', 'Not connected (FSM=%s). Run esp32_cli connect first.', s.Phase);
            end
            if s.Busy
                log_fsm_event(s, 'esp32_io.m', 'MUTEX_REJECT_BUSY', sprintf('Busy rejecting "%s"', rawCmd));
                out = 'BUSY'; return;
            end
            [out, latencyMs] = execute_wire_transaction(s, cfg, rawCmd);

        otherwise
            error('ESP32:UnknownIoAction', 'Unknown esp32_io action "%s".', char(action));
    end
end

function [out, latencyMs] = execute_wire_transaction(s, cfg, rawCmd)
    s = transition_fsm(s, 'EXECUTING_CMD', sprintf('%s (%s) Tx -> "%s"', upper(s.Mode), s.Target, rawCmd));
    t0 = tic;
    try
        if any(strcmp(s.Mode, {'serial', 'bluetooth'}))
            if isempty(s.SerialObj) || ~isvalid(s.SerialObj)
                error('ESP32:PortClosed', '%s connection closed.', s.Mode);
            end
            flush(s.SerialObj);
            writeline(s.SerialObj, rawCmd);
            s = transition_fsm(s, 'DRAINING_BOOT_LOG', sprintf('Awaiting response on %s', s.Target));
            [out, skipped] = drain_boot_banners(s.SerialObj);
            latencyMs = toc(t0) * 1000.0;
            transition_fsm(s, 'READY_IDLE', sprintf('Rx <- "%s" (skipped=%d, %.1f ms)', out, skipped, latencyMs));
        elseif strcmp(s.Mode, 'wifi')
            opts = weboptions('Timeout', cfg.transport.wifi.httpTimeoutSec, 'ContentType', 'text');
            url = sprintf('http://%s/cmd?q=%s', s.Target, urlencode(rawCmd));
            out = strtrim(char(webread(url, opts)));
            latencyMs = toc(t0) * 1000.0;
            transition_fsm(s, 'READY_IDLE', sprintf('HTTP Rx <- "%s" (%.1f ms)', out, latencyMs));
        end
    catch ME
        transition_fsm(s, 'FAULT_RECOVERY', sprintf('Command "%s" error: %s', rawCmd, ME.message));
        rethrow(ME);
    end
end

function [payload, skipped] = drain_boot_banners(serialObj)
    bootPrefixes = ["ets ", "rst:", "mode:", "load:", "entry ", "configsip:", "clk_drv:", "ho 0 ", "E (", "W (", "I (", "D ("];
    skipped = 0;
    emptyHits = 0;
    for k = 1:30
        lastwarn('');
        lineStr = strtrim(char(readline(serialObj)));
        [warnMsg, ~] = lastwarn;
        if isempty(lineStr)
            emptyHits = emptyHits + 1;
            if ~isempty(warnMsg) || emptyHits >= 2
                error('ESP32:SerialTimeout', 'Timeout waiting for response on %s.', serialObj.Port);
            end
            continue;
        end
        if ~any(startsWith(string(lineStr), bootPrefixes)) && ~strcmp(lineStr, 'ESP32_READY')
            payload = lineStr; return;
        end
        skipped = skipped + 1;
    end
    error('ESP32:BootSpam', 'Exceeded 30 boot banner lines on %s without command payload.', serialObj.Port);
end

function s = transition_fsm(s, nextPhase, reasonMsg)
    prev = s.Phase; s.Phase = nextPhase;
    switch nextPhase
        case {'DISCONNECTED', 'READY_IDLE'}, s.Busy = false;
        case 'FAULT_RECOVERY', s.Busy = false; s.LastError = reasonMsg;
        otherwise, s.Busy = true;
    end
    s.LastTransition = sprintf('%s -> %s', prev, nextPhase);
    s = log_fsm_event(s, 'esp32_io.m', sprintf('FSM: %s -> %s', prev, nextPhase), reasonMsg);
    set_state(s);
end

function s = log_fsm_event(s, fileTag, fsmTag, msg)
    ts = char(datetime('now', 'Format', 'HH:mm:ss.SSS'));
    entry = sprintf('[TRACE %s] [%-16s] [%-30s] %s', ts, fileTag, fsmTag, msg);
    s.TraceHistory(end+1) = string(entry);
    if numel(s.TraceHistory) > 150, s.TraceHistory = s.TraceHistory(end-149:end); end
    if s.Verbose, fprintf('%s\n', entry); end
    set_state(s);
end

function release_existing_port(targetPort)
    try
        objs = serialportfind('Port', upper(string(targetPort)));
        for k = 1:numel(objs), try delete(objs(k)); catch, end; end
    catch
    end
end

function acli = find_arduino_cli(cfg)
    [st, ~] = system('where arduino-cli >nul 2>&1');
    if st == 0, acli = char(cfg.toolchain.arduinoCliBinary); return; end
    envCli = getenv('ARDUINO_CLI_PATH');
    if ~isempty(envCli) && isfile(envCli), acli = envCli; return; end
    for k = 1:numel(cfg.toolchain.arduinoCliSearchPaths)
        cand = expand_win_env(cfg.toolchain.arduinoCliSearchPaths{k});
        if isfile(cand), acli = cand; return; end
    end
    error('ESP32:NoArduinoCLI', 'arduino-cli not found on PATH or config search paths.');
end

function p = expand_win_env(raw)
    p = char(raw);
    tokens = regexp(p, '%([^%]+)%', 'tokens');
    for k = 1:numel(tokens)
        val = getenv(tokens{k}{1});
        if ~isempty(val), p = strrep(p, ['%' tokens{k}{1} '%'], val); end
    end
end

function port = auto_pick_serial_port(s, cfg)
    log_fsm_event(s, 'esp32_io.m', 'AUTO_PICK_PORT', 'Scanning USB serial devices via arduino-cli & serialportlist');
    try
        acli = find_arduino_cli(cfg);
        [~, out] = system(sprintf('"%s" board list 2>nul', acli));
        lines = splitlines(string(strtrim(out)));
        for k = 1:numel(lines)
            if contains(lines(k), "Serial Port (USB)", "IgnoreCase", true)
                tok = split(strtrim(lines(k)));
                port = char(tok(1)); return;
            end
        end
    catch
    end
    avail = serialportlist("available");
    if ~isempty(avail) && ispc
        ps = 'powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''(CH340|CH341|CP210|FTDI|Silicon|USB.*Serial|UART).*\(COM\d+\)''} | ForEach-Object {$_.Name}"';
        [~, pOut] = system(ps);
        toks = regexp(pOut, '\((COM\d+)\)', 'tokens');
        for t = 1:numel(toks)
            cand = string(toks{t}{1});
            if any(avail == cand), port = char(cand); return; end
        end
    end
    if ~isempty(avail), port = char(avail(1)); return; end
    error('ESP32:NoPort', 'No USB serial port detected. Pass COMx, IP, or bt:DeviceName explicitly.');
end

function ssid = get_active_wifi_ssid()
    ssid = '';
    if ~ispc, return; end
    [~, wOut] = system('netsh wlan show interfaces');
    tok = regexp(wOut, 'Profile\s*:\s*([^\r\n]+)', 'tokens', 'once');
    if isempty(tok), tok = regexp(wOut, 'SSID\s*:\s*([^\r\n]+)', 'tokens', 'once'); end
    if ~isempty(tok), ssid = strtrim(tok{1}); end
end

function restore_wifi_ssid(prevSsid, apSsid)
    if isempty(prevSsid) || strcmpi(prevSsid, apSsid) || ~ispc, return; end
    if strcmpi(get_active_wifi_ssid(), prevSsid), return; end
    fprintf('[WIFI] Restoring WLAN to "%s"...\n', prevSsid);
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prevSsid));
    for k = 1:8
        pause(1.0);
        if strcmpi(get_active_wifi_ssid(), prevSsid), return; end
        system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prevSsid));
    end
end

function ok = ensure_ap_connected(s, cfg, ip)
    ok = true;
    if ~ispc, return; end
    ssid = cfg.transport.wifi.apSsid;
    pass = cfg.transport.wifi.apPassword;
    [~, wlanInfo] = system('netsh wlan show interfaces');
    if contains(wlanInfo, ssid) && is_ip_pingable(ip)
        log_fsm_event(s, 'esp32_io.m', 'WIFI_AP_READY', sprintf('Already connected to %s (%s)', ssid, ip));
        return;
    end
    log_fsm_event(s, 'esp32_io.m', 'WIFI_AP_SWITCH', sprintf('Connecting Windows WLAN to "%s"', ssid));
    xmlProfile = [ ...
        '<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">' ...
        '<name>' ssid '</name><SSIDConfig><SSID><name>' ssid '</name></SSID></SSIDConfig>' ...
        '<connectionType>ESS</connectionType><connectionMode>manual</connectionMode><MSM><security>' ...
        '<authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>' ...
        '<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>' pass '</keyMaterial></sharedKey>' ...
        '</security></MSM></WLANProfile>'];
    xmlPath = fullfile(tempdir, 'esp32_wb_wlan_profile.xml');
    fid = fopen(xmlPath, 'w'); fwrite(fid, xmlProfile, 'char'); fclose(fid);
    system(sprintf('netsh wlan add profile filename="%s" >nul 2>&1', xmlPath));
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', ssid));
    for k = 1:10
        pause(1.0);
        [~, wOut] = system('netsh wlan show interfaces');
        if contains(wOut, ssid) && is_ip_pingable(ip), pause(0.4); return; end
        system(sprintf('netsh wlan connect name="%s" >nul 2>&1', ssid));
    end
    ok = false;
    warning('ESP32:WifiNotReachable', 'Could not reach %s on WLAN "%s".', ip, ssid);
end

function ok = is_ip_pingable(ip)
    [st, pOut] = system(sprintf('ping -n 1 -w 600 %s', ip));
    ok = (st == 0) && contains(pOut, 'TTL=', 'IgnoreCase', true);
end

function s = get_state()
    if isappdata(0, 'ESP32_WORKBENCH_STATE')
        s = getappdata(0, 'ESP32_WORKBENCH_STATE');
    else
        s = struct('Phase','DISCONNECTED','Mode','none','Target','','SerialObj',[], ...
            'Busy',false,'Verbose',true,'CmdTimeoutSec',2.0, ...
            'LastTransition','INIT -> DISCONNECTED','LastError','','TraceHistory',strings(0,1));
        setappdata(0, 'ESP32_WORKBENCH_STATE', s);
    end
end

function set_state(s), setappdata(0, 'ESP32_WORKBENCH_STATE', s); end
function out = ternary_str(c, a, b), if c, out = a; else, out = b; end; end