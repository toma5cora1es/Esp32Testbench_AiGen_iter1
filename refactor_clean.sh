#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "=== [1/4] Aggressive Purge: Removing UI bloat, twin pollution from core/, and legacy config ==="
rm -rf ui
rm -rf firmware/sketches
rm -rf firmware/build_last
rm -f core/wb_twin.m core/esp32_dual_deploy.m
rm -f config/board_green_agv_rev52a.json config/ui_manifest.json
rm -f firmware/core0_daemon/web_ui_agv.html firmware/core0_daemon/web_ui_sim.html

echo "=== [2/4] Creating Clean Layered Directory Hierarchy ==="
mkdir -p config/boards core firmware/core0_daemon firmware/sketches/esp32_sfr_core \
         projects/green_agv experiments/digital_twin \
         instruments testsequences databases \
         results/hil_validation results/power_latency_matrix results/adc_dynamic_cal results/interactive_drive

echo "=== [3/4] Writing Generic Configs, Core, Plugins, Experiment & Firmware ==="

cat << 'EOF' > config/workbench_config.json
{
  "project": { "name": "ESP32 Generic Workbench", "version": "3.0.0" },
  "toolchain": {
    "arduinoCliBinary": "arduino-cli",
    "arduinoCliSearchPaths": [
      "C:\\Program Files\\Arduino CLI\\arduino-cli.exe",
      "%LOCALAPPDATA%\\Programs\\Arduino CLI\\arduino-cli.exe"
    ],
    "fqbn": "esp32:esp32:esp32:PartitionScheme=min_spiffs",
    "partitionScheme": "min_spiffs",
    "maxAppBytes": 1966080,
    "sdkPackagesRoot": "%LOCALAPPDATA%\\Arduino15\\packages\\esp32"
  },
  "transport": {
    "serial": { "defaultBaud": 115200, "connectTimeoutSec": 2.0, "fastCmdTimeoutSec": 0.35, "bootDrainWaitSec": 0.35 },
    "wifi": { "apSsid": "ESP32_LAB", "apPassword": "12345678", "apIp": "192.168.4.1", "espNowChannel": 1, "httpTimeoutSec": 3.5, "otaTimeoutSec": 120, "otaRebootSettleSec": 3.5, "restoreHostWifiAfterOta": true },
    "bluetooth": { "deviceName": "ESP32_BT_BRIDGE", "rfcommChannel": 1, "connectTimeoutSec": 3.0 }
  },
  "logLevel": "normal"
}
EOF

cat << 'EOF' > config/boards/green_agv_rev52a.json
{
  "boardName": "Green AGV Rev 5.2a (Carinthia UAS)",
  "registers": {
    "commandWordSfr": "RTC_CNTL_STORE0_REG",
    "telemetrySfrBase": "RTC_CNTL_STORE1_REG",
    "telemetryWordCount": 4
  },
  "macros": {
    "AGV_PIN_MOT_L_A": 13, "AGV_PIN_MOT_L_B": 12,
    "AGV_PIN_MOT_R_A": 4,  "AGV_PIN_MOT_R_B": 2,
    "AGV_PIN_ENC_L": 19,   "AGV_PIN_ENC_R": 18,
    "AGV_PIN_US_TRIG": 27, "AGV_PIN_US_ECHO": 26,
    "AGV_PIN_LINE_L": 34,  "AGV_PIN_LINE_M": 32, "AGV_PIN_LINE_R": 35,
    "AGV_PIN_BTN_T1": 5,   "AGV_PIN_BTN_T2": 15, "AGV_BTN_ACT_LVL": "HIGH",
    "AGV_PIN_LED_FL": 25,  "AGV_PIN_LED_FR": 33, "AGV_PIN_LED_RR": 14, "AGV_PIN_LED_RL": 23,
    "AGV_PIN_BUZZER": 32,  "AGV_BUZZER_EN": 0,
    "AGV_PWM_FREQ_HZ": 2000, "AGV_PWM_RES_BITS": 10,
    "AGV_WHEEL_DIAM_MM": "65.0000f", "AGV_WHEEL_BASE_MM": "140.0000f", "AGV_TICKS_PER_REV": 20,
    "SIM_LINE_L_OUT": 16, "SIM_LINE_M_OUT": 32, "SIM_LINE_R_OUT": 17,
    "SIM_BTN_T1_OUT": 5,  "SIM_BTN_T2_OUT": 15,
    "SIM_ENC_L_OUT": 19,  "SIM_ENC_R_OUT": 18,
    "SIM_US_TRIG_IN": 27, "SIM_US_ECHO_OUT": 26,
    "SIM_MOT_LA_IN": 13,  "SIM_MOT_LB_IN": 12, "SIM_MOT_RA_IN": 4, "SIM_MOT_RB_IN": 2,
    "SIM_LED_FL_IN": 25,  "SIM_LED_FR_IN": 33, "SIM_LED_RR_IN": 14, "SIM_LED_RL_IN": 23
  },
  "pins": { "builtinLed": 2, "masterRttStrobe": 4, "vspiCs": 5 },
  "adc1Channels": [
    { "gpio": 36, "channel": "ADC1_CH0", "silkscreen": "VP / SVP (Pin 2)" },
    { "gpio": 39, "channel": "ADC1_CH3", "silkscreen": "VN / SVN (Pin 3)" },
    { "gpio": 34, "channel": "ADC1_CH6", "silkscreen": "D34 / SENS_L (Pin 4)" },
    { "gpio": 35, "channel": "ADC1_CH7", "silkscreen": "D35 / SENS_R (Pin 5)" },
    { "gpio": 32, "channel": "ADC1_CH4", "silkscreen": "D32 / SENS_M (Pin 6)" },
    { "gpio": 33, "channel": "ADC1_CH5", "silkscreen": "D33 / LED3 (Pin 7)" }
  ],
  "touchPins": [
    { "gpio": 32, "label": "D32 (TOUCH9)" }, { "gpio": 33, "label": "D33 (TOUCH8)" },
    { "gpio": 27, "label": "D27 (TOUCH7)" }, { "gpio": 14, "label": "D14 (TOUCH6)" },
    { "gpio": 12, "label": "D12 (TOUCH5)" }, { "gpio": 13, "label": "D13 (TOUCH4)" },
    { "gpio": 15, "label": "D15 (TOUCH3)" }, { "gpio": 2,  "label": "D2  (TOUCH2)" },
    { "gpio": 4,  "label": "D4  (TOUCH0)" }
  ],
  "kinematics": { "ultrasonicForwardOffsetMm": 95.0 }
}
EOF

cat << 'EOF' > init_workbench.m
function paths = init_workbench()
%INIT_WORKBENCH Register generic core, projects, experiments, instruments & testsequences.
    rootDir = fileparts(mfilename('fullpath'));
    setenv('ESP32_WB_ROOT', rootDir);
    dirs = {'core', 'instruments', 'testsequences', 'projects', 'experiments'};
    for k = 1:numel(dirs)
        p = fullfile(rootDir, dirs{k});
        if isfolder(p), addpath(genpath(p)); end
    end
    paths = wb_paths();
    wb_log('info', 'INIT', 'WORKSPACE', sprintf('Root ready: %s', paths.root));
end
EOF

cat << 'EOF' > core/wb_paths.m
function out = wb_paths(kind, name)
%WB_PATHS Generic dynamic path resolver (zero hardcoded user/app paths).
    rootEnv = getenv('ESP32_WB_ROOT');
    if ~isempty(rootEnv) && isfolder(rootEnv), rootDir = rootEnv;
    else, rootDir = fileparts(fileparts(mfilename('fullpath'))); end

    p = struct( ...
        'root',        rootDir, ...
        'config',      fullfile(rootDir, 'config'), ...
        'boards',      fullfile(rootDir, 'config', 'boards'), ...
        'core',        fullfile(rootDir, 'core'), ...
        'firmware',    fullfile(rootDir, 'firmware'), ...
        'daemon',      fullfile(rootDir, 'firmware', 'core0_daemon'), ...
        'sketches',    fullfile(rootDir, 'firmware', 'sketches'), ...
        'projects',    fullfile(rootDir, 'projects'), ...
        'experiments', fullfile(rootDir, 'experiments'), ...
        'databases',   fullfile(rootDir, 'databases'), ...
        'results',     fullfile(rootDir, 'results'), ...
        'sfrDb',       fullfile(rootDir, 'databases', 'esp32_sfr.json'), ...
        'hwCalDb',     fullfile(rootDir, 'databases', 'esp32_hw_cal.json'), ...
        'buildTemp',   fullfile(tempdir, 'esp32_workbench_build'));

    if nargin == 0 || isempty(kind), out = p; return; end
    switch lower(strtrim(char(kind)))
        case 'board'
            out = fullfile(p.boards, [regexprep(char(name), '\.json$', '') '.json']);
        case 'sketch'
            sName = regexprep(strtrim(char(name)), '^["'']|["'']$', '');
            if isfile(sName), out = sName; return; end
            hits = [dir(fullfile(p.sketches, '**', [sName '.ino'])); ...
                    dir(fullfile(p.projects, '**', [sName '.ino'])); ...
                    dir(fullfile(p.experiments, '**', [sName '.ino']))];
            if ~isempty(hits), out = fullfile(hits(1).folder, hits(1).name); else, out = sName; end
        case 'results_suite'
            sd = fullfile(p.results, strtrim(char(name)));
            if ~isfolder(sd), mkdir(sd); end
            out = sd;
        otherwise
            out = p.(kind);
    end
end
EOF

cat << 'EOF' > core/wb_config.m
function cfg = wb_config(section, arg)
%WB_CONFIG Config loader supporting workbench, instruments, and any board in config/boards/.
    persistent cache
    if isempty(cache), cache = struct(); end
    if nargin < 1 || isempty(section), section = 'workbench'; end
    key = lower(strtrim(char(section)));
    if strcmp(key, 'reload'), cache = struct(); cfg = wb_config('workbench'); return; end

    if strcmp(key, 'board')
        bName = 'green_agv_rev52a';
        if nargin >= 2 && ~isempty(arg), bName = char(arg); end
        cKey = ['board_' matlab.lang.makeValidName(bName)];
        if ~isfield(cache, cKey)
            bp = wb_paths('board', bName);
            if ~isfile(bp), error('WB:MissingBoard', 'Board profile not found: %s', bp); end
            cache.(cKey) = jsondecode(fileread(bp));
        end
        cfg = cache.(cKey); return;
    end

    fileMap = struct('workbench', 'workbench_config.json', 'instruments', 'instruments.json');
    if ~isfield(fileMap, key), error('WB:BadCfg', 'Unknown config section: %s', key); end
    if ~isfield(cache, key)
        cp = fullfile(wb_paths('config'), fileMap.(key));
        cache.(key) = jsondecode(fileread(cp));
    end
    cfg = cache.(key);
end
EOF

cat << 'EOF' > core/wb_log.m
function out = wb_log(level, modTag, stageTag, msg)
%WB_LOG Structured, spaced, color-aware workbench logger.
%   Levels: 'quiet' (errors/results only), 'normal' (user ops), 'trace' (FSM/wire tx/rx).
    persistent state
    if isempty(state)
        state = struct('Level', 'normal', 'History', strings(0,1));
    end

    lvl = lower(strtrim(char(level)));
    if strcmp(lvl, 'set_level')
        val = lower(strtrim(char(modTag)));
        if ismember(val, {'quiet', 'normal', 'trace'}), state.Level = val; end
        out = state.Level; return;
    elseif strcmp(lvl, 'get_level')
        out = state.Level; return;
    elseif strcmp(lvl, 'history')
        fprintf('\n================ WORKBENCH LOG RING BUFFER (%d entries) ================\n', numel(state.History));
        for k = 1:numel(state.History), fprintf('  %s\n', state.History(k)); end
        fprintf('======================================================================\n\n');
        out = state.History; return;
    end

    ts = char(datetime('now', 'Format', 'HH:mm:ss.SSS'));
    uLvl = upper(lvl);
    line = sprintf('[%s] [%-5s] [%-12s] [%-18s] %s', ts, uLvl, upper(char(modTag)), char(stageTag), char(msg));
    state.History(end+1) = string(line);
    if numel(state.History) > 200, state.History = state.History(end-199:end); end

    rank = map_rank(uLvl);
    minRank = map_rank(upper(state.Level));
    if rank < minRank, out = false; return; end

    isDesktop = usejava('desktop');
    if isDesktop
        switch uLvl
            case {'ERR', 'FAIL', 'OPEN'}
                fprintf(2, '  %s\n', line);
            case {'PASS', 'HDR', 'FSM'}
                fprintf(1, '  <strong>%s</strong>\n', line);
            otherwise
                fprintf(1, '  %s\n', line);
        end
    else
        cMap = struct('TRACE','36','INFO','37','TX','33','RX','32','FSM','35','PASS','92','WARN','93','ERR','91','FAIL','91','OPEN','91','HDR','96');
        col = '37'; if isfield(cMap, uLvl), col = cMap.(uLvl); end
        fprintf(1, '  \x1b[%sm%s\x1b[0m\n', col, line);
    end
    out = true;
