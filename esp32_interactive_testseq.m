function seqReport = esp32_interactive_testseq(durationSec, masterPort, visaAddr)
%ESP32_INTERACTIVE_TESTSEQ Crash-Proof 2-Minute Interactive Web UI + Keysight E36312A Recorder.
%   - Uses single atomic 'TELEM' serial transaction (with fallback to 'D 3FF4804C 5')
%   - Regex-validates all 5 hexadecimal words so hex2dec NEVER crashes on partial reads
%   - Measures BOTH Keysight CH1 (5.00V Slave ESP32 Logic) and CH2 (4.00V Battery / Motor Rail)
%
%   USAGE:
%     rep = esp32_interactive_testseq(120, 'COM8');

    if nargin < 1 || isempty(durationSec), durationSec = 120; end
    if nargin < 2 || isempty(masterPort),  masterPort  = 'COM8'; end
    if nargin < 3 || isempty(visaAddr)
        visaAddr = 'USB0::0x2A8D::0x1102::MY59004507::0::INSTR';
    end

    fprintf('\n=========================================================================================\n');
    fprintf('  GREEN AGV 2-MINUTE INTERACTIVE WEB UI + KEYSIGHT E36312A TEST SEQUENCE RECORDER\n');
    fprintf('  Duration : %d seconds | Master Port : %s | Keysight VISA : %s\n', durationSec, masterPort, visaAddr);
    fprintf('=========================================================================================\n');

    % 1. Connect to Keysight E36312A:
    %    CH1 = 5.00V / 2.0A (Slave ESP32 5V Logic Rail)
    %    CH2 = 4.00V / 1.0A (Optional: Wire to TP-BATT+ with Switch S2=ON to power 9V Motor Boost!)
    ks = connect_keysight(visaAddr);
    cleanupAll = onCleanup(@() safe_teardown(ks)); %#ok<NASGU>
    idn = ks_query(ks, '*IDN?');
    fprintf('  [KEYSIGHT] %s\n', idn);
    ks_write(ks, 'VOLT 5.000, (@1)'); ks_write(ks, 'CURR 2.000, (@1)'); ks_write(ks, 'OUTP ON, (@1)');
    ks_write(ks, 'VOLT 4.000, (@2)'); ks_write(ks, 'CURR 1.000, (@2)'); ks_write(ks, 'OUTP ON, (@2)');
    pause(1.2);

    % 2. Connect to Master ESP32 on COM8
    esp32_cli('verbose', 'off');
    esp32_cli('connect', masterPort);
    safe_cmd('ROLE MASTER');
    safe_cmd('UI AGV');
    % Initialize Slave into MANUAL_IDLE (Mode=1) instead of E-STOP (Mode=0)
    safe_cmd('W 3FF4804C 11000000');

    ensure_wifi_connected_for_browser();
    fprintf('  [BROWSER]  Launching Web UI Cockpit at http://192.168.4.1/agv ...\n');
    web('http://192.168.4.1/agv', '-browser');

    % 3. Build Real-Time 3-Panel Engineering Strip-Chart Dashboard
    fig = figure('Name', 'Green AGV — 2-Minute Interactive Web UI + Keysight Current Test Sequence', ...
        'Position', [60 60 1320 720], 'Color', [0.07 0.09 0.13]);
    tlo = tiledlayout(fig, 3, 1, 'Padding', 'compact', 'TileSpacing', 'compact');

    axCurr = nexttile(tlo, 1);
    hLineCurr1 = animatedline(axCurr, 'Color', [0.0 0.95 0.55], 'LineWidth', 2.0, 'DisplayName', 'CH1: Slave 5V Logic (mA)');
    hLineCurr2 = animatedline(axCurr, 'Color', [1.0 0.35 0.35], 'LineWidth', 1.8, 'DisplayName', 'CH2: Motor/Batt Rail (mA)');
    ylabel(axCurr, 'Current (mA)', 'Color', 'w');
    title(axCurr, '1. Real-Time Slave AGV Current Draw (Keysight CH1 Logic & CH2 Motor Rail)', 'Color', [0 0.95 1]);
    lgd1 = legend(axCurr, 'Location', 'northeast'); set(lgd1, 'Color', [0.10 0.12 0.16], 'TextColor', 'w');
    set(axCurr, 'Color', [0.11 0.13 0.18], 'XColor', 'w', 'YColor', 'w'); grid(axCurr, 'on');
    xlim(axCurr, [0 durationSec]);

    axCmd = nexttile(tlo, 2);
    hLinePwmL = animatedline(axCmd, 'Color', [0.0 0.75 1.0], 'LineWidth', 1.8, 'DisplayName', 'Motor L (%) [D13/D12]');
    hLinePwmR = animatedline(axCmd, 'Color', [1.0 0.55 0.1], 'LineWidth', 1.8, 'DisplayName', 'Motor R (%) [D4/D2]');
    hLineVel  = animatedline(axCmd, 'Color', [1.0 0.95 0.2], 'LineWidth', 1.5, 'DisplayName', 'Velocity (mm/s)');
    ylabel(axCmd, 'PWM (%) / Vel (mm/s)', 'Color', 'w');
    title(axCmd, '2. Web UI Commanded Motor Duty & Measured Odometry Velocity (D18/D19)', 'Color', [0 0.95 1]);
    lgd2 = legend(axCmd, 'Location', 'northeast'); set(lgd2, 'Color', [0.10 0.12 0.16], 'TextColor', 'w');
    set(axCmd, 'Color', [0.11 0.13 0.18], 'XColor', 'w', 'YColor', 'w'); grid(axCmd, 'on');
    xlim(axCmd, [0 durationSec]);

    axSen = nexttile(tlo, 3);
    hLineUs  = animatedline(axSen, 'Color', [0.85 0.35 1.0], 'LineWidth', 1.8, 'DisplayName', 'HC-SR04 Distance (mm)');
    hLineRtt = animatedline(axSen, 'Color', [0.2 0.95 0.95], 'LineWidth', 1.5, 'DisplayName', 'ESP-NOW RTT x100 (us)');
    ylabel(axSen, 'US (mm) / RTT', 'Color', 'w'); xlabel(axSen, 'Elapsed Time (seconds)', 'Color', 'w');
    title(axSen, '3. Ultrasonic Rangefinder (D27/D26) & ESP-NOW Wireless Latency', 'Color', [0 0.95 1]);
    lgd3 = legend(axSen, 'Location', 'northeast'); set(lgd3, 'Color', [0.10 0.12 0.16], 'TextColor', 'w');
    set(axSen, 'Color', [0.11 0.13 0.18], 'XColor', 'w', 'YColor', 'w'); grid(axSen, 'on');
    xlim(axSen, [0 durationSec]);

    fprintf('\n  Time(s) | CH1 Logic | CH2 Mot  | Action / Mode in Web UI       | PWM(L/R) | US_mm | Line/Btns | RTT(ms)\n');
    fprintf('  --------+-----------+----------+-------------------------------+----------+-------+-----------+--------\n');

    tStart = tic;
    k = 0;
    lastActionTag = '';
    supportsTelemCmd = true;
    records = struct('Time_s', {}, 'V_CH1', {}, 'I_CH1_mA', {}, 'I_CH2_mA', {}, 'P_Total_mW', {}, ...
                     'CmdHex', {}, 'ActionDesc', {}, 'CmdL', {}, 'CmdR', {}, ...
                     'US_mm', {}, 'LineMask', {}, 'BtnT1', {}, 'BtnT2', {}, 'Vel_mms', {}, 'RTT_ms', {});

    while toc(tStart) < durationSec && ishandle(fig)
        tNow = toc(tStart);

        % 1. Query Keysight CH1 (5V Logic) & CH2 (Motor/Battery Supply)
        v1 = str2double(ks_query(ks, 'MEAS:VOLT? (@1)'));
        i1 = str2double(ks_query(ks, 'MEAS:CURR? (@1)')) * 1000.0;
        v2 = str2double(ks_query(ks, 'MEAS:VOLT? (@2)'));
        i2 = str2double(ks_query(ks, 'MEAS:CURR? (@2)')) * 1000.0;
        if isnan(i2) || i2 < 0.5, i2 = 0.0; end

        % 2. Atomic Single-Command Telemetry Fetch (Crash-proof regex parsing)
        [okParse, w0, w1, w2, w3, w4, rttMs, hex0] = fetch_5_words_safely(supportsTelemCmd);
        if ~okParse && supportsTelemCmd
            supportsTelemCmd = false; % Fallback if Master has older firmware without TELEM
            [okParse, w0, w1, w2, w3, w4, rttMs, hex0] = fetch_5_words_safely(false);
        end

        if okParse
            k = k + 1;
            [actDesc, cmdL, cmdR] = decode_store0_action(w0);
            usMm    = double(bitshift(w2, -16));
            senMask = double(bitand(bitshift(w2, -8), 255));
            lineMsk = bitand(senMask, 7);
            btnT1   = bitand(bitshift(senMask, -3), 1);
            btnT2   = bitand(bitshift(senMask, -4), 1);
            velMms  = double(to_int16(bitand(w4, 65535)));

            addpoints(hLineCurr1, tNow, i1);
            addpoints(hLineCurr2, tNow, i2);
            addpoints(hLinePwmL,  tNow, cmdL);
            addpoints(hLinePwmR,  tNow, cmdR);
            addpoints(hLineVel,   tNow, velMms);
            addpoints(hLineUs,    tNow, min(usMm, 2500));
            if ~isnan(rttMs)
                addpoints(hLineRtt, tNow, rttMs * 100.0);
            end

            if ~strcmp(actDesc, lastActionTag)
                xline(axCurr, tNow, '--', actDesc, 'Color', [1 0.8 0.2], ...
                    'LabelOrientation', 'horizontal', 'FontSize', 8, ...
                    'Interpreter', 'none', 'HandleVisibility', 'off');
                lastActionTag = actDesc;
            end

            pTotMw = v1 * i1 + v2 * i2;
            title(axCurr, sprintf('[%.1f / %d s] I_CH1: %.2f mA | I_CH2: %.2f mA | P_tot: %.0f mW | UI: %s | T1=%d T2=%d', ...
                tNow, durationSec, i1, i2, pTotMw, actDesc, btnT1, btnT2), ...
                'Color', [0 0.95 1], 'Interpreter', 'none');
            drawnow limitrate;

            fprintf('  %6.1fs | %6.2f mA | %5.1f mA | %-29s | %3d/%3d%% | %4d  | %s B:%d%d | %5.2f\n', ...
                tNow, i1, i2, actDesc, cmdL, cmdR, usMm, dec2bin(lineMsk, 3), btnT1, btnT2, rttMs);

            records(k).Time_s     = tNow;
            records(k).V_CH1      = v1;
            records(k).I_CH1_mA   = i1;
            records(k).I_CH2_mA   = i2;
            records(k).P_Total_mW = pTotMw;
            records(k).CmdHex     = hex0;
            records(k).ActionDesc = actDesc;
            records(k).CmdL       = cmdL;
            records(k).CmdR       = cmdR;
            records(k).US_mm      = usMm;
            records(k).LineMask   = lineMsk;
            records(k).BtnT1      = btnT1;
            records(k).BtnT2      = btnT2;
            records(k).Vel_mms    = velMms;
            records(k).RTT_ms     = rttMs;
        end
        pause(0.18);
    end

    seqReport = struct( ...
        'Timestamp',      char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        'IDN',            idn, ...
        'Mode',           'interactive_2min_webui_testseq', ...
        'Duration_s',     durationSec, ...
        'MeanCH1_mA',     mean([records.I_CH1_mA], 'omitnan'), ...
        'PeakCH1_mA',     max([records.I_CH1_mA]), ...
        'MeanCH2_mA',     mean([records.I_CH2_mA], 'omitnan'), ...
        'PeakCH2_mA',     max([records.I_CH2_mA]), ...
        'MeanRTT_ms',     mean([records.RTT_ms], 'omitnan'), ...
        'Records',        records);

    save_testseq_to_db(seqReport);
