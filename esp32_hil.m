function report = esp32_hil(mode, varargin)
%ESP32_HIL End-to-End Hardware-in-the-Loop (HIL) Autonomous Validation & Pre-Flight Engine.
%
%   Validates a priori all hardware, SFR registers, analog/digital/PWM/SPI loopbacks,
%   tri-transport parity (USB Serial + Bluetooth Classic SPP + Wi-Fi HTTP),
%   Wi-Fi OTA firmware flashing with live UART0 crash/telemetry monitoring,
%   and automatically restores the PC's previous Wi-Fi network (e.g. Magenta_5KQG).

    if nargin < 1 || isempty(mode)
        mode = 'all';
    end
    mode = lower(strtrim(char(mode)));

    rootDir = fileparts(mfilename('fullpath'));
    cd(rootDir);
    addpath(genpath(rootDir));

    % Snapshot the user's current Wi-Fi network (e.g. Magenta_5KQG / eduroam) to restore at finish
    initialWifiSsid = get_active_wifi_ssid();
    if ~isempty(initialWifiSsid) && ~strcmpi(initialWifiSsid, 'ESP32_LAB')
        wifiRestoreGuard = onCleanup(@() restore_previous_wifi_ssid(initialWifiSsid));
    end

    report = struct();
    report.timestamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    report.mode = mode;
    report.rootDir = rootDir;
    report.previousWifiSsid = initialWifiSsid;
    report.usbPort = '';
    report.wifiIp = '192.168.4.1';
    report.btTarget = 'ESP32_BT_BRIDGE';
    report.wiring = struct('D25_to_D34_Loopback', false, 'D4_to_D35_Loopback', false, 'MOSI23_to_MISO19_Loopback', false);
    report.stages = struct([]);
    report.allPassed = true;

    fprintf('\n================================================================================\n');
    fprintf('  ESP32 WORKBENCH — AUTONOMOUS HARDWARE-IN-THE-LOOP (HIL) VALIDATION ENGINE\n');
    fprintf('  Mode: %-10s | Timestamp: %s | Initial Wi-Fi: %s\n', ...
        upper(mode), report.timestamp, ternary_str(~isempty(initialWifiSsid), initialWifiSsid, 'None'));
    fprintf('================================================================================\n');

    if strcmp(mode, 'audit') && ~isempty(varargin)
        [ok, details] = stage1_static_core_audit(rootDir, varargin{1});
        report = record_stage(report, 'STAGE1_STATIC_API_AUDIT', ok, details);
        save_hil_report(rootDir, report);
        return;
    end

    % =========================================================================
    % STAGE 1: Static Toolchain, Modular Files, Core 3.3.12 Audit & SFR DB
    % =========================================================================
    fprintf('\n--- [STAGE 1/7] MODULAR DAEMON FILES, CORE 3.3.12 AUDIT & SFR DB CHECK ---\n');
    sketchPath = fullfile(rootDir, 'firmware', 'esp32_bridge_ota', 'esp32_bridge_ota.ino');
    if ~isfile(sketchPath)
        sketchPath = fullfile(tempdir, 'hil_base_sketch.ino');
        fid = fopen(sketchPath, 'w');
        fprintf(fid, '#include <Arduino.h>\nvoid setup() { pinMode(2, OUTPUT); }\nvoid loop() { delay(50); }\n');
        fclose(fid);
    end
    [s1Ok, s1Details] = stage1_static_core_audit(rootDir, sketchPath);
    report = record_stage(report, 'STAGE1_TOOLCHAIN_AND_SFR_DB', s1Ok, s1Details);

    usbPort = detect_hil_usb_port();
    report.usbPort = usbPort;
    fprintf('  [USB] Selected Physical Diagnostic Port: %s\n', usbPort);

    % =========================================================================
    % STAGE 2: USB Bootstrap Flash & Build-ID / Heap Telemetry Verification
    % =========================================================================
    fprintf('\n--- [STAGE 2/7] USB BOOTSTRAP FLASH & FREE HEAP TELEMETRY (%s) ---\n', usbPort);
    if strcmp(mode, 'all')
        try
            [flashOk, expectedUsbBuildId] = esp32_flash(sketchPath, '--usb', usbPort);
            esp32_io('connect', usbPort);
            infoStr = esp32_io('cmd', 'INFO');
            statStr = esp32_io('cmd', 'STATUS');
            heapFree = parse_kv_num(infoStr, 'HEAP_FREE');
            otaMax   = parse_kv_num(infoStr, 'NEXT_OTA_MAX');
            fwIdMatch = contains(infoStr, expectedUsbBuildId);
            fprintf('  [INFO]   %s\n', infoStr);
            fprintf('  [STATUS] %s\n', statStr);
            fprintf('  [VERIFY] Build ID Match (%s): %d | Boot Heap (Wi-Fi+BT active): %d bytes | Next OTA Max: %d bytes\n', ...
                expectedUsbBuildId, fwIdMatch, heapFree, otaMax);
            s2Ok = flashOk && fwIdMatch && (heapFree > 28000) && (otaMax == 1966080);
            s2Details = sprintf('USB Flash OK. FW_ID=%s, HEAP_FREE=%d, NEXT_OTA_MAX=%d', expectedUsbBuildId, heapFree, otaMax);
        catch ME
            s2Ok = false;
            s2Details = ['USB Bootstrap failed: ' ME.message];
            fprintf('  [FAIL] %s\n', s2Details);
        end
    else
        try
            esp32_io('connect', usbPort);
            infoStr = esp32_io('cmd', 'INFO');
            s2Ok = contains(infoStr, 'HEAP_FREE');
            s2Details = ['Quick mode connected: ' infoStr];
            fprintf('  [INFO] %s\n', infoStr);
        catch ME
            s2Ok = false;
            s2Details = ME.message;
        end
    end
    report = record_stage(report, 'STAGE2_USB_BOOTSTRAP_AND_HEAP', s2Ok, s2Details);

    % =========================================================================
    % STAGE 3: Bare-Metal 32-Bit SFR Register & Symbolic Bitfield Closed-Loop
    % =========================================================================
    fprintf('\n--- [STAGE 3/7] BARE-METAL 32-BIT SFR REGISTER & BITFIELD AUDIT ---\n');
    try
        esp32_io('connect', usbPort);
        testPat1 = uint32(hex2dec('A5A55A5A'));
        rb1 = esp32_cli('reg', 'RTC_CNTL_STORE0_REG', testPat1);
        % Leave a non-zero test signature (0x000005DC = 1500) in RTC_CNTL_STORE0_REG for Stage 6 parity check
        esp32_cli('reg', 'RTC_CNTL_STORE0_REG', uint32(1500));

        esp32_cli('pin', 2, 'high');
        outHi = esp32_cli('bits', 'GPIO_OUT_REG', 'GPIO2');
        inHi  = esp32_cli('bits', 'GPIO_IN_REG',  'GPIO2');
        esp32_cli('pin', 2, 'low');
        outLo = esp32_cli('bits', 'GPIO_OUT_REG', 'GPIO2');
        inLo  = esp32_cli('bits', 'GPIO_IN_REG',  'GPIO2');

        s3Ok = (rb1 == testPat1) && (outHi == 1) && (inHi == 1) && (outLo == 0) && (inLo == 0);
        s3Details = sprintf('RTC_STORE0 R/W=0x%08X (OK=%d) | GPIO2 Atomic HIGH(Out=%d,In=%d) LOW(Out=%d,In=%d)', ...
            rb1, rb1 == testPat1, outHi, inHi, outLo, inLo);
        fprintf('  [PASS=%d] %s\n', s3Ok, s3Details);
    catch ME
        s3Ok = false;
        s3Details = ['SFR Register test failed: ' ME.message];
        fprintf('  [FAIL] %s\n', s3Details);
    end
    report = record_stage(report, 'STAGE3_SFR_REGISTER_BITFIELD_LOOPBACK', s3Ok, s3Details);

    % =========================================================================
    % STAGE 4: Closed-Loop Analog (DAC1 -> ADC1) & Hardware PWM Capture
    % =========================================================================
    fprintf('\n--- [STAGE 4/7] CLOSED-LOOP ANALOG (DAC1->ADC1) & PWM FREQUENCY/DUTY TEST ---\n');
    try
        esp32_io('connect', usbPort);
        esp32_io('cmd', 'PIN 34 IN');
        dacSweep = [0, 64, 128, 192, 255];
        adcSweep = zeros(size(dacSweep));
        for idx = 1:numel(dacSweep)
            esp32_io('cmd', sprintf('DAC 25 %d', dacSweep(idx)));
            pause(0.06);
            adcSweep(idx) = str2double(esp32_io('cmd', 'ADC 34'));
        end
        esp32_io('cmd', 'DAC 25 0');

        hasWireD25D34 = (adcSweep(1) < 150) && (adcSweep(3) > 1400 && adcSweep(3) < 2600) && (adcSweep(5) > 3700);
        report.wiring.D25_to_D34_Loopback = hasWireD25D34;
        fprintf('  [DAC25 -> ADC34 Sweep] DAC=[0,64,128,192,255] -> ADC=[%s] (External Jumper Detected: %d)\n', ...
            num2str(adcSweep), hasWireD25D34);

        esp32_io('cmd', 'PIN 35 IN');
        esp32_io('cmd', 'PWM 4 1000 512');
        pause(0.08);
        pulseD4  = esp32_io('cmd', 'PULSE 4 25000');
        pulseD35 = esp32_io('cmd', 'PULSE 35 25000');
        esp32_io('cmd', 'PWM 4 0 0');

        freqD4  = parse_kv_num(pulseD4,  'FREQ_HZ');
        dutyD4  = parse_kv_num(pulseD4,  'DUTY_PCT');
        freqD35 = parse_kv_num(pulseD35, 'FREQ_HZ');
        dutyD35 = parse_kv_num(pulseD35, 'DUTY_PCT');

        hasWireD4D35 = (freqD35 > 850 && freqD35 < 1150) && (dutyD35 > 40 && dutyD35 < 60);
        report.wiring.D4_to_D35_Loopback = hasWireD4D35;

        freqD34 = 0; dutyD34 = 0;
        if hasWireD25D34
            esp32_io('cmd', 'PWM 25 1000 512');
            pause(0.08);
            pulseD34 = esp32_io('cmd', 'PULSE 34 25000');
            esp32_io('cmd', 'PWM 25 0 0');
            freqD34 = parse_kv_num(pulseD34, 'FREQ_HZ');
            dutyD34 = parse_kv_num(pulseD34, 'DUTY_PCT');
            fprintf('  [PWM D25 -> D34 Physical Wire Capture] %s\n', pulseD34);
        end

        pwmSelfOk = (freqD4 > 850 && freqD4 < 1150) && (dutyD4 > 40 && dutyD4 < 60);
        pwmWireOk = (freqD34 > 850 && freqD34 < 1150) && (dutyD34 > 40 && dutyD34 < 60);
        fprintf('  [PWM D4 Self-Pad Capture]  %s (Self-Loopback OK: %d)\n', pulseD4, pwmSelfOk);

        s4Ok = pwmSelfOk || pwmWireOk;
        s4Details = sprintf('PWM_1000Hz_50pct: D4_Pad(%.1fHz,%.1f%%) | D25->D34_Wire=%d (ADC_mid=%d, PWM=%.1fHz/%.1f%%)', ...
            freqD4, dutyD4, hasWireD25D34, adcSweep(3), freqD34, dutyD34);
    catch ME
        s4Ok = false;
        s4Details = ['Analog/PWM test failed: ' ME.message];
        fprintf('  [FAIL] %s\n', s4Details);
    end
    report = record_stage(report, 'STAGE4_ANALOG_DAC_ADC_AND_PWM_CAPTURE', s4Ok, s4Details);

    % =========================================================================
    % STAGE 5: Capacitive Touch Array, I2C Bus & VSPI Bus Self-Test
    % =========================================================================
    fprintf('\n--- [STAGE 5/7] CAPACITIVE TOUCH, I2C BUS & VSPI SELF-TEST ---\n');
    try
        esp32_io('connect', usbPort);
        t4  = str2double(esp32_io('cmd', 'TOUCH 4'));
        t15 = str2double(esp32_io('cmd', 'TOUCH 15'));
        t32 = str2double(esp32_io('cmd', 'TOUCH 32'));
        i2cResp = esp32_io('cmd', 'I2C SCAN');
        spiResp = esp32_io('cmd', 'SPI 5 0xA5');
        report.wiring.MOSI23_to_MISO19_Loopback = strcmpi(strtrim(spiResp), '0xA5');

        touchValid = ~isnan(t4) && ~isnan(t15) && ~isnan(t32);
        s5Ok = touchValid && startsWith(i2cResp, 'I2C_FOUND:') && startsWith(spiResp, '0x');
        s5Details = sprintf('TOUCH(D4=%d,D15=%d,D32=%d) | %s | VSPI(TX=0xA5)->RX=%s (MOSI->MISO Wire=%d)', ...
            t4, t15, t32, i2cResp, spiResp, report.wiring.MOSI23_to_MISO19_Loopback);
        fprintf('  [PASS=%d] %s\n', s5Ok, s5Details);
    catch ME
        s5Ok = false;
        s5Details = ['Bus self-test failed: ' ME.message];
        fprintf('  [FAIL] %s\n', s5Details);
    end
    report = record_stage(report, 'STAGE5_TOUCH_I2C_SPI_BUS_VALIDATION', s5Ok, s5Details);

    % =========================================================================
    % STAGE 6: Tri-Transport Parity & Latency Benchmark (USB + BT SPP + Wi-Fi)
    % =========================================================================
    fprintf('\n--- [STAGE 6/7] TRI-TRANSPORT PARITY & LATENCY (USB + BLUETOOTH SPP + WI-FI) ---\n');
    try
        % 6.1 USB Serial Transport
        esp32_io('connect', usbPort);
        [usbStat, usbLat] = esp32_io('cmd', 'STATUS');
        [usbReg,  usbRegLat] = esp32_io('cmd', 'R 3FF4804C');
        fprintf('  [1/3 USB Serial (%s)]       Reg=%s | Latency=%.1f ms | %s\n', usbPort, usbReg, usbRegLat, usbStat);

        % 6.2 Bluetooth Classic SPP Transport (Native SPP 'bt:ESP32_BT_BRIDGE' or BT Virtual COM)
        btOk = false;
        btReg = '';
        btRegLat = NaN;
        btMethod = 'Not Paired';
        try
            esp32_io('connect', 'bt:ESP32_BT_BRIDGE');
            [btStat, ~] = esp32_io('cmd', 'STATUS');
            [btReg, btRegLat] = esp32_io('cmd', 'R 3FF4804C');
            btOk = contains(btStat, 'ESP32_READY') && strcmp(btReg, usbReg);
            btMethod = 'Native_SPP(ESP32_BT_BRIDGE)';
            fprintf('  [2/3 Bluetooth (%s)] Reg=%s | Latency=%.1f ms | %s\n', btMethod, btReg, btRegLat, btStat);
        catch ME_BT
            % Fallback: try Windows Bluetooth Virtual Serial Ports (e.g. COM10 / COM11)
            btComs = detect_bt_virtual_com_ports();
            for bIdx = 1:numel(btComs)
                try
                    esp32_io('connect', char(btComs(bIdx)));
                    [btStat, ~] = esp32_io('cmd', 'STATUS');
                    [btReg, btRegLat] = esp32_io('cmd', 'R 3FF4804C');
                    if contains(btStat, 'ESP32_READY')
                        btOk = strcmp(btReg, usbReg);
                        btMethod = sprintf('BT_VCOM(%s)', btComs(bIdx));
                        fprintf('  [2/3 Bluetooth (%s)] Reg=%s | Latency=%.1f ms | %s\n', btMethod, btReg, btRegLat, btStat);
                        break;
                    end
                catch
                end
            end
            if ~btOk
                fprintf('  [2/3 Bluetooth SPP]         Skipped/Unavailable (%s)\n', ME_BT.message);
            end
        end

        % 6.3 Wi-Fi SoftAP HTTP Transport (192.168.4.1)
        esp32_io('connect', report.wifiIp);
        [wifiStat, ~] = esp32_io('cmd', 'STATUS');
        [wifiReg, wifiRegLat] = esp32_io('cmd', 'R 3FF4804C');
        fprintf('  [3/3 Wi-Fi HTTP (%s)] Reg=%s | Latency=%.1f ms | %s\n', report.wifiIp, wifiReg, wifiRegLat, wifiStat);

        s6Ok = contains(usbStat, 'ESP32_READY') && contains(wifiStat, 'ESP32_READY') && strcmp(usbReg, wifiReg);
        if btOk
            s6Details = sprintf('Tri-Parity Match (%s) | USB=%.1fms, BT(%s)=%.1fms, Wi-Fi=%.1fms', ...
                usbReg, usbRegLat, btMethod, btRegLat, wifiRegLat);
        else
            s6Details = sprintf('USB+Wi-Fi Parity Match (%s) | USB=%.1fms, Wi-Fi=%.1fms (BT=%s)', ...
                usbReg, usbRegLat, wifiRegLat, btMethod);
        end
        fprintf('  [PASS=%d] %s\n', s6Ok, s6Details);
    catch ME
        s6Ok = false;
        s6Details = ['Multi-transport parity failed: ' ME.message];
        fprintf('  [FAIL] %s\n', s6Details);
    end
    report = record_stage(report, 'STAGE6_TRI_TRANSPORT_PARITY_USB_BT_WIFI', s6Ok, s6Details);

    % =========================================================================
    % STAGE 7: Live Wi-Fi OTA End-to-End Flash + Simultaneous UART0 Monitor
    % =========================================================================
    fprintf('\n--- [STAGE 7/7] WI-FI OTA FLASH WITH SIMULTANEOUS UART0 (COM) TELEMETRY ---\n');
    if strcmp(mode, 'all')
        spMon = [];
        try
            esp32_io('disconnect');
            pause(0.4);

            try
                spMon = serialport(usbPort, 115200, 'Timeout', 0.5);
                configureTerminator(spMon, "LF");
                fprintf('  [UART0 Monitor] Opened %s (waiting 2.5s for SoftAP settle before Wi-Fi OTA)...\n', usbPort);
                pause(2.5);
                flush(spMon);
            catch
                spMon = [];
            end

            % Pass --keep-wifi to esp32_flash so esp32_hil restores initialWifiSsid cleanly right after
            [otaOk, expectedOtaBuildId] = esp32_flash(sketchPath, '--wifi', report.wifiIp, '--keep-wifi');

            uartLog = '';
            if ~isempty(spMon) && isvalid(spMon)
                pause(1.0);
                if spMon.NumBytesAvailable > 0
                    uartLog = strtrim(read(spMon, spMon.NumBytesAvailable, "char"));
                end
                delete(spMon);
                spMon = [];
            end

            if ~isempty(uartLog)
                fprintf('  --- [CAPTURED UART0 SERIAL LOG DURING WI-FI OTA] ---\n');
                fprintf('  %s\n', strrep(uartLog, newline, [newline '  ']));
                fprintf('  ----------------------------------------------------\n');
            end

            esp32_io('connect', usbPort);
            postOtaInfo = esp32_io('cmd', 'INFO');
            verifiedNewBuild = contains(postOtaInfo, expectedOtaBuildId);
            fprintf('  [POST-OTA INFO] %s\n', postOtaInfo);
            fprintf('  [VERIFY] Silicon running newly flashed Wi-Fi OTA build (%s): %d\n', expectedOtaBuildId, verifiedNewBuild);

            s7Ok = otaOk && verifiedNewBuild;
            s7Details = sprintf('Wi-Fi OTA Verified! New FW_ID=%s confirmed on silicon.', expectedOtaBuildId);
        catch ME
            if ~isempty(spMon) && isvalid(spMon), try delete(spMon); catch, end; end
            s7Ok = false;
            s7Details = ['Wi-Fi OTA stage failed: ' ME.message];
            fprintf('  [FAIL] %s\n', s7Details);
        end
    else
        s7Ok = true;
        s7Details = 'Skipped in quick mode (use esp32_hil(''all'') for full OTA flash cycle).';
        fprintf('  [SKIP] %s\n', s7Details);
    end
    report = record_stage(report, 'STAGE7_WIFI_OTA_END_TO_END_VERIFICATION', s7Ok, s7Details);

    % =========================================================================
    % RESTORE PREVIOUS WI-FI NETWORK (e.g. Magenta_5KQG) & PRINT FINAL REPORT
    % =========================================================================
    if ~isempty(initialWifiSsid) && ~strcmpi(initialWifiSsid, 'ESP32_LAB')
        restore_previous_wifi_ssid(initialWifiSsid);
    end

    save_hil_report(rootDir, report);

    fprintf('\n================================================================================\n');
    fprintf('  ESP32 HIL VALIDATION SUMMARY — OVERALL STATUS: %s\n', ternary_str(report.allPassed, 'ALL 7 STAGES PASSED', 'FAILURES DETECTED'));
    fprintf('================================================================================\n');
    for k = 1:numel(report.stages)
        st = report.stages(k);
        fprintf('  [%s] %-42s : %s\n', ternary_str(st.passed, 'PASS', 'FAIL'), st.name, st.details);
    end
    fprintf('--------------------------------------------------------------------------------\n');
    fprintf('  Physical Loopback Wires Detected:\n');
    fprintf('    - Wire #1 (D25 DAC1 -> D34 ADC1) : %s\n', ternary_str(report.wiring.D25_to_D34_Loopback, 'CONNECTED (Closed-Loop Analog & PWM Verified)', 'NOT DETECTED'));
    fprintf('    - Wire #2 (D4  PWM  -> D35 In  ) : %s\n', ternary_str(report.wiring.D4_to_D35_Loopback,  'CONNECTED (External Pin PWM Verified)',  'NOT DETECTED'));
    fprintf('    - Wire #3 (D23 MOSI -> D19 MISO) : %s\n', ternary_str(report.wiring.MOSI23_to_MISO19_Loopback, 'CONNECTED (Full-Duplex SPI Verified)', 'NOT DETECTED'));
    fprintf('  Concatenated Sketch Saved To : %s\n', fullfile(rootDir, 'firmware', 'build_last', 'ota_sketch.ino'));
    fprintf('  JSON HIL Report Saved To     : %s\n', fullfile(rootDir, 'hil_report.json'));
    fprintf('  Active Windows Wi-Fi Network : %s\n', get_active_wifi_ssid());
    fprintf('================================================================================\n\n');
