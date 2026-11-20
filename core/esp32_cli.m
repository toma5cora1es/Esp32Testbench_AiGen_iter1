function varargout = esp32_cli(cmd, varargin)
%ESP32_CLI Generic CLI Router + Dynamic Plugin Dispatcher.
%   Core handles transport, SFR/Bitfields, GPIO/ADC/DAC/PWM/I2C/SPI, Flash, Power, and Logging.
%   Any project/experiment plugin (<verb>_cli.m) on path is dispatched automatically!
    if nargin == 0, help esp32_cli; return; end
    act = lower(strtrim(char(cmd)));
    if ~ismember(act, {'verbose','log'})
        wb_log('trace', 'CLI', act, strjoin(string(cellfun(@num2str,varargin,'UniformOutput',false)), ', '));
    end
    cfg = wb_config('workbench');

    switch act
        case {'verbose', 'log'}
            if isempty(varargin)
                cur = wb_log('get_level');
                nxt = iif(strcmp(cur,'trace'), 'normal', 'trace');
                out = wb_log('set_level', nxt);
                fprintf('  [LOG LEVEL] -> %s\n', upper(out));
            elseif strcmpi(char(varargin{1}), 'history')
                out = wb_log('history');
            else
                lvl = lower(char(varargin{1}));
                if strcmp(lvl,'on'), lvl='trace'; elseif strcmp(lvl,'off'), lvl='normal'; end
                out = wb_log('set_level', lvl);
                fprintf('  [LOG LEVEL] -> %s\n', upper(out));
            end
            if nargout > 0, varargout{1} = out; end

        case 'fsm'
            s = esp32_io('state');
            wb_log('hdr', 'FSM', s.Phase, sprintf('Mode=%s | Target=%s | Busy=%d | Log=%s', upper(s.Mode), s.Target, s.Busy, upper(wb_log('get_level'))));
            if nargout > 0, varargout{1} = s; end

        case 'scan'
            ports = serialportlist("all"); avail = serialportlist("available");
            pnp = get_pnp_map();
            fprintf('\n=== Serial / Virtual BT Ports ===\n');
            for p = ports
                d = ''; if isKey(pnp, char(p)), d = [' - ' pnp(char(p))]; end
                fprintf('  %-7s [%-9s]%s\n', p, iif(any(p==avail),'AVAILABLE','BUSY'), d);
            end
            fprintf('\n');
            if nargout > 0, varargout{1} = ports; end

        case 'connect'
            ok = esp32_io('connect', varargin{:});
            if nargout > 0, varargout{1} = ok; end

        case 'disconnect', esp32_io('disconnect');

        case {'status', 'info', 'raw', 'send', 'cmd'}
            q = upper(act);
            if any(strcmp(act,{'raw','send','cmd'})), q = char(strjoin(string(varargin),' ')); end
            r = esp32_io('cmd', q);
            if nargout == 0, wb_log('info', 'CHIP', upper(act), r); else, varargout{1} = r; end

        case 'sfr'
            db = get_sfr_db(); regs = string(fieldnames(db.registers));
            if isempty(varargin), fprintf('SFR DB: %d registers\n', numel(regs)); if nargout>0, varargout{1}=db; end; return; end
            q = upper(strtrim(string(varargin{1})));
            if isfield(db.registers, q)
                rm = db.registers.(q); fprintf('\n=== %s (%s) ===\n', q, rm.address);
                for fn = fieldnames(rm.bitfields)', bf = rm.bitfields.(fn{1});
                    fprintf('  %-26s [%2d:%2d] %s\n', fn{1}, bf.offset+bf.width-1, bf.offset, bf.access);
                end
                if nargout > 0, varargout{1} = rm; end
            else
                m = regs(contains(regs, q, 'IgnoreCase', true));
                for k = 1:min(numel(m),40), fprintf('  %-32s %s\n', m(k), db.registers.(m(k)).address); end
                if nargout > 0, varargout{1} = m; end
            end

        case 'reg'
            [addr, sym, rm] = resolve_sfr(varargin{1});
            ah = sprintf('%08X', addr);
            if numel(varargin) == 1
                v = parse_num(esp32_io('cmd', ['R ' ah]));
                if nargout == 0, fprintf('  [REG %s (0x%s)] = 0x%08X (%u) | %s\n', sym, ah, v, v, bin32(v)); if ~isempty(rm), print_bfs(rm.bitfields, v); end
                else, varargout{1} = v; end
            else
                v = parse_num(varargin{2});
                rb = parse_num(esp32_io('cmd', sprintf('W %s %08X', ah, v)));
                if nargout == 0, fprintf('  [WRITE %s (0x%s)] <= 0x%08X (RB: 0x%08X)\n', sym, ah, v, rb); else, varargout{1} = rb; end
            end

        case 'bits'
            [addr, sym, rm] = resolve_sfr(varargin{1}); a2 = strtrim(char(varargin{2}));
            if ~isempty(rm) && isfield(rm.bitfields, upper(a2))
                bf = rm.bitfields.(upper(a2)); lsb = double(bf.offset); w = double(bf.width);
                hasVal = numel(varargin) >= 3; if hasVal, nv = varargin{3}; end
                lbl = sprintf('%s.%s', sym, upper(a2));
            else
                msb = double(parse_num(varargin{2})); lsb = double(parse_num(varargin{3})); w = msb - lsb + 1;
                hasVal = numel(varargin) >= 4; if hasVal, nv = varargin{4}; end
                lbl = sprintf('0x%08X[%d:%d]', addr, msb, lsb);
            end
            mask = bitshift(uint32(2^w - 1), lsb);
            cur = esp32_cli('reg', addr);
            if ~hasVal
                fv = bitshift(bitand(cur, mask), -lsb);
                if nargout == 0, fprintf('  [BITS %s] = %u (0x%X)\n', lbl, fv, fv); else, varargout{1} = fv; end
            else
                nf = bitand(uint32(parse_num(nv)), uint32(2^w - 1));
                rb = esp32_cli('reg', addr, bitor(bitand(cur, bitcmp(mask,'uint32')), bitshift(nf, lsb)));
                if nargout == 0, fprintf('  [BITS %s] <= %u -> 0x%08X\n', lbl, nf, rb); else, varargout{1} = rb; end
            end

        case 'pin'
            p = double(parse_num(varargin{1})); op = iif(numel(varargin)>=2, upper(char(varargin{2})), 'READ');
            st = str2double(esp32_io('cmd', sprintf('PIN %d %s', p, op)));
            if nargout == 0, fprintf('  [GPIO %02d] -> %d\n', p, st); else, varargout{1} = st; end

        case 'adc'
            p = double(parse_num(varargin{1}));
            raw = str2double(esp32_io('cmd', sprintf('ADC %d', p)));
            v = wb_calibration('adc1_raw_to_volts', raw);
            if nargout == 0, fprintf('  [ADC GPIO %02d] = %4d/4095 (%.3f V)\n', p, raw, v); else, varargout{1} = raw; end

        case 'dac',   r = esp32_io('cmd', sprintf('DAC %d %d', double(parse_num(varargin{1})), double(parse_num(varargin{2})))); if nargout>0, varargout{1}=r; else, disp(r); end
        case 'pwm',   r = esp32_io('cmd', sprintf('PWM %d %d %d', double(parse_num(varargin{1})), double(parse_num(varargin{2})), double(parse_num(varargin{3})))); if nargout>0, varargout{1}=r; else, disp(r); end
        case 'pulse', r = esp32_io('cmd', sprintf('PULSE %d %d', double(parse_num(varargin{1})), iif(numel(varargin)>=2,double(parse_num(varargin{2})),50000))); if nargout>0, varargout{1}=r; else, disp(r); end
        case 'touch', r = str2double(esp32_io('cmd', sprintf('TOUCH %d', double(parse_num(varargin{1}))))); if nargout>0, varargout{1}=r; else, fprintf('  [TOUCH] = %d\n', r); end
        case 'i2c',   r = esp32_io('cmd', ['I2C ' iif(isempty(varargin),'SCAN',upper(char(strjoin(string(varargin),' '))))]); if nargout>0, varargout{1}=r; else, disp(r); end
        case 'spi',   r = esp32_io('cmd', sprintf('SPI %d 0x%02X', double(parse_num(varargin{1})), double(parse_num(varargin{2})))); if nargout>0, varargout{1}=r; else, disp(r); end
        case 'dump'
            [ba,~,~] = resolve_sfr(varargin{1}); n = iif(numel(varargin)>=2, double(parse_num(varargin{2})), 8);
            vals = uint32(hex2dec(strsplit(strtrim(esp32_io('cmd', sprintf('D %08X %d', ba, n))))));
            if nargout == 0, for i=1:numel(vals), fprintf('  0x%08X : 0x%08X | %s\n', ba+uint32((i-1)*4), vals(i), bin32(vals(i))); end
            else, varargout{1} = vals; end

        case {'power','role','ui','espnow'}
            r = esp32_io('cmd', [upper(act) ' ' iif(isempty(varargin),'STATUS',upper(char(varargin{1})))]);
            if nargout == 0, wb_log('info', upper(act), 'RESP', r); else, varargout{1} = r; end

        case 'flash'
            [ok, bid] = esp32_flash(varargin{:});
            if nargout > 0, varargout{1} = ok; end; if nargout > 1, varargout{2} = bid; end

        case 'web'
            s = esp32_io('state');
            ip = iif(strcmp(s.Mode,'wifi') && ~isempty(s.Target), s.Target, cfg.transport.wifi.apIp);
            if strcmp(ip, cfg.transport.wifi.apIp), esp32_io('ensure_ap', ip); end
            url = sprintf('http://%s/', ip); wb_log('info','WEB','OPEN',url); web(url, '-browser');

        case 'run'
            suite = lower(strtrim(char(varargin{1}))); args = varargin(2:end);
            switch suite
                case 'hil',   rep = seq_hil_validation(args{:});
                case 'power', rep = seq_power_latency_matrix(args{:});
                case 'adc',   rep = seq_adc_dynamic_cal(args{:});
                case 'drive', rep = seq_interactive_drive_log(args{:});
                otherwise, error('ESP32:BadSuite', 'Unknown suite: %s', suite);
            end
            if nargout > 0, varargout{1} = rep; end

        otherwise
            % Dynamic Plugin Resolution: projects/<act>/<act>_cli.m or <act>_cli.m on path
            fn = [act '_cli'];
            if exist(fn, 'file') == 2
                if nargout > 0, varargout{1} = feval(fn, varargin{:}); else, feval(fn, varargin{:}); end
            else
                error('ESP32:UnknownCmd', 'Unknown command or plugin "%s".', act);
            end
    end
end

function pnp = get_pnp_map()
    pnp = containers.Map('KeyType','char','ValueType','char');
    if ~ispc, return; end
    [st, o] = system('powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''\(COM\d+\)''} | ForEach-Object {$_.Name}"');
    if st ~= 0, return; end
    for ln = splitlines(string(strtrim(o)))'
        t = regexp(char(ln), '\((COM\d+)\)', 'tokens', 'once');
        if ~isempty(t), pnp(t{1}) = char(ln); end
    end
end
function db = get_sfr_db()
    persistent d; if isempty(d), p = wb_paths('sfrDb'); d = iif(isfile(p), @() jsondecode(fileread(p)), @() buildSfrDatabase(p)); if isa(d,'function_handle'), d = d(); end; end; db = d;
end
function [addr, sym, rm] = resolve_sfr(in)
    sym = ""; rm = []; db = get_sfr_db();
    if isnumeric(in), addr = uint32(in); return; end
    u = upper(strtrim(char(in)));
    if isfield(db.registers, u), sym = string(u); rm = db.registers.(u); addr = parse_num(rm.address); return; end
    if isfield(db.registers, [u '_REG']), sym = string([u '_REG']); rm = db.registers.([u '_REG']); addr = parse_num(rm.address); return; end
    addr = parse_num(u);
end
function print_bfs(bfs, val)
    for fn = fieldnames(bfs)', bf = bfs.(fn{1});
        fv = bitshift(bitand(val, bitshift(uint32(2^double(bf.width)-1), double(bf.offset))), -double(bf.offset));
        if fv ~= 0, fprintf('    %s = 0x%X (%u)\n', fn{1}, fv, fv); end
    end
end
function n = parse_num(in)
    if isnumeric(in), n = uint32(in); return; end
    s = regexprep(strtrim(char(in)),'^0[xX]','');
    if any(ismember(upper(s),'ABCDEF')) || length(s)>=7, n=uint32(hex2dec(s)); else, v=str2double(s); n=iif(isnan(v),uint32(hex2dec(s)),uint32(v)); end
end
function b = bin32(v), r=dec2bin(v,32); b=sprintf('%s_%s_%s_%s_%s_%s_%s_%s',r(1:4),r(5:8),r(9:12),r(13:16),r(17:20),r(21:24),r(25:28),r(29:32)); end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
