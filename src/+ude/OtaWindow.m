classdef OtaWindow < handle
    % OtaWindow  Wireless "bootloader" console: shows the flash partition table (which OTA slot is running,
    %            which one will be overwritten), builds the sketch, streams the image over WiFi and walks
    %            through the six OTA steps so you can SEE what happens. All logic is in
    %            ude.FirmwareBuilder + ude.OtaUploader; this class only draws and wires.
    properties (SetAccess = private)
        Mcu
        Fig
        H struct = struct()
        LastPct double = -1
        Busy logical = false
        States = repmat({'pending'}, 1, 6)
    end

    methods
        function obj = OtaWindow(mcu)
            obj.Mcu = mcu;
            obj.build();
            obj.guard(@() obj.refreshInfo());
        end

        function tf = isOpen(obj)
            tf = ~isempty(obj.Fig) && isvalid(obj.Fig);
        end

        function close(obj)
            if obj.isOpen(), delete(obj.Fig); end
        end
    end

    methods (Access = private)
        function build(obj)
            T = ude.Theme;
            f = uifigure('Name', 'Wireless update (OTA bootloader)', 'Position', [180 110 1000 650], 'Color', T.Bg);
            g = uigridlayout(f, [6 1], 'BackgroundColor', T.Bg, 'Padding', [8 8 8 8], 'RowSpacing', 6);
            g.RowHeight = {26, 36, 170, 34, 26, '1x'};

            H.Info = uilabel(g, 'Text', '', 'FontName', T.Font, 'FontColor', T.Text);

            sg = uigridlayout(g, [1 6], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 4);
            names = {'1  Compile', '2  Connect :3334', '3  Stream .bin', '4  Verify MD5', '5  Switch boot slot', '6  Reboot + check'};
            H.Step = cell(1, 6);
            for k = 1:6
                H.Step{k} = uilabel(sg, 'Text', names{k}, 'HorizontalAlignment', 'center', 'FontName', T.Font, ...
                    'BackgroundColor', T.PanelHi, 'FontColor', T.Dim, 'FontWeight', 'bold');
            end

            H.Ax = uiaxes(g);
            H.Ax.Color = T.Bg;  H.Ax.XColor = 'none';  H.Ax.YColor = 'none';
            H.Ax.XLim = [0 100];  H.Ax.YLim = [0 2.4];
            disableDefaultInteractivity(H.Ax);
            H.Ax.Toolbar.Visible = 'off';

            cg = uigridlayout(g, [1 7], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            cg.ColumnWidth = {40, 120, 100, 90, 150, 210, '1x'};
            ude.Theme.label(cg, 'Host');
            H.Host = uieditfield(cg, 'text', 'Value', char(ude.Config.ApIp), 'FontName', T.Font);
            ude.Theme.label(cg, 'Boot blinks');
            H.Blinks = uieditfield(cg, 'numeric', 'Value', 5, 'Limits', [1 20], 'RoundFractionalValues', 'on', ...
                'Tooltip', 'Compiled into the new image. After the update the LED blinks this many times at boot.');
            H.RefreshBtn = ude.Theme.button(cg, 'Refresh device info');
            H.BuildBtn   = ude.Theme.button(cg, 'Build + upload over WiFi', 'BackgroundColor', [0.0 0.45 0.74]);
            H.FileBtn    = ude.Theme.button(cg, 'Upload an existing .bin...');

            pg = uigridlayout(g, [1 3], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 0);
            pg.ColumnWidth = {'1x', '99x', 140};
            H.BarFill = uilabel(pg, 'Text', '', 'BackgroundColor', T.Good);
            H.BarRest = uilabel(pg, 'Text', '', 'BackgroundColor', T.Panel);
            H.BarText = uilabel(pg, 'Text', '  idle', 'FontName', T.Font, 'FontColor', T.Dim);

            H.Log = uitextarea(g, 'Editable', 'off', 'FontName', T.Font, 'FontSize', 12, ...
                'BackgroundColor', T.Panel, 'FontColor', T.Text);

            H.RefreshBtn.ButtonPushedFcn = @(~, ~) obj.guard(@() obj.refreshInfo());
            H.BuildBtn.ButtonPushedFcn   = @(~, ~) obj.guard(@() obj.onBuildUpload());
            H.FileBtn.ButtonPushedFcn    = @(~, ~) obj.guard(@() obj.onPickFile());
            f.CloseRequestFcn = @(~, ~) obj.close();
            obj.Fig = f;
            obj.H = H;
            obj.log('Ready. Join the WiFi network "ESP32_UDE_BRIDGE" (password 12345678) before uploading: scripts\connect_wifi.ps1');
        end

        % ---------------------------------------------------------------- small helpers
        function guard(obj, fcn)
            try
                fcn();
            catch ME
                obj.log(['ERROR: ' ME.message]);
                obj.Busy = false;
            end
        end

        function log(obj, msg)
            if ~obj.isOpen(), return; end
            obj.H.Log.Value = [obj.H.Log.Value; {[datestr(now, 'HH:MM:SS') '  ' char(msg)]}];
            scroll(obj.H.Log, 'bottom');
            drawnow limitrate;
        end

        function resetSteps(obj)
            for k = 1:6, obj.setStep(k, 'pending'); end
            obj.setBar(0, 1);
        end

        function setStep(obj, k, state)
            T = ude.Theme;
            switch state
                case 'active',  bg = T.Accent;   fg = [1 1 1];
                case 'done',    bg = T.Good;     fg = [0 0 0];
                case 'fail',    bg = T.Bad;      fg = [1 1 1];
                otherwise,      bg = T.PanelHi;  fg = T.Dim;
            end
            obj.States{k} = state;
            obj.H.Step{k}.BackgroundColor = bg;
            obj.H.Step{k}.FontColor = fg;
            drawnow limitrate;
        end

        function setBar(obj, sent, total)
            pct = floor(100 * sent / max(total, 1));
            if pct == obj.LastPct, return; end
            obj.LastPct = pct;
            pg = obj.H.BarFill.Parent;
            pg.ColumnWidth = {sprintf('%gx', max(pct, 0.01)), sprintf('%gx', max(100 - pct, 0.01)), 140};
            if total > 1
                obj.H.BarText.Text = sprintf('  %d%%  %d / %d KB', pct, round(sent / 1024), round(total / 1024));
            else
                obj.H.BarText.Text = '  idle';
            end
            drawnow limitrate;
        end

        function onStage(obj, stage, state)
            switch char(stage)
                case 'connect', steps = 2;
                case 'stream',  steps = 3;
                case 'verify',  steps = [4 5];
            end
            for k = steps, obj.setStep(k, char(state)); end
        end

        % ---------------------------------------------------------------- partition picture
        function refreshInfo(obj)
            obj.Mcu.refreshInfo();
            obj.drawPartitions();
            i = obj.Mcu.Info;
            obj.H.Info.Text = sprintf('Running: %s   |   next OTA target: %s   |   firmware %s build %s   |   boot blinks %s   |   chip %s rev %s @ %s MHz', ...
                Esp32.field(i, 'RUN'), Esp32.field(i, 'NEXT'), Esp32.field(i, 'FW'), Esp32.field(i, 'BUILD'), ...
                Esp32.field(i, 'BLINKS'), Esp32.field(i, 'CHIP'), Esp32.field(i, 'REV'), Esp32.field(i, 'CPU'));
        end

        function drawPartitions(obj)
            T = ude.Theme;
            ax = obj.H.Ax;
            cla(ax);
            hold(ax, 'on');
            P = obj.Mcu.partitions();
            run = Esp32.field(obj.Mcu.Info, 'RUN');
            nxt = Esp32.field(obj.Mcu.Info, 'NEXT');
            w = sqrt(P.Size);
            w = 100 * w / sum(w);
            x = 0;
            for i = 1:height(P)
                lab = char(P.Label(i));
                if strcmp(lab, run),            col = T.Good;  role = 'RUNNING';
                elseif strcmp(lab, nxt),        col = T.Warn;  role = 'next OTA target';
                elseif P.Type(i) == 0,          col = [0.35 0.40 0.55];  role = 'app slot';
                elseif strcmp(lab, 'otadata'),  col = T.Accent;  role = 'boot selector';
                else,                           col = [0.32 0.34 0.38];  role = '';
                end
                rectangle(ax, 'Position', [x 0.55 w(i) 1.0], 'FaceColor', col, 'EdgeColor', T.Bg, 'LineWidth', 2);
                if w(i) > 9
                    text(ax, x + w(i) / 2, 1.05, {lab, OtaWindow.sizeText(P.Size(i))}, 'Color', 'k', 'FontName', T.Font, ...
                        'FontWeight', 'bold', 'HorizontalAlignment', 'center', 'Interpreter', 'none', 'FontSize', 11);
                else
                    text(ax, x + w(i) / 2, 1.05, [lab '  ' OtaWindow.sizeText(P.Size(i))], 'Color', 'k', 'Rotation', 90, ...
                        'FontName', T.Font, 'HorizontalAlignment', 'center', 'Interpreter', 'none', 'FontSize', 9);
                end
                text(ax, x + w(i) / 2, 1.85, sprintf('0x%X', P.Offset(i)), 'Color', T.Dim, 'FontName', T.Font, ...
                    'HorizontalAlignment', 'center', 'FontSize', 8, 'Interpreter', 'none');
                if ~isempty(role)
                    text(ax, x + w(i) / 2, 0.25, role, 'Color', col, 'FontName', T.Font, 'HorizontalAlignment', 'center', ...
                        'FontSize', 9, 'Interpreter', 'none');
                end
                x = x + w(i);
            end
            text(ax, 50, 2.25, 'Flash partition table (width ~ sqrt(size))', 'Color', T.Dim, 'FontName', T.Font, ...
                'HorizontalAlignment', 'center', 'FontSize', 10);
            hold(ax, 'off');
        end

        % ---------------------------------------------------------------- actions
        function onBuildUpload(obj)
            if obj.Busy, return; end
            obj.Busy = true;
            obj.resetSteps();
            obj.setStep(1, 'active');
            obj.log(sprintf('Compiling the sketch with BOOT_BLINKS=%d ...', obj.H.Blinks.Value));
            d = uiprogressdlg(obj.Fig, 'Title', 'Compiling', 'Indeterminate', 'on', ...
                'Message', 'arduino-cli compile (the first build takes about a minute) ...');
            try
                bin = ude.FirmwareBuilder.compile('BootBlinks', obj.H.Blinks.Value);
            catch ME
                close(d);
                obj.setStep(1, 'fail');
                obj.Busy = false;
                rethrow(ME);
            end
            close(d);
            obj.setStep(1, 'done');
            obj.upload(bin);
        end

        function onPickFile(obj)
            if obj.Busy, return; end
            [file, folder] = uigetfile({'*.bin', 'ESP32 app image (*.bin)'}, 'Pick the app image', ...
                fullfile(ude.Config.sketchDir(), 'build'));
            if isequal(file, 0), return; end
            obj.Busy = true;
            obj.resetSteps();
            obj.setStep(1, 'done');
            obj.upload(fullfile(folder, file));
        end

        function upload(obj, binPath)
            before = obj.Mcu.Info;
            up = ude.OtaUploader(obj.H.Host.Value);
            up.OnStage    = @(s, st) obj.onStage(s, st);
            up.OnProgress = @(a, b) obj.setBar(a, b);
            up.OnLog      = @(m) obj.log(m);
            try
                up.upload(binPath);
                obj.setStep(6, 'active');
                obj.log('Waiting for the new firmware to answer on the control port ...');
                info = up.waitForReboot(60);
                obj.setStep(6, 'done');
                obj.log(sprintf('Back online. Running %s (was %s); build %s (was %s); boot blinks %s.', ...
                    Esp32.field(info, 'RUN'), Esp32.field(before, 'RUN'), Esp32.field(info, 'BUILD'), ...
                    Esp32.field(before, 'BUILD'), Esp32.field(info, 'BLINKS')));
                try
                    obj.Mcu.refreshInfo();
                    obj.refreshInfo();
                catch
                    obj.log('(USB link needs a reconnect to refresh the picture: close and reopen this window.)');
                end
            catch ME
                for k = 1:6
                    if strcmp(obj.States{k}, 'active'), obj.setStep(k, 'fail'); end
                end
                obj.log(['ERROR: ' ME.message]);
            end
            obj.Busy = false;
        end
    end

    methods (Static, Access = private)
        function s = sizeText(n)
            if n >= 1024 * 1024, s = sprintf('%g MB', n / 1024 / 1024);
            elseif n >= 1024,    s = sprintf('%g KB', n / 1024);
            else,                s = sprintf('%d B', n);
            end
        end
    end
end
