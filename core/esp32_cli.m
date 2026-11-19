function varargout = esp32_cli(cmd, varargin)
%ESP32_CLI First-Priority CLI Controller for ESP32 Core & Green AGV Mainboard.
%   Zero hardcoded paths, COM ports, register magic numbers, or backwards-compat fallbacks.
    if nargin == 0, help esp32_cli; return; end
    action = lower(strtrim(char(cmd)));
    if ~ismember(action, {'verbose', 'trace', 'fsm'})
        argPreview = strjoin(string(cellfun(@num2str, varargin, 'UniformOutput', false)), ', ');
        esp32_io('trace', 'esp32_cli.m', 'CLI_CMD', sprintf('cmd="%s" args=[%s]', action, argPreview));
    end

    cfg   = wb_config('workbench');
    board = wb_config('board');

    switch action
        case {'verbose', 'trace', 'log'}
            if isempty(varargin)
                s = esp32_io('state'); out = esp32_io('verbose', ~s.Verbose);
            elseif any(strcmpi(char(varargin{1}), {'history', 'show', 'list'}))
                out = esp32_io('history');
            else
                out = esp32_io('verbose', varargin{1});
            end
            if nargout > 0, varargout{1} = out; end

        case 'fsm'
            s = esp32_io('state');
            fprintf('\n=== ESP32 Workbench FSM ===\n  Phase: %s | Trans: %s\n  Mode: %s | Target: %s | Busy: %d | Trace: %s\n\n', ...
                s.Phase, s.LastTransition, upper(s.Mode), s.Target, s.Busy, ternary_str(s.Verbose,'ON','OFF'));
            if nargout > 0, varargout{1} = s; end

        case 'config'
            sub = ternary_str(~isempty(varargin), lower(char(varargin{1})), 'show');
            if strcmp(sub, 'reload'), wb_config('workbench', 'reload'); fprintf('[CONFIG] Reloaded.\n'); end
            if nargout > 0, varargout{1} = struct('workbench', wb_config('workbench'), 'board', wb_config('board'), 'instruments', wb_config('instruments'));
            else, disp(cfg.transport); disp(board.pins); end

        case 'scan'
            ports = serialportlist("all");
            avail = serialportlist("available");
            pnp = get_windows_port_descriptions();
            fprintf('\n=== Detected Serial / Virtual BT Ports ===\n');
            if isempty(ports), fprintf('  (None detected)\n'); end
            for p = ports
                tag = ternary_str(any(p == avail), 'AVAILABLE', 'BUSY');
                desc = '';
                if isKey(pnp, char(p)), desc = [' - ' pnp(char(p))]; end
                fprintf('  %-8s [%-9s]%s\n', p, tag, desc);
            end
            fprintf('\n');
            if nargout > 0, varargout{1} = ports; end

        case {'debug', 'diag', 'doctor'}
            run_host_diagnostics(cfg);

        case 'connect'
            ok = esp32_io('connect', varargin{:});
            if nargout > 0, varargout{1} = ok; end

        case 'disconnect'
            esp32_io('disconnect'); fprintf('[ESP32] Disconnected.\n');

        case {'status', 'ping', 'state'}
            s = esp32_io('state');
            if strcmp(s.Mode, 'none'), fprintf('[ESP32] DISCONNECTED (FSM=%s)\n', s.Phase); if nargout>0, varargout{1}=s; end; return; end
            resp = esp32_io('cmd', 'STATUS');
            if nargout == 0, fprintf('[ESP32] %s | %s -> %s\n', s.Phase, s.Target, resp); else, varargout{1} = resp; end

        case 'info'
            resp = esp32_io('cmd', 'INFO');
            if nargout == 0, fprintf('  [INFO] %s\n', resp); else, varargout{1} = resp; end

        case {'raw', 'send', 'cmd'}
            resp = esp32_io('cmd', char(strjoin(string(varargin), ' ')));
            if nargout == 0, fprintf('  [RAW] -> %s\n', resp); else, varargout{1} = resp; end

        case 'sfr'
            db = get_sfr_database();
            regNames = string(fieldnames(db.registers));
            if isempty(varargin)
                fprintf('[SFR DB] %s (%d registers)\n', db.derivative, numel(regNames));
                if nargout > 0, varargout{1} = db; end
                return;
            end
            q = upper(strtrim(string(varargin{1})));
            if isfield(db.registers, q)
                rMeta = db.registers.(q);
                fprintf('\n=== %s (%s) ===\n', q, rMeta.address);
                bfs = fieldnames(rMeta.bitfields);
                for k = 1:numel(bfs)
                    bf = rMeta.bitfields.(bfs{k});
                    fprintf('  %-26s [%2d:%2d] %-4s\n', bfs{k}, bf.offset+bf.width-1, bf.offset, bf.access);
                end
                if nargout > 0, varargout{1} = rMeta; end
            else
                m = regNames(contains(regNames, q, 'IgnoreCase', true));
                fprintf('\n=== SFR matches for "%s" (%d) ===\n', q, numel(m));
                for k = 1:min(numel(m), 50)
                    r = db.registers.(m(k));
                    fprintf('  %-32s %s (%d fields)\n', m(k), r.address, numel(fieldnames(r.bitfields)));
                end
                if nargout > 0, varargout{1} = m; end
            end

        case 'reg'
            [addr, symName, rMeta] = resolve_sfr_address(varargin{1});
            addrHex = sprintf('%08X', addr);
            lbl = ternary_str(strlength(symName)>0, sprintf('%s (0x%s)', symName, addrHex), ['0x' addrHex]);
            if numel(varargin) == 1
                val = parse_num(esp32_io('cmd', ['R ' addrHex]));
                if nargout == 0
                    fprintf('  [REG %s] = 0x%08X (%u) | %s\n', lbl, val, val, format_bin32(val));
                    if ~isempty(rMeta), print_active_bitfields(rMeta.bitfields, val); end
                else, varargout{1} = val; end
            else
                val = parse_num(varargin{2});
                rb = parse_num(esp32_io('cmd', sprintf('W %s %08X', addrHex, val)));
                if nargout == 0, fprintf('  [WRITE %s] <= 0x%08X (RB: 0x%08X)\n', lbl, val, rb);
                else, varargout{1} = rb; end
            end

        case 'bits'
            [addr, symName, rMeta] = resolve_sfr_address(varargin{1});
            a2 = strtrim(char(varargin{2}));
            if ~isempty(rMeta) && isfield(rMeta.bitfields, upper(a2))
                bf = rMeta.bitfields.(upper(a2));
                lsb = double(bf.offset); w = double(bf.width); msb = lsb + w - 1;
                bfLbl = sprintf('%s.%s[%d:%d]', symName, upper(a2), msb, lsb);
                hasVal = numel(varargin) >= 3;
                if hasVal, newValArg = varargin{3}; end
            else
                msb = double(parse_num(varargin{2})); lsb = double(parse_num(varargin{3}));
                w = msb - lsb + 1; bfLbl = sprintf('0x%08X[%d:%d]', addr, msb, lsb);
                hasVal = numel(varargin) >= 4;
                if hasVal, newValArg = varargin{4}; end
            end
            mask = bitshift(uint32(2^w - 1), lsb);
            curVal = esp32_cli('reg', addr);
            if ~hasVal
                fv = bitshift(bitand(curVal, mask), -lsb);
                if nargout == 0, fprintf('  [BITS %s] = %u (0x%X)\n', bfLbl, fv, fv); else, varargout{1} = fv; end
            else
                nf = bitand(uint32(parse_num(newValArg)), uint32(2^w - 1));
                upd = bitor(bitand(curVal, bitcmp(mask, 'uint32')), bitshift(nf, lsb));
                rb = esp32_cli('reg', addr, upd);
                if nargout == 0, fprintf('  [BITS %s] <= %u -> 0x%08X\n', bfLbl, nf, rb); else, varargout{1} = rb; end
            end

        case {'pin', 'led'}
            if strcmp(action, 'led')
                pinNum = board.pins.builtinLed;
                pinCmd = ternary_str(~isempty(varargin), lower(char(varargin{1})), 'toggle');
            else
                pinNum = double(parse_num(varargin{1}));
                pinCmd = ternary_str(numel(varargin)>=2, lower(char(varargin{2})), 'read');
            end
            resp = esp32_io('cmd', sprintf('PIN %d %s', pinNum, upper(pinCmd)));
            if startsWith(resp, 'ERR'), error('ESP32:PinFailed', 'Firmware PIN command error: %s', resp); end
            st = str2double(resp);
            if nargout == 0, fprintf('  [GPIO %02d] -> %d\n', pinNum, st); else, varargout{1} = st; end

        case 'adc'
            chs = board.adc1Channels;
            if isempty(varargin) || strcmpi(strtrim(char(varargin{1})), 'all')
                fprintf('\n=== ADC1 Multi-Channel Scan ===\n');
                rawOut = zeros(1, numel(chs));
                for k = 1:numel(chs)
                    r = str2double(esp32_io('cmd', sprintf('ADC %d', chs(k).gpio)));
                    rawOut(k) = r;
                    vCal = wb_calibration('adc1_raw_to_volts', r);
                    fprintf('  GPIO %2d | %-26s | %4d/4095 | %.3f V\n', chs(k).gpio, chs(k).silkscreen, r, vCal);
                end
                fprintf('\n');
                if nargout > 0, varargout{1} = rawOut; end
                return;
            end
            pinNum = double(parse_num(varargin{1}));
            raw = str2double(esp32_io('cmd', sprintf('ADC %d', pinNum)));
            vCal = wb_calibration('adc1_raw_to_volts', raw);
            if nargout == 0, fprintf('  [ADC GPIO %02d] = %4d/4095 | Calibrated: %.3f V\n', pinNum, raw, vCal);
            else, varargout{1} = raw; end

        case 'dac'
            pinNum = double(parse_num(varargin{1}));
            valNum = min(max(double(parse_num(varargin{2})), 0), 255);
            resp = esp32_io('cmd', sprintf('DAC %d %d', pinNum, valNum));
            if nargout == 0, fprintf('  [DAC %d] <= %d -> %s\n', pinNum, valNum, resp); else, varargout{1} = resp; end

        case 'pwm'
            pinNum = double(parse_num(varargin{1}));
            freqHz = double(parse_num(varargin{2}));
            duty = min(max(double(parse_num(varargin{3})), 0), 1023);
            resp = esp32_io('cmd', sprintf('PWM %d %d %d', pinNum, freqHz, duty));
            if nargout == 0, fprintf('  [PWM %d] %d Hz duty=%d/1023 -> %s\n', pinNum, freqHz, duty, resp); else, varargout{1} = resp; end

        case 'touch'
            tps = board.touchPins;
            if isempty(varargin) || strcmpi(strtrim(char(varargin{1})), 'all')
                tOut = zeros(1, numel(tps));
                for k = 1:numel(tps)
                    tOut(k) = str2double(esp32_io('cmd', sprintf('TOUCH %d', tps(k).gpio)));
                    fprintf('  GPIO %2d | %-22s | %4d\n', tps(k).gpio, tps(k).label, tOut(k));
                end
                if nargout > 0, varargout{1} = tOut; end; return;
            end
            p = double(parse_num(varargin{1}));
            r = str2double(esp32_io('cmd', sprintf('TOUCH %d', p)));
            if nargout == 0, fprintf('  [TOUCH %d] = %d\n', p, r); else, varargout{1} = r; end

        case 'i2c'
            sub = ternary_str(isempty(varargin), 'SCAN', upper(strtrim(char(strjoin(string(varargin), ' ')))));
            resp = esp32_io('cmd', ['I2C ' sub]);
            if nargout == 0, fprintf('  [I2C %s] -> %s\n', sub, resp); else, varargout{1} = resp; end

        case 'spi'
            cs = double(parse_num(varargin{1})); tx = double(parse_num(varargin{2}));
            resp = esp32_io('cmd', sprintf('SPI %d 0x%02X', cs, tx));
            if nargout == 0, fprintf('  [SPI CS=%d TX=0x%02X] -> %s\n', cs, tx, resp); else, varargout{1} = resp; end

        case 'beep'
            p = board.pins.buzzer; f = 1200; ms = 150;
            if numel(varargin)>=1, p=double(parse_num(varargin{1})); end
            if numel(varargin)>=2, f=double(parse_num(varargin{2})); end
            if numel(varargin)>=3, ms=double(parse_num(varargin{3})); end
            resp = esp32_io('cmd', sprintf('BEEP %d %d %d', p, f, ms));
            if nargout == 0, fprintf('  [BEEP %d] -> %s\n', p, resp); else, varargout{1} = resp; end

        case 'pulse'
            p = double(parse_num(varargin{1}));
            tout = ternary_str(numel(varargin)>=2, double(parse_num(varargin{2})), 50000);
            resp = esp32_io('cmd', sprintf('PULSE %d %d', p, tout));
            if nargout == 0, fprintf('  [PULSE %d] -> %s\n', p, resp); else, varargout{1} = resp; end

        case 'dump'
            [baseAddr, ~, ~] = resolve_sfr_address(varargin{1});
            cnt = ternary_str(numel(varargin)>=2, double(parse_num(varargin{2})), 8);
            resp = esp32_io('cmd', sprintf('D %08X %d', baseAddr, cnt));
            vals = uint32(hex2dec(strsplit(strtrim(resp))));
            if nargout == 0
                for i = 1:numel(vals)
                    fprintf('  0x%08X : 0x%08X | %s\n', baseAddr+uint32((i-1)*4), vals(i), format_bin32(vals(i)));
                end
            else, varargout{1} = vals; end

        case 'agv'
            out = handle_agv_cli(varargin{:});
            if nargout > 0, varargout{1} = out; end

        case 'power'
            prof = upper(strtrim(char(varargin{1})));
            resp = esp32_io('cmd', ['POWER ' prof]);
            if nargout == 0, fprintf('  [POWER] -> %s\n', resp); else, varargout{1} = resp; end

        case 'ui'
            sub = ternary_str(~isempty(varargin), upper(char(varargin{1})), 'AGV');
            resp = esp32_io('cmd', ['UI ' sub]);
            if nargout == 0, fprintf('  [UI] -> %s\n', resp); else, varargout{1} = resp; end

        case 'role'
            sub = ternary_str(~isempty(varargin), upper(char(varargin{1})), 'MASTER');
            resp = esp32_io('cmd', ['ROLE ' sub]);
            if nargout == 0, fprintf('  [ROLE] -> %s\n', resp); else, varargout{1} = resp; end

        case 'espnow'
            sub = ternary_str(~isempty(varargin), upper(char(varargin{1})), 'STATUS');
            resp = esp32_io('cmd', ['ESPNOW ' sub]);
            if nargout == 0, fprintf('  [ESPNOW] -> %s\n', resp); else, varargout{1} = resp; end

        case 'flash'
            [ok, bid] = esp32_flash(varargin{:});
            if nargout > 0, varargout{1} = ok; end
            if nargout > 1, varargout{2} = bid; end

        case {'deploy', 'dual'}
            rep = esp32_dual_deploy(varargin{:});
            if nargout > 0, varargout{1} = rep; end

        case 'run'
            if isempty(varargin), error('Usage: esp32_cli run <hil|power|adc|drive> [args]'); end
            suite = lower(strtrim(char(varargin{1})));
            args = varargin(2:end);
            switch suite
                case 'hil',   rep = seq_hil_validation(args{:});
                case 'power', rep = seq_power_latency_matrix(args{:});
                case 'adc',   rep = seq_adc_dynamic_cal(args{:});
                case 'drive', rep = seq_interactive_drive_log(args{:});
                otherwise, error('Unknown test sequence "%s". Use hil, power, adc, or drive.', suite);
            end
            if nargout > 0, varargout{1} = rep; end

        case 'web'
            s = esp32_io('state');
            ip = ternary_str(strcmp(s.Mode,'wifi') && ~isempty(s.Target), s.Target, cfg.transport.wifi.apIp);
            url = sprintf('http://%s/', ip);
            if strcmp(ip, cfg.transport.wifi.apIp), esp32_io('ensure_ap', ip); end
            fprintf('[ESP32] Opening %s\n', url);
            web(url, '-browser');

        case 'gui'
            kind = ternary_str(~isempty(varargin), lower(char(varargin{1})), 'ude');
            if strcmp(kind, 'agv'), agv_cockpit_gui(varargin{2:end}); else, esp32_gui(); end

        otherwise
            error('ESP32:UnknownCmd', 'Unknown CLI command "%s".', action);
    end
