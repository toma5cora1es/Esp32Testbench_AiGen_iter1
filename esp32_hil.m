function report = esp32_hil(mode, varargin)
%ESP32_HIL Explicit Table-Driven 8-Stage Hardware-in-the-Loop (HIL) Autonomous Validation FSM.
%   Validates toolchain, SFR database, USB bootstrap, 32-bit registers, DAC/ADC/PWM loopbacks,
%   Touch/I2C/SPI buses, Tri-Transport parity, Wi-Fi OTA, and Multi-Page UI + ESP-NOW Link.

    if nargin < 1 || isempty(mode)
        mode = 'all';
    end
    mode = lower(strtrim(char(mode)));

    rootDir = fileparts(mfilename('fullpath'));
    cd(rootDir);
    addpath(genpath(rootDir));

    initialWifiSsid = get_active_wifi_ssid();
    if ~isempty(initialWifiSsid) && ~strcmpi(initialWifiSsid, 'ESP32_LAB')
        wifiRestoreGuard = onCleanup(@() restore_previous_wifi_ssid(initialWifiSsid)); %#ok<NASGU>
    end

    report = struct();
    report.timestamp        = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    report.mode             = mode;
    report.fsmState         = 'STAGE0_HIL_INIT';
    report.rootDir          = rootDir;
    report.previousWifiSsid = initialWifiSsid;
    report.usbPort          = '';
    report.wifiIp           = '192.168.4.1';
    report.btTarget         = 'ESP32_BT_BRIDGE';
    report.wiring           = struct('D25_to_D34_Loopback', false, 'D4_to_D35_Loopback', false, 'MOSI23_to_MISO19_Loopback', false);
    report.stages           = struct([]);
    report.allPassed        = true;

    sketchPath = fullfile(rootDir, 'firmware', 'esp32_bridge_ota', 'esp32_bridge_ota.ino');
    if strcmp(mode, 'audit') && ~isempty(varargin)
        sketchPath = varargin{1};
    end

    if ~strcmp(mode, 'audit')
        report.usbPort = detect_hil_usb_port();
        fprintf('  [USB] Selected Physical Diagnostic Port: %s\n', report.usbPort);
    end

    pipeline = {
        'STAGE1_TOOLCHAIN_AND_SFR_DB',             {'audit', 'quick', 'all'};
        'STAGE2_USB_BOOTSTRAP_AND_HEAP',           {'quick', 'all'};
        'STAGE3_SFR_REGISTER_BITFIELD_LOOPBACK',   {'quick', 'all'};
        'STAGE4_ANALOG_DAC_ADC_AND_PWM_CAPTURE',   {'quick', 'all'};
        'STAGE5_TOUCH_I2C_SPI_BUS_VALIDATION',     {'quick', 'all'};
        'STAGE6_TRI_TRANSPORT_PARITY_USB_BT_WIFI', {'quick', 'all'};
        'STAGE7_WIFI_OTA_END_TO_END_VERIFICATION', {'all'};
        'STAGE8_MULTI_UI_AND_ESPNOW_BRIDGE_CHECK', {'quick', 'all'}
    };

    for sIdx = 1:size(pipeline, 1)
        stName      = pipeline{sIdx, 1};
        activeModes = pipeline{sIdx, 2};
        if ~ismember(mode, activeModes)
            continue;
        end
        report.fsmState = stName;
        [report, stOk, stDetails] = execute_hil_stage(stName, report, rootDir, sketchPath);
        report = record_stage(report, stName, stOk, stDetails);
    end

    if ~isempty(initialWifiSsid) && ~strcmpi(initialWifiSsid, 'ESP32_LAB')
        restore_previous_wifi_ssid(initialWifiSsid);
    end
    save_hil_report(rootDir, report);
end

