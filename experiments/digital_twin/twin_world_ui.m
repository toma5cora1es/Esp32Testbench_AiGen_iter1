function twin_world_ui(dutPort, simPort)
%TWIN_WORLD_UI Closed-Loop Virtual Room & Hardware Digital Twin Mapper.
%   Controls Board A (COM8: green_agv_mainboard), feeds virtual room walls/benches/chairs
%   & oval tape track through Board B (COM7: green_agv_plant_sim) over real GPIO wires,
%   and updates a live 2D Occupancy Grid Map solely from Board A's hardware telemetry.
    if nargin < 1 || isempty(dutPort), dutPort = 'COM8'; end
    if nargin < 2 || isempty(simPort), simPort = 'COM7'; end

    prev = findall(0, 'Type', 'figure', 'Tag', 'TWIN_WORLD_UI');
    if ~isempty(prev), close(prev); drawnow; end

    esp32_cli('verbose', 'normal');
    esp32_cli('connect', dutPort);
    stStr = esp32_cli('status');
    if ~contains(stStr, 'BLD_GREENAGV', 'IgnoreCase', true)
        wb_log('warn', 'TWIN', 'WRONG_FW', sprintf('%s is running "%s", not green_agv_mainboard! Run: esp32_cli(''green_agv'',''flash'',''%s'',''standalone'')', dutPort, stStr, dutPort));
    end

    simSp = twin_cli('get_sim_handle', simPort);
    green_agv_cli('zero');
    pause(0.05);

    % --- VIRTUAL 4m x 4m LAB ROOM GEOMETRY (Walls, Benches, Chairs) ---
    % Each row: [x1, y1, x2, y2] in meters
    walls = [
        -1.95, -1.95,  1.95, -1.95;  % South wall
         1.95, -1.95,  1.95,  1.95;  % East wall
         1.95,  1.95, -1.95,  1.95;  % North wall
        -1.95,  1.95, -1.95, -1.95;  % West wall
         0.55,  0.65,  1.45,  0.65;  % Bench 1
         1.45,  0.65,  1.45,  1.25;
         1.45,  1.25,  0.55,  1.25;
         0.55,  1.25,  0.55,  0.65;
        -1.50, -1.35, -0.65, -1.35;  % Bench 2
        -0.65, -1.35, -0.65, -0.80;
        -0.65, -0.80, -1.50, -0.80;
        -1.50, -0.80, -1.50, -1.35;
         0.65, -1.15,  1.05, -1.15;  % Chair 1
         1.05, -1.15,  1.05, -0.75;
         1.05, -0.75,  0.65, -0.75;
         0.65, -0.75,  0.65, -1.15;
        -1.25,  0.70, -0.85,  0.70;  % Chair 2
        -0.85,  0.70, -0.85,  1.10;
        -0.85,  1.10, -1.25,  1.10;
        -1.25,  1.10, -1.25,  0.70
    ];

    % --- OCCUPANCY GRID (4m x 4m, 5cm resolution -> 80x80) ---
    resM = 0.05; halfM = 2.00; nCells = round((2 * halfM) / resM);
    logOdds = zeros(nCells, nCells);
    axCoords = linspace(-halfM, halfM, nCells);

    % --- STATE ---
    st = struct('Running',true,'Mode',1,'Aux',0,'Speed',65,'CmdL',0,'CmdR',0,'Magic',1, ...
                'PoseTrail',zeros(0,2),'Hits',zeros(0,2),'Keys',containers.Map('KeyType','char','ValueType','logical'));

    % --- BUILD NATIVE MATLAB WINDOW ---
    bg = [0.08 0.10 0.14]; pnl = [0.06 0.08 0.11];
    fig = figure('Name', sprintf('Green AGV Hardware Digital Twin World (%s <-> %s)', dutPort, simPort), ...
        'NumberTitle','off','MenuBar','none','ToolBar','none','Color',bg,'Position',[50 50 1320 740], ...
        'Tag','TWIN_WORLD_UI','WindowKeyPressFcn',@onKeyDown,'WindowKeyReleaseFcn',@onKeyUp,'CloseRequestFcn',@onClose);

    % Left Panel: Live Virtual Room + Occupancy Grid Map
    pMap = uipanel(fig,'Title','Live Occupancy Map (Built From Real Hardware US & Encoders) + Virtual Room Overlay', ...
        'Units','normalized','Position',[0.01 0.03 0.64 0.94],'BackgroundColor',pnl,'ForegroundColor',[0 0.95 1],'FontWeight','bold');
    ax = axes('Parent',pMap,'Units','normalized','Position',[0.08 0.09 0.88 0.86],'Color',[0.04 0.05 0.08],'XColor','w','YColor','w');
    hold(ax,'on'); axis(ax,'equal'); xlim(ax,[-halfM halfM]); ylim(ax,[-halfM halfM]); grid(ax,'on');
    xlabel(ax,'Room X (m) — [Controls: WASD/Arrows=Drive | L=Line PID | Space=E-STOP | R=Reset]','Color','w');
    ylabel(ax,'Room Y (m)','Color','w');

    hGrid = imagesc(ax, axCoords, axCoords, logodds_to_prob(logOdds));
    set(ax,'YDir','normal'); colormap(ax, flipud(gray(256))); caxis(ax,[0 1]);

    % Draw virtual oval floor track + virtual ground-truth walls (cyan dashed)
    thTrk = linspace(0, 2*pi, 120);
    plot(ax, 0.85*cos(thTrk), 0.45*sin(thTrk), ':', 'Color', [0.2 0.8 0.4], 'LineWidth', 1.4, 'DisplayName', 'Virtual Tape Track');
    for w = 1:size(walls,1)
        plot(ax, [walls(w,1) walls(w,3)], [walls(w,2) walls(w,4)], '--', 'Color', [0 0.85 1 0.55], 'LineWidth', 1.5, 'HandleVisibility', iif(w==1,'on','off'), 'DisplayName', 'Virtual Walls/Furniture');
    end
    hTrail = plot(ax, NaN, NaN, '-', 'Color', [0.1 0.65 1.0], 'LineWidth', 2.0, 'DisplayName', 'DUT Odometry Path');
    hHits  = scatter(ax, NaN, NaN, 26, [1 0.2 0.25], 'filled', 'DisplayName', 'HW Ultrasonic Hits');
    hRay   = plot(ax, NaN, NaN, '--', 'Color', [1 0.85 0.2], 'LineWidth', 1.6, 'DisplayName', 'HC-SR04 Ray');
    hBot   = plot(ax, 0, 0, 'o', 'MarkerSize', 9, 'MarkerFaceColor', [0 0.95 0.5], 'MarkerEdgeColor', 'w', 'DisplayName', 'AGV (DUT Pose)');
    hHead  = plot(ax, [0 0.15], [0 0], '-', 'Color', [0 1 0.5], 'LineWidth', 2.5, 'HandleVisibility', 'off');
    lg = legend(ax,'Location','northwest'); set(lg,'Color',[0.09 0.11 0.16],'TextColor','w');

    % Right Panel: Hardware Telemetry & Drive Controls
    pCtrl = uipanel(fig,'Title','Hardware Closed-Loop Cockpit (Board A <-> Board B)', ...
        'Units','normalized','Position',[0.66 0.03 0.33 0.94],'BackgroundColor',pnl,'ForegroundColor',[0 0.95 0.55],'FontWeight','bold');

    lblState  = mkTxt(pCtrl,[0.05 0.90 0.90 0.06],'FSM: MANUAL | Speed Limit: 65%',pnl,[0 0.95 1],'bold');
    lblPose   = mkTxt(pCtrl,[0.05 0.83 0.90 0.06],'DUT Pose: (0.00m, 0.00m, 0 deg) | Vel: 0 mm/s',pnl,[1 1 1],'bold');
    lblSensor = mkTxt(pCtrl,[0.05 0.76 0.90 0.06],'DUT US: -- mm | Line: 000 | Enc: 0/0',pnl,[0.5 0.95 0.6],'normal');
    lblSim    = mkTxt(pCtrl,[0.05 0.69 0.90 0.06],'SIM Cap: L=0% (0Hz) R=0% (0Hz) | Trig=0',pnl,[0.85 0.7 1],'normal');
    lblVirt   = mkTxt(pCtrl,[0.05 0.62 0.90 0.06],'World Raycast -> SIM: Dist=-- mm | Track=000',pnl,[1 0.85 0.3],'normal');

    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.05 0.51 0.28 0.08],'String','Front LED','Callback',@(~,~) togAux(1));
    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.36 0.51 0.28 0.08],'String','FWD (W)','BackgroundColor',[0.16 0.55 0.35],'ForegroundColor','w','FontWeight','bold','Callback',@(~,~) btnDrv(1,1));
    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.67 0.51 0.28 0.08],'String','Rear LED','Callback',@(~,~) togAux(2));

    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.05 0.41 0.28 0.08],'String','LEFT (A)','BackgroundColor',[0.2 0.4 0.75],'ForegroundColor','w','FontWeight','bold','Callback',@(~,~) btnDrv(-1,1));
    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.36 0.41 0.28 0.08],'String','IDLE (0%)','BackgroundColor',[0.3 0.3 0.35],'ForegroundColor','w','Callback',@(~,~) btnDrv(0,0));
    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.67 0.41 0.28 0.08],'String','RIGHT (D)','BackgroundColor',[0.2 0.4 0.75],'ForegroundColor','w','FontWeight','bold','Callback',@(~,~) btnDrv(1,-1));

    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.36 0.31 0.28 0.08],'String','REV (S)','BackgroundColor',[0.6 0.3 0.2],'ForegroundColor','w','FontWeight','bold','Callback',@(~,~) btnDrv(-1,-1));

    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.05 0.20 0.43 0.08],'String','LINE PID (L)','BackgroundColor',[0.18 0.45 0.65],'ForegroundColor','w','FontWeight','bold','Callback',@(~,~) setMode(iif(st.Mode==2,1,2)));
    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.52 0.20 0.43 0.08],'String','RESET WORLD (R)','BackgroundColor',[0.25 0.30 0.38],'ForegroundColor','w','Callback',@(~,~) resetWorld());
    uicontrol(pCtrl,'Style','pushbutton','Units','normalized','Position',[0.05 0.09 0.90 0.09],'String','EMERGENCY STOP (SPACE)','BackgroundColor',[0.80 0.12 0.16],'ForegroundColor','w','FontWeight','bold','Callback',@(~,~) setMode(0));

    chkTrack = uicontrol(pCtrl,'Style','checkbox','Units','normalized','Position',[0.05 0.02 0.90 0.05], ...
        'String','Simulate Oval Floor Line Track into D34/D32/D35','Value',1,'BackgroundColor',pnl,'ForegroundColor',[0.8 0.95 1]);

    tmr = timer('ExecutionMode','fixedSpacing','Period',0.08,'BusyMode','drop','TimerFcn',@(~,~) onTick());
    start(tmr);

    function onTick()
        persistent busyTick
        if isempty(busyTick), busyTick = false; end
        if busyTick || ~st.Running || ~ishandle(fig), return; end
        busyTick = true;
        try
            updKeys();
            % 1. Send Drive Command to Board A (DUT) & read Real Hardware Pose + US + Line
            w0 = pack_agv(st.Magic, st.Mode, st.Aux, st.CmdL, st.CmdR);
            st.Magic = 1;
            rawDut = esp32_io('cmd', sprintf('SYNC %08X', w0));
            d = parse_dut(rawDut);

            xM = d.x_mm / 1000.0; yM = d.y_mm / 1000.0; th = d.theta_rad;
            sensX = xM + 0.095 * cos(th); sensY = yM + 0.095 * sin(th);

            % 2. Raycast against Virtual Room Walls -> Compute True Distance & Virtual Floor Line
            virtDistMm = raycast_room_mm(sensX, sensY, th, walls);
            virtLineMask = 0;
            if get(chkTrack, 'Value') == 1
                virtLineMask = sample_oval_track(xM, yM, th);
            end

            % 3. Inject Virtual World Distance & Line Mask into Board B (Plant Sim) over USB
            simT = twin_cli('sync_raw', simSp, 0, 0, virtLineMask, virtDistMm);

            % 4. Update Occupancy Grid SOLELY from Board A's real physical US & Pose!
            usM = min(d.us_mm / 1000.0, 2.20);
            isHit = (d.us_mm > 25 && d.us_mm < 2150);
            endX = sensX + usM * cos(th); endY = sensY + usM * sin(th);

            [r0,c0] = w2g(sensX, sensY, halfM, resM, nCells);
            [r1,c1] = w2g(endX,  endY,  halfM, resM, nCells);
            nPts = max(abs(r1-r0), abs(c1-c0)) + 1;
            rr = round(linspace(r0,r1,nPts)); cc = round(linspace(c0,c1,nPts));
            for k = 1:(numel(rr)-1)
                if rr(k)>=1 && rr(k)<=nCells && cc(k)>=1 && cc(k)<=nCells
                    logOdds(rr(k),cc(k)) = max(-4.0, logOdds(rr(k),cc(k)) - 0.35);
                end
            end
            if isHit && r1>=1 && r1<=nCells && c1>=1 && c1<=nCells
                logOdds(r1,c1) = min(4.0, logOdds(r1,c1) + 0.85);
                st.Hits(end+1,:) = [endX, endY];
                if size(st.Hits,1) > 400, st.Hits(1,:) = []; end
            end

            st.PoseTrail(end+1,:) = [xM, yM];
            if size(st.PoseTrail,1) > 400, st.PoseTrail(1,:) = []; end

            % 5. Refresh Plots & Telemetry Labels
            set(hGrid,  'CData', logodds_to_prob(logOdds));
            set(hTrail, 'XData', st.PoseTrail(:,1), 'YData', st.PoseTrail(:,2));
            set(hBot,   'XData', xM, 'YData', yM);
            set(hHead,  'XData', [xM, xM+0.18*cos(th)], 'YData', [yM, yM+0.18*sin(th)]);
            set(hRay,   'XData', [sensX, endX], 'YData', [sensY, endY]);
            if ~isempty(st.Hits), set(hHits, 'XData', st.Hits(:,1), 'YData', st.Hits(:,2)); end

            fsmNames = {'E-STOP','MANUAL','LINE_PID','SLAM','OBST_HOLD'};
            set(lblState,  'String', sprintf('FSM: %s | Cmd=(%d%%, %d%%)', fsmNames{min(d.fsm+1,5)}, st.CmdL, st.CmdR));
            set(lblPose,   'String', sprintf('DUT Pose: (%.2fm, %.2fm, %.0f deg) | Vel: %d mm/s', xM, yM, rad2deg(th), d.vel_mms));
            set(lblSensor, 'String', sprintf('DUT US: %d mm | Line: %s | Enc: %d/%d', d.us_mm, dec2bin(d.lineMask,3), d.encL, d.encR));
            set(lblSim,    'String', sprintf('SIM Cap: L=%d%%(%dHz) R=%d%%(%dHz) | Trig=%d', simT.pwmL, simT.freqL, simT.pwmR, simT.freqR, simT.trigCount));
            set(lblVirt,   'String', sprintf('Virtual Ray -> SIM: %d mm | Track=%s', virtDistMm, dec2bin(virtLineMask,3)));
            drawnow limitrate;
        catch ME
            wb_log('warn','TWIN','TICK_ERR',ME.message);
        end
        busyTick = false;
    end

    function onKeyDown(~, e)
        k = lower(char(e.Key));
        if strcmp(k,'space'), setMode(0); return;
        elseif strcmp(k,'l'), setMode(iif(st.Mode==2,1,2)); return;
        elseif strcmp(k,'r'), resetWorld(); return; end
        st.Keys(k) = true;
    end
    function onKeyUp(~, e), st.Keys(lower(char(e.Key))) = false; end
    function updKeys()
        if st.Mode ~= 1, return; end
        vy = double(keyOn('w')||keyOn('uparrow')) - double(keyOn('s')||keyOn('downarrow'));
        vx = double(keyOn('d')||keyOn('rightarrow')) - double(keyOn('a')||keyOn('leftarrow'));
        if vy ~= 0 || vx ~= 0
            st.CmdL = max(-100, min(100, round((vy + 0.75*vx)*st.Speed)));
            st.CmdR = max(-100, min(100, round((vy - 0.75*vx)*st.Speed)));
        elseif isempty(st.Keys.keys) || ~any(cell2mat(values(st.Keys)))
            % Keep button drive if setDrv wasn't cleared, else zero on key release
        end
    end
    function ok = keyOn(k), ok = isKey(st.Keys, k) && st.Keys(k); end
    function btnDrv(l, r), st.Mode = 1; st.CmdL = round(l*st.Speed); st.CmdR = round(r*st.Speed); end
    function setMode(m), st.Mode = m; if m~=1, st.CmdL = 0; st.CmdR = 0; end; end
    function togAux(b), st.Aux = bitxor(st.Aux, b); end
    function resetWorld()
        st.Magic = 15; logOdds(:) = 0; st.PoseTrail = zeros(0,2); st.Hits = zeros(0,2);
        set(hHits,'XData',NaN,'YData',NaN);
    end
    function onClose(~, ~)
        st.Running = false;
        try stop(tmr); delete(tmr); catch, end
        try green_agv_cli('stop'); catch, end
        try twin_cli('disconnect'); catch, end
        delete(fig);
    end