end

function [ok, w0, w1, w2, w3, w4, rttMs, hex0] = fetch_5_words_safely(useTelem)
    ok = false; w0 = uint32(0); w1 = uint32(0); w2 = uint32(0); w3 = uint32(0); w4 = uint32(0);
    rttMs = NaN; hex0 = '00000000';

    if useTelem
        raw = safe_cmd('TELEM');
        if strcmp(raw, 'ERR') || isempty(raw), return; end
        tok = regexp(raw, '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})', 'tokens', 'once');
        if isempty(tok), return; end
        rttUs = parse_kv(raw, 'RTT_US');
        rttMs = rttUs / 1000.0;
    else
        raw = safe_cmd('D 3FF4804C 5');
        tok = regexp(raw, '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})', 'tokens', 'once');
        if isempty(tok), return; end
        enStat = safe_cmd('ESPNOW STATUS');
        rttMs  = parse_kv(enStat, 'RTT_US') / 1000.0;
    end

    hex0 = upper(tok{1});
    w0 = uint32(hex2dec(tok{1}));
    w1 = uint32(hex2dec(tok{2}));
    w2 = uint32(hex2dec(tok{3}));
    w3 = uint32(hex2dec(tok{4}));
    w4 = uint32(hex2dec(tok{5}));
    ok = true;