end

function out = handle_agv_cli(varargin)
    if isempty(varargin), sub = 'telem'; else, sub = lower(strtrim(char(varargin{1}))); end
    persistent auxState
    if isempty(auxState), auxState = uint32(0); end

    magic = uint32(1); mode = uint32(1); cmdL = int32(0); cmdR = int32(0);
    switch sub
        case 'stop',  mode = uint32(0);
        case 'line',  mode = uint32(2);
        case 'zero',  magic = uint32(15); mode = uint32(1);
        case 'drive'
            cmdL = int32(min(max(str2double(string(varargin{2})), -100), 100));
            cmdR = int32(min(max(str2double(string(varargin{3})), -100), 100));
            if numel(varargin) >= 4, auxState = uint32(parse_num(varargin{4})); end
        case 'lights'
            auxState = bitor(bitand(auxState, uint32(252)), bitand(uint32(parse_num(varargin{2})), uint32(3)));
        case 'horn'
            auxState = bitor(auxState, uint32(4));
            syncWord = pack_cmd(magic, mode, auxState, cmdL, cmdR);
            esp32_io('cmd', sprintf('SYNC %08X', syncWord));
            pause(0.2);
            auxState = bitand(auxState, uint32(251));
        case 'power'
            esp32_io('cmd', ['POWER ' upper(char(varargin{2}))]);
        case 'telem'
            raw = esp32_io('cmd', 'TELEM');
            out = decode_telem_str(raw);
            print_agv_telem(out);
            return;
        otherwise
            error('Usage: esp32_cli agv <stop|drive L R|line|lights 0..3|horn|zero|power|telem>');
    end

    cmdWord = pack_cmd(magic, mode, auxState, cmdL, cmdR);
    rawSync = esp32_io('cmd', sprintf('SYNC %08X', cmdWord));
    out = decode_telem_str(rawSync);
    out.cmdHex = sprintf('%08X', cmdWord);
    print_agv_telem(out);
