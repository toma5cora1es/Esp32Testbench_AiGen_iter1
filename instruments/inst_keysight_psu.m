function out = inst_keysight_psu(action, ks, varargin)
%INST_KEYSIGHT_PSU SCPI driver for Keysight E36312A Triple-Channel Power Supply.
    switch lower(strtrim(char(action)))
        case 'open'
            addr = ''; if nargin >= 2 && ~isempty(ks), addr = ks; end
            out = inst_session('open', 'keysight_e36312a', addr);
            inst_session('write', out, '*CLS');
        case 'config'
            ch = varargin{1}; v = varargin{2}; iLim = varargin{3}; on = varargin{4};
            inst_session('write', ks, sprintf('VOLT %.3f, (@%d)', v, ch));
            inst_session('write', ks, sprintf('CURR %.3f, (@%d)', iLim, ch));
            inst_session('write', ks, sprintf('OUTP %s, (@%d)', ternary(on,'ON','OFF'), ch));
            out = true;
        case 'volt'
            inst_session('write', ks, sprintf('VOLT %.3f, (@%d)', varargin{2}, varargin{1}));
            out = true;
        case 'measure'
            ch = varargin{1};
            v = str2double(inst_session('query', ks, sprintf('MEAS:VOLT? (@%d)', ch)));
            i = str2double(inst_session('query', ks, sprintf('MEAS:CURR? (@%d)', ch)));
            out = struct('V', v, 'I_A', i, 'I_mA', i * 1000.0, 'P_mW', v * i * 1000.0);
        case 'safe_off'
            cfg = wb_config('instruments');
            c1 = cfg.keysight_e36312a.channels.slaveLogic;
            try
                inst_session('write', ks, sprintf('VOLT %.3f, (@%d)', c1.nominalV, c1.ch));
                inst_session('write', ks, 'OUTP OFF, (@3)');
            catch
            end
            out = true;
        case 'close'
            inst_keysight_psu('safe_off', ks);
            inst_session('close', ks);
            out = true;
    end
end
function r = ternary(c, a, b), if c, r = a; else, r = b; end; end