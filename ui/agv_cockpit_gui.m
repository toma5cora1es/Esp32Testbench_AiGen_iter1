function agv_cockpit_gui(targetEndpoint)
%AGV_COCKPIT_GUI Native MATLAB Mainboard Cockpit & Radar (100% English, config-driven).
    if nargin < 1 || isempty(targetEndpoint), targetEndpoint = esp32_io('detect_port'); end
    prev = findall(0, 'Type', 'figure', 'Tag', 'AGV_COCKPIT_GUI');
    if ~isempty(prev), close(prev); drawnow; end

    board = wb_config('board');
    esp32_cli('verbose', 'off');
    esp32_cli('connect', targetEndpoint);

    st = struct('Running',true,'Mode',1,'AuxMask',0,'MaxSpeed',75,'CmdL',0,'CmdR',0,'Magic',1, ...
        'Keys',containers.Map('KeyType','char','ValueType','logical'),'Trail',zeros(0,2),'Hits',zeros(0,2));

    fig = uifigure('Name', sprintf('%s â€” Native Mainboard Cockpit', board.boardName), ...
        'Position', [60 60 1260 660], 'Color', [0.04 0.05 0.08], 'Tag', 'AGV_COCKPIT_GUI', ...
        'WindowKeyPressFcn', @onKeyDown, 'WindowKeyReleaseFcn', @onKeyUp, 'CloseRequestFcn', @onClose);

    gMain = uigridlayout(fig, [2 1]); gMain.RowHeight = {46, '1x'}; gMain.BackgroundColor = [0.04 0.05 0.08];
    pnlTop = uipanel(gMain, 'BackgroundColor', [0.07 0.09 0.14], 'BorderType', 'none');
    gTop = uigridlayout(pnlTop, [1 2]); gTop.ColumnWidth = {'1x', 220}; gTop.BackgroundColor = [0.07 0.09 0.14];
    uilabel(gTop, 'Text', sprintf('%s | Endpoint: %s', board.boardName, targetEndpoint), 'FontColor', [0 0.95 0.55], 'FontSize', 14, 'FontWeight', 'bold');
    lblFsm = uilabel(gTop, 'Text', 'FSM: MANUAL', 'FontColor', [0 0.95 1], 'FontWeight', 'bold', 'HorizontalAlignment', 'center', 'BackgroundColor', [0.12 0.16 0.23]);

    gCols = uigridlayout(gMain, [1 3]); gCols.ColumnWidth = {'1x', '1.2x', '1x'}; gCols.BackgroundColor = [0.04 0.05 0.08];

    pTelem = uipanel(gCols, 'BackgroundColor', [0.07 0.09 0.14], 'Title', '1. TELEMETRY & PERIPHERALS', 'ForegroundColor', [0 0.95 1], 'FontWeight', 'bold');
    gt = uigridlayout(pTelem, [6 2]); gt.RowHeight = {56, 56, 36, 38, 38, '1x'}; gt.BackgroundColor = [0.07 0.09 0.14];
    kVel = makeCard(gt,1,1,'VELOCITY','0 mm/s'); kUs = makeCard(gt,1,2,'ULTRASONIC','-- mm');
    kPos = makeCard(gt,2,1,'POSITION (X,Y)','0, 0 mm'); kHdg = makeCard(gt,2,2,'HEADING / ENC','0 deg (0|0)');

    pDots = uigridlayout(gt, [1 5]); pDots.Layout.Row=3; pDots.Layout.Column=[1 2]; pDots.BackgroundColor=[0.07 0.09 0.14];
    dL  = makeDot(pDots, sprintf('L(%d)', board.pins.lineSensorLeft));
    dM  = makeDot(pDots, sprintf('M(%d)', board.pins.lineSensorMid));
    dR  = makeDot(pDots, sprintf('R(%d)', board.pins.lineSensorRight));
    dT1 = makeDot(pDots, sprintf('T1(%d)', board.pins.buttonT1));
    dT2 = makeDot(pDots, sprintf('T2(%d)', board.pins.buttonT2));

    btnFL = uibutton(gt,'Text','FRONT LED (1)','BackgroundColor',[0.15 0.20 0.30],'FontColor','w','ButtonPushedFcn',@(~,~) togLight(1));
    btnFL.Layout.Row=4; btnFL.Layout.Column=1;
    btnRL = uibutton(gt,'Text','REAR LED (2)','BackgroundColor',[0.15 0.20 0.30],'FontColor','w','ButtonPushedFcn',@(~,~) togLight(2));
    btnRL.Layout.Row=4; btnRL.Layout.Column=2;
    btnHn = uibutton(gt,'Text','HORN / BUZZER (B)','BackgroundColor',[0.70 0.45 0.10],'FontColor','w','FontWeight','bold','ButtonPushedFcn',@(~,~) trigHorn());
    btnHn.Layout.Row=5; btnHn.Layout.Column=[1 2];

    pRad = uipanel(gCols, 'BackgroundColor', [0.07 0.09 0.14], 'Title', '2. POSE & ULTRASONIC RADAR', 'ForegroundColor', [0 0.95 1], 'FontWeight', 'bold');
    gr = uigridlayout(pRad, [1 1]); gr.BackgroundColor = [0.07 0.09 0.14];
    axR = uiaxes(gr); set(axR, 'Color', [0.03 0.04 0.06], 'XColor', [0.6 0.7 0.8], 'YColor', [0.6 0.7 0.8]);
    hold(axR,'on'); grid(axR,'on'); axis(axR,'equal'); xlim(axR,[-1500 1500]); ylim(axR,[-1500 1500]);
    thC = linspace(0, 2*pi, 80);
    for rc = [500 1000 1500], plot(axR, rc*cos(thC), rc*sin(thC), ':', 'Color', [0.15 0.22 0.35]); end
    hTr = plot(axR, NaN, NaN, '-', 'Color', [0 0.7 1], 'LineWidth', 1.8);
    hHt = scatter(axR, NaN, NaN, 22, [1 0.15 0.25], 'filled');
    hBt = plot(axR, 0, 0, 'o', 'MarkerSize', 8, 'MarkerFaceColor', [0 0.9 0.45], 'MarkerEdgeColor', 'w');
    hHd = plot(axR, [0 0], [0 150], '-', 'Color', [0 0.95 1], 'LineWidth', 2.2);

    pDrv = uipanel(gCols, 'BackgroundColor', [0.07 0.09 0.14], 'Title', '3. DRIVE & OPERATING MODES', 'ForegroundColor', [0 0.95 1], 'FontWeight', 'bold');
    gd = uigridlayout(pDrv, [6 2]); gd.RowHeight = {38, 38, 36, 28, '1x', 72}; gd.BackgroundColor = [0.07 0.09 0.14];
    btnMan = uibutton(gd,'Text','MANUAL ARCADE','BackgroundColor',[0 0.5 0.8],'FontColor','w','FontWeight','bold','ButtonPushedFcn',@(~,~) setMode(1));
    btnMan.Layout.Row=1; btnMan.Layout.Column=1;
    btnPid = uibutton(gd,'Text','LINE FOLLOWER PID (L)','BackgroundColor',[0.15 0.20 0.30],'FontColor','w','ButtonPushedFcn',@(~,~) setMode(2));
    btnPid.Layout.Row=1; btnPid.Layout.Column=2;
    btnStp = uibutton(gd,'Text','EMERGENCY STOP (SPACE)','BackgroundColor',[0.75 0.10 0.15],'FontColor','w','FontWeight','bold','ButtonPushedFcn',@(~,~) setMode(0));
    btnStp.Layout.Row=2; btnStp.Layout.Column=[1 2];
    btnZro = uibutton(gd,'Text','ZERO ODOMETRY (R)','BackgroundColor',[0.2 0.25 0.35],'FontColor','w','ButtonPushedFcn',@(~,~) resetOdom());
    btnZro.Layout.Row=3; btnZro.Layout.Column=[1 2];
    lblSpd = uilabel(gd,'Text',sprintf('Max Speed: %d%%', st.MaxSpeed),'FontColor',[0.8 0.9 1]); lblSpd.Layout.Row=4; lblSpd.Layout.Column=1;
    sldSpd = uislider(gd,'Limits',[20 100],'Value',st.MaxSpeed,'ValueChangedFcn',@(s,~) updSpd(s)); sldSpd.Layout.Row=4; sldSpd.Layout.Column=2;
    axM = uiaxes(gd); axM.Layout.Row=5; axM.Layout.Column=[1 2]; set(axM,'Color',[0.03 0.04 0.06],'XColor','w','YColor','w');
    hBars = barh(axM, [0 0], 'FaceColor', [0 0.8 1]); xlim(axM,[-100 100]); yticks(axM,[1 2]); yticklabels(axM,{'Motor L','Motor R'}); grid(axM,'on');
    lblHint = uilabel(gd,'Text','Keys: W/S=Fwd/Rev | A/D=Turn | Space=E-STOP | L=Line PID | R=Zero','FontColor',[0.6 0.7 0.8],'FontSize',11);
    lblHint.Layout.Row=6; lblHint.Layout.Column=[1 2];

    usOff = board.kinematics.ultrasonicForwardOffsetMm;
    while st.Running && isvalid(fig)
        updDrive();
        uL = bitand(int32(st.CmdL), 255); uR = bitand(int32(st.CmdR), 255);
        cmdW = bitor(bitor(bitshift(uint32(st.Magic),28), bitshift(uint32(st.Mode),24)), ...
                     bitor(bitshift(uint32(bitand(st.AuxMask,255)),16), bitor(bitshift(uint32(uL),8), uint32(uR))));
        st.Magic = 1;
        try
            raw = esp32_io('cmd', sprintf('SYNC %08X', cmdW));
            hp = regexp(raw, '[0-9A-Fa-f]{8}', 'match');
            if numel(hp) >= 4
                w1=uint32(hex2dec(hp{1})); w2=uint32(hex2dec(hp{2})); w3=uint32(hex2dec(hp{3})); w4=uint32(hex2dec(hp{4}));
                eL=to_i16(bitshift(w1,-16)); eR=to_i16(bitand(w1,65535));
                usMm=double(bitshift(w2,-16)); msk=double(bitand(bitshift(w2,-8),255)); fst=bitand(w2,255);
                xMm=to_i16(bitshift(w3,-16)); yMm=to_i16(bitand(w3,65535));
                th=to_i16(bitshift(w4,-16))/1000.0; vMm=to_i16(bitand(w4,65535));

                kVel.Value.Text = sprintf('%.0f mm/s', vMm);
                kUs.Value.Text  = ternary(usMm<3000, sprintf('%d mm', usMm), 'CLEAR');
                kPos.Value.Text = sprintf('%.0f, %.0f mm', xMm, yMm);
                kHdg.Value.Text = sprintf('%.0f deg (%.0f|%.0f)', rad2deg(th), eL, eR);
                updDot(dL,  bitand(msk,4)~=0, [1 0.1 0.2]); updDot(dM, bitand(msk,2)~=0, [1 0.1 0.2]); updDot(dR, bitand(msk,1)~=0, [1 0.1 0.2]);
                updDot(dT1, bitand(msk,8)~=0, [0 0.9 0.4]); updDot(dT2, bitand(msk,16)~=0, [0 0.9 0.4]);
                stNames = {'E-STOP','MANUAL_ARCADE','LINE_PID','SLAM','OBSTACLE_HOLD'};
                lblFsm.Text = ['FSM: ' stNames{min(fst+1, numel(stNames))}];
                hBars.YData = [st.CmdL, st.CmdR];
                st.Trail(end+1,:) = [xMm, yMm]; if size(st.Trail,1)>250, st.Trail(1,:)=[]; end
                if usMm>20 && usMm<2100
                    st.Hits(end+1,:) = [xMm+(usMm+usOff)*cos(th), yMm+(usMm+usOff)*sin(th)];
                    if size(st.Hits,1)>350, st.Hits(1,:)=[]; end
                end
                set(hTr,'XData',st.Trail(:,1),'YData',st.Trail(:,2));
                set(hBt,'XData',xMm,'YData',yMm);
                set(hHd,'XData',[xMm xMm+160*cos(th)],'YData',[yMm yMm+160*sin(th)]);
                if ~isempty(st.Hits), set(hHt,'XData',st.Hits(:,1),'YData',st.Hits(:,2)); end
                drawnow limitrate;
            end
        catch
        end
        pause(0.05);
    end
    try esp32_cli('agv', 'stop'); catch, end

    function updSpd(s), st.MaxSpeed = round(s.Value); lblSpd.Text = sprintf('Max Speed: %d%%', st.MaxSpeed); end
    function updDrive()
        if st.Mode ~= 1, st.CmdL = 0; st.CmdR = 0; return; end
        vy = double(isActive('w')||isActive('uparrow')) - double(isActive('s')||isActive('downarrow'));
        vx = double(isActive('d')||isActive('rightarrow')) - double(isActive('a')||isActive('leftarrow'));
        st.CmdL = max(-100, min(100, round((vy + 0.75*vx)*st.MaxSpeed)));
        st.CmdR = max(-100, min(100, round((vy - 0.75*vx)*st.MaxSpeed)));
    end
    function ok = isActive(k), ok = isKey(st.Keys, k) && st.Keys(k); end
    function onKeyDown(~, e)
        k = lower(char(e.Key));
        if strcmp(k,'space'), setMode(0); return;
        elseif strcmp(k,'l'), setMode(ternary(st.Mode==2,1,2)); return;
        elseif strcmp(k,'1'), togLight(1); return;
        elseif strcmp(k,'2'), togLight(2); return;
        elseif strcmp(k,'b'), trigHorn(); return;
        elseif strcmp(k,'r'), resetOdom(); return; end
        st.Keys(k) = true;
    end
    function onKeyUp(~, e), st.Keys(lower(char(e.Key))) = false; end
    function setMode(m)
        st.Mode = m; st.CmdL = 0; st.CmdR = 0;
        btnMan.BackgroundColor = ternary(m==1,[0 0.5 0.8],[0.15 0.20 0.30]);
        btnPid.BackgroundColor = ternary(m==2,[0 0.5 0.8],[0.15 0.20 0.30]);
    end
    function togLight(b)
        st.AuxMask = bitxor(st.AuxMask, b);
        btnFL.BackgroundColor = ternary(bitand(st.AuxMask,1)~=0,[0 0.7 0.3],[0.15 0.20 0.30]);
        btnRL.BackgroundColor = ternary(bitand(st.AuxMask,2)~=0,[0.8 0.2 0.2],[0.15 0.20 0.30]);
    end
    function trigHorn()
        st.AuxMask = bitor(st.AuxMask, 4);
        start(timer('StartDelay',0.22,'TimerFcn',@(~,~) clearHorn(),'StopFcn',@(t,~) delete(t)));
    end
    function clearHorn(), st.AuxMask = bitand(st.AuxMask, 251); end
    function resetOdom(), st.Magic = 15; st.Trail = zeros(0,2); st.Hits = zeros(0,2); end
    function onClose(~,~), st.Running = false; delete(fig); end
end
function c = makeCard(p, r, col, t, v)
    pn = uipanel(p,'BackgroundColor',[0.05 0.07 0.11],'BorderColor',[0.15 0.20 0.28]); pn.Layout.Row=r; pn.Layout.Column=col;
    g = uigridlayout(pn,[2 1]); g.RowHeight={15,'1x'}; g.BackgroundColor=[0.05 0.07 0.11];
    uilabel(g,'Text',t,'FontColor',[0.55 0.65 0.75],'FontSize',10);
    val = uilabel(g,'Text',v,'FontColor',[0 0.95 0.55],'FontSize',14,'FontWeight','bold');
    c = struct('Value', val);
end
function d = makeDot(p, t), d = uilabel(p,'Text',t,'HorizontalAlignment','center','BackgroundColor',[0.12 0.15 0.22],'FontColor',[0.5 0.6 0.7],'FontWeight','bold','FontSize',10); end
function updDot(l, on, col), if on, l.BackgroundColor=col; l.FontColor=[1 1 1]; else, l.BackgroundColor=[0.12 0.15 0.22]; l.FontColor=[0.5 0.6 0.7]; end; end
function v = to_i16(u), v = double(int32(u)); if v>=32768, v=v-65536; end; end
function r = ternary(c, a, b), if c, r = a; else, r = b; end; end