end

function r = map_rank(u)
    switch u
        case {'TRACE', 'TX', 'RX', 'FSM'}, r = 1;
        case {'NORMAL', 'INFO', 'PASS', 'HDR'}, r = 2;
        otherwise, r = 3; % WARN, ERR, FAIL, OPEN, QUIET
    end
end
EOF

cat << 'EOF' > core/esp32_io.m
function [out, latencyMs] = esp32_io(action, varargin)
%ESP32_IO Pure Generic Multi-Transport FSM (Serial / BT SPP / Wi-Fi HTTP).
%   Zero project, board, or instrument coupling.
    persistent s
    if isempty(s)
        s = struct('Phase','DISCONNECTED','Mode','none','Target','','SerialObj',[],'Busy',false,'CmdTimeoutSec',2.0,'LastError','');
    end
    out = ''; latencyMs = 0;
    if nargin < 1 || isempty(action), action = 'state'; end
    cfg = wb_config('workbench');
    act = lower(strtrim(char(action)));

    switch act
        case 'state', out = s;
        case 'timeout'
            if ~isempty(varargin) && isnumeric(varargin{1})
                s.CmdTimeoutSec = double(varargin{1});
                if ~isempty(s.SerialObj) && isvalid(s.SerialObj), s.SerialObj.Timeout = s.CmdTimeoutSec; end
            end
            out = s.CmdTimeoutSec;
        case 'get_ssid', out = get_active_ssid();
        case 'ensure_ap', out = ensure_ap(cfg, iif(~isempty(varargin), char(varargin{1}), cfg.transport.wifi.apIp));
        case 'restore_ssid', if ~isempty(varargin), restore_ssid(char(varargin{1}), cfg.transport.wifi.apSsid); end; out = true;
        case 'find_cli', out = find_acli(cfg);
        case 'detect_port', out = pick_usb_port(cfg);

        case 'connect'
            target = iif(isempty(varargin) || isempty(varargin{1}), pick_usb_port(cfg), strtrim(char(varargin{1})));
            isSer = startsWith(upper(target), 'COM') || startsWith(target, '/dev/');
            isIp  = ~isempty(regexp(target, '^(https?://)?\d+\.\d+\.\d+\.\d+', 'once'));

            if isSer
                if strcmp(s.Mode,'serial') && strcmpi(s.Target,target) && ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                    try
                        [r, latencyMs] = tx_rx(s, cfg, 'STATUS');
                        if contains(r, 'ESP32_READY'), s.Phase = 'READY_IDLE'; out = true; return; end
                    catch
                    end
                end
                esp32_io('disconnect');
                release_port(target);
                wb_log('fsm', 'IO', 'OPEN_SERIAL', sprintf('%s @ %d baud', upper(target), cfg.transport.serial.defaultBaud));
                sp = serialport(target, cfg.transport.serial.defaultBaud, 'Timeout', cfg.transport.serial.connectTimeoutSec);
                configureTerminator(sp, "LF"); pause(cfg.transport.serial.bootDrainWaitSec); flush(sp);
                s.Mode = 'serial'; s.Target = upper(target); s.SerialObj = sp; s.CmdTimeoutSec = cfg.transport.serial.connectTimeoutSec;

                resp = '';
                for a = 1:3
                    try [resp, latencyMs] = tx_rx(s, cfg, 'STATUS'); if contains(resp, 'ESP32_READY'), break; end; catch, pause(0.25); end
                end
                if ~contains(resp, 'ESP32_READY')
                    esp32_io('disconnect');
                    error('ESP32:NoReady', 'No ESP32_READY on %s. Flash core0 firmware first.', upper(target));
                end
                s.Phase = 'READY_IDLE';
                wb_log('pass', 'IO', 'CONNECTED', sprintf('Serial %s (%.1f ms) -> %s', s.Target, latencyMs, resp));
                out = true;

            elseif isIp
                esp32_io('disconnect');
                ip = regexprep(regexprep(target, '^https?://', ''), '/.*$', '');
                if strcmp(ip, cfg.transport.wifi.apIp) && ispc, ensure_ap(cfg, ip); end
                s.Mode = 'wifi'; s.Target = ip; s.SerialObj = []; s.CmdTimeoutSec = cfg.transport.wifi.httpTimeoutSec;
                [resp, latencyMs] = tx_rx(s, cfg, 'STATUS');
                s.Phase = 'READY_IDLE';
                wb_log('pass', 'IO', 'CONNECTED', sprintf('Wi-Fi http://%s (%.1f ms) -> %s', ip, latencyMs, resp));
                out = true;

            else
                esp32_io('disconnect');
                btName = regexprep(target, '^(?i)(bt:|bluetooth:)', '');
                wb_log('fsm', 'IO', 'OPEN_BT_SPP', sprintf('Connecting "%s" ch %d', btName, cfg.transport.bluetooth.rfcommChannel));
                btObj = bluetooth(btName, cfg.transport.bluetooth.rfcommChannel, 'Timeout', cfg.transport.bluetooth.connectTimeoutSec);
                configureTerminator(btObj, "LF"); flush(btObj); pause(0.15); flush(btObj);
                s.Mode = 'bluetooth'; s.Target = btName; s.SerialObj = btObj; s.CmdTimeoutSec = cfg.transport.bluetooth.connectTimeoutSec;
                [resp, latencyMs] = tx_rx(s, cfg, 'STATUS');
                s.Phase = 'READY_IDLE';
                wb_log('pass', 'IO', 'CONNECTED', sprintf('BT SPP "%s" (%.1f ms) -> %s', btName, latencyMs, resp));
                out = true;
            end

        case 'disconnect'
            if ~isempty(s.SerialObj) && isvalid(s.SerialObj)
                try flush(s.SerialObj); delete(s.SerialObj); catch, end
            end
            s.Mode = 'none'; s.Target = ''; s.SerialObj = []; s.Busy = false; s.Phase = 'DISCONNECTED';
            wb_log('fsm', 'IO', 'DISCONNECTED', 'Handles released');
            out = true;

        case {'cmd', 'send', 'raw', 'exec'}
            if strcmp(s.Mode, 'none'), error('ESP32:NotConnected', 'Not connected. Run: esp32_cli connect <COMx|IP>'); end
            if s.Busy, out = 'BUSY'; return; end
            rawCmd = strtrim(char(strjoin(string(varargin), ' ')));
            s.Busy = true; cGuard = onCleanup(@() clear_busy());
            [out, latencyMs] = tx_rx(s, cfg, rawCmd);

        otherwise
            error('ESP32:BadIoAction', 'Unknown esp32_io action: %s', act);
    end
    function clear_busy(), s.Busy = false; end
end

function [out, ms] = tx_rx(s, cfg, rawCmd)
    wb_log('tx', 'IO', upper(s.Mode), rawCmd);
    t0 = tic;
    if any(strcmp(s.Mode, {'serial', 'bluetooth'}))
        flush(s.SerialObj); writeline(s.SerialObj, rawCmd);
        out = drain_uart(s.SerialObj);
    else
        opts = weboptions('Timeout', cfg.transport.wifi.httpTimeoutSec, 'ContentType', 'text');
        out = strtrim(char(webread(sprintf('http://%s/cmd?q=%s', s.Target, urlencode(rawCmd)), opts)));
    end
    ms = toc(t0) * 1000.0;
    wb_log('rx', 'IO', sprintf('%.1fms', ms), out);
end

function payload = drain_uart(sp)
    bootP = ["ets ", "rst:", "mode:", "load:", "entry ", "configsip:", "clk_drv:", "ho 0 ", "E (", "W (", "I (", "D ("];
    emptyHits = 0;
    for k = 1:30
        lastwarn('');
        ln = strtrim(char(readline(sp)));
        [wm, ~] = lastwarn;
        if isempty(ln)
            emptyHits = emptyHits + 1;
            if ~isempty(wm) || emptyHits >= 2, error('ESP32:Timeout', 'Serial timeout on %s', sp.Port); end
            continue;
        end
        if ~any(startsWith(string(ln), bootP)) && ~strcmp(ln, 'ESP32_READY'), payload = ln; return; end
    end
    error('ESP32:NoPayload', 'Exceeded 30 boot/log lines on %s', sp.Port);
end

function release_port(p)
    try objs = serialportfind('Port', upper(string(p))); for k=1:numel(objs), delete(objs(k)); end; catch, end
end

function acli = find_acli(cfg)
    [st, ~] = system('where arduino-cli >nul 2>&1');
    if st == 0, acli = char(cfg.toolchain.arduinoCliBinary); return; end
    for k = 1:numel(cfg.toolchain.arduinoCliSearchPaths)
        c = char(cfg.toolchain.arduinoCliSearchPaths{k});
        toks = regexp(c, '%([^%]+)%', 'tokens');
        for t = 1:numel(toks), val = getenv(toks{t}{1}); if ~isempty(val), c = strrep(c, ['%' toks{t}{1} '%'], val); end; end
        if isfile(c), acli = c; return; end
    end
    error('ESP32:NoCli', 'arduino-cli not found.');
end

function port = pick_usb_port(cfg)
    try
        [~, out] = system(sprintf('"%s" board list 2>nul', find_acli(cfg)));
        for ln = splitlines(string(strtrim(out)))'
            if contains(ln, "Serial Port (USB)", "IgnoreCase", true)
                tok = split(strtrim(ln)); port = char(tok(1)); return;
            end
        end
    catch
    end
    avail = serialportlist("available");
    if ~isempty(avail) && ispc
        [~, pOut] = system('powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''(CH340|CH341|CP210|FTDI|Silicon|USB.*Serial|UART).*\(COM\d+\)''} | ForEach-Object {$_.Name}"');
        toks = regexp(pOut, '\((COM\d+)\)', 'tokens');
        for t = 1:numel(toks), if any(avail == string(toks{t}{1})), port = char(toks{t}{1}); return; end; end
    end
    if ~isempty(avail), port = char(avail(1)); return; end
    error('ESP32:NoPort', 'No USB port detected.');
end

function ssid = get_active_ssid()
    ssid = ''; if ~ispc, return; end
    [~, w] = system('netsh wlan show interfaces');
    t = regexp(w, 'Profile\s*:\s*([^\r\n]+)', 'tokens', 'once');
    if isempty(t), t = regexp(w, 'SSID\s*:\s*([^\r\n]+)', 'tokens', 'once'); end
    if ~isempty(t), ssid = strtrim(t{1}); end
end

function restore_ssid(prev, apSsid)
    if isempty(prev) || strcmpi(prev, apSsid) || ~ispc || strcmpi(get_active_ssid(), prev), return; end
    wb_log('info', 'WIFI', 'RESTORE', prev);
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prev));
    for k = 1:8, pause(1.0); if strcmpi(get_active_ssid(), prev), return; end; system(sprintf('netsh wlan connect name="%s" >nul 2>&1', prev)); end
end

