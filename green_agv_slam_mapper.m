function mapReport = green_agv_slam_mapper(targetEndpoint)
%GREEN_AGV_SLAM_MAPPER Interactive 2D Room & Obstacle Occupancy Grid Mapper for Green AGV.
%   Fuses on-chip wheel encoder dead-reckoning (D18/D19) + HC-SR04 ultrasonic rangefinder (D27/D26)
%   over Wi-Fi ('192.168.4.1') or Bluetooth ('ESP32_BT_BRIDGE') using burst register reads.
%
%   CONTROLS IN FIGURE WINDOW:
%     [W / S] : Drive Forward / Reverse
%     [A / D] : Turn Left / Right
%     [L]     : Toggle Autonomous Line-Follower Mode (follows floor tape while mapping room!)
%     [SPACE] : Emergency Stop (Brake)
%     [R]     : Reset Odometry & Clear Map
%     [Q]     : Stop & Save Map Report

    if nargin < 1 || isempty(targetEndpoint)
        targetEndpoint = '192.168.4.1';
    end

    esp32_cli('verbose', 'off');
    esp32_cli('connect', targetEndpoint);

    % --- OCCUPANCY GRID PARAMETERS (4.0m x 4.0m Room, 5cm Cell Resolution) ---
    gridRes_m  = 0.05;                   % 50 mm per grid cell
    mapHalf_m  = 2.00;                   % -2.0m .. +2.0m
    nCells     = round((2 * mapHalf_m) / gridRes_m); % 80 x 80 cells
    logOddsMap = zeros(nCells, nCells);  % 0 = Unknown, >0 = Occupied (Chair/Bench), <0 = Free
    L_FREE     = -0.35;
    L_OCC      = +0.85;
    L_MIN      = -4.0;
    L_MAX      = +4.0;

    % --- TELEOP & STATE CONTEXT ---
    st = struct('Running', true, 'Mode', 1, 'CmdL', 0, 'CmdR', 0, ...
                'ResetReq', true, 'SpeedPct', 65, ...
                'PoseHistory', zeros(0, 3), 'HitPoints', zeros(0, 2));

    % --- BUILD DUAL-VIEWPORT MATLAB SLAM DASHBOARD ---
    fig = figure('Name', 'Green AGV — Real-Time 2D Ultrasonic SLAM & Room Mapper', ...
        'Position', [80 80 1240 620], 'Color', [0.08 0.10 0.14], ...
        'KeyPressFcn', @onKeyDown, 'KeyReleaseFcn', @onKeyUp, ...
        'CloseRequestFcn', @onClose);

    tlo = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');

    % Left Plot: Robot Trajectory, Ultrasonic Acoustic Cone & Detected Obstacles
    axWorld = nexttile(tlo, 1);
    hold(axWorld, 'on'); grid(axWorld, 'on'); axis(axWorld, 'equal');
    set(axWorld, 'Color', [0.05 0.07 0.10], 'XColor', 'w', 'YColor', 'w', 'GridColor', [0.2 0.3 0.4]);
    xlim(axWorld, [-mapHalf_m, mapHalf_m]); ylim(axWorld, [-mapHalf_m, mapHalf_m]);
    xlabel(axWorld, 'Room X (m)', 'Color', 'w'); ylabel(axWorld, 'Room Y (m)', 'Color', 'w');
    title(axWorld, 'Live AGV Odometry Trajectory & Ultrasonic Raycasting', 'Color', [0 0.95 1]);

    hTrail = plot(axWorld, NaN, NaN, '-', 'Color', [0.1 0.6 1.0], 'LineWidth', 2.0, 'DisplayName', 'AGV Path');
    hHits  = scatter(axWorld, NaN, NaN, 28, [1 0.15 0.3], 'filled', 'DisplayName', 'Benches / Chairs (Hits)');
    hRay   = plot(axWorld, NaN, NaN, '--', 'Color', [0 1 0.5], 'LineWidth', 1.5, 'DisplayName', 'HC-SR04 Ray');
    hBot   = plot(axWorld, 0, 0, 'o', 'MarkerSize', 10, 'MarkerFaceColor', [0 0.9 0.4], 'MarkerEdgeColor', 'w', 'DisplayName', 'Green AGV');
    legend(axWorld, 'TextColor', 'w', 'Color', [0.1 0.12 0.18], 'Location', 'northwest');

    % Right Plot: Bayesian Log-Odds Occupancy Grid Map
    axGrid = nexttile(tlo, 2);
    axisCoords = linspace(-mapHalf_m, mapHalf_m, nCells);
    hImg = imagesc(axGrid, axisCoords, axisCoords, repeat_prob(logOddsMap));
    set(axGrid, 'YDir', 'normal', 'XColor', 'w', 'YColor', 'w');
    axis(axGrid, 'equal'); xlim(axGrid, [-mapHalf_m, mapHalf_m]); ylim(axGrid, [-mapHalf_m, mapHalf_m]);
    colormap(axGrid, flipud(gray(256))); caxis(axGrid, [0 1]);
    xlabel(axGrid, 'Room X (m) [Controls: WASD=Drive | L=LineFollow | Space=Stop | Q=Quit]', 'Color', 'w');
    ylabel(axGrid, 'Room Y (m)', 'Color', 'w');
    title(axGrid, '2D Room Occupancy Grid (Black = Benches/Chairs, White = Free)', 'Color', [0.3 1 0.5]);

    % --- MAIN REAL-TIME SLAM ACQUISITION & MAPPING LOOP ---
    while st.Running && ishandle(fig)
        % 1. Pack and Write Command Word to RTC_CNTL_STORE0_REG (0x3FF4804C)
        magic = 1;
        if st.ResetReq
            magic = 15; % 0xF resets on-chip odometry
            st.ResetReq = false;
        end
        uL = bitand(int32(st.CmdL), 255);
        uR = bitand(int32(st.CmdR), 255);
        cmdWord = bitor(bitor(bitshift(uint32(magic), 28), bitshift(uint32(st.Mode), 24)), ...
                        bitor(bitshift(uint32(3), 16), bitor(bitshift(uint32(uL), 8), uint32(uR))));
        esp32_io('cmd', sprintf('W 3FF4804C %08X', cmdWord));

        % 2. Single-Transaction Burst Read of RTC_CNTL_STORE1..4_REG (0x3FF48050..0x3FF4805C)
        rawDump = esp32_io('cmd', 'D 3FF48050 4');
        hexWords = strsplit(strtrim(rawDump));
        if numel(hexWords) >= 4
            w1 = uint32(hex2dec(regexprep(hexWords{1}, '^0x', '')));
            w2 = uint32(hex2dec(regexprep(hexWords{2}, '^0x', '')));
            w3 = uint32(hex2dec(regexprep(hexWords{3}, '^0x', '')));
            w4 = uint32(hex2dec(regexprep(hexWords{4}, '^0x', '')));

            encL    = to_int16(bitshift(w1, -16));
            encR    = to_int16(bitand(w1, 65535));
            us_mm   = double(bitshift(w2, -16));
            lineMsk = bitand(bitshift(w2, -8), 255);
            fsmSt   = bitand(w2, 255);

            x_m     = double(to_int16(bitshift(w3, -16))) / 1000.0;
            y_m     = double(to_int16(bitand(w3, 65535))) / 1000.0;
            th_rad  = double(to_int16(bitshift(w4, -16))) / 1000.0;
            v_mms   = double(to_int16(bitand(w4, 65535)));

            st.PoseHistory(end+1, :) = [x_m, y_m, th_rad]; %#ok<AGROW>

            % 3. Sensor Transformation (HC-SR04 mounted 95 mm ahead of axle)
            sensX = x_m + 0.095 * cos(th_rad);
            sensY = y_m + 0.095 * sin(th_rad);
            maxRay_m = min(us_mm / 1000.0, 2.20);
            isHit    = (us_mm > 25 && us_mm < 2100);

            endX = sensX + maxRay_m * cos(th_rad);
            endY = sensY + maxRay_m * sin(th_rad);

            % 4. Bresenham Raycasting Update on Log-Odds Occupancy Grid
            [r0, c0] = world_to_grid(sensX, sensY, mapHalf_m, gridRes_m, nCells);
            [r1, c1] = world_to_grid(endX,  endY,  mapHalf_m, gridRes_m, nCells);
            [rayR, rayC] = bresenham_line(r0, c0, r1, c1);

            if numel(rayR) > 1
                for idx = 1:(numel(rayR) - 1)
                    rr = rayR(idx); cc = rayC(idx);
                    if rr >= 1 && rr <= nCells && cc >= 1 && cc <= nCells
                        logOddsMap(rr, cc) = max(L_MIN, logOddsMap(rr, cc) + L_FREE);
                    end
                end
            end
            if isHit && r1 >= 1 && r1 <= nCells && c1 >= 1 && c1 <= nCells
                logOddsMap(r1, c1) = min(L_MAX, logOddsMap(r1, c1) + L_OCC);
                st.HitPoints(end+1, :) = [endX, endY]; %#ok<AGROW>
            end

            % 5. Update Visual Artifacts
            set(hTrail, 'XData', st.PoseHistory(:, 1), 'YData', st.PoseHistory(:, 2));
            set(hBot,   'XData', x_m, 'YData', y_m);
            set(hRay,   'XData', [sensX, endX], 'YData', [sensY, endY]);
            if ~isempty(st.HitPoints)
                set(hHits, 'XData', st.HitPoints(:, 1), 'YData', st.HitPoints(:, 2));
            end
            set(hImg, 'CData', repeat_prob(logOddsMap));
            title(axWorld, sprintf('Pose: (%.2fm, %.2fm, %.0f°) | Vel: %.0f mm/s | US: %.0f mm | Line: %s | Enc: %d/%d', ...
                x_m, y_m, rad2deg(th_rad), v_mms, us_mm, dec2bin(lineMsk, 3), encL, encR), 'Color', [0 0.95 1]);
            drawnow limitrate;
        end
        pause(0.05);
    end

    % Stop motors on exit
    esp32_io('cmd', 'W 3FF4804C 10000000');
    mapReport = struct('OccupancyProb', repeat_prob(logOddsMap), ...
                       'Trajectory', st.PoseHistory, 'Hits', st.HitPoints);

    %% --- NESTED KEYBOARD & COORDINATE HELPERS ---
    function onKeyDown(~, evt)
        switch lower(evt.Key)
            case {'w', 'uparrow'},    st.Mode = 1; st.CmdL =  st.SpeedPct; st.CmdR =  st.SpeedPct;
            case {'s', 'downarrow'},  st.Mode = 1; st.CmdL = -st.SpeedPct; st.CmdR = -st.SpeedPct;
            case {'a', 'leftarrow'},  st.Mode = 1; st.CmdL = -st.SpeedPct; st.CmdR =  st.SpeedPct;
            case {'d', 'rightarrow'}, st.Mode = 1; st.CmdL =  st.SpeedPct; st.CmdR = -st.SpeedPct;
            case 'l',                 st.Mode = ternary(st.Mode == 2, 0, 2); st.CmdL = 0; st.CmdR = 0;
            case 'space',             st.Mode = 0; st.CmdL = 0; st.CmdR = 0;
            case 'r',                 st.ResetReq = true; logOddsMap(:) = 0; st.PoseHistory = zeros(0,3); st.HitPoints = zeros(0,2);
            case 'q',                 st.Running = false;
        end
    end

    function onKeyUp(~, evt)
        if ismember(lower(evt.Key), {'w','s','a','d','uparrow','downarrow','leftarrow','rightarrow'})
            st.CmdL = 0; st.CmdR = 0;
        end
    end

    function onClose(~, ~)
        st.Running = false;
        delete(fig);
    end
end

function val = to_int16(u16)
    val = int32(u16);
    if val >= 32768, val = val - 65536; end
end

function p = repeat_prob(logOdds)
    p = 1.0 - (1.0 ./ (1.0 + exp(logOdds)));
end

function [r, c] = world_to_grid(x, y, halfM, resM, n)
    c = round((x + halfM) / resM) + 1;
    r = round((y + halfM) / resM) + 1;
    c = min(max(c, 1), n);
    r = min(max(r, 1), n);
end

function [rr, cc] = bresenham_line(r0, c0, r1, c1)
    nPts = max(abs(r1 - r0), abs(c1 - c0)) + 1;
    rr = round(linspace(r0, r1, nPts));
    cc = round(linspace(c0, c1, nPts));
end

function out = ternary(c, a, b)
    if c, out = a; else, out = b; end
end