end

function w = pack_cmd(magic, mode, aux, cmdL, cmdR)
    uL = bitand(cmdL, 255); uR = bitand(cmdR, 255);
    w = bitor(bitor(bitshift(magic, 28), bitshift(mode, 24)), ...
              bitor(bitshift(bitand(aux, 255), 16), bitor(bitshift(uint32(uL), 8), uint32(uR))));
end

function t = decode_telem_str(raw)
    hexP = regexp(raw, '[0-9A-Fa-f]{8}', 'match');
    if numel(hexP) == 5, hexP = hexP(2:5); end
    t = struct('encL',0,'encR',0,'us_mm',0,'lineMask',0,'btnT1',0,'btnT2',0,'fsm',0,'x_mm',0,'y_mm',0,'theta_deg',0,'vel_mms',0,'rtt_us',NaN,'loss',NaN);
    if numel(hexP) < 4, return; end
    w1 = uint32(hex2dec(hexP{1})); w2 = uint32(hex2dec(hexP{2}));
    w3 = uint32(hex2dec(hexP{3})); w4 = uint32(hex2dec(hexP{4}));
    t.encL = to_i16(bitshift(w1,-16)); t.encR = to_i16(bitand(w1,65535));
    t.us_mm = double(bitshift(w2,-16));
    msk = double(bitand(bitshift(w2,-8),255));
    t.lineMask = bitand(msk,7); t.btnT1 = bitand(bitshift(msk,-3),1); t.btnT2 = bitand(bitshift(msk,-4),1);
    t.fsm = double(bitand(w2,255));
    t.x_mm = to_i16(bitshift(w3,-16)); t.y_mm = to_i16(bitand(w3,65535));
    t.theta_deg = rad2deg(to_i16(bitshift(w4,-16)) / 1000.0);
    t.vel_mms = to_i16(bitand(w4,65535));
    rm = regexp(raw, 'RTT_US:(\d+)', 'tokens', 'once'); if ~isempty(rm), t.rtt_us = str2double(rm{1}); end
    lm = regexp(raw, 'LOSS:(\d+)', 'tokens', 'once'); if ~isempty(lm), t.loss = str2double(lm{1}); end
