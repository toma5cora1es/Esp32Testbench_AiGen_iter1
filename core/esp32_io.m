function [out, latencyMs] = esp32_io(action, varargin)
%ESP32_IO Pure Generic Multi-Transport FSM (Serial / BT SPP / Wi-Fi HTTP).
%   Zero project, board, or instrument coupling.
    persistent s
    if isempty(s)
        s = struct('Phase','DISCONNECTED','Mode','none','Target','','SerialObj',[],'Busy',false,'CmdTimeoutSec',2.0,'LastError','');
    end
    out = ''; latencyMs = 0;
    if nargin < 1 || isempty(action), action = 'state'; end
    cfg = wb_config('workbench');
    act = lower(strtrim(char(action)));

    switch act
        case 'state', out = s;
        case 'timeout'
            if ~isempty(varargin) && isnumeric(varargin{1})
                s.CmdTimeoutSec = double(varargin{1});
                if ~isempty(s.SerialObj) && isvalid(s.SerialObj), s.SerialObj.Timeout = s.CmdTimeoutSec; end
            end
            out = s.CmdTimeoutSec;
        case 'get_ssid', out = get_active_ssid();
        case 'ensure_ap', out = ensure_ap(cfg, iif(~isempty(varargin), char(varargin{1}), cfg.transport.wifi.apIp));
        case 'restore_ssid', if ~isempty(varargin), restore_ssid(char(varargin{1}), cfg.transport.wifi.apSsid); end; out = true;
        case 'find_cli', out = find_acli(cfg);
        case 'detect_port', out = pick_usb_port(cfg);

        case 'connect'
            target = iif(isempty(varargin) || isempty(varargin{1}), pick_usb_port(cfg), strtrim(char(varargin{1})));
            isSer = startsWith(upper(target), 'COM') || startsWith(target, '/dev/');
            isIp  = ~isempty(regexp(target, '^(https?://)?\d+\.\d+\.\d+\.\d+', 'once'));

            if isSer
                if strcmp(s.Mode,'serial') && strcmpi(s.Target,target) && ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                    try
                        [r, latencyMs] = tx_rx(s, cfg, 'STATUS');
                        if contains(r, 'ESP32_READY'), s.Phase = 'READY_IDLE'; out = true; return; end
                    catch
                    end
                end
                esp32_io('disconnect');
                release_port(target);
                wb_log('fsm', 'IO', 'OPEN_SERIAL', sprintf('%s @ %d baud', upper(target), cfg.transport.serial.defaultBaud));
                sp = serialport(target, cfg.transport.serial.defaultBaud, 'Timeout', cfg.transport.serial.connectTimeoutSec);
                configureTerminator(sp, "LF"); pause(cfg.transport.serial.bootDrainWaitSec); flush(sp);
                s.Mode = 'serial'; s.Target = upper(target); s.SerialObj = sp; s.CmdTimeoutSec = cfg.transport.serial.connectTimeoutSec;

                resp = '';
                for a = 1:3
                    try [resp, latencyMs] = tx_rx(s, cfg, 'STATUS'); if contains(resp, 'ESP32_READY'), break; end; catch, pause(0.25); end
                end
                if ~contains(resp, 'ESP32_READY')
                    esp32_io('disconnect');
                    error('ESP32:NoReady', 'No ESP32_READY on %s. Flash core0 firmware first.', upper(target));
                end
                s.Phase = 'READY_IDLE';
                wb_log('pass', 'IO', 'CONNECTED', sprintf('Serial %s (%.1f ms) -> %s', s.Target, latencyMs, resp));
                out = true;

            elseif isIp
                esp32_io('disconnect');
                ip = regexprep(regexprep(target, '^https?://', ''), '/.*$', '');
                if strcmp(ip, cfg.transport.wifi.apIp) && ispc, ensure_ap(cfg, ip); end
                s.Mode = 'wifi'; s.Target = ip; s.SerialObj = []; s.CmdTimeoutSec = cfg.transport.wifi.httpTimeoutSec;
                [resp, latencyMs] = tx_rx(s, cfg, 'STATUS');
                s.Phase = 'READY_IDLE';
                wb_log('pass', 'IO', 'CONNECTED', sprintf('Wi-Fi http://%s (%.1f ms) -> %s', ip, latencyMs, resp));
                out = true;

            else
                esp32_io('disconnect');
                btName = regexprep(target, '^(?i)(bt:|bluetooth:)', '');
                wb_log('fsm', 'IO', 'OPEN_BT_SPP', sprintf('Connecting "%s" ch %d', btName, cfg.transport.bluetooth.rfcommChannel));
                btObj = bluetooth(btName, cfg.transport.bluetooth.rfcommChannel, 'Timeout', cfg.transport.bluetooth.connectTimeoutSec);
                configureTerminator(btObj, "LF"); flush(btObj); pause(0.15); flush(btObj);
                s.Mode = 'bluetooth'; s.Target = btName; s.SerialObj = btObj; s.CmdTimeoutSec = cfg.transport.bluetooth.connectTimeoutSec;
                [resp, latencyMs] = tx_rx(s, cfg, 'STATUS');
                s.Phase = 'READY_IDLE';
                wb_log('pass', 'IO', 'CONNECTED', sprintf('BT SPP "%s" (%.1f ms) -> %s', btName, latencyMs, resp));
                out = true;
            end

        case 'disconnect'
            if ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                try flush(s.SerialObj); delete(s.SerialObj); catch, end
            end
            s.Mode = 'none'; s.Target = ''; s.SerialObj = []; s.Busy = false; s.Phase = 'DISCONNECTED';
            wb_log('fsm', 'IO', 'DISCONNECTED', 'Handles released');
            out = true;

        case {'cmd', 'send', 'raw', 'exec'}
            if strcmp(s.Mode, 'none'), error('ESP32:NotConnected', 'Not connected. Run: esp32_cli connect <COMx|IP>'); end
            if s.Busy
                wb_log('warn', 'IO', 'BUSY', 'Transport mutex locked; resetting stale lock');
                s.Busy = false;
            end
            rawCmd = strtrim(char(strjoin(string(varargin), ' ')));
            s.Busy = true;
            try
                [out, latencyMs] = tx_rx(s, cfg, rawCmd);
                s.Busy = false;
            catch ME
                s.Busy = false;
                rethrow(ME);
            end

        otherwise
            error('ESP32:BadIoAction', 'Unknown esp32_io action: %s', act);
    end
