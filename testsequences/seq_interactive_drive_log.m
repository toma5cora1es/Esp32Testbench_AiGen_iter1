function seqReport = seq_interactive_drive_log(durationSec, masterPort)
%SEQ_INTERACTIVE_DRIVE_LOG Interactive Web Cockpit + Keysight E36312A Current & RTT Logger.
    if nargin < 1 || isempty(durationSec), durationSec = 120; end
    if nargin < 2 || isempty(masterPort), masterPort = esp32_io('detect_port'); end

    cfg     = wb_config('workbench');
    instCfg = wb_config('instruments');
    ks = inst_keysight_psu('open');
    c1 = instCfg.keysight_e36312a.channels.slaveLogic;
    c2 = instCfg.keysight_e36312a.channels.motorBatteryRail;
    inst_keysight_psu('config', ks, c1.ch, c1.nominalV, c1.currentLimitA, true);
    inst_keysight_psu('config', ks, c2.ch, c2.nominalV, c2.currentLimitA, true);
    pause(1.0);
    cleanup = onCleanup(@() teardown(ks)); %#ok<NASGU>

    esp32_cli('verbose', 'off');
    esp32_cli('connect', masterPort);
    esp32_io('timeout', cfg.transport.serial.fastCmdTimeoutSec);
    esp32_io('cmd', 'ROLE MASTER');
    esp32_io('cmd', 'UI AGV');
    esp32_cli('agv', 'drive', 0, 0);

    esp32_io('ensure_ap', cfg.transport.wifi.apIp);
    web(sprintf('http://%s/agv', cfg.transport.wifi.apIp), '-browser');

    fig = figure('Name', 'Green AGV Interactive Drive + Keysight Recorder', 'Position', [60 60 1260 680], 'Color', [0.07 0.09 0.13]);
    tlo = tiledlayout(fig, 3, 1, 'Padding', 'compact');
    ax1 = nexttile(tlo,1); lI1=animatedline(ax1,'Color',[0 0.95 0.55],'LineWidth',1.8,'DisplayName','CH1 Logic (mA)');
    lI2=animatedline(ax1,'Color',[1 0.35 0.35],'LineWidth',1.8,'DisplayName','CH2 Motor (mA)');
    ylabel(ax1,'Current (mA)','Color','w'); legend(ax1); set(ax1,'Color',[0.11 0.13 0.18],'XColor','w','YColor','w'); grid(ax1,'on'); xlim(ax1,[0 durationSec]);

    ax2 = nexttile(tlo,2); lVel=animatedline(ax2,'Color',[1 0.95 0.2],'LineWidth',1.8,'DisplayName','Velocity (mm/s)');
    ylabel(ax2,'Vel (mm/s)','Color','w'); legend(ax2); set(ax2,'Color',[0.11 0.13 0.18],'XColor','w','YColor','w'); grid(ax2,'on'); xlim(ax2,[0 durationSec]);

    ax3 = nexttile(tlo,3); lUs=animatedline(ax3,'Color',[0.85 0.35 1],'LineWidth',1.6,'DisplayName','US (mm)');
    lRtt=animatedline(ax3,'Color',[0.2 0.95 0.95],'LineWidth',1.6,'DisplayName','RTT (us)');
    ylabel(ax3,'US / RTT','Color','w'); xlabel(ax3,'Time (s)','Color','w'); legend(ax3); set(ax3,'Color',[0.11 0.13 0.18],'XColor','w','YColor','w'); grid(ax3,'on'); xlim(ax3,[0 durationSec]);

    recs = struct('Time_s',{},'I_CH1_mA',{},'I_CH2_mA',{},'Vel_mms',{},'US_mm',{},'RTT_us',{});
    t0 = tic; k = 0;
    while toc(t0) < durationSec && ishandle(fig)
        tNow = toc(t0);
        m1 = inst_keysight_psu('measure', ks, c1.ch);
        m2 = inst_keysight_psu('measure', ks, c2.ch);
        raw = esp32_io('cmd', 'TELEM');
        hp = regexp(raw, '[0-9A-Fa-f]{8}', 'match');
        if numel(hp) >= 5
            k = k + 1;
            w2 = uint32(hex2dec(hp{3})); w4 = uint32(hex2dec(hp{5}));
            usMm = double(bitshift(w2, -16));
            vel = double(int32(bitand(w4, 65535))); if vel >= 32768, vel = vel - 65536; end
            rm = regexp(raw, 'RTT_US:(\d+)', 'tokens', 'once');
            rttUs = iif_nan(rm);
            addpoints(lI1, tNow, m1.I_mA); addpoints(lI2, tNow, m2.I_mA);
            addpoints(lVel, tNow, vel); addpoints(lUs, tNow, min(usMm,2500));
            if ~isnan(rttUs), addpoints(lRtt, tNow, rttUs); end
            drawnow limitrate;
            recs(k) = struct('Time_s',tNow,'I_CH1_mA',m1.I_mA,'I_CH2_mA',m2.I_mA,'Vel_mms',vel,'US_mm',usMm,'RTT_us',rttUs);
        end
        pause(0.18);
    end
    seqReport = struct('Duration_s',durationSec,'MeanCH1_mA',mean([recs.I_CH1_mA],'omitnan'),'MeanCH2_mA',mean([recs.I_CH2_mA],'omitnan'),'Records',recs);
    wb_results('interactive_drive', sprintf('drive_%ds', durationSec), seqReport);
end
function v = iif_nan(tok), if isempty(tok), v=NaN; else, v=str2double(tok{1}); end; end
function teardown(ks), try esp32_io('disconnect'); catch, end; try inst_keysight_psu('close', ks); catch, end; end