end

function [desc, cmdL, cmdR] = decode_store0_action(w0)
    magic = bitand(bitshift(w0, -28), 15);
    mode  = bitand(bitshift(w0, -24), 15);
    aux   = bitand(bitshift(w0, -16), 255);
    cmdL  = double(to_int8(bitand(bitshift(w0, -8), 255)));
    cmdR  = double(to_int8(bitand(w0, 255)));

    if magic == 14, desc = 'OTA_WAKE_240MHZ'; return;
    elseif magic == 13, desc = 'ECO_MODE_80MHZ'; return;
    elseif magic == 15, desc = 'ZERO_ODOMETRY'; return;
    end

    if mode == 0, mStr = 'E-STOP';
    elseif mode == 2, mStr = 'LINE_PID';
    else
        if cmdL == 0 && cmdR == 0, mStr = 'MANUAL_IDLE';
        elseif cmdL > 0 && cmdR > 0, mStr = 'DRIVE_FWD';
        elseif cmdL < 0 && cmdR < 0, mStr = 'DRIVE_REV';
        else, mStr = 'SPIN_TURN';
        end
    end

    tags = {mStr};
    if bitand(aux, 1), tags{end+1} = 'W_LED'; end
    if bitand(aux, 2), tags{end+1} = 'R_LED'; end
    if bitand(aux, 4), tags{end+1} = 'HORN';  end
    if bitand(aux, 8), tags{end+1} = sprintf('SERVO#%d', bitshift(aux, -4)); end
    desc = strjoin(tags, '+');