function ok = ensure_ap(cfg, ip)
    ok = true; if ~ispc, return; end
    ssid = cfg.transport.wifi.apSsid; pass = cfg.transport.wifi.apPassword;
    [~, wi] = system('netsh wlan show interfaces');
    if contains(wi, ssid) && ping_ok(ip), return; end
    wb_log('info', 'WIFI', 'SWITCH_AP', sprintf('Joining %s (%s)', ssid, ip));
    xml = ['<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">' ...
           '<name>' ssid '</name><SSIDConfig><SSID><name>' ssid '</name></SSID></SSIDConfig>' ...
           '<connectionType>ESS</connectionType><connectionMode>manual</connectionMode><MSM><security>' ...
           '<authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>' ...
           '<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>' pass '</keyMaterial></sharedKey></security></MSM></WLANProfile>'];
    xp = fullfile(tempdir, 'esp32_wb_ap.xml'); fid = fopen(xp,'w'); fwrite(fid, xml,'char'); fclose(fid);
    system(sprintf('netsh wlan add profile filename="%s" >nul 2>&1', xp));
    system(sprintf('netsh wlan connect name="%s" >nul 2>&1', ssid));
    for k = 1:10
        pause(1.0); [~, wo] = system('netsh wlan show interfaces');
        if contains(wo, ssid) && ping_ok(ip), pause(0.4); return; end
        system(sprintf('netsh wlan connect name="%s" >nul 2>&1', ssid));
    end
    ok = false; wb_log('warn', 'WIFI', 'TIMEOUT', sprintf('Could not ping %s', ip));
end

function ok = ping_ok(ip), [st, o] = system(sprintf('ping -n 1 -w 600 %s', ip)); ok = (st==0) && contains(o,'TTL=','IgnoreCase',true); end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
EOF

