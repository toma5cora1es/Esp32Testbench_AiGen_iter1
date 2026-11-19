function out = wb_calibration(action, arg)
%WB_CALIBRATION Single source of truth for ADC1 voltage conversion and calibration persistence.
    if nargin < 1 || isempty(action), action = 'load'; end
    calFile = wb_paths('hwCalDb');

    switch lower(strtrim(char(action)))
        case 'load'
            if isfile(calFile)
                out = jsondecode(fileread(calFile));
            else
                out = struct('adc1_11db_calibration', struct( ...
                    'offset_volts', 0.108, 'slope_volts_per_fs', 3.227, ...
                    'saturation_knee_raw', 3100, 'knee_comp_volts', 0.135, ...
                    'knee_comp_exp', 1.6, 'vref_clamp_max_v', 3.30));
            end
        case 'adc1_raw_to_volts'
            raw = double(arg);
            if raw <= 0 || isnan(raw), out = 0.0; return; end
            cal = wb_calibration('load');
            m = cal.adc1_11db_calibration;
            v = m.offset_volts + (raw / 4095.0) * m.slope_volts_per_fs;
            if raw > m.saturation_knee_raw
                excess = (raw - m.saturation_knee_raw) / (4095.0 - m.saturation_knee_raw);
                v = v - m.knee_comp_volts * (excess ^ m.knee_comp_exp);
            end
            out = min(max(v, 0.0), m.vref_clamp_max_v);
        case 'save'
            if ~isfolder(wb_paths('databases')), mkdir(wb_paths('databases')); end
            fid = fopen(calFile, 'w', 'n', 'UTF-8');
            fwrite(fid, jsonencode(arg, 'PrettyPrint', true), 'char');
            fclose(fid);
            out = calFile;
        otherwise
            error('WB:UnknownCalAction', 'Unknown calibration action: %s', action);
    end
end