end

function distMm = raycast_room_mm(ox, oy, th, segs)
    dx = cos(th); dy = sin(th); bestT = 2.50;
    for k = 1:size(segs, 1)
        x1 = segs(k,1); y1 = segs(k,2); sx = segs(k,3) - x1; sy = segs(k,4) - y1;
        den = dx * sy - dy * sx;
        if abs(den) < 1e-6, continue; end
        t = ((x1 - ox) * sy - (y1 - oy) * sx) / den;
        u = ((x1 - ox) * dy - (y1 - oy) * dx) / den;
        if t > 0.02 && t < bestT && u >= 0.0 && u <= 1.0, bestT = t; end
    end
    distMm = round(bestT * 1000.0);
end

function msk = sample_oval_track(x, y, th)
    % Oval track: (x/0.85)^2 + (y/0.45)^2 = 1; 3 sensors 22mm apart at +70mm ahead
    offsets = [0.022, 0.0, -0.022]; bits = [4, 2, 1]; msk = 0;
    for k = 1:3
        px = x + 0.070*cos(th) - offsets(k)*sin(th);
        py = y + 0.070*sin(th) + offsets(k)*cos(th);
        rVal = sqrt((px / 0.85)^2 + (py / 0.45)^2);
        if abs(rVal - 1.0) < 0.06, msk = bitor(msk, bits(k)); end
    end
