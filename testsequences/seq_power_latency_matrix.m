function report = seq_power_latency_matrix(masterPort, enableScope, enableDropout)
%SEQ_POWER_LATENCY_MATRIX Master/Slave Efficiency Profiler (CPU MHz, Radio State, RTT, Packet Loss, PSU + Scope).
    if nargin < 1 || isempty(masterPort), masterPort = esp32_io('detect_port'); end
    if nargin < 2 || isempty(enableScope), enableScope = true; end
    if nargin < 3 || isempty(enableDropout), enableDropout = true; end

    cfg = wb_config('workbench');
    instCfg = wb_config('instruments');
    board = wb_config('board');

    ks = inst_keysight_psu('open');
    c1 = instCfg.keysight_e36312a.channels.slaveLogic;
    inst_keysight_psu('config', ks, c1.ch, c1.nominalV, c1.currentLimitA, true);
    pause(1.5);

    sc = [];
    if enableScope
        try
            sc = inst_lecroy_scope('open');
            inst_lecroy_scope('setup_ch', sc, instCfg.lecroy_ws4104hd.channels.espNowRttProbe.ch, 1.0, 1e-3);
            inst_lecroy_scope('trigger_edge', sc, instCfg.lecroy_ws4104hd.channels.espNowRttProbe.ch, 1.65);
        catch ME
            warning('Scope unavailable (%s); continuing with PSU + ESP-NOW telemetry.', ME.message);
            sc = [];
        end
    end
    guard = onCleanup(@() teardown(ks, sc)); %#ok<NASGU>

    esp32_cli('verbose', 'off');
    esp32_cli('connect', masterPort);
    esp32_io('cmd', 'ROLE MASTER');

    profiles = {'ECO', 'BALANCED', 'TURBO'};
    states = {
        'IDLE_SAFE',    '10000000';
        'LIGHTS_ON',    '11030000';
        'DRIVE_50PCT',  '11033232';
        'LINE_PID',     '12030000';
        'OTA_WAKE_AP',  'E0000000'
    };

    recs = struct('Profile',{},'State',{},'V_Slave',{},'I_Slave_mA',{},'P_Slave_mW',{},'RTT_us',{},'Loss',{},'ScopeWid_us',{});
    idx = 0;
    fprintf('\n=== POWER & LATENCY EFFICIENCY MATRIX ===\n');
    for p = 1:numel(profiles)
        prof = profiles{p};
        esp32_io('cmd', ['POWER ' prof]);
        for s = 1:size(states, 1)
            idx = idx + 1;
            stName = states{s,1}; cmdHex = states{s,2};
            esp32_io('cmd', ['SYNC ' cmdHex]);
            pause(0.8);
            m = inst_keysight_psu('measure', ks, c1.ch);
            en = esp32_io('cmd', 'ESPNOW PING');
            rttUs = parse_kv(en, 'RTT_US');
            loss  = parse_kv(en, 'LOSS');
            scWid = NaN;
            if ~isempty(sc)
                try pava = inst_lecroy_scope('measure_pava', sc, instCfg.lecroy_ws4104hd.channels.espNowRttProbe.ch); scWid = pava.WID * 1e6; catch, end
            end
            recs(idx) = struct('Profile',prof,'State',stName,'V_Slave',m.V,'I_Slave_mA',m.I_mA,'P_Slave_mW',m.P_mW,'RTT_us',rttUs,'Loss',loss,'ScopeWid_us',scWid);
            fprintf('  %-8s | %-12s | %6.2f mA | %6.1f mW | RTT=%5.0f us | Loss=%2.0f | Scope=%5.0f us\n', ...
                prof, stName, m.I_mA, m.P_mW, rttUs, loss, scWid);
        end
    end
    esp32_cli('agv', 'stop');
    esp32_io('cmd', 'POWER BALANCED');

    dropout = [];
    if enableDropout
        fprintf('\n--- Battery Brownout & LDO Dropout Sweep (5.2V -> 3.4V) ---\n');
        vSweep = 5.20:-0.20:3.40;
        dropout = struct('V_Set',{},'V_Meas',{},'I_mA',{},'Alive',{},'RTT_us',{});
        for k = 1:numel(vSweep)
            inst_keysight_psu('volt', ks, c1.ch, vSweep(k)); pause(0.45);
            m = inst_keysight_psu('measure', ks, c1.ch);
            b = parse_kv(esp32_io('cmd','ESPNOW STATUS'), 'RX');
            esp32_io('cmd','ESPNOW PING'); pause(0.06);
            aStr = esp32_io('cmd','ESPNOW STATUS');
            alive = parse_kv(aStr,'RX') > b;
            rUs = ternary(alive, parse_kv(aStr,'RTT_US'), NaN);
            dropout(k) = struct('V_Set',vSweep(k),'V_Meas',m.V,'I_mA',m.I_mA,'Alive',alive,'RTT_us',rUs);
            fprintf('  Vin=%.2fV | I=%.1f mA | Alive=%d | RTT=%.0f us\n', m.V, m.I_mA, alive, rUs);
        end
        inst_keysight_psu('volt', ks, c1.ch, c1.nominalV); pause(1.2);
    end

    report = struct('Board',board.boardName,'PowerProfiles',cfg.powerProfiles,'Matrix',recs,'Dropout',dropout);
    wb_results('power_latency_matrix', sprintf('eff_%s', strrep(masterPort,'/','_')), report);
end

function teardown(ks, sc)
    try inst_keysight_psu('close', ks); catch, end
    if ~isempty(sc), try inst_lecroy_scope('close', sc); catch, end; end
end
function v = parse_kv(s, k), v=NaN; t=regexp(char(s),[k ':([0-9.]+)'],'tokens','once'); if ~isempty(t), v=str2double(t{1}); end; end
function r = ternary(c,a,b), if c, r=a; else, r=b; end; end