end

function print_agv_telem(t)
    fprintf('  [AGV] FSM=%d | Vel=%d mm/s | Pose=(%d, %d mm, %.1f deg) | Enc=%d/%d | US=%d mm | Line=%s T1=%d T2=%d | RTT=%.0f us Loss=%.0f\n', ...
        t.fsm, t.vel_mms, t.x_mm, t.y_mm, t.theta_deg, t.encL, t.encR, t.us_mm, dec2bin(t.lineMask,3), t.btnT1, t.btnT2, t.rtt_us, t.loss);
end

function v = to_i16(u16)
    v = double(int32(u16)); if v >= 32768, v = v - 65536; end
end

function run_host_diagnostics(cfg)
    fprintf('\n=== ESP32 Workbench Host Diagnostics ===\n');
    try
        objs = serialportfind();
        for k = 1:numel(objs), fprintf('Releasing MATLAB handle %s\n', objs(k).Port); delete(objs(k)); end
    catch
    end
    [~, regOut] = system('powershell -NoProfile -Command "Get-ItemProperty ''HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'' -ErrorAction SilentlyContinue | Format-List"');
    fprintf('%s\n', strtrim(regOut));
    try
        acli = esp32_io('find_cli');
        [~, acliOut] = system(sprintf('"%s" board list', acli));
        fprintf('%s\n', strtrim(acliOut));
    catch ME
        fprintf('arduino-cli check: %s\n', ME.message);
    end
    [~, wOut] = system(sprintf('powershell -NoProfile -Command "netsh wlan show interfaces | Select-String ''SSID|State''; Test-Connection -ComputerName %s -Count 1 -Quiet"', cfg.transport.wifi.apIp));
    fprintf('%s\n========================================\n\n', strtrim(wOut));