cat << 'EOF' > core/esp32_flash.m
function [success, buildId] = esp32_flash(sketchOrPath, varargin)
%ESP32_FLASH Generic Build & Flash FSM.
%   Zero project/pin hardcoding: pass optional '--board <name>' (injects macros from config/boards/*.json),
%   '--ui-file <html_path>', '--radio <ap_now|sta_now|off>', '--role <standalone|master|slave>', '--bt'.
    cfg = wb_config('workbench');
    resolved = wb_paths('sketch', sketchOrPath);
    if isfolder(resolved)
        [~, fn] = fileparts(resolved); cand = fullfile(resolved, [fn '.ino']);
        if isfile(cand), resolved = cand; else, inos = dir(fullfile(resolved,'*.ino')); resolved = fullfile(inos(1).folder, inos(1).name); end
    end
    if ~isfile(resolved), error('ESP32:NoSketch', 'Sketch not found: %s', resolved); end

    s = esp32_io('state');
    mode = ''; target = ''; role = 'standalone'; radio = 'ap_now'; enableBt = false;
    boardName = ''; customUiPath = ''; injectDaemon = true; restoreWifi = cfg.transport.wifi.restoreHostWifiAfterOta;

    i = 1;
    while i <= numel(varargin)
        a = regexprep(strtrim(char(varargin{i})), '^["'']|["'']$', ''); al = lower(a);
        if any(strcmp(al, {'--usb','-u','usb'})), mode='usb'; if i<numel(varargin)&&~startsWith(char(varargin{i+1}),'-'), target=upper(strtrim(char(varargin{i+1}))); i=i+1; end
        elseif any(strcmp(al, {'--wifi','-w','wifi'})), mode='wifi'; if i<numel(varargin)&&~startsWith(char(varargin{i+1}),'-'), target=strtrim(char(varargin{i+1})); i=i+1; end
        elseif strcmp(al, '--role') && i<numel(varargin), role=lower(strtrim(char(varargin{i+1}))); i=i+1;
        elseif strcmp(al, '--radio') && i<numel(varargin), radio=lower(strtrim(char(varargin{i+1}))); i=i+1;
        elseif strcmp(al, '--board') && i<numel(varargin), boardName=strtrim(char(varargin{i+1})); i=i+1;
        elseif strcmp(al, '--ui-file') && i<numel(varargin), customUiPath=strtrim(char(varargin{i+1})); i=i+1;
        elseif strcmp(al, '--bt'), enableBt = true;
        elseif strcmp(al, '--no-bt'), enableBt = false;
        elseif strcmp(al, '--keep-wifi'), restoreWifi = false;
        elseif strcmp(al, '--raw'), injectDaemon = false;
        elseif startsWith(upper(a),'COM') || startsWith(a,'/dev/'), mode='usb'; target=upper(a);
        elseif ~isempty(regexp(a,'^\d+\.\d+\.\d+\.\d+$','once')), mode='wifi'; target=a;
        end
        i = i + 1;
    end

    if isempty(mode)
        if strcmp(s.Mode,'wifi'), mode='wifi'; target=s.Target;
        elseif strcmp(s.Mode,'serial'), mode='usb'; target=s.Target;
        else, mode='usb'; target=esp32_io('detect_port');
        end
    end
    if isempty(target), target = iif(strcmp(mode,'wifi'), cfg.transport.wifi.apIp, esp32_io('detect_port')); end

    [~, baseName, ext] = fileparts(resolved);
    short = upper(regexprep(baseName, '[^a-zA-Z0-9]', ''));
    if strlength(short) > 10, short = extractBefore(short, 11); end
    buildId = sprintf('BLD_%s_%s', short, char(datetime('now','Format','HHmmss')));

    buildRoot = wb_paths('buildTemp'); sketchDir = fullfile(buildRoot,'ota_sketch'); outBinDir = fullfile(buildRoot,'bin');
    outIno = fullfile(sketchDir, 'ota_sketch.ino');
    if isfolder(buildRoot), try rmdir(buildRoot,'s'); catch, end; end
    mkdir(sketchDir); mkdir(outBinDir);

    macroHdr = build_board_macro_header(boardName);
    userCode = fileread(resolved);
    if injectDaemon && strcmpi(ext, '.ino')
        merged = build_daemon_sketch(userCode, macroHdr, buildId, role, radio, enableBt, cfg, customUiPath);
        write_utf8(outIno, merged);
    else
        write_utf8(outIno, [macroHdr newline userCode]);
    end

    acli = esp32_io('find_cli');
    cmdCompile = sprintf('"%s" compile --fqbn %s --build-property "build.partitions=%s" --build-property "upload.maximum_size=%d" --output-dir "%s" "%s"', ...
        acli, cfg.toolchain.fqbn, cfg.toolchain.partitionScheme, cfg.toolchain.maxAppBytes, outBinDir, sketchDir);
    wb_log('fsm', 'FLASH', 'COMPILE', sprintf('%s | Role=%s | Radio=%s | BT=%d | ID=%s', baseName, upper(role), upper(radio), enableBt, buildId));
    [st, cout] = system(cmdCompile);
    if st ~= 0, fprintf(2, '%s\n', cout); error('ESP32:CompileFail', 'arduino-cli compile failed.'); end
    binFile = fullfile(outBinDir, 'ota_sketch.ino.bin');

    if strcmp(mode, 'usb')
        wasConn = strcmp(s.Mode,'serial') && strcmpi(s.Target, target);
        if wasConn, esp32_io('disconnect'); end
        try objs = serialportfind('Port', upper(string(target))); for k=1:numel(objs), delete(objs(k)); end; catch, end
        wb_log('fsm', 'FLASH', 'USB_UPLOAD', target);
        [st, uout] = system(sprintf('"%s" upload -p %s --fqbn %s --input-dir "%s"', acli, target, cfg.toolchain.fqbn, outBinDir));
        if st ~= 0, fprintf(2, '%s\n', uout); error('ESP32:UploadFail', 'USB upload failed on %s.', target); end
        pause(1.8);
        if wasConn || ~strcmp(radio,'off'), esp32_io('connect', target); end
    else
        prevSsid = esp32_io('get_ssid');
        if restoreWifi && ~isempty(prevSsid), g = onCleanup(@() esp32_io('restore_ssid', prevSsid)); end %#ok<NASGU>
        if strcmp(target, cfg.transport.wifi.apIp), esp32_io('ensure_ap', target); end
        try webread(sprintf('http://%s/cmd?q=OTA_PREP', target), weboptions('Timeout',3.0,'ContentType','text')); pause(0.25); catch, end
        wb_log('fsm', 'FLASH', 'OTA_STREAM', sprintf('POST http://%s/ota', target));
        [st, resp] = system(sprintf('curl.exe -s -S --http1.1 -H "Expect:" --connect-timeout 8 --max-time %d -F "image=@%s" http://%s/ota 2>&1', cfg.transport.wifi.otaTimeoutSec, binFile, target));
        if st ~= 0 && ~contains(resp,'OTA_OK') && ~contains(resp,'Empty reply') && st ~= 52 && st ~= 56
            error('ESP32:OtaFail', 'OTA failed: %s', strtrim(resp));
        end
        pause(cfg.transport.wifi.otaRebootSettleSec);
    end
    success = true;
    wb_log('pass', 'FLASH', 'COMPLETE', sprintf('BuildID=%s flashed via %s (%s)', buildId, upper(mode), target));
end

function hdr = build_board_macro_header(boardName)
    hdr = '';
    if isempty(boardName), return; end
    b = wb_config('board', boardName);
    if ~isfield(b, 'macros'), return; end
    fns = fieldnames(b.macros);
    lines = strings(numel(fns), 1);
    for k = 1:numel(fns)
        v = b.macros.(fns{k});
        if isnumeric(v), vs = num2str(v); elseif islogical(v), vs = num2str(double(v)); else, vs = char(v); end
        lines(k) = sprintf('#define %s %s', fns{k}, vs);
    end
    hdr = char(strjoin(lines, newline));
end

function merged = build_daemon_sketch(userCode, macroHdr, buildId, role, radio, enableBt, cfg, customUiPath)
    modUser = regexprep(userCode, '\<void\s+setup\s*\(\s*(void)?\s*\)', 'void user_setup()', 'once');
    if ~contains(modUser,'user_setup'), modUser = [modUser newline 'void user_setup() {}' newline]; end
    if isempty(regexp(modUser,'\<\s*void\s+loop\s*\(\s*(void)?\s*\)','once')), modUser = [modUser newline 'void loop() { delay(100); }' newline]; end

    dDir = wb_paths('daemon');
    cpp  = fileread(fullfile(dDir, 'core0_daemon.cpp'));
    udeHtml = strrep(fileread(fullfile(dDir, 'web_ui.html')), '{{FW_BUILD_ID}}', buildId);
    appHtml = udeHtml; hasAppUi = '0';
    if ~isempty(customUiPath)
        cp = customUiPath;
        if ~isfile(cp), cp = fullfile(wb_paths('root'), customUiPath); end
        if ~isfile(cp), error('ESP32:NoUiFile', 'Custom UI HTML not found: %s', customUiPath); end
        appHtml = strrep(fileread(cp), '{{FW_BUILD_ID}}', buildId);
        hasAppUi = '1';
    end

    roleId = '0';
    if strcmpi(role,'master'), roleId = '1'; elseif strcmpi(role,'slave'), roleId = '2'; end
    radioId = '0'; % 0=AP+ESP-NOW, 1=STA+ESP-NOW, 2=OFF(USB-only)
    if strcmpi(radio,'sta_now') || strcmpi(role,'slave'), radioId = '1';
    elseif strcmpi(radio,'off') || strcmpi(radio,'usb'), radioId = '2'; end

    tokens = {
        '{{FW_BUILD_ID}}',       buildId;
        '{{NODE_ROLE_ID}}',      roleId;
        '{{RADIO_MODE_ID}}',     radioId;
        '{{ENABLE_BT}}',         iif(enableBt,'1','0');
        '{{HAS_APP_UI}}',        hasAppUi;
        '{{WB_AP_SSID}}',        cfg.transport.wifi.apSsid;
        '{{WB_AP_PASS}}',        cfg.transport.wifi.apPassword;
        '{{WB_BT_NAME}}',        cfg.transport.bluetooth.deviceName;
        '{{WB_ESPNOW_CH}}',      num2str(cfg.transport.wifi.espNowChannel);
        '{{WEB_UI_UDE_HTML}}',   udeHtml;
        '{{WEB_UI_APP_HTML}}',   appHtml;
        '{{USER_SKETCH_CODE}}',  [macroHdr newline modUser]
    };
    merged = cpp;
    for k = 1:size(tokens,1), merged = strrep(merged, tokens{k,1}, tokens{k,2}); end
end

function write_utf8(p, txt), f=fopen(p,'w','n','UTF-8'); fwrite(f,txt,'char'); fclose(f); end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
EOF

cat << 'EOF' > core/esp32_cli.m
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
EOF

cat << 'EOF' > core/esp32.m
classdef esp32 < handle
%ESP32 OO Facade over generic esp32_cli & esp32_flash.
    methods
        function obj = esp32(t, varargin), if nargin>=1 && ~isempty(t), esp32_cli('connect', t, varargin{:}); end; end
        function out = Verbose(~, varargin), out = esp32_cli('verbose', varargin{:}); end
        function out = Fsm(~), out = esp32_cli('fsm'); end
        function out = Scan(~), out = esp32_cli('scan'); end
        function ok  = Connect(~, t, varargin), ok = esp32_cli('connect', t, varargin{:}); end
        function Disconnect(~), esp32_cli('disconnect'); end
        function [ok, bid] = Flash(~, s, varargin), [ok, bid] = esp32_flash(s, varargin{:}); end
        function out = Reg(~, r, varargin), out = esp32_cli('reg', r, varargin{:}); end
        function out = Bits(~, r, f, varargin), out = esp32_cli('bits', r, f, varargin{:}); end
        function out = Pin(~, g, varargin), out = esp32_cli('pin', g, varargin{:}); end
        function out = Adc(~, g), out = esp32_cli('adc', g); end
        function out = Status(~), out = esp32_cli('status'); end
        function Web(~), esp32_cli('web'); end
    end
end
EOF

cat << 'EOF' > firmware/core0_daemon/core0_daemon.cpp
#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Update.h>
#include <Wire.h>
#include <SPI.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_arduino_version.h>
#include <BluetoothSerial.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include "soc/io_mux_reg.h"
#include "soc/gpio_periph.h"
#include "esp_log.h"

#define WB_BUILD_ID   "{{FW_BUILD_ID}}"
#define WB_NODE_ROLE  {{NODE_ROLE_ID}}
#define WB_RADIO_MODE {{RADIO_MODE_ID}}
#define WB_ENABLE_BT  {{ENABLE_BT}}
#define WB_HAS_APP_UI {{HAS_APP_UI}}
#define WB_AP_SSID    "{{WB_AP_SSID}}"
#define WB_AP_PASS    "{{WB_AP_PASS}}"
#define WB_BT_NAME    "{{WB_BT_NAME}}"
#define WB_ESPNOW_CH  {{WB_ESPNOW_CH}}
#define WB_RTT_PIN    4

void user_setup();

static const char* HTML_UDE_UI = R"WB_UI_UDE({{WEB_UI_UDE_HTML}})WB_UI_UDE";
static const char* HTML_APP_UI = R"WB_UI_APP({{WEB_UI_APP_HTML}})WB_UI_APP";

static WebServer g_http(80);
static BluetoothSerial g_bt;
static portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;

static volatile uint8_t  g_role = WB_NODE_ROLE, g_radio = WB_RADIO_MODE, g_uiId = WB_HAS_APP_UI;
static volatile bool     g_httpUp = false, g_btUp = false, g_hasPeer = false, g_syncPending = false, g_pongWait = false;
static uint8_t           g_peerMac[6] = {0}, g_bcastMac[6] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
static volatile uint16_t g_seq = 0;
static volatile uint32_t g_txPkts = 0, g_rxPkts = 0, g_lossPkts = 0, g_rttUs = 0;

enum WbMsgType : uint8_t { PKT_BEACON = 1, PKT_CMD = 2, PKT_TLM = 3, PKT_PING = 4, PKT_PONG = 5 };
typedef struct __attribute__((packed)) {
  uint32_t magic; uint8_t type, role; uint16_t seq; uint32_t txUs, s0, s1, s2, s3, s4, crc;
} WbEspNowFrame;

static uint32_t calcCrc(const WbEspNowFrame& f) {
  const uint8_t* p = reinterpret_cast<const uint8_t*>(&f); uint32_t h = 2166136261u;
  for (size_t i = 0; i < sizeof(WbEspNowFrame) - sizeof(uint32_t); ++i) { h ^= p[i]; h *= 16777619u; }
  return h;
}

static inline void writeLedc(uint8_t pin, uint8_t ch, uint32_t freq, uint8_t res, uint32_t duty) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcDetach(pin);
  if (freq == 0 || duty == 0) { pinMode(pin, OUTPUT); digitalWrite(pin, LOW); }
  else { ledcAttach(pin, freq, res); ledcWrite(pin, duty); if (pin < SOC_GPIO_PIN_COUNT && GPIO_PIN_MUX_REG[pin]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]); }
#else
  ledcSetup(ch, freq, res); ledcAttachPin(pin, ch); ledcWrite(ch, duty);
  if (pin < SOC_GPIO_PIN_COUNT && GPIO_PIN_MUX_REG[pin]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);
#endif
  (void)ch;
}

static const char* roleStr(uint8_t r) { return (r==1)?"MASTER":((r==2)?"SLAVE":"STANDALONE"); }

static void ensurePeer(const uint8_t* mac) {
  if (g_radio == 2 || esp_now_is_peer_exist(mac)) return;
  esp_now_peer_info_t peer = {}; memcpy(peer.peer_addr, mac, 6);
  peer.channel = WB_ESPNOW_CH; peer.ifidx = WIFI_IF_STA; peer.encrypt = false;
  esp_now_add_peer(&peer);
}

static void sendFrame(uint8_t type, uint32_t txOverride = 0) {
  if (g_radio == 2) return;
  WbEspNowFrame f = {}; f.magic = 0x57424E31u; f.type = type; f.role = g_role; f.seq = ++g_seq;
  f.txUs = txOverride ? txOverride : micros();
  f.s0 = REG_READ(RTC_CNTL_STORE0_REG); f.s1 = REG_READ(RTC_CNTL_STORE1_REG);
  f.s2 = REG_READ(RTC_CNTL_STORE2_REG); f.s3 = REG_READ(RTC_CNTL_STORE3_REG); f.s4 = REG_READ(RTC_CNTL_STORE4_REG);
  f.crc = calcCrc(f);
  const uint8_t* dst = (g_hasPeer && type != PKT_BEACON) ? g_peerMac : g_bcastMac;
  if (esp_now_send(dst, reinterpret_cast<const uint8_t*>(&f), sizeof(f)) == ESP_OK) g_txPkts++;
}

#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
static void onEspNowRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
  const uint8_t* mac = info ? info->src_addr : nullptr;
#else
static void onEspNowRecv(const uint8_t* mac, const uint8_t* data, int len) {
#endif
  if (!mac || len != (int)sizeof(WbEspNowFrame)) return;
  WbEspNowFrame f; memcpy(&f, data, sizeof(f));
  if (f.magic != 0x57424E31u || f.crc != calcCrc(f)) return;
  portENTER_CRITICAL_ISR(&g_mux);
  if (!g_hasPeer && f.role != g_role && f.role != 0) { memcpy(g_peerMac, mac, 6); g_hasPeer = true; }
  g_rxPkts++;
  portEXIT_CRITICAL_ISR(&g_mux);
  ensurePeer(mac);

  if (g_role == 2) {
    if (f.type == PKT_CMD) { REG_WRITE(RTC_CNTL_STORE0_REG, f.s0); sendFrame(PKT_TLM, f.txUs); }
    else if (f.type == PKT_PING) sendFrame(PKT_PONG, f.txUs);
  } else if (g_role == 1 && (f.type == PKT_TLM || f.type == PKT_PONG)) {
    uint32_t now = micros(); digitalWrite(WB_RTT_PIN, LOW); g_rttUs = now - f.txUs;
    if (f.type == PKT_TLM) {
      REG_WRITE(RTC_CNTL_STORE1_REG, f.s1); REG_WRITE(RTC_CNTL_STORE2_REG, f.s2);
      REG_WRITE(RTC_CNTL_STORE3_REG, f.s3); REG_WRITE(RTC_CNTL_STORE4_REG, f.s4);
      g_syncPending = false;
    }
    g_pongWait = false;
  }
}

static bool parseHex(const String& tok, uint32_t& out) {
  String s = tok; s.trim(); if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2);
  if (!s.length()) return false; char* e = nullptr; out = strtoul(s.c_str(), &e, 16); return (e != s.c_str());
}

static String processCommand(const String& rawIn) {
  String cmd = rawIn; cmd.trim(); if (!cmd.length()) return "";
  int sp = cmd.indexOf(' '); String op = (sp<0)?cmd:cmd.substring(0,sp); String rest = (sp<0)?"":cmd.substring(sp+1);
  op.toUpperCase(); rest.trim();

  if (op == "STATUS") {
    char b[192]; snprintf(b, sizeof(b), "ESP32_READY|ROLE:%s|RADIO:%s|ID:%s|IP:%s|MHZ:%u|PEER:%d",
      roleStr(g_role), (g_radio==2?"USB_ONLY":(g_radio==1?"STA_NOW":"AP_NOW")), WB_BUILD_ID,
      (g_radio==2?"0.0.0.0":WiFi.softAPIP().toString().c_str()), (unsigned)getCpuFrequencyMhz(), g_hasPeer?1:0);
    return String(b);
  }
  if (op == "INFO") {
    char b[200]; snprintf(b, sizeof(b), "ID:%s ROLE:%s HEAP_FREE:%u FLASH_MB:%u SKETCH_KB:%u OTA_FREE_KB:%u MHZ:%u",
      WB_BUILD_ID, roleStr(g_role), (unsigned)ESP.getFreeHeap(), (unsigned)(ESP.getFlashChipSize()/1048576u),
      (unsigned)(ESP.getSketchSize()/1024u), (unsigned)(ESP.getFreeSketchSpace()/1024u), (unsigned)getCpuFrequencyMhz());
    return String(b);
  }
  if (op == "R" || op == "REG") {
    uint32_t a=0; if (!parseHex(rest,a)||(a&3)||a<0x3FF00000u||a>0x3FF80000u) return "ERR_ADDR";
    char o[12]; snprintf(o,sizeof(o),"%08X",(unsigned)*reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a))); return String(o);
  }
  if (op == "W") {
    int s2 = rest.indexOf(' '); if (s2<0) return "ERR_ARGS"; uint32_t a=0, v=0;
    if (!parseHex(rest.substring(0,s2),a)||!parseHex(rest.substring(s2+1),v)) return "ERR_HEX";
    if ((a&3)||a<0x3FF00000u||a>0x3FF80000u) return "ERR_ADDR";
    *reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a)) = v;
    if (a == RTC_CNTL_STORE0_REG && g_role == 1) sendFrame(PKT_CMD);
    char o[12]; snprintf(o,sizeof(o),"%08X",(unsigned)*reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a))); return String(o);
  }
  if (op == "D") {
    int s2 = rest.indexOf(' '); uint32_t a=0; int cnt=8;
    if (s2<0) { if (!parseHex(rest,a)) return "ERR_ADDR"; } else { if (!parseHex(rest.substring(0,s2),a)) return "ERR_ADDR"; cnt=constrain(rest.substring(s2+1).toInt(),1,64); }
    if ((a&3)||a<0x3FF00000u||a>0x3FF80000u) return "ERR_ADDR";
    String out; for (int i=0;i<cnt;++i){ char h[12]; snprintf(h,sizeof(h),"%08X",(unsigned)*reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a+i*4))); if(i>0)out+=' '; out+=h; } return out;
  }
  if (op == "SYNC") {
    uint32_t cw=0; if (!parseHex(rest,cw)) return "ERR_HEX";
    REG_WRITE(RTC_CNTL_STORE0_REG, cw);
    if (g_role == 1) {
      g_syncPending = true; digitalWrite(WB_RTT_PIN, HIGH); sendFrame(PKT_CMD);
      uint32_t t0 = micros(); while (g_syncPending && (micros()-t0) < 8000u) delayMicroseconds(100);
      if (g_syncPending) { digitalWrite(WB_RTT_PIN, LOW); g_lossPkts++; }
    }
    char b[96]; snprintf(b,sizeof(b),"%08X %08X %08X %08X RTT_US:%u LOSS:%u",
      (unsigned)REG_READ(RTC_CNTL_STORE1_REG),(unsigned)REG_READ(RTC_CNTL_STORE2_REG),
      (unsigned)REG_READ(RTC_CNTL_STORE3_REG),(unsigned)REG_READ(RTC_CNTL_STORE4_REG),(unsigned)g_rttUs,(unsigned)g_lossPkts);
    return String(b);
  }
  if (op == "TELEM") {
    char b[120]; snprintf(b,sizeof(b),"%08X %08X %08X %08X %08X RTT_US:%u RX:%u LOSS:%u",
      (unsigned)REG_READ(RTC_CNTL_STORE0_REG),(unsigned)REG_READ(RTC_CNTL_STORE1_REG),(unsigned)REG_READ(RTC_CNTL_STORE2_REG),
      (unsigned)REG_READ(RTC_CNTL_STORE3_REG),(unsigned)REG_READ(RTC_CNTL_STORE4_REG),(unsigned)g_rttUs,(unsigned)g_rxPkts,(unsigned)g_lossPkts);
    return String(b);
  }
  if (op == "PIN") {
    int s2=rest.indexOf(' '), pin=(s2<0)?rest.toInt():rest.substring(0,s2).toInt();
    String act=(s2<0)?"READ":rest.substring(s2+1); act.trim(); act.toUpperCase();
    if (pin<0||pin>39) return "ERR_PIN"; if (act=="READ"||act=="R") return String(digitalRead(pin));
    pinMode(pin,OUTPUT); int v=digitalRead(pin); if(act=="HIGH"||act=="1"||act=="ON")v=1; else if(act=="LOW"||act=="0"||act=="OFF")v=0; else v=!v;
    digitalWrite(pin,v); return String(v);
  }
  if (op == "ADC") { int p=rest.toInt(); analogReadResolution(12); analogSetPinAttenuation(p,ADC_11db); return String(analogRead(p)); }
  if (op == "DAC") { int s2=rest.indexOf(' '); if(s2<0)return"ERR"; dacWrite(rest.substring(0,s2).toInt(),(uint8_t)constrain(rest.substring(s2+1).toInt(),0,255)); return "DAC_OK"; }
  if (op == "PWM") {
    int s2=rest.indexOf(' '), s3=(s2<0)?-1:rest.indexOf(' ',s2+1); if(s2<0||s3<0)return"ERR";
    int p=rest.substring(0,s2).toInt(); long rf=rest.substring(s2+1,s3).toInt();
    writeLedc((uint8_t)p, 14, rf<=0?0u:(uint32_t)rf, 10, constrain(rest.substring(s3+1).toInt(),0,1023)); return "PWM_OK";
  }
  if (op == "PULSE") {
    int s2=rest.indexOf(' '), p=(s2<0)?rest.toInt():rest.substring(0,s2).toInt();
    uint32_t tout=(s2<0)?50000u:(uint32_t)max(1000L,rest.substring(s2+1).toInt());
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
    if (ledcReadFreq((uint8_t)p)==0) pinMode(p,INPUT); else if(p>=0&&p<SOC_GPIO_PIN_COUNT&&GPIO_PIN_MUX_REG[p]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[p]);
#else
    pinMode(p,INPUT);
#endif
    unsigned long hi=pulseIn(p,HIGH,tout), lo=pulseIn(p,LOW,tout), per=hi+lo;
    char b[72]; snprintf(b,sizeof(b),"FREQ_HZ:%.2f DUTY_PCT:%.2f HI_US:%lu LO_US:%lu", per?(1e6f/per):0.0f, per?(100.0f*hi/per):0.0f, hi, lo); return String(b);
  }
  if (op == "TOUCH") return String(touchRead(rest.toInt()));
  if (op == "I2C") {
    Wire.begin(); rest.toUpperCase();
    if (rest.startsWith("SCAN")) {
      String f=""; for(uint8_t a=1;a<127;++a){ Wire.beginTransmission(a); if(Wire.endTransmission()==0){ char h[8]; snprintf(h,sizeof(h),"0x%02X",a); if(f.length())f+=','; f+=h; } }
      return "I2C_FOUND:" + (f.length()?f:String("NONE"));
    }
    return "ERR_I2C";
  }
  if (op == "SPI") {
    int cs=5; unsigned tx=0; if(sscanf(rest.c_str(),"%d %i",&cs,(int*)&tx)<2)return"ERR";
    pinMode(cs,OUTPUT); digitalWrite(cs,HIGH); SPI.begin(); SPI.beginTransaction(SPISettings(1000000,MSBFIRST,SPI_MODE0));
    digitalWrite(cs,LOW); uint8_t rx=SPI.transfer((uint8_t)tx); digitalWrite(cs,HIGH); SPI.endTransaction();
    char h[8]; snprintf(h,sizeof(h),"0x%02X",rx); return String(h);
  }
  if (op == "POWER") {
    rest.toUpperCase();
    if (rest=="ECO") { setCpuFrequencyMhz(80); if(g_radio!=2) esp_wifi_set_ps(WIFI_PS_MIN_MODEM); if(g_btUp){g_bt.end();g_btUp=false;} }
    else if (rest=="BALANCED") { setCpuFrequencyMhz(160); if(g_radio!=2) esp_wifi_set_ps(WIFI_PS_NONE); if(g_btUp){g_bt.end();g_btUp=false;} }
    else { setCpuFrequencyMhz(240); if(g_radio!=2) esp_wifi_set_ps(WIFI_PS_NONE); }
    return "POWER_OK:" + String(getCpuFrequencyMhz()) + "MHZ";
  }
  if (op == "UI") { rest.toUpperCase(); g_uiId = (rest=="APP"||rest=="AGV")?1:0; return g_uiId?"APP_UI":"UDE_WORKBENCH"; }
  if (op == "ROLE") {
    rest.toUpperCase();
    if(rest=="MASTER"){g_role=1;pinMode(WB_RTT_PIN,OUTPUT);digitalWrite(WB_RTT_PIN,LOW);} else if(rest=="SLAVE")g_role=2; else g_role=0;
    return String("ROLE_OK:") + roleStr(g_role);
  }
  if (op == "ESPNOW") {
    rest.toUpperCase();
    if (rest=="PING" && g_role==1) {
      g_pongWait=true; uint32_t tx=micros(); digitalWrite(WB_RTT_PIN,HIGH); sendFrame(PKT_PING, tx);
      uint32_t t0=millis(); while(g_pongWait && (millis()-t0)<25u) delay(1);
      if(g_pongWait){ digitalWrite(WB_RTT_PIN,LOW); g_lossPkts++; }
    } else if (rest=="PING" && g_role==2) sendFrame(PKT_BEACON);
    char b[112]; snprintf(b,sizeof(b),"ESPNOW_STAT ROLE:%s PEER:%d TX:%u RX:%u LOSS:%u RTT_US:%u",
      roleStr(g_role), g_hasPeer?1:0, (unsigned)g_txPkts, (unsigned)g_rxPkts, (unsigned)g_lossPkts, (unsigned)g_rttUs);
    return String(b);
  }
  if (op == "OTA_PREP") { REG_WRITE(RTC_CNTL_STORE0_REG, 0x10000000u); if(g_btUp){g_bt.end();g_btUp=false;} return "OTA_PREP_OK"; }
  return "ERR_CMD";
}

static void sendHtml(const char* html) { g_http.sendHeader("Connection","close"); g_http.send(200, "text/html; charset=utf-8", html); }

static void setupHttp() {
  g_http.on("/", HTTP_GET, []() { sendHtml(g_uiId ? HTML_APP_UI : HTML_UDE_UI); });
  g_http.on("/ude", HTTP_GET, []() { sendHtml(HTML_UDE_UI); });
  g_http.on("/app", HTTP_GET, []() { sendHtml(HTML_APP_UI); });
  g_http.on("/agv", HTTP_GET, []() { sendHtml(HTML_APP_UI); });
  g_http.on("/cmd", HTTP_GET, []() {
    g_http.sendHeader("Connection", "close");
    if (!g_http.hasArg("q")) { g_http.send(400, "text/plain", "ERR_NO_Q"); return; }
    g_http.send(200, "text/plain", processCommand(g_http.arg("q")));
  });
  g_http.on("/ota", HTTP_POST,
    []() { g_http.sendHeader("Connection","close"); bool ok=!Update.hasError(); g_http.send(ok?200:500,"text/plain",ok?"OTA_OK":"OTA_FAIL"); delay(250); if(ok)ESP.restart(); },
    []() {
      HTTPUpload& up = g_http.upload();
      if (up.status==UPLOAD_FILE_START) { REG_WRITE(RTC_CNTL_STORE0_REG,0x10000000u); if(g_btUp){g_bt.end();g_btUp=false;} Update.begin(UPDATE_SIZE_UNKNOWN); }
      else if (up.status==UPLOAD_FILE_WRITE) Update.write(up.buf, up.currentSize);
      else if (up.status==UPLOAD_FILE_END) Update.end(true);
    });
}

static void core0Task(void*) {
  uint32_t lastBcn = 0; static String serBuf, btBuf;
  for (;;) {
    if (g_httpUp) g_http.handleClient();
    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c=='\n') { String o = processCommand(serBuf); serBuf=""; if(o.length()) Serial.println(o); }
      else if (c!='\r' && serBuf.length()<256) serBuf += c;
    }
    while (g_btUp && g_bt.available()) {
      char c = (char)g_bt.read();
      if (c=='\n') { String o = processCommand(btBuf); btBuf=""; if(o.length()) g_bt.println(o); }
      else if (c!='\r' && btBuf.length()<256) btBuf += c;
    }
    if (g_radio != 2 && (g_role == 1 || g_role == 2) && !g_hasPeer && (millis()-lastBcn) > 500u) {
      lastBcn = millis(); sendFrame(PKT_BEACON);
    }
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void setup() {
  esp_log_level_set("*", ESP_LOG_NONE);
  Serial.begin(115200); Serial.setTimeout(25);
  REG_WRITE(RTC_CNTL_STORE0_REG, 0x10000000u);
  if (WB_NODE_ROLE == 1) { pinMode(WB_RTT_PIN, OUTPUT); digitalWrite(WB_RTT_PIN, LOW); }

  if (g_radio != 2) {
    setupHttp();
    if (g_radio == 1) {
      WiFi.mode(WIFI_STA); esp_wifi_set_channel(WB_ESPNOW_CH, WIFI_SECOND_CHAN_NONE); esp_wifi_set_ps(WIFI_PS_NONE);
    } else {
      WiFi.mode(WIFI_AP_STA); WiFi.softAP(WB_AP_SSID, WB_AP_PASS, WB_ESPNOW_CH);
      g_http.begin(); g_httpUp = true;
      if (WB_ENABLE_BT) { g_bt.begin(WB_BT_NAME); g_btUp = true; }
    }
    if (esp_now_init() == ESP_OK) { esp_now_register_recv_cb(onEspNowRecv); ensurePeer(g_bcastMac); }
  }

  user_setup();
  xTaskCreatePinnedToCore(core0Task, "wb_core0", 8192, nullptr, 2, nullptr, 0);
  Serial.println("ESP32_READY");
}

{{USER_SKETCH_CODE}}
EOF

cat << 'EOF' > firmware/sketches/esp32_sfr_core/esp32_sfr_core.ino
#include <Arduino.h>
void setup() { pinMode(2, OUTPUT); digitalWrite(2, LOW); }
void loop() { delay(250); }
EOF

cat << 'EOF' > projects/green_agv/green_agv_cli.m
function varargout = green_agv_cli(varargin)
%GREEN_AGV_CLI Project plugin for Green AGV Mainboard (invoked via 'esp32_cli green_agv ...').
    if isempty(varargin), sub = 'telem'; else, sub = lower(strtrim(char(varargin{1}))); end
    persistent auxState
    if isempty(auxState), auxState = uint32(0); end

    switch sub
        case 'flash'
            port = iif(numel(varargin)>=2, char(varargin{2}), esp32_io('detect_port'));
            role = iif(numel(varargin)>=3, char(varargin{3}), 'standalone');
            radio = iif(strcmpi(role,'slave'), 'sta_now', 'ap_now');
            uiHtml = fullfile(wb_paths('projects'), 'green_agv', 'web_ui_agv.html');
            inoPath = fullfile(wb_paths('projects'), 'green_agv', 'green_agv_mainboard.ino');
            [ok, bid] = esp32_flash(inoPath, '--usb', port, '--board', 'green_agv_rev52a', '--role', role, '--radio', radio, '--ui-file', uiHtml);
            if nargout > 0, varargout{1} = struct('ok',ok,'buildId',bid); end
            return;
        case 'stop',  w0 = pack(1, 0, auxState, 0, 0);
        case 'line',  w0 = pack(1, 2, auxState, 0, 0);
        case 'zero',  w0 = pack(15, 1, auxState, 0, 0);
        case 'lights'
            auxState = bitor(bitand(auxState, uint32(252)), bitand(uint32(str2double(string(varargin{2}))), uint32(3)));
            w0 = pack(1, 1, auxState, 0, 0);
        case 'drive'
            cL = int32(min(max(str2double(string(varargin{2})), -100), 100));
            cR = int32(min(max(str2double(string(varargin{3})), -100), 100));
            if numel(varargin) >= 4, auxState = uint32(str2double(string(varargin{4}))); end
            w0 = pack(1, 1, auxState, cL, cR);
        case 'telem'
            t = decode_t(esp32_io('cmd', 'TELEM'));
            print_t(t); if nargout>0, varargout{1}=t; end; return;
        otherwise
            error('AGV:BadSub', 'Usage: esp32_cli green_agv <flash|drive L R|line|stop|zero|lights 0..3|telem>');
    end

    t = decode_t(esp32_io('cmd', sprintf('SYNC %08X', w0)));
    print_t(t); if nargout>0, varargout{1}=t; end
end

function w = pack(m, md, aux, l, r)
    w = bitor(bitor(bitshift(uint32(m),28), bitshift(uint32(md),24)), ...
              bitor(bitshift(bitand(uint32(aux),255),16), bitor(bitshift(uint32(bitand(int32(l),255)),8), uint32(bitand(int32(r),255)))));
end
function t = decode_t(raw)
    hp = regexp(raw,'[0-9A-Fa-f]{8}','match'); if numel(hp)==5, hp=hp(2:5); end
    t = struct('encL',0,'encR',0,'us_mm',0,'lineMask',0,'btnT1',0,'btnT2',0,'fsm',0,'x_mm',0,'y_mm',0,'theta_deg',0,'vel_mms',0,'rtt_us',NaN,'loss',NaN);
    if numel(hp)<4, return; end
    w1=uint32(hex2dec(hp{1})); w2=uint32(hex2dec(hp{2})); w3=uint32(hex2dec(hp{3})); w4=uint32(hex2dec(hp{4}));
    t.encL=i16(bitshift(w1,-16)); t.encR=i16(bitand(w1,65535)); t.us_mm=double(bitshift(w2,-16));
    msk=double(bitand(bitshift(w2,-8),255)); t.lineMask=bitand(msk,7); t.btnT1=bitand(bitshift(msk,-3),1); t.btnT2=bitand(bitshift(msk,-4),1);
    t.fsm=double(bitand(w2,255)); t.x_mm=i16(bitshift(w3,-16)); t.y_mm=i16(bitand(w3,65535));
    t.theta_deg=rad2deg(i16(bitshift(w4,-16))/1000.0); t.vel_mms=i16(bitand(w4,65535));
    rm=regexp(raw,'RTT_US:(\d+)','tokens','once'); if~isempty(rm), t.rtt_us=str2double(rm{1}); end
    lm=regexp(raw,'LOSS:(\d+)','tokens','once'); if~isempty(lm), t.loss=str2double(lm{1}); end
end
function print_t(t)
    wb_log('info','AGV',sprintf('FSM=%d',t.fsm),sprintf('Vel=%d mm/s | Pose=(%d, %d mm, %.1f deg) | Enc=%d/%d | US=%d mm | Line=%s T=%d%d | RTT=%.0fus', ...
        t.vel_mms,t.x_mm,t.y_mm,t.theta_deg,t.encL,t.encR,t.us_mm,dec2bin(t.lineMask,3),t.btnT1,t.btnT2,t.rtt_us));
end
function v = i16(u), v=double(int32(u)); if v>=32768, v=v-65536; end; end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
EOF

cat << 'EOF' > projects/green_agv/green_agv_mainboard.ino
#include <Arduino.h>
#include <esp_arduino_version.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"

static volatile int32_t  g_encTicksL = 0, g_encTicksR = 0;
static volatile uint32_t g_lastIsrL  = 0, g_lastIsrR  = 0;
static volatile int8_t   g_dirL = 1, g_dirR = 1;
static float g_xMm = 0.0f, g_yMm = 0.0f, g_thetaRad = 0.0f;
static int16_t g_velMms = 0; static uint16_t g_usMm = 3000; static uint8_t g_fsm = 0; static int8_t g_locMode = -1;
static float g_lastErr = 0.0f, g_integ = 0.0f; static int8_t g_lastSign = 1;

void IRAM_ATTR isrEncL() { uint32_t t = micros(); if ((t - g_lastIsrL) >= 500u) { g_encTicksL += g_dirL; g_lastIsrL = t; } }
void IRAM_ATTR isrEncR() { uint32_t t = micros(); if ((t - g_lastIsrR) >= 500u) { g_encTicksR += g_dirR; g_lastIsrR = t; } }

static inline void agvPwmAttach(uint8_t pin, uint8_t ch) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(pin, AGV_PWM_FREQ_HZ, AGV_PWM_RES_BITS);
#else
  ledcSetup(ch, AGV_PWM_FREQ_HZ, AGV_PWM_RES_BITS); ledcAttachPin(pin, ch);
#endif
  (void)ch;
}
static inline void agvPwmWrite(uint8_t pin, uint8_t ch, uint32_t d) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(pin, d);
#else
  ledcWrite(ch, d);
#endif
  (void)ch;
}
static void drivePair(uint8_t pA, uint8_t cA, uint8_t pB, uint8_t cB, int8_t pct, volatile int8_t& dir) {
  int p = constrain((int)pct, -100, 100); uint32_t mx = (1u << AGV_PWM_RES_BITS) - 1u;
  if (p > 0) { dir = 1; agvPwmWrite(pA, cA, (uint32_t)(p * (int)mx / 100)); agvPwmWrite(pB, cB, 0); }
  else if (p < 0) { dir = -1; agvPwmWrite(pA, cA, 0); agvPwmWrite(pB, cB, (uint32_t)((-p) * (int)mx / 100)); }
  else { agvPwmWrite(pA, cA, 0); agvPwmWrite(pB, cB, 0); }
}
static uint16_t readUsMm() {
  digitalWrite(AGV_PIN_US_TRIG, LOW); delayMicroseconds(2);
  digitalWrite(AGV_PIN_US_TRIG, HIGH); delayMicroseconds(10);
  digitalWrite(AGV_PIN_US_TRIG, LOW);
  unsigned long d = pulseIn(AGV_PIN_US_ECHO, HIGH, 12000u);
  return (d < 100u) ? 3000 : (uint16_t)min(3000UL, (d * 343UL) / 2000UL);
}

void setup() {
  agvPwmAttach(AGV_PIN_MOT_L_A,0); agvPwmAttach(AGV_PIN_MOT_L_B,1);
  agvPwmAttach(AGV_PIN_MOT_R_A,2); agvPwmAttach(AGV_PIN_MOT_R_B,3);
  drivePair(AGV_PIN_MOT_L_A,0,AGV_PIN_MOT_L_B,1,0,g_dirL); drivePair(AGV_PIN_MOT_R_A,2,AGV_PIN_MOT_R_B,3,0,g_dirR);

  pinMode(AGV_PIN_ENC_L, INPUT_PULLUP); pinMode(AGV_PIN_ENC_R, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(AGV_PIN_ENC_L), isrEncL, RISING);
  attachInterrupt(digitalPinToInterrupt(AGV_PIN_ENC_R), isrEncR, RISING);

  pinMode(AGV_PIN_US_TRIG, OUTPUT); digitalWrite(AGV_PIN_US_TRIG, LOW); pinMode(AGV_PIN_US_ECHO, INPUT_PULLDOWN);
  pinMode(AGV_PIN_LINE_L, INPUT); pinMode(AGV_PIN_LINE_M, INPUT); pinMode(AGV_PIN_LINE_R, INPUT);
  pinMode(AGV_PIN_BTN_T1, INPUT_PULLDOWN); pinMode(AGV_PIN_BTN_T2, INPUT_PULLDOWN);
  pinMode(AGV_PIN_LED_FL, OUTPUT); pinMode(AGV_PIN_LED_FR, OUTPUT);
  pinMode(AGV_PIN_LED_RR, OUTPUT); pinMode(AGV_PIN_LED_RL, OUTPUT);
}

void loop() {
  static uint32_t lastUs = 0, lastPing = 0; static int32_t pL = 0, pR = 0;
  static bool prevT1 = false, prevT2 = false; static float vDs = 0.0f, vDt = 0.0f;
  uint32_t now = micros(); if ((now - lastUs) < 2000u) { delayMicroseconds(200); return; }
  float dt = (float)(now - lastUs) * 1e-6f; lastUs = now; if (dt <= 0.0f || dt > 0.1f) dt = 0.002f;
  if ((millis() - lastPing) >= 60u) { lastPing = millis(); g_usMm = readUsMm(); }

  uint32_t s0 = REG_READ(RTC_CNTL_STORE0_REG);
  uint8_t magic = (s0>>28)&15, mode = (s0>>24)&15, aux = (s0>>16)&255;
  int8_t cmdL = (int8_t)((s0>>8)&255), cmdR = (int8_t)(s0&255);
  if (magic == 0xF) {
    noInterrupts(); g_encTicksL=0; g_encTicksR=0; interrupts();
    pL=0; pR=0; g_xMm=0; g_yMm=0; g_thetaRad=0;
    REG_WRITE(RTC_CNTL_STORE0_REG, (s0 & 0x0FFFFFFFu) | 0x10000000u);
  }

  bool lH=(digitalRead(AGV_PIN_LINE_L)==HIGH), mH=(digitalRead(AGV_PIN_LINE_M)==HIGH), rH=(digitalRead(AGV_PIN_LINE_R)==HIGH);
  bool t1=(digitalRead(AGV_PIN_BTN_T1)==AGV_BTN_ACT_LVL), t2=(digitalRead(AGV_PIN_BTN_T2)==AGV_BTN_ACT_LVL);
  if (t1 && !prevT1) g_locMode = (g_locMode == 2) ? -1 : 2;
  if (t2 && !prevT2) g_locMode = 0;
  prevT1 = t1; prevT2 = t2;
  if (g_locMode >= 0 && mode != 0) mode = (uint8_t)g_locMode;
  if (mode == 0) g_locMode = -1;

  digitalWrite(AGV_PIN_LED_FL, (aux&1)?HIGH:LOW); digitalWrite(AGV_PIN_LED_FR, (aux&1)?HIGH:LOW);
  digitalWrite(AGV_PIN_LED_RR, (aux&2)?HIGH:LOW); digitalWrite(AGV_PIN_LED_RL, (aux&2)?HIGH:LOW);

  int8_t oL = 0, oR = 0;
  if (mode == 0) { g_fsm = 0; g_integ = 0; }
  else if (mode == 1) { g_fsm = 1; oL = cmdL; oR = cmdR; }
  else if (mode == 2) {
    if (g_usMm < 120) { g_fsm = 4; }
    else {
      g_fsm = 2; int cnt = (lH?1:0)+(mH?1:0)+(rH?1:0);
      float err = cnt ? (((rH?1.0f:0.0f)-(lH?1.0f:0.0f))/(float)cnt) : (1.2f*(float)g_lastSign);
      if (cnt && err != 0.0f) g_lastSign = (err > 0.0f) ? 1 : -1;
      g_integ = constrain(g_integ + err*dt, -1.5f, 1.5f);
      float deriv = (err - g_lastErr) / dt; g_lastErr = err;
      float corr = 38.0f*err + 0.5f*g_integ + 0.45f*deriv;
      oL = (int8_t)constrain((int)(55 + corr), -100, 100);
      oR = (int8_t)constrain((int)(55 - corr), -100, 100);
    }
  }
  drivePair(AGV_PIN_MOT_L_A,0,AGV_PIN_MOT_L_B,1,oL,g_dirL); drivePair(AGV_PIN_MOT_R_A,2,AGV_PIN_MOT_R_B,3,oR,g_dirR);

  int32_t cL, cR; noInterrupts(); cL=g_encTicksL; cR=g_encTicksR; interrupts();
  int32_t dTL=cL-pL, dTR=cR-pR; pL=cL; pR=cR;
  float mmPt = (3.1415926f * AGV_WHEEL_DIAM_MM) / (float)AGV_TICKS_PER_REV;
  float dL=dTL*mmPt, dR=dTR*mmPt, dS=0.5f*(dL+dR), dTh=(dR-dL)/AGV_WHEEL_BASE_MM;
  g_thetaRad += dTh; g_xMm += dS*cosf(g_thetaRad); g_yMm += dS*sinf(g_thetaRad);
  vDs += dS; vDt += dt;
  if (vDt >= 0.040f) { g_velMms = (int16_t)constrain((int)(vDs/vDt), -32767, 32767); vDs=0; vDt=0; }

  uint8_t msk = (rH?1:0)|(mH?2:0)|(lH?4:0)|(t1?8:0)|(t2?16:0);
  REG_WRITE(RTC_CNTL_STORE1_REG, ((uint32_t)(uint16_t)(int16_t)cL<<16)|(uint16_t)(int16_t)cR);
  REG_WRITE(RTC_CNTL_STORE2_REG, ((uint32_t)g_usMm<<16)|((uint32_t)msk<<8)|g_fsm);
  REG_WRITE(RTC_CNTL_STORE3_REG, ((uint32_t)(uint16_t)(int16_t)g_xMm<<16)|(uint16_t)(int16_t)g_yMm);
  REG_WRITE(RTC_CNTL_STORE4_REG, ((uint32_t)(uint16_t)(int16_t)constrain((int)(g_thetaRad*1000.0f),-32767,32767)<<16)|(uint16_t)g_velMms);
}
EOF

cat << 'EOF' > experiments/digital_twin/twin_cli.m
function varargout = twin_cli(varargin)
%TWIN_CLI Isolated Digital-Twin Experiment Plugin (invoked via 'esp32_cli twin <flash|verify|map>').
%   Completely decoupled from core/: uses esp32_io for DUT and a private serial handle for Plant Sim.
    if isempty(varargin), sub = 'verify'; else, sub = lower(strtrim(char(varargin{1}))); end
    persistent simSp
    cfg = wb_config('workbench');

    switch sub
        case 'flash'
            simPort = iif(numel(varargin)>=2, char(varargin{2}), esp32_io('detect_port'));
            ino = fullfile(wb_paths('experiments'), 'digital_twin', 'green_agv_plant_sim.ino');
            [ok, bid] = esp32_flash(ino, '--usb', simPort, '--board', 'green_agv_rev52a', '--radio', 'off');
            if nargout>0, varargout{1}=struct('ok',ok,'buildId',bid); end

        case 'verify'
            dutPort = char(varargin{2});
            simPort = char(varargin{3});
            esp32_cli('connect', dutPort);
            simSp = open_sim(simSp, simPort, cfg);

            wb_log('hdr', 'TWIN', 'WIRE_AUDIT', sprintf('Testing DUT=%s <-> SIM=%s', dutPort, simPort));
            send_sim(simSp, 0, 0, 5, 350);
            green_agv_cli('drive', 60, 60, 3);
            pause(0.25);
            simT = send_sim(simSp, 0, 0, 5, 350);
            dutT = green_agv_cli('telem');
            green_agv_cli('stop'); green_agv_cli('lights', 0);

            checks = {
                'Motor L PWM (A:D13 -> B:D13)',   abs(simT.pwmL-60)<=5 && simT.freqL>1500, iif(simT.pwmL<-50, sprintf('%d%% @ %d Hz (WIRED TO B:D12! Move to B:D13)', simT.pwmL, simT.freqL), sprintf('%d%% @ %d Hz', simT.pwmL, simT.freqL));
                'Motor R PWM (A:D4  -> B:D4)',    abs(simT.pwmR-60)<=5 && simT.freqR>1500, sprintf('%d%% @ %d Hz', simT.pwmR, simT.freqR);
                'LEDs (A:25,33,14,23->B)',        simT.ledMask==15,                         sprintf('Mask=0x%X (exp 0xF)', simT.ledMask);
                'Line L/M/R (B:16,32,17->A:34,32,35)', dutT.lineMask==5,                   sprintf('Read=%s (exp 101)', dec2bin(dutT.lineMask,3));
                'Ultrasonic (D27 Trig / D26 Echo)', simT.trigCount>0 && abs(dutT.us_mm-350)<=35, sprintf('Trig=%d Meas=%d mm (exp 350)', simT.trigCount, dutT.us_mm)
            };
            allOk = true;
            for k = 1:size(checks, 1)
                ok = checks{k,2}; if ~ok, allOk = false; end
                wb_log(iif(ok,'pass','open'), 'TWIN', checks{k,1}, checks{k,3});
            end
            if nargout>0, varargout{1} = struct('allPassed',allOk,'checks',{checks},'dut',dutT,'sim',simT); end

        case 'disconnect'
            if ~isempty(simSp) && isvalid(simSp), try delete(simSp); catch, end; end; simSp = [];

        otherwise
            error('TWIN:BadSub', 'Usage: esp32_cli twin <flash SIM_PORT | verify DUT_PORT SIM_PORT | disconnect>');
    end
end

function sp = open_sim(spOld, port, cfg)
    if ~isempty(spOld) && isvalid(spOld) && strcmpi(spOld.Port, port), sp = spOld; return; end
    if ~isempty(spOld) && isvalid(spOld), try delete(spOld); catch, end; end
    try objs=serialportfind('Port',upper(string(port))); for k=1:numel(objs), delete(objs(k)); end; catch, end
    sp = serialport(port, cfg.transport.serial.defaultBaud, 'Timeout', 1.2);
    configureTerminator(sp, "LF"); pause(0.35); flush(sp);
    writeline(sp, 'STATUS'); resp = drain(sp);
    if ~contains(resp, 'USB_ONLY'), delete(sp); error('TWIN:BadSim', 'Port %s is not USB_ONLY SIM: %s', port, resp); end
    wb_log('pass', 'TWIN', 'SIM_READY', sprintf('%s -> %s', port, resp));
end

function s = send_sim(sp, autoTrk, btns, lineMask, distMm)
    w0 = bitor(bitor(bitshift(uint32(1),28), bitshift(uint32(autoTrk),24)), ...
               bitor(bitshift(uint32(btns),20), bitor(bitshift(uint32(lineMask),16), uint32(min(max(distMm,40),3000)))));
    flush(sp); writeline(sp, sprintf('SYNC %08X', w0)); raw = drain(sp);
    hp = regexp(raw,'[0-9A-Fa-f]{8}','match');
    s = struct('pwmL',0,'pwmR',0,'freqL',0,'freqR',0,'ledMask',0,'trigCount',0,'encL',0,'encR',0);
    if numel(hp)<4, return; end
    w1=uint32(hex2dec(hp{1})); w2=uint32(hex2dec(hp{2})); w3=uint32(hex2dec(hp{3})); w4=uint32(hex2dec(hp{4}));
    s.pwmL=i16(bitshift(w1,-16)); s.pwmR=i16(bitand(w1,65535));
    s.freqL=double(bitshift(w2,-16)); s.freqR=double(bitand(w2,65535));
    s.ledMask=double(bitand(bitshift(w3,-16),15)); s.trigCount=double(bitand(w3,65535));
    s.encL=i16(bitshift(w4,-16)); s.encR=i16(bitand(w4,65535));
end

function ln = drain(sp)
    bp = ["ets ","rst:","mode:","load:","entry ","configsip:","clk_drv:","ho 0 ","E (","W (","I (","D ("];
    for k=1:25
        lastwarn(''); ln=strtrim(char(readline(sp))); [wm,~]=lastwarn;
        if isempty(ln) && ~isempty(wm), error('TWIN:Timeout','Timeout on %s',sp.Port); end
        if ~isempty(ln) && ~any(startsWith(string(ln),bp)) && ~strcmp(ln,'ESP32_READY'), return; end
    end
    error('TWIN:NoData','No payload from SIM');
end
function v = i16(u), v=double(int32(u)); if v>=32768, v=v-65536; end; end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
EOF

cat << 'EOF' > experiments/digital_twin/green_agv_plant_sim.ino
#include <Arduino.h>
#include "driver/gpio.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"

struct PwmCap { uint8_t pin; volatile uint32_t lastRiseUs, highUs, periodUs, lastEdgeUs; volatile uint16_t edgeCount; };
static portMUX_TYPE g_simMux = portMUX_INITIALIZER_UNLOCKED;
static PwmCap g_cap[4] = {
  {SIM_MOT_LA_IN,0,0,0,0,0}, {SIM_MOT_LB_IN,0,0,0,0,0},
  {SIM_MOT_RA_IN,0,0,0,0,0}, {SIM_MOT_RB_IN,0,0,0,0,0}
};

static inline void IRAM_ATTR handlePwmEdge(int idx) {
  uint32_t now = (uint32_t)esp_timer_get_time();
  portENTER_CRITICAL_ISR(&g_simMux);
  g_cap[idx].lastEdgeUs = now; g_cap[idx].edgeCount++;
  if (gpio_get_level((gpio_num_t)g_cap[idx].pin) == 1) {
    uint32_t per = now - g_cap[idx].lastRiseUs;
    if (per >= 100u && per <= 50000u) g_cap[idx].periodUs = per;
    g_cap[idx].lastRiseUs = now;
  } else {
    uint32_t hi = now - g_cap[idx].lastRiseUs;
    if (hi <= 50000u) g_cap[idx].highUs = hi;
  }
  portEXIT_CRITICAL_ISR(&g_simMux);
}
void IRAM_ATTR isrPwm0() { handlePwmEdge(0); } void IRAM_ATTR isrPwm1() { handlePwmEdge(1); }
void IRAM_ATTR isrPwm2() { handlePwmEdge(2); } void IRAM_ATTR isrPwm3() { handlePwmEdge(3); }

static volatile bool g_trigSeen = false; static volatile uint32_t g_trigUs = 0; static volatile uint16_t g_trigCount = 0;
void IRAM_ATTR isrUsTrig() {
  portENTER_CRITICAL_ISR(&g_simMux);
  g_trigUs = (uint32_t)esp_timer_get_time(); g_trigSeen = true; g_trigCount++;
  portEXIT_CRITICAL_ISR(&g_simMux);
}

static void readCap(int i, float* dutyPct, uint16_t* freqHz) {
  uint32_t now = (uint32_t)esp_timer_get_time();
  portENTER_CRITICAL(&g_simMux);
  uint32_t age = now - g_cap[i].lastEdgeUs, hi = g_cap[i].highUs, per = g_cap[i].periodUs; uint16_t ec = g_cap[i].edgeCount;
  if (age > 6000u) g_cap[i].edgeCount = 0;
  portEXIT_CRITICAL(&g_simMux);
  if (age > 6000u || per == 0 || ec < 3) { *dutyPct = (digitalRead(g_cap[i].pin)==HIGH)?100.0f:0.0f; *freqHz = 0; }
  else { *dutyPct = constrain(100.0f*(float)hi/(float)per, 0.0f, 100.0f); *freqHz = (uint16_t)min(65535UL, (unsigned long)(1000000UL/per)); }
}

void setup() {
  for (int i=0;i<4;++i) pinMode(g_cap[i].pin, INPUT_PULLDOWN);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_LA_IN), isrPwm0, CHANGE);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_LB_IN), isrPwm1, CHANGE);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_RA_IN), isrPwm2, CHANGE);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_RB_IN), isrPwm3, CHANGE);
  pinMode(SIM_US_TRIG_IN, INPUT_PULLDOWN); attachInterrupt(digitalPinToInterrupt(SIM_US_TRIG_IN), isrUsTrig, FALLING);

  pinMode(SIM_US_ECHO_OUT,OUTPUT); digitalWrite(SIM_US_ECHO_OUT,LOW);
  pinMode(SIM_LINE_L_OUT,OUTPUT); digitalWrite(SIM_LINE_L_OUT,LOW);
  pinMode(SIM_LINE_M_OUT,OUTPUT); digitalWrite(SIM_LINE_M_OUT,HIGH);
  pinMode(SIM_LINE_R_OUT,OUTPUT); digitalWrite(SIM_LINE_R_OUT,LOW);
  pinMode(SIM_BTN_T1_OUT,OUTPUT); digitalWrite(SIM_BTN_T1_OUT,LOW);
  pinMode(SIM_BTN_T2_OUT,OUTPUT); digitalWrite(SIM_BTN_T2_OUT,LOW);
  pinMode(SIM_ENC_L_OUT,OUTPUT); digitalWrite(SIM_ENC_L_OUT,LOW);
  pinMode(SIM_ENC_R_OUT,OUTPUT); digitalWrite(SIM_ENC_R_OUT,LOW);
  pinMode(SIM_LED_FL_IN,INPUT_PULLDOWN); pinMode(SIM_LED_FR_IN,INPUT_PULLDOWN);
  pinMode(SIM_LED_RR_IN,INPUT_PULLDOWN); pinMode(SIM_LED_RL_IN,INPUT_PULLDOWN);
  REG_WRITE(RTC_CNTL_STORE0_REG, 0x10020258u);
}

void loop() {
  static uint32_t lastPhys = (uint32_t)esp_timer_get_time(), eStart = 0, eEnd = 0; static uint8_t ePh = 0;
  static float phL = 0.0f, phR = 0.0f; static int16_t encL = 0, encR = 0;
  uint32_t s0 = REG_READ(RTC_CNTL_STORE0_REG);
  uint8_t autoTrk=(s0>>24)&15, btns=(s0>>20)&15, lineMsk=(s0>>16)&15; uint16_t distMm=(uint16_t)(s0&0xFFFFu);
  if (distMm < 30) distMm = 3000;

  uint32_t now = (uint32_t)esp_timer_get_time(); bool trigNow=false; uint32_t t0=0;
  portENTER_CRITICAL(&g_simMux);
  if (g_trigSeen) { g_trigSeen=false; t0=g_trigUs; trigNow=true; }
  uint16_t trigSnap = g_trigCount;
  portEXIT_CRITICAL(&g_simMux);

  if (trigNow) { eStart = t0 + 420u; eEnd = eStart + (uint32_t)(distMm * 5.831f); ePh = 1; }
  if (ePh == 1 && (int32_t)(now - eStart) >= 0) { digitalWrite(SIM_US_ECHO_OUT, HIGH); ePh = 2; }
  else if (ePh == 2 && (int32_t)(now - eEnd) >= 0) { digitalWrite(SIM_US_ECHO_OUT, LOW); ePh = 0; }

  if (autoTrk) { static const uint8_t seq[6]={2,6,4,2,3,1}; lineMsk=seq[(millis()/1200u)%6u]; }
  digitalWrite(SIM_LINE_L_OUT,(lineMsk&4)?HIGH:LOW); digitalWrite(SIM_LINE_M_OUT,(lineMsk&2)?HIGH:LOW); digitalWrite(SIM_LINE_R_OUT,(lineMsk&1)?HIGH:LOW);
  digitalWrite(SIM_BTN_T1_OUT,(btns&1)?HIGH:LOW); digitalWrite(SIM_BTN_T2_OUT,(btns&2)?HIGH:LOW);

  float dt = (float)(now - lastPhys) * 1e-6f;
  if (dt >= 0.001f) {
    lastPhys = now; float dLA,dLB,dRA,dRB; uint16_t fLA,fLB,fRA,fRB;
    readCap(0,&dLA,&fLA); readCap(1,&dLB,&fLB); readCap(2,&dRA,&fRA); readCap(3,&dRB,&fRB);
    int16_t netL=(int16_t)roundf(dLA-dLB), netR=(int16_t)roundf(dRA-dRB);
    uint16_t fL=(dLA>=dLB)?fLA:fLB, fR=(dRA>=dRB)?fRA:fRB;

    phL += fabsf((float)netL)*0.45f*dt; phR += fabsf((float)netR)*0.45f*dt;
    if (phL>=1.0f){phL-=1.0f; encL+=(netL>=0)?1:-1;} if (phR>=1.0f){phR-=1.0f; encR+=(netR>=0)?1:-1;}
    digitalWrite(SIM_ENC_L_OUT, (phL<0.5f && netL!=0)?HIGH:LOW);
    digitalWrite(SIM_ENC_R_OUT, (phR<0.5f && netR!=0)?HIGH:LOW);

    uint8_t leds=(digitalRead(SIM_LED_FL_IN)?1:0)|(digitalRead(SIM_LED_FR_IN)?2:0)|(digitalRead(SIM_LED_RR_IN)?4:0)|(digitalRead(SIM_LED_RL_IN)?8:0);
    REG_WRITE(RTC_CNTL_STORE1_REG, ((uint32_t)(uint16_t)netL<<16)|(uint16_t)netR);
    REG_WRITE(RTC_CNTL_STORE2_REG, ((uint32_t)fL<<16)|(uint32_t)fR);
    REG_WRITE(RTC_CNTL_STORE3_REG, ((uint32_t)leds<<16)|(uint32_t)trigSnap);
    REG_WRITE(RTC_CNTL_STORE4_REG, ((uint32_t)(uint16_t)encL<<16)|(uint16_t)encR);
  }
  delayMicroseconds(20);
}
EOF

echo "=== [4/4] Moving Untethered Field Cockpit HTML into projects/green_agv/ ==="
# Restore web_ui_agv.html inside projects/green_agv/ (optional field web UI, only injected when green_agv flashes)
cat << 'EOF' > projects/green_agv/web_ui_agv.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>Green AGV Field Cockpit</title>
<style>
:root{--bg:#090d16;--pnl:#111827;--bd:#1f2937;--fg:#f3f4f6;--mut:#9ca3af;--acc:#06b6d4;--ok:#10b981}
*{box-sizing:border-box;user-select:none;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
html,body{margin:0;padding:0;height:100%;background:var(--bg);color:var(--fg);overflow:hidden}
.app{display:grid;height:100%;padding:8px;gap:8px;grid-template-rows:40px 1fr}
.top{display:flex;justify-content:space-between;align-items:center;background:var(--pnl);border:1px solid var(--bd);border-radius:10px;padding:0 12px}
.deck{display:grid;gap:8px;min-height:0}
.card{background:var(--pnl);border:1px solid var(--bd);border-radius:12px;padding:10px;display:flex;flex-direction:column;gap:8px}
.kpis{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
.kpi{background:#0b1220;border:1px solid var(--bd);border-radius:8px;padding:6px;text-align:center}
.kpi b{font-family:monospace;font-size:15px;color:var(--ok)}
.btn{border:1px solid var(--bd);background:#1f2937;color:var(--fg);border-radius:10px;padding:10px;font-weight:700;cursor:pointer}
.btn.estop{background:#b91c1c;color:#fff}.btn.on{background:#0284c7}
.dpad{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;flex:1}
canvas{width:100%;flex:1;min-height:110px;background:#050811;border:1px solid var(--bd);border-radius:8px}
@media(min-width:960px){.deck{grid-template-columns:1fr 1.3fr 1fr}}
@media(max-width:959px) and (orientation:landscape){.deck{grid-template-columns:1fr 1.2fr 1fr}}
</style>
</head>
<body>
<div class="app">
  <div class="top"><strong style="color:var(--ok)">GREEN AGV FIELD COCKPIT</strong><div><span id="fsm" style="font-family:monospace;color:var(--acc)">IDLE</span> | <a href="/ude" style="color:#93c5fd">/ude</a></div></div>
  <div class="deck">
    <div class="card">
      <div style="display:flex;gap:6px"><button class="btn" id="bFL" onclick="aux^=1;this.classList.toggle('on',aux&1)">Front LED</button><button class="btn" id="bRL" onclick="aux^=2;this.classList.toggle('on',aux&2)">Rear LED</button></div>
      <div style="display:flex;gap:6px"><button class="btn" id="bPid" onclick="mode=(mode===2?1:2);this.classList.toggle('on',mode===2)">Line PID</button><button class="btn" onclick="magic=15;trail=[]">Zero Pose</button></div>
      <div class="kpi"><small>LINE / US / ENC</small><br><b id="sen">000 | --mm | 0:0</b></div>
    </div>
    <div class="card">
      <div class="kpis"><div class="kpi"><small>VEL</small><br><b id="vel">0 mm/s</b></div><div class="kpi"><small>POSE</small><br><b id="pos">0,0</b></div><div class="kpi"><small>HDG</small><br><b id="hdg">0°</b></div></div>
      <canvas id="rad" width="320" height="190"></canvas>
      <button class="btn estop" onclick="mode=0;cmdL=0;cmdR=0">E-STOP (SPACE)</button>
    </div>
    <div class="card">
      <div class="dpad">
        <div></div><button class="btn" onmousedown="drv(1,1)" onmouseup="drv(0,0)" onmouseleave="drv(0,0)" ontouchstart="drv(1,1)" ontouchend="drv(0,0)">FWD</button><div></div>
        <button class="btn" onmousedown="drv(-1,1)" onmouseup="drv(0,0)" onmouseleave="drv(0,0)" ontouchstart="drv(-1,1)" ontouchend="drv(0,0)">LEFT</button>
        <button class="btn" onclick="mode=1">MAN</button>
        <button class="btn" onmousedown="drv(1,-1)" onmouseup="drv(0,0)" onmouseleave="drv(0,0)" ontouchstart="drv(1,-1)" ontouchend="drv(0,0)">RIGHT</button>
        <div></div><button class="btn" onmousedown="drv(-1,-1)" onmouseup="drv(0,0)" onmouseleave="drv(0,0)" ontouchstart="drv(-1,-1)" ontouchend="drv(0,0)">REV</button><div></div>
      </div>
      <input type="range" min="25" max="100" value="70" oninput="spd=+this.value">
    </div>
  </div>
</div>
<script>
let mode=1,aux=0,spd=70,cmdL=0,cmdR=0,magic=1,trail=[];
function i16(v){return(v&0x8000)?(v-65536):v;}
function drv(l,r){mode=1;cmdL=Math.round(l*spd);cmdR=Math.round(r*spd);}
function pack(){const w=((magic<<28)|(mode<<24)|(aux<<16)|((cmdL&255)<<8)|(cmdR&255))>>>0;magic=1;return w.toString(16).toUpperCase().padStart(8,'0');}
async function tick(){
  try{
    const t=await(await fetch('/cmd?q=SYNC%20'+pack())).text();
    const m=t.match(/([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})/);
    if(m){
      const w1=parseInt(m[1],16)>>>0,w2=parseInt(m[2],16)>>>0,w3=parseInt(m[3],16)>>>0,w4=parseInt(m[4],16)>>>0;
      const eL=i16(w1>>>16),eR=i16(w1&65535),us=w2>>>16,msk=(w2>>>8)&255,x=i16(w3>>>16),y=i16(w3&65535),th=i16(w4>>>16)/1000,v=i16(w4&65535);
      vel.textContent=v+' mm/s'; pos.textContent=x+','+y; hdg.textContent=Math.round(th*57.3)+'°';
      sen.textContent=(msk&7).toString(2).padStart(3,'0')+' | '+us+'mm | '+eL+':'+eR;
      fsm.textContent=['E-STOP','MANUAL','LINE_PID','SLAM','HOLD'][w2&255]||'RUN';
      trail.push([x,y]);if(trail.length>120)trail.shift();
      const cv=rad,ctx=cv.getContext('2d'),cx=cv.width/2,cy=cv.height/2,sc=0.05;
      ctx.fillStyle='#050811';ctx.fillRect(0,0,cv.width,cv.height);
      ctx.strokeStyle='#0ea5e9';ctx.beginPath();trail.forEach((p,i)=>{i?ctx.lineTo(cx+p[0]*sc,cy-p[1]*sc):ctx.moveTo(cx+p[0]*sc,cy-p[1]*sc);});ctx.stroke();
      ctx.fillStyle='#10b981';ctx.beginPath();ctx.arc(cx+x*sc,cy-y*sc,5,0,6.28);ctx.fill();
    }
  }catch(_){}
  setTimeout(tick,80);
}
tick();
</script>
</body>
</html>
EOF

echo "=== REFACTOR COMPLETE ==="