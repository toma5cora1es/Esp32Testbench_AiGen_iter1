function out = inst_tektronix_afg(action, afg, varargin)
%INST_TEKTRONIX_AFG SCPI driver for Tektronix AFG3252C with strict 0..3.30V ESP32 hardware clamps.
    cfg = wb_config('instruments');
    saf = cfg.tektronix_afg3252c.esp32Safety;

    switch lower(strtrim(char(action)))
        case 'open'
            addr = ''; if nargin >= 2 && ~isempty(afg), addr = afg; end
            out = inst_session('open', 'tektronix_afg3252c', addr);
            for ch = 1:2
                inst_session('write', out, sprintf('OUTPut%d:STATe OFF', ch));
                inst_session('write', out, sprintf('OUTPut%d:IMPedance %s', ch, saf.loadImpedance));
                inst_session('write', out, sprintf('SOURce%d:VOLTage:LIMit:HIGH %.3fV', ch, saf.maxAllowedV));
                inst_session('write', out, sprintf('SOURce%d:VOLTage:LIMit:LOW %.3fV', ch, saf.minAllowedV));
            end
        case 'output_wave'
            ch = varargin{1}; shape = upper(char(varargin{2}));
            freqHz = varargin{3}; vLow = varargin{4}; vHigh = varargin{5};
            if vLow < saf.minAllowedV || vHigh > saf.maxAllowedV || vHigh <= vLow
                error('AFG:UnsafeVoltage', 'Requested [%.2f, %.2f]V violates ESP32 limits [%.2f, %.2f]V!', ...
                    vLow, vHigh, saf.minAllowedV, saf.maxAllowedV);
            end
            inst_session('write', afg, sprintf('OUTPut%d:IMPedance %s', ch, saf.loadImpedance));
            inst_session('write', afg, sprintf('SOURce%d:FUNCtion:SHAPe %s', ch, shape));
            inst_session('write', afg, sprintf('SOURce%d:FREQuency:FIXed %.3fHz', ch, freqHz));
            inst_session('write', afg, sprintf('SOURce%d:VOLTage:LEVel:IMMediate:LOW %.3fV', ch, vLow));
            inst_session('write', afg, sprintf('SOURce%d:VOLTage:LEVel:IMMediate:HIGH %.3fV', ch, vHigh));
            inst_session('write', afg, sprintf('OUTPut%d:STATe ON', ch));
            out = true;
        case 'off'
            ch = varargin{1};
            inst_session('write', afg, sprintf('OUTPut%d:STATe OFF', ch));
            out = true;
        case 'close'
            try
                inst_session('write', afg, 'OUTPut1:STATe OFF');
                inst_session('write', afg, 'OUTPut2:STATe OFF');
            catch
            end
            inst_session('close', afg);
            out = true;
    end
end