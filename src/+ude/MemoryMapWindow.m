classdef MemoryMapWindow < handle
    % MemoryMapWindow  The ESP32 address map as a picture. The rows come from the firmware's own guard
    %                  table (command MAP), so the picture shows what the chip will really let you touch.
    %                  Click a block to open it in the Memory window.
    properties (SetAccess = private)
        Mcu
        Fig
        Ax
        Info
        Map table
        Rects = {}
    end
    properties
        OnJump = @(addr) []
    end

    methods
        function obj = MemoryMapWindow(mcu)
            obj.Mcu = mcu;
            obj.Map = mcu.memoryMap();
            obj.build();
        end

        function tf = isOpen(obj)
            tf = ~isempty(obj.Fig) && isvalid(obj.Fig);
        end

        function close(obj)
            if obj.isOpen(), delete(obj.Fig); end
        end

        function highlight(obj, addr)
            if ~obj.isOpen(), return; end
            T = ude.Theme;
            best = 0;  bestSize = inf;
            for i = 1:height(obj.Map)                 % smallest block containing addr wins (EXEC_BUF inside IRAM)
                if addr >= obj.Map.Lo(i) && addr < obj.Map.Hi(i) && (obj.Map.Hi(i) - obj.Map.Lo(i)) < bestSize
                    best = i;  bestSize = obj.Map.Hi(i) - obj.Map.Lo(i);
                end
            end
            for i = 1:numel(obj.Rects)
                if i == best
                    obj.Rects{i}.EdgeColor = T.Warn;  obj.Rects{i}.LineWidth = 3;
                else
                    obj.Rects{i}.EdgeColor = [0.2 0.2 0.25];  obj.Rects{i}.LineWidth = 1;
                end
            end
            if best > 0
                obj.Info.Text = sprintf('Memory window is at 0x%08X  ->  %s  +0x%X', addr, obj.Map.Name(best), addr - obj.Map.Lo(best));
            else
                obj.Info.Text = sprintf('Memory window is at 0x%08X  ->  NOT MAPPED (the bridge refuses to read it)', addr);
            end
        end
    end

    methods (Access = private)
        function build(obj)
            T = ude.Theme;
            f = uifigure('Name', 'ESP32 memory map', 'Position', [200 120 880 560], 'Color', T.Bg);
            g = uigridlayout(f, [3 1], 'BackgroundColor', T.Bg, 'Padding', [8 8 8 8], 'RowSpacing', 4);
            g.RowHeight = {26, '1x', 24};
            ude.Theme.label(g, 'Blocks the bridge may access (not to scale; block width ~ log size). Click a block to open it.', ...
                'FontName', T.Font);
            ax = uiaxes(g);
            ax.Layout.Row = 2;
            ax.Color = T.Bg;  ax.XColor = 'none';  ax.YColor = 'none';
            ax.XLim = [0 100];  ax.YLim = [0 height(obj.Map)];  ax.YDir = 'reverse';
            disableDefaultInteractivity(ax);
            ax.Toolbar.Visible = 'off';
            hold(ax, 'on');
            sz = obj.Map.Hi - obj.Map.Lo;
            lo = log2(min(sz));  hi = log2(max(sz));
            obj.Rects = cell(1, height(obj.Map));
            for i = 1:height(obj.Map)
                w = 40 + 58 * (log2(sz(i)) - lo) / max(hi - lo, 1e-9);
                r = rectangle(ax, 'Position', [0 i - 1 + 0.08 w 0.84], 'FaceColor', MemoryMapWindow.colorFor(obj.Map.Name(i)), ...
                    'EdgeColor', [0.2 0.2 0.25], 'LineWidth', 1, 'Curvature', 0.08);
                a0 = obj.Map.Lo(i);
                r.ButtonDownFcn = @(~, ~) obj.OnJump(a0);
                rw = 'read-only';
                if obj.Map.Writable(i), rw = 'read/write'; end
                text(ax, 1, i - 0.5, sprintf('%-11s 0x%08X - 0x%08X   %s   %s', obj.Map.Name(i), obj.Map.Lo(i), ...
                    obj.Map.Hi(i) - 1, MemoryMapWindow.sizeText(sz(i)), rw), 'Color', 'w', 'FontName', T.Font, ...
                    'FontSize', 11, 'VerticalAlignment', 'middle', 'Interpreter', 'none', 'HitTest', 'off');
                obj.Rects{i} = r;
            end
            hold(ax, 'off');
            obj.Info = uilabel(g, 'Text', '', 'FontName', T.Font, 'FontColor', T.Warn);
            obj.Info.Layout.Row = 3;
            f.CloseRequestFcn = @(~, ~) obj.close();
            obj.Fig = f;
            obj.Ax = ax;
        end
    end

    methods (Static, Access = private)
        function c = colorFor(name)
            name = char(name);
            if strncmp(name, 'RTC', 3),                 c = [0.55 0.35 0.80];
            elseif strncmp(name, 'ROM', 3),             c = [0.42 0.45 0.52];
            elseif any(strcmp(name, {'PERIPH', 'DPORT'})), c = [0.85 0.50 0.18];
            elseif strcmp(name, 'DRAM'),                c = [0.22 0.60 0.38];
            elseif strcmp(name, 'EXEC_BUF'),            c = [0.85 0.28 0.42];
            else,                                       c = [0.22 0.46 0.85];
            end
        end
        function s = sizeText(n)
            if n >= 1024 * 1024, s = sprintf('%g MB', n / 1024 / 1024);
            elseif n >= 1024,    s = sprintf('%g KB', n / 1024);
            else,                s = sprintf('%d B', n);
            end
        end
    end
end