end

function pnpMap = get_windows_port_descriptions()
    pnpMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
    if ~ispc, return; end
    psCmd = 'powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''\(COM\d+\)''} | ForEach-Object { ''PNP|'' + $_.Name }"';
    [st, out] = system(psCmd);
    if st ~= 0, return; end
    for ln = splitlines(string(strtrim(out)))'
        tok = regexp(char(ln), '\((COM\d+)\)', 'tokens', 'once');
        if ~isempty(tok), pnpMap(tok{1}) = char(extractAfter(ln, "PNP|")); end
    end
end

function db = get_sfr_database()
    persistent cachedDb
    if ~isempty(cachedDb), db = cachedDb; return; end
    jsonPath = wb_paths('sfrDb');
    if ~isfile(jsonPath)
        cachedDb = buildSfrDatabase(jsonPath);
    else
        cachedDb = jsondecode(fileread(jsonPath));
    end
    db = cachedDb;
end

function addrMap = get_address_to_name_map()
    persistent cachedMap
    if ~isempty(cachedMap), addrMap = cachedMap; return; end
    cachedMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
    db = get_sfr_database();
    fns = fieldnames(db.registers);
    for i = 1:numel(fns)
        r = db.registers.(fns{i});
        if isfield(r, 'address')
            k = strrep(upper(char(r.address)), '0X', '0x');
            if ~isKey(cachedMap, k), cachedMap(k) = fns{i}; end
        end
    end
    addrMap = cachedMap;
end

function [addr, symName, regMeta] = resolve_sfr_address(in)
    symName = ""; regMeta = [];
    db = get_sfr_database();
    if isnumeric(in)
        addr = uint32(in);
        am = get_address_to_name_map();
        ak = sprintf('0x%08X', addr);
        if isKey(am, ak), symName = string(am(ak)); regMeta = db.registers.(symName); end
        return;
    end
    uStr = upper(strtrim(char(in)));
    if isfield(db.registers, uStr)
        symName = string(uStr); regMeta = db.registers.(uStr); addr = parse_num(regMeta.address); return;
    end
    if isfield(db.registers, [uStr '_REG'])
        symName = string([uStr '_REG']); regMeta = db.registers.([uStr '_REG']); addr = parse_num(regMeta.address); return;
    end
    addr = parse_num(uStr);
    am = get_address_to_name_map();
    ak = sprintf('0x%08X', addr);
    if isKey(am, ak), symName = string(am(ak)); regMeta = db.registers.(symName); end
end

function print_active_bitfields(bfsStruct, regVal)
    bfs = fieldnames(bfsStruct);
    active = strings(0,1);
    for i = 1:numel(bfs)
        bf = bfsStruct.(bfs{i});
        mask = bitshift(uint32(2^double(bf.width) - 1), double(bf.offset));
        fv = bitshift(bitand(regVal, mask), -double(bf.offset));
        if fv ~= 0, active(end+1) = sprintf('%s=0x%X', bfs{i}, fv); end %#ok<AGROW>
    end
    if ~isempty(active), fprintf('    Active Bitfields: %s\n', strjoin(active, ', ')); end
end

function num = parse_num(in)
    if isnumeric(in), num = uint32(in); return; end
    str = regexprep(strtrim(char(in)), '^0[xX]', '');
    if any(ismember(upper(str), 'ABCDEF')) || length(str) >= 7
        num = uint32(hex2dec(str));
    else
        v = str2double(str);
        num = ternary_str(isnan(v), uint32(hex2dec(str)), uint32(v));
    end
end

function b = format_bin32(val)
    raw = dec2bin(val, 32);
    b = sprintf('%s_%s_%s_%s_%s_%s_%s_%s', raw(1:4),raw(5:8),raw(9:12),raw(13:16),raw(17:20),raw(21:24),raw(25:28),raw(29:32));
end

function out = ternary_str(c, a, b), if c, out = a; else, out = b; end; end