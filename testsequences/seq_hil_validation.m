function report = seq_hil_validation(mode, usbPort)
%SEQ_HIL_VALIDATION 8-Stage Generic Core & Hardware-in-the-Loop Validation FSM.
    if nargin < 1 || isempty(mode), mode = 'all'; end
    mode = lower(strtrim(char(mode)));
    cfg   = wb_config('workbench');
    board = wb_config('board', 'green_agv_rev52a');
    sketchPath = wb_paths('sketch', 'esp32_sfr_core');

    prevSsid = esp32_io('get_ssid');
    if ~isempty(prevSsid) && ~strcmpi(prevSsid, cfg.transport.wifi.apSsid)
        wifiGuard = onCleanup(@() esp32_io('restore_ssid', prevSsid)); %#ok<NASGU>
    end

    if ~strcmp(mode, 'audit') && (nargin < 2 || isempty(usbPort)), usbPort = esp32_io('detect_port');
    elseif strcmp(mode, 'audit'), usbPort = ''; end

    report = struct('mode',mode,'usbPort',usbPort,'wifiIp',cfg.transport.wifi.apIp,'stages',struct([]),'allPassed',true);
    pipeline = {
        'STAGE1_TOOLCHAIN_CONFIG_AND_SFR',   {'audit','quick','all'};
        'STAGE2_USB_FLASH_AND_HEAP',         {'quick','all'};
        'STAGE3_SFR_BITFIELD_LOOPBACK',      {'quick','all'};
        'STAGE4_LEDC_PWM_AND_PULSE_CAPTURE', {'quick','all'};
        'STAGE5_TOUCH_I2C_SPI_BUS_PROBE',    {'quick','all'};
        'STAGE6_TRANSPORT_PARITY',           {'quick','all'};
        'STAGE7_WIFI_OTA_E2E',               {'all'};
        'STAGE8_MULTI_UI_AND_ESPNOW',        {'quick','all'}
    };

    for idx = 1:size(pipeline, 1)
        if ~ismember(mode, pipeline{idx, 2}), continue; end
        st = pipeline{idx, 1};
        [ok, det] = run_stage(st, mode, usbPort, sketchPath, cfg, board);
        n = numel(report.stages) + 1;
        report.stages(n).name = st; report.stages(n).passed = logical(ok); report.stages(n).details = char(det);
        if ~ok, report.allPassed = false; end
        wb_log(iif(ok,'pass','fail'), 'HIL', st, det);
    end
    wb_results('hil_validation', mode, report);
end

function [ok, det] = run_stage(st, mode, usbPort, sketchPath, cfg, board)
    switch st
        case 'STAGE1_TOOLCHAIN_CONFIG_AND_SFR'
            dDir = wb_paths('daemon');
            okD = isfile(fullfile(dDir,'core0_daemon.cpp')) && isfile(fullfile(dDir,'web_ui.html'));
            db = jsondecode(fileread(wb_paths('sfrDb')));
            ok = okD && isfile(sketchPath) && numel(fieldnames(db.registers)) >= 500;
            det = sprintf('Daemon=%d | Sketch=%d | SFR=%d', okD, isfile(sketchPath), numel(fieldnames(db.registers)));
        case 'STAGE2_USB_FLASH_AND_HEAP'
            if strcmp(mode, 'all')
                [fOk, bid] = esp32_flash(sketchPath, '--usb', usbPort, '--role', 'master');
                esp32_io('connect', usbPort); info = esp32_io('cmd', 'INFO');
                ok = fOk && contains(info, bid) && parse_kv(info,'HEAP_FREE') > 28000; det = info;
            else
                esp32_io('connect', usbPort); info = esp32_io('cmd', 'INFO');
                ok = contains(info, 'HEAP_FREE'); det = info;
            end
        case 'STAGE3_SFR_BITFIELD_LOOPBACK'
            esp32_io('connect', usbPort);
            pat = uint32(hex2dec('A5A55A5A')); sfrName = board.registers.commandWordSfr;
            rb = esp32_cli('reg', sfrName, pat);
            esp32_cli('reg', sfrName, uint32(hex2dec('10000000')));
            led = board.pins.builtinLed;
            esp32_cli('pin', led, 'high'); hi = esp32_cli('bits', 'GPIO_OUT_REG', sprintf('GPIO%d', led));
            esp32_cli('pin', led, 'low');  lo = esp32_cli('bits', 'GPIO_OUT_REG', sprintf('GPIO%d', led));
            ok = (rb == pat) && (hi == 1) && (lo == 0);
            det = sprintf('%s=0x%08X | GPIO%d Hi=%d Lo=%d', sfrName, rb, led, hi, lo);
        case 'STAGE4_LEDC_PWM_AND_PULSE_CAPTURE'
            esp32_io('connect', usbPort); p = board.pins.masterRttStrobe;
            esp32_io('cmd', sprintf('PWM %d 1000 512', p)); pause(0.08);
            cap = esp32_io('cmd', sprintf('PULSE %d 25000', p));
            esp32_io('cmd', sprintf('PWM %d 0 0', p));
            fq = parse_kv(cap,'FREQ_HZ'); du = parse_kv(cap,'DUTY_PCT');
            ok = (fq > 850 && fq < 1150) && (du > 40 && du < 60);
            det = sprintf('GPIO%d PWM: %.1f Hz, %.1f%%', p, fq, du);
        case 'STAGE5_TOUCH_I2C_SPI_BUS_PROBE'
            esp32_io('connect', usbPort);
            tp = str2double(esp32_io('cmd', sprintf('TOUCH %d', board.touchPins(1).gpio)));
            i2c = esp32_io('cmd', 'I2C SCAN');
            spi = esp32_io('cmd', sprintf('SPI %d 0xA5', board.pins.vspiCs));
            ok = ~isnan(tp) && startsWith(i2c,'I2C_FOUND:') && startsWith(spi,'0x');
            det = sprintf('Touch=%d | %s | SPI=%s', tp, i2c, spi);
        case 'STAGE6_TRANSPORT_PARITY'
            sfrName = board.registers.commandWordSfr;
            esp32_io('connect', usbPort); uVal = esp32_cli('reg', sfrName);
            esp32_io('connect', cfg.transport.wifi.apIp); wVal = esp32_cli('reg', sfrName);
            ok = (uVal == wVal); det = sprintf('USB=0x%08X == WiFi=0x%08X', uVal, wVal);
        case 'STAGE7_WIFI_OTA_E2E'
            esp32_io('disconnect');
            [oOk, oBid] = esp32_flash(sketchPath, '--wifi', cfg.transport.wifi.apIp, '--keep-wifi', '--role', 'master');
            esp32_io('connect', usbPort); info = esp32_io('cmd', 'INFO');
            ok = oOk && contains(info, oBid); det = ['OTA Build=' oBid];
        case 'STAGE8_MULTI_UI_AND_ESPNOW'
            esp32_io('connect', usbPort);
            u1 = esp32_io('cmd', 'UI APP'); u0 = esp32_io('cmd', 'UI UDE');
            en = esp32_io('cmd', 'ESPNOW PING');
            ok = contains(u1,'APP_UI') && contains(u0,'UDE_WORKBENCH') && contains(en,'ESPNOW_STAT');
            det = [u1 ' | ' u0 ' | ' en];
    end
end
function v = parse_kv(s, k), v=NaN; t=regexp(char(s),[k ':([0-9.]+)'],'tokens','once'); if ~isempty(t), v=str2double(t{1}); end; end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end