end

function v = to_int8(u8)
    v = int32(u8);
    if v >= 128, v = v - 256; end
end

function v = to_int16(u16)
    v = int32(u16);
    if v >= 32768, v = v - 65536; end
end

function ensure_wifi_connected_for_browser()
    if ~ispc, return; end
    [~, wOut] = system('netsh wlan show interfaces');
    if ~contains(wOut, 'ESP32_LAB')
        fprintf('  [WIFI] Connecting Windows WLAN to "ESP32_LAB" so Browser can load http://192.168.4.1/agv ...\n');
        system('netsh wlan connect name="ESP32_LAB" >nul 2>&1');
        pause(2.5);
    end
end

function save_testseq_to_db(seqReport)
    try
        rootDir = fileparts(mfilename('fullpath'));
        dbFile  = fullfile(rootDir, 'databases', 'keysight_hil_benchmarks.json');
        if isfile(dbFile)
            ledger = jsondecode(fileread(dbFile));
            if isstruct(ledger.runs), runsCell = num2cell(ledger.runs); else, runsCell = ledger.runs; end
            runsCell{end+1} = seqReport;
            ledger.runs = runsCell;
        else
            ledger = struct('runs', {{seqReport}});
        end
        fid = fopen(dbFile, 'w', 'n', 'UTF-8');
        fwrite(fid, jsonencode(ledger, 'PrettyPrint', true), 'char');
        fclose(fid);
        fprintf('\n  [SAVED] 2-Minute Interactive Test Sequence archived to %s\n', dbFile);
    catch
    end
end

function resp = safe_cmd(c)
    resp = '';
    try
        s = getappdata(0, 'ESP32_WORKBENCH_STATE');
        if ~isempty(s) && ~isempty(s.SerialObj) && isvalid(s.SerialObj)
            s.SerialObj.Timeout = 0.35; % Fast 350ms timeout so a dropped packet never stalls 2 seconds
        end
        resp = esp32_io('cmd', c);
    catch
    end
end

function val = parse_kv(str, key)
    val = NaN;
    tok = regexp(char(str), [key ':([0-9.]+)'], 'tokens', 'once');
    if ~isempty(tok), val = str2double(tok{1}); end
end

function ks = connect_keysight(visaAddr)
    NET.addAssembly('Ivi.Visa');
    try
        NET.addAssembly('Keysight.Visa');
    catch
        dlls = [dir('C:\Windows\Microsoft.NET\assembly\**\Keysight.Visa.dll'); ...
                dir('C:\Program Files*\Keysight\**\Keysight.Visa.dll'); ...
                dir('C:\Program Files*\IVI Foundation\**\Keysight.Visa.dll')];
        if ~isempty(dlls), NET.addAssembly(fullfile(dlls(1).folder, dlls(1).name)); end
    end
    rm = Keysight.Visa.ResourceManager();
    sess = rm.Open(char(visaAddr));
    sess.TimeoutMilliseconds = 5000;
    sess.TerminationCharacter = 10;
    sess.TerminationCharacterEnabled = true;
    sess.Clear();
    io = Ivi.Visa.FormattedIO.MessageBasedFormattedIO(sess);
    ks = struct('Session', sess, 'RM', rm, 'IO', io);
end

function ks_write(ks, cmd), ks.IO.WriteLine(char(cmd)); end
function r = ks_query(ks, cmd), ks.IO.WriteLine(char(cmd)); r = strtrim(char(ks.IO.ReadLine())); end

function safe_teardown(ks)
    try esp32_io('disconnect'); catch, end
    try ks.Session.Dispose(); ks.RM.Dispose(); catch, end
end