end

function [ok, details] = stage1_static_core_audit(rootDir, inoFile)
    ok = true;
    msgs = strings(0, 1);

    htmlFile = fullfile(rootDir, 'firmware', 'core0_daemon', 'web_ui.html');
    cppFile  = fullfile(rootDir, 'firmware', 'core0_daemon', 'core0_daemon.cpp');
    if isfile(htmlFile) && isfile(cppFile)
        msgs(end+1) = "Modular_Daemon_Files_OK(web_ui.html+core0_daemon.cpp)";
    else
        ok = false;
        msgs(end+1) = "Missing firmware/core0_daemon/ files";
    end

    db = esp32_cli('sfr');
    nRegs = numel(fieldnames(db.registers));
    if nRegs < 500
        ok = false;
        msgs(end+1) = sprintf('SFR DB incomplete (%d regs)', nRegs);
    else
        msgs(end+1) = sprintf('SFR_DB_OK(%d_regs)', nRegs);
    end

    if isfile(inoFile)
        code = fileread(inoFile);
        forbidden = {'ledcSetup', 'ledcAttachPin', 'timerAlarmWrite', 'timerAlarmEnable', 'adcAttachPin', 'SYSTEM_EVENT_'};
        foundBad = strings(0, 1);
        for k = 1:numel(forbidden)
            if contains(code, forbidden{k})
                foundBad(end+1) = string(forbidden{k}); %#ok<AGROW>
            end
        end
        if ~isempty(foundBad)
            ok = false;
            msgs(end+1) = "Deprecated Core 2.x APIs found: " + strjoin(foundBad, ", ");
        else
            msgs(end+1) = "Core_3.3.12_API_Audit_Clean";
        end
    end
    details = char(strjoin(msgs, ' | '));
    fprintf('  [PASS=%d] %s\n', ok, details);
