function report = seq_power_latency_matrix(masterPort, enableScope, enableDropout)
%SEQ_POWER_LATENCY_MATRIX Master/Slave Power & Latency Profiler (Keysight PSU + LeCroy Scope).
    if nargin < 1 || isempty(masterPort), masterPort = esp32_io('detect_port'); end
    if nargin < 2 || isempty(enableScope), enableScope = true; end
    if nargin < 3 || isempty(enableDropout), enableDropout = true; end

    instCfg = wb_config('instruments');
    board   = wb_config('board', 'green_agv_rev52a');
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
            wb_log('warn', 'SCOPE', 'SKIP', ME.message); sc = [];
        end
    end
    guard = onCleanup(@() teardown(ks, sc)); %#ok<NASGU>

    esp32_cli('connect', masterPort);
    esp32_io('cmd', 'ROLE MASTER');

    profiles = {'ECO', 'BALANCED', 'TURBO'};
    states = { 'IDLE_SAFE','10000000'; 'LIGHTS_ON','11030000'; 'DRIVE_50PCT','11033232'; 'LINE_PID','12030000' };
    recs = struct('Profile',{},'State',{},'V_Slave',{},'I_Slave_mA',{},'P_Slave_mW',{},'RTT_us',{},'Loss',{},'ScopeWid_us',{});
    idx = 0;
    for p = 1:numel(profiles)
        prof = profiles{p}; esp32_io('cmd', ['POWER ' prof]);
        for s = 1:size(states, 1)
            idx = idx + 1;
            esp32_io('cmd', ['SYNC ' states{s,2}]); pause(0.8);
            m = inst_keysight_psu('measure', ks, c1.ch);
            en = esp32_io('cmd', 'ESPNOW PING');
            rttUs = parse_kv(en, 'RTT_US'); loss = parse_kv(en, 'LOSS'); scWid = NaN;
            if ~isempty(sc)
                try pava = inst_lecroy_scope('measure_pava', sc, instCfg.lecroy_ws4104hd.channels.espNowRttProbe.ch); scWid = pava.WID * 1e6; catch, end
            end
            recs(idx) = struct('Profile',prof,'State',states{s,1},'V_Slave',m.V,'I_Slave_mA',m.I_mA,'P_Slave_mW',m.P_mW,'RTT_us',rttUs,'Loss',loss,'ScopeWid_us',scWid);
            wb_log('info','PWR',sprintf('%s/%s',prof,states{s,1}),sprintf('%.2f mA | %.1f mW | RTT=%.0f us | Loss=%.0f',m.I_mA,m.P_mW,rttUs,loss));
        end
    end
    esp32_cli('green_agv', 'stop'); esp32_io('cmd', 'POWER BALANCED');

    dropout = [];
    if enableDropout
        vSweep = 5.20:-0.20:3.40;
        dropout = struct('V_Set',{},'V_Meas',{},'I_mA',{},'Alive',{},'RTT_us',{});
        for k = 1:numel(vSweep)
            inst_keysight_psu('volt', ks, c1.ch, vSweep(k)); pause(0.45);
            m = inst_keysight_psu('measure', ks, c1.ch);
            b = parse_kv(esp32_io('cmd','ESPNOW STATUS'), 'RX');
            esp32_io('cmd','ESPNOW PING'); pause(0.06);
            aStr = esp32_io('cmd','ESPNOW STATUS'); alive = parse_kv(aStr,'RX') > b;
            rUs = iif(alive, parse_kv(aStr,'RTT_US'), NaN);
            dropout(k) = struct('V_Set',vSweep(k),'V_Meas',m.V,'I_mA',m.I_mA,'Alive',alive,'RTT_us',rUs);
        end
        inst_keysight_psu('volt', ks, c1.ch, c1.nominalV); pause(1.2);
    end
    report = struct('Board',board.boardName,'Matrix',recs,'Dropout',dropout);
    wb_results('power_latency_matrix', sprintf('eff_%s', strrep(masterPort,'/','_')), report);
end
function teardown(ks, sc), try inst_keysight_psu('close', ks); catch, end; if ~isempty(sc), try inst_lecroy_scope('close', sc); catch, end; end; end
function v = parse_kv(s, k), v=NaN; t=regexp(char(s),[k ':([0-9.]+)'],'tokens','once'); if ~isempty(t), v=str2double(t{1}); end; end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end