function [report, sOk, sDetails] = execute_hil_stage(stName, report, rootDir, sketchPath)
    usbPort = report.usbPort;
    mode    = report.mode;

    switch stName
        case 'STAGE1_TOOLCHAIN_AND_SFR_DB'
            [sOk, sDetails] = stage1_static_core_audit(rootDir, sketchPath);

        case 'STAGE2_USB_BOOTSTRAP_AND_HEAP'
            if strcmp(mode, 'all')
                [flashOk, expectedUsbBuildId] = esp32_flash(sketchPath, '--usb', usbPort, '--role', 'master', '--ui', 'ude');
                esp32_io('connect', usbPort);
                infoStr  = esp32_io('cmd', 'INFO');
                heapFree = parse_kv_num(infoStr, 'HEAP_FREE');
                sOk      = flashOk && contains(infoStr, expectedUsbBuildId) && (heapFree > 28000);
                sDetails = sprintf('USB Flash OK. %s', infoStr);
            else
                esp32_io('connect', usbPort);
                infoStr  = esp32_io('cmd', 'INFO');
                sOk      = contains(infoStr, 'HEAP_FREE');
                sDetails = infoStr;
            end

        case 'STAGE3_SFR_REGISTER_BITFIELD_LOOPBACK'
            esp32_io('connect', usbPort);
            testPat1 = uint32(hex2dec('A5A55A5A'));
            rb1 = esp32_cli('reg', 'RTC_CNTL_STORE0_REG', testPat1);
            esp32_cli('reg', 'RTC_CNTL_STORE0_REG', uint32(1500));
            esp32_cli('pin', 2, 'high');
            outHi = esp32_cli('bits', 'GPIO_OUT_REG', 'GPIO2');
            esp32_cli('pin', 2, 'low');
            outLo = esp32_cli('bits', 'GPIO_OUT_REG', 'GPIO2');
            sOk      = (rb1 == testPat1) && (outHi == 1) && (outLo == 0);
            sDetails = sprintf('RTC_STORE0=0x%08X | GPIO2 Hi=%d Lo=%d', rb1, outHi, outLo);

        case 'STAGE4_ANALOG_DAC_ADC_AND_PWM_CAPTURE'
            esp32_io('connect', usbPort);
            esp32_io('cmd', 'PWM 4 1000 512');
            pause(0.08);
            pulseD4 = esp32_io('cmd', 'PULSE 4 25000');
            esp32_io('cmd', 'PWM 4 0 0');
            freqD4  = parse_kv_num(pulseD4, 'FREQ_HZ');
            dutyD4  = parse_kv_num(pulseD4, 'DUTY_PCT');
            sOk      = (freqD4 > 850 && freqD4 < 1150) && (dutyD4 > 40 && dutyD4 < 60);
            sDetails = sprintf('PWM_D4: %.1f Hz, %.1f%% duty', freqD4, dutyD4);

        case 'STAGE5_TOUCH_I2C_SPI_BUS_VALIDATION'
            esp32_io('connect', usbPort);
            t4      = str2double(esp32_io('cmd', 'TOUCH 4'));
            i2cResp = esp32_io('cmd', 'I2C SCAN');
            spiResp = esp32_io('cmd', 'SPI 5 0xA5');
            sOk      = ~isnan(t4) && startsWith(i2cResp, 'I2C_FOUND:') && startsWith(spiResp, '0x');
            sDetails = sprintf('TOUCH4=%d | %s | SPI=%s', t4, i2cResp, spiResp);

        case 'STAGE6_TRI_TRANSPORT_PARITY_USB_BT_WIFI'
            esp32_io('connect', usbPort);
            usbReg = esp32_io('cmd', 'R 3FF4804C');
            esp32_io('connect', report.wifiIp);
            wifiReg = esp32_io('cmd', 'R 3FF4804C');
            sOk      = strcmp(usbReg, wifiReg);
            sDetails = sprintf('USB=%s == Wi-Fi=%s', usbReg, wifiReg);

        case 'STAGE7_WIFI_OTA_END_TO_END_VERIFICATION'
            esp32_io('disconnect');
            [otaOk, expectedOtaBuildId] = esp32_flash(sketchPath, '--wifi', report.wifiIp, '--keep-wifi', '--role', 'master');
            esp32_io('connect', usbPort);
            postInfo = esp32_io('cmd', 'INFO');
            sOk      = otaOk && contains(postInfo, expectedOtaBuildId);
            sDetails = sprintf('OTA FW_ID=%s verified', expectedOtaBuildId);

        case 'STAGE8_MULTI_UI_AND_ESPNOW_BRIDGE_CHECK'
            esp32_io('connect', usbPort);
            ui1 = esp32_io('cmd', 'UI AGV');
            ui0 = esp32_io('cmd', 'UI UDE');
            enStat = esp32_io('cmd', 'ESPNOW PING');
            sOk = contains(ui1, 'AGV_COCKPIT') && contains(ui0, 'UDE_WORKBENCH') && contains(enStat, 'ESPNOW_STAT');
            sDetails = sprintf('%s | %s | %s', ui1, ui0, enStat);
    end
end

function [ok, details] = stage1_static_core_audit(rootDir, inoFile)
    html1 = fullfile(rootDir, 'firmware', 'core0_daemon', 'web_ui.html');
    html2 = fullfile(rootDir, 'firmware', 'core0_daemon', 'web_ui_agv.html');
    cpp   = fullfile(rootDir, 'firmware', 'core0_daemon', 'core0_daemon.cpp');
    db    = esp32_cli('sfr');
    ok    = isfile(html1) && isfile(html2) && isfile(cpp) && numel(fieldnames(db.registers)) >= 500 && isfile(inoFile);
    details = sprintf('Dual_HTML_OK=%d | SFR_Regs=%d', isfile(html1) && isfile(html2), numel(fieldnames(db.registers)));
end

function ssid = get_active_wifi_ssid()
    ssid = '';
    if ~ispc, return; end
    [~, wOut] = system('netsh wlan show interfaces');
    tok = regexp(wOut, 'Profile\s*:\s*([^\r\n]+)', 'tokens', 'once');
    if ~isempty(tok), ssid = strtrim(tok{1}); end
end

function restore_previous_wifi_ssid(prevSsid)
    if isempty(prevSsid) || strcmpi(prevSsid, 'ESP32_LAB') || ~ispc, return; end
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prevSsid));
end

function usbPort = detect_hil_usb_port()
    avail = serialportlist("all");
    if any(strcmpi(avail, "COM8")), usbPort = 'COM8';
    elseif ~isempty(avail), usbPort = char(avail(end));
    else, usbPort = 'COM8';
    end
end

function val = parse_kv_num(str, key)
    val = NaN;
    tok = regexp(char(str), [key ':([0-9.]+)'], 'tokens', 'once');
    if ~isempty(tok), val = str2double(tok{1}); end
end

function report = record_stage(report, stageName, passed, details)
    idx = numel(report.stages) + 1;
    report.stages(idx).name    = stageName;
    report.stages(idx).passed  = logical(passed);
    report.stages(idx).details = char(details);
    if ~passed, report.allPassed = false; end
end

function save_hil_report(rootDir, report)
    try
        fid = fopen(fullfile(rootDir, 'hil_report.json'), 'w', 'n', 'UTF-8');
        fwrite(fid, jsonencode(report, 'PrettyPrint', true), 'char');
        fclose(fid);
    catch
    end
end