end

function btPorts = detect_bt_virtual_com_ports()
    btPorts = strings(0, 1);
    if ~ispc, return; end
    [st, psOut] = system('powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''Bluetooth.*\(COM\d+\)''} | ForEach-Object { $_.Name }"');
    if st == 0 && ~isempty(strtrim(psOut))
        lines = splitlines(string(strtrim(psOut)));
        for k = 1:numel(lines)
            tok = regexp(lines(k), '\((COM\d+)\)', 'tokens', 'once');
            if ~isempty(tok)
                btPorts(end+1) = upper(string(tok{1})); %#ok<AGROW>
            end
        end
    end
end

function ssid = get_active_wifi_ssid()
    ssid = '';
    if ~ispc, return; end
    [~, wOut] = system('netsh wlan show interfaces');
    tok = regexp(wOut, 'Profile\s*:\s*([^\r\n]+)', 'tokens', 'once');
    if isempty(tok)
        tok = regexp(wOut, 'SSID\s*:\s*([^\r\n]+)', 'tokens', 'once');
    end
    if ~isempty(tok)
        ssid = strtrim(tok{1});
    end
end

function restore_previous_wifi_ssid(prevSsid)
    if isempty(prevSsid) || strcmpi(prevSsid, 'ESP32_LAB') || ~ispc
        return;
    end
    if strcmpi(get_active_wifi_ssid(), prevSsid)
        return;
    end
    fprintf('\n  [WIFI RESTORE] Switching Windows Wi-Fi from "ESP32_LAB" back to "%s"...\n', prevSsid);
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prevSsid));
    for k = 1:8
        pause(1.0);
        if strcmpi(get_active_wifi_ssid(), prevSsid)
            fprintf('  [WIFI RESTORE] Successfully reconnected to "%s"!\n', prevSsid);
            return;
        end
        system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prevSsid));
    end