end

function [out, ms] = tx_rx(s, cfg, rawCmd)
    wb_log('tx', 'IO', upper(s.Mode), rawCmd);
    t0 = tic;
    if any(strcmp(s.Mode, {'serial', 'bluetooth'}))
        flush(s.SerialObj); writeline(s.SerialObj, rawCmd);
        out = drain_uart(s.SerialObj);
    else
        opts = weboptions('Timeout', cfg.transport.wifi.httpTimeoutSec, 'ContentType', 'text');
        out = strtrim(char(webread(sprintf('http://%s/cmd?q=%s', s.Target, urlencode(rawCmd)), opts)));
    end
    ms = toc(t0) * 1000.0;
    wb_log('rx', 'IO', sprintf('%.1fms', ms), out);
end

function payload = drain_uart(sp)
    bootP = ["ets ", "rst:", "mode:", "load:", "entry ", "configsip:", "clk_drv:", "ho 0 ", "E (", "W (", "I (", "D ("];
    emptyHits = 0;
    for k = 1:30
        lastwarn('');
        ln = strtrim(char(readline(sp)));
        [wm, ~] = lastwarn;
        if isempty(ln)
            emptyHits = emptyHits + 1;
            if ~isempty(wm) || emptyHits >= 2, error('ESP32:Timeout', 'Serial timeout on %s', sp.Port); end
            continue;
        end
        if ~any(startsWith(string(ln), bootP)) && ~strcmp(ln, 'ESP32_READY'), payload = ln; return; end
    end
    error('ESP32:NoPayload', 'Exceeded 30 boot/log lines on %s', sp.Port);
end

function release_port(p)
    try objs = serialportfind('Port', upper(string(p))); for k=1:numel(objs), delete(objs(k)); end; catch, end
end

function acli = find_acli(cfg)
    [st, ~] = system('where arduino-cli >nul 2>&1');
    if st == 0, acli = char(cfg.toolchain.arduinoCliBinary); return; end
    for k = 1:numel(cfg.toolchain.arduinoCliSearchPaths)
        c = char(cfg.toolchain.arduinoCliSearchPaths{k});
        toks = regexp(c, '%([^%]+)%', 'tokens');
        for t = 1:numel(toks), val = getenv(toks{t}{1}); if ~isempty(val), c = strrep(c, ['%' toks{t}{1} '%'], val); end; end
        if isfile(c), acli = c; return; end
    end
    error('ESP32:NoCli', 'arduino-cli not found.');
end

function port = pick_usb_port(cfg)
    try
        [~, out] = system(sprintf('"%s" board list 2>nul', find_acli(cfg)));
        for ln = splitlines(string(strtrim(out)))'
            if contains(ln, "Serial Port (USB)", "IgnoreCase", true)
                tok = split(strtrim(ln)); port = char(tok(1)); return;
            end
        end
    catch
    end
    avail = serialportlist("available");
    if ~isempty(avail) && ispc
        [~, pOut] = system('powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''(CH340|CH341|CP210|FTDI|Silicon|USB.*Serial|UART).*\(COM\d+\)''} | ForEach-Object {$_.Name}"');
        toks = regexp(pOut, '\((COM\d+)\)', 'tokens');
        for t = 1:numel(toks), if any(avail == string(toks{t}{1})), port = char(toks{t}{1}); return; end; end
    end
    if ~isempty(avail), port = char(avail(1)); return; end
    error('ESP32:NoPort', 'No USB port detected.');
end

function ssid = get_active_ssid()
    ssid = ''; if ~ispc, return; end
    [~, w] = system('netsh wlan show interfaces');
    t = regexp(w, 'Profile\s*:\s*([^\r\n]+)', 'tokens', 'once');
    if isempty(t), t = regexp(w, 'SSID\s*:\s*([^\r\n]+)', 'tokens', 'once'); end
    if ~isempty(t), ssid = strtrim(t{1}); end
end

function restore_ssid(prev, apSsid)
    if isempty(prev) || strcmpi(prev, apSsid) || ~ispc || strcmpi(get_active_ssid(), prev), return; end
    wb_log('info', 'WIFI', 'RESTORE', prev);
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prev));
    for k = 1:8, pause(1.0); if strcmpi(get_active_ssid(), prev), return; end; system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prev)); end
end

function ok = ensure_ap(cfg, ip)
    ok = true; if ~ispc, return; end
    ssid = cfg.transport.wifi.apSsid; pass = cfg.transport.wifi.apPassword;
    [~, wi] = system('netsh wlan show interfaces');
    if contains(wi, ssid) && ping_ok(ip), return; end
    wb_log('info', 'WIFI', 'SWITCH_AP', sprintf('Joining %s (%s)', ssid, ip));
    xml = ['<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">' ...
           '<name>' ssid '</name><SSIDConfig><SSID><name>' ssid '</name></SSID></SSIDConfig>' ...
           '<connectionType>ESS</connectionType><connectionMode>manual</connectionMode><MSM><security>' ...
           '<authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>' ...
           '<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>' pass '</keyMaterial></sharedKey></security></MSM></WLANProfile>'];
    xp = fullfile(tempdir, 'esp32_wb_ap.xml'); fid = fopen(xp,'w'); fwrite(fid, xml,'char'); fclose(fid);
    system(sprintf('netsh wlan add profile filename="%s" >nul 2>&1', xp));
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', ssid));
    for k = 1:10
        pause(1.0); [~, wo] = system('netsh wlan show interfaces');
        if contains(wo, ssid) && ping_ok(ip), pause(0.4); return; end
        system(sprintf('netsh wlan connect name="%s" >nul 2>&1', ssid));
    end
    ok = false; wb_log('warn', 'WIFI', 'TIMEOUT', sprintf('Could not ping %s', ip));
end

function ok = ping_ok(ip), [st, o] = system(sprintf('ping -n 1 -w 600 %s', ip)); ok = (st==0) && contains(o,'TTL=','IgnoreCase',true); end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
