function report = seq_adc_dynamic_cal(targetEndpoint, adcPin, useAfg)
%SEQ_ADC_DYNAMIC_CAL Closed-Loop ADC1 Calibration (Keysight CH3 DC + Tektronix AFG3252C + LeCroy Scope).
    if nargin < 1 || isempty(targetEndpoint), targetEndpoint = esp32_io('detect_port'); end
    board = wb_config('board');
    if nargin < 2 || isempty(adcPin), adcPin = board.adc1Channels(3).gpio; end
    if nargin < 3 || isempty(useAfg), useAfg = false; end

    instCfg = wb_config('instruments');
    ks = inst_keysight_psu('open');
    ch3 = instCfg.keysight_e36312a.channels.adcStimulusDc;
    inst_keysight_psu('config', ks, ch3.ch, 0.0, ch3.currentLimitA, true);
    afg = [];
    if useAfg, afg = inst_tektronix_afg('open'); end
    guard = onCleanup(@() cleanup(ks, afg, ch3.ch)); %#ok<NASGU>

    esp32_cli('verbose', 'off');
    esp32_cli('connect', targetEndpoint);

    vTargets = 0.25:0.25:3.00;
    dcRecs = struct('V_Set',{},'V_Ks',{},'Raw',{},'V_Cal',{},'Err_mV',{});
    fprintf('\n=== CLOSED-LOOP ADC1 DC SWEEP (GPIO %d) ===\n', adcPin);
    for k = 1:numel(vTargets)
        inst_keysight_psu('volt', ks, ch3.ch, vTargets(k)); pause(0.4);
        m = inst_keysight_psu('measure', ks, ch3.ch);
        raw = str2double(esp32_io('cmd', sprintf('ADC %d', adcPin)));
        vCal = wb_calibration('adc1_raw_to_volts', raw);
        errMv = (vCal - m.V) * 1000.0;
        dcRecs(k) = struct('V_Set',vTargets(k),'V_Ks',m.V,'Raw',raw,'V_Cal',vCal,'Err_mV',errMv);
        fprintf('  Set %.2fV | PSU %.4fV | Raw %4d | Cal %.3fV | Err %+6.1f mV\n', vTargets(k), m.V, raw, vCal, errMv);
    end
    inst_keysight_psu('config', ks, ch3.ch, 0.0, ch3.currentLimitA, false);

    dynRecs = [];
    if ~isempty(afg)
        fprintf('\n--- Tektronix AFG3252C Clamped Stimulus (0.20V .. 3.00V, 100 Hz) ---\n');
        inst_tektronix_afg('output_wave', afg, 1, 'SIN', 100.0, 0.20, 3.00);
        pause(0.2);
        samples = zeros(1, 30);
        for s = 1:30
            samples(s) = wb_calibration('adc1_raw_to_volts', str2double(esp32_io('cmd', sprintf('ADC %d', adcPin))));
        end
        inst_tektronix_afg('off', afg, 1);
        dynRecs = struct('Min_V', min(samples), 'Max_V', max(samples), 'Mean_V', mean(samples));
        fprintf('  AFG Dynamic Capture: Min=%.3fV Max=%.3fV Mean=%.3fV\n', dynRecs.Min_V, dynRecs.Max_V, dynRecs.Mean_V);
    end

    cal = wb_calibration('load');
    cal.last_updated = char(datetime('now','Format','yyyy-MM-dd HH:mm:ss'));
    cal.instrument = struct('idn', ks.Idn, 'visa_address', ks.Addr);
    wb_calibration('save', cal);

    lin = [dcRecs.V_Ks] <= 2.55;
    report = struct('AdcPin',adcPin,'DcSweep',dcRecs,'AfgDynamic',dynRecs,'RmsLinError_mV',sqrt(mean([dcRecs(lin).Err_mV].^2)));
    wb_results('adc_dynamic_cal', sprintf('gpio%d', adcPin), report);
end
function cleanup(ks, afg, ch3)
    try inst_keysight_psu('config', ks, ch3, 0.0, 0.05, false); inst_keysight_psu('close', ks); catch, end
    if ~isempty(afg), try inst_tektronix_afg('close', afg); catch, end; end
end