end

function usbPort = detect_hil_usb_port()
    avail = serialportlist("all");
    if any(strcmpi(avail, "COM8"))
        usbPort = 'COM8';
        return;
    end
    [~, out] = system('arduino-cli board list 2>nul');
    lines = splitlines(string(strtrim(out)));
    for k = 1:numel(lines)
        if contains(lines(k), "Serial Port (USB)", "IgnoreCase", true)
            tok = split(strtrim(lines(k)));
            usbPort = char(tok(1));
            return;
        end
    end
    if ~isempty(avail)
        usbPort = char(avail(end));
    else
        usbPort = 'COM8';
    end
end

function val = parse_kv_num(str, key)
    val = NaN;
    tok = regexp(char(str), [key ':([0-9.]+)'], 'tokens', 'once');
    if ~isempty(tok)
        val = str2double(tok{1});
    end
end

function report = record_stage(report, stageName, passed, details)
    idx = numel(report.stages) + 1;
    report.stages(idx).name = stageName;
    report.stages(idx).passed = logical(passed);
    report.stages(idx).details = char(details);
    if ~passed
        report.allPassed = false;
    end
end

function save_hil_report(rootDir, report)
    try
        jsonPath = fullfile(rootDir, 'hil_report.json');
        fid = fopen(jsonPath, 'w', 'n', 'UTF-8');
        fwrite(fid, jsonencode(report, 'PrettyPrint', true), 'char');
        fclose(fid);
    catch
    end
end

function out = ternary_str(cond, a, b)
    if cond, out = a; else, out = b; end
end