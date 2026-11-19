function out = inst_lecroy_scope(action, sc, varargin)
%INST_LECROY_SCOPE SCPI driver for Teledyne LeCroy WS4104HD 4-Channel Oscilloscope.
    switch lower(strtrim(char(action)))
        case 'open'
            addr = ''; if nargin >= 2 && ~isempty(sc), addr = sc; end
            out = inst_session('open', 'lecroy_ws4104hd', addr);
            inst_session('write', out, 'COMM_HEADER OFF');
        case 'setup_ch'
            ch = upper(char(varargin{1})); vdiv = varargin{2}; tdiv = varargin{3};
            inst_session('write', sc, sprintf('%s:TRA ON', ch));
            inst_session('write', sc, sprintf('%s:VDIV %.3f', ch, vdiv));
            inst_session('write', sc, sprintf('%s:OFST %.3f', ch, -1.5 * vdiv));
            inst_session('write', sc, sprintf('TDIV %.6g', tdiv));
            out = true;
        case 'trigger_edge'
            ch = upper(char(varargin{1})); lvl = varargin{2};
            inst_session('write', sc, sprintf('TRIG_SELECT EDGE,SR,%s', ch));
            inst_session('write', sc, sprintf('%s:TRLV %.3f', ch, lvl));
            inst_session('write', sc, sprintf('%s:TRSL POS', ch));
            out = true;
        case 'measure_pava'
            ch = upper(char(varargin{1}));
            inst_session('write', sc, 'TRMD SINGLE');
            inst_session('write', sc, 'ARM');
            pause(0.15);
            resp = inst_session('query', sc, sprintf('%s:PAVA? FREQ,DUTY,WID,MEAN,PKPK', ch));
            inst_session('write', sc, 'TRMD AUTO');
            out = parse_lecroy_pava(resp);
        case 'close'
            try inst_session('write', sc, 'TRMD AUTO'); catch, end
            inst_session('close', sc);
            out = true;
    end
end

function s = parse_lecroy_pava(resp)
    s = struct('raw', resp, 'FREQ', NaN, 'DUTY', NaN, 'WID', NaN, 'MEAN', NaN, 'PKPK', NaN);
    parts = strsplit(char(resp), ',');
    for k = 1:numel(parts)-1
        key = upper(strtrim(parts{k}));
        if isfield(s, key)
            val = str2double(strtrim(parts{k+1}));
            if ~isnan(val), s.(key) = val; end
        end
    end
end