end

function w = pack_agv(m, md, aux, l, r)
    w = bitor(bitor(bitshift(uint32(m),28), bitshift(uint32(md),24)), ...
              bitor(bitshift(bitand(uint32(aux),255),16), bitor(bitshift(uint32(bitand(int32(l),255)),8), uint32(bitand(int32(r),255)))));
end
function t = parse_dut(raw)
    hp = regexp(raw,'[0-9A-Fa-f]{8}','match'); if numel(hp)==5, hp=hp(2:5); end
    t = struct('encL',0,'encR',0,'us_mm',3000,'lineMask',0,'fsm',0,'x_mm',0,'y_mm',0,'theta_rad',0,'vel_mms',0);
    if numel(hp)<4, return; end
    w1=uint32(hex2dec(hp{1})); w2=uint32(hex2dec(hp{2})); w3=uint32(hex2dec(hp{3})); w4=uint32(hex2dec(hp{4}));
    t.encL=i16(bitshift(w1,-16)); t.encR=i16(bitand(w1,65535)); t.us_mm=double(bitshift(w2,-16));
    t.lineMask=bitand(double(bitand(bitshift(w2,-8),255)),7); t.fsm=double(bitand(w2,255));
    t.x_mm=i16(bitshift(w3,-16)); t.y_mm=i16(bitand(w3,65535));
    t.theta_rad=i16(bitshift(w4,-16))/1000.0; t.vel_mms=i16(bitand(w4,65535));
end
function [r,c] = w2g(x,y,hM,res,n), c=min(max(round((x+hM)/res)+1,1),n); r=min(max(round((y+hM)/res)+1,1),n); end
function p = logodds_to_prob(lo), p = 1.0 - (1.0 ./ (1.0 + exp(lo))); end
function h = mkTxt(p,pos,str,bg,fg,fw)
    h = uicontrol(p,'Style','text','Units','normalized','Position',pos,'String',str,'BackgroundColor',bg,'ForegroundColor',fg,'FontWeight',fw,'HorizontalAlignment','left','FontSize',10);
end
function v = i16(u), v=double(int32(u)); if v>=32768, v=v-65536; end; end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end