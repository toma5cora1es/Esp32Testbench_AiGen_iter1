classdef MemoryView < handle
    % MemoryView  Widgets only. Builds the UDE-style memory window and knows how to DRAW data it is
    %             handed. It never talks to the chip and holds no callbacks: MemoryWindow wires those.
    properties (SetAccess = private)
        Fig
        H struct = struct()
    end

    methods
        function obj = MemoryView(titleText)
            obj.build(titleText);
        end

        function build(obj, titleText)
            T = ude.Theme;
            f = uifigure('Name', titleText, 'Position', [90 70 1080 690], 'Color', T.Bg);
            root = uigridlayout(f, [4 1], 'BackgroundColor', T.Bg, 'Padding', [8 8 8 8], 'RowSpacing', 6);
            root.RowHeight = {40, '1x', 158, 24};

            % ---- toolbar -------------------------------------------------------------
            tb = uigridlayout(root, [1 12], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            tb.Layout.Row = 1;
            tb.ColumnWidth = {55, 120, 32, 32, 105, 90, 70, 95, 140, 105, 170, '1x'};
            H.AddrLbl    = ude.Theme.label(tb, 'Address');
            H.AddrField  = uieditfield(tb, 'text', 'Value', '0x00000000', 'FontName', T.Font);
            H.PrevBtn    = ude.Theme.button(tb, '<', 'Tooltip', 'Previous page (lower addresses)');
            H.NextBtn    = ude.Theme.button(tb, '>', 'Tooltip', 'Next page (higher addresses)');
            H.WidthDD    = uidropdown(tb, 'Items', {'Byte', 'Word (16)', 'DWord (32)'}, 'ItemsData', [1 2 4], 'Value', 4);
            H.RowsDD     = uidropdown(tb, 'Items', {'8 rows', '16 rows', '32 rows'}, 'ItemsData', [8 16 32], 'Value', 16);
            H.RefreshBtn = ude.Theme.button(tb, 'Refresh');
            H.LiveChk    = uicheckbox(tb, 'Text', 'Live (2 Hz)', 'FontColor', T.Good);
            H.ImmChk     = uicheckbox(tb, 'Text', 'Write immediately', 'Value', true, 'FontColor', T.Text, ...
                'Tooltip', 'Off: edits turn blue and are written only when you press "Write pending".');
            H.CommitBtn  = ude.Theme.button(tb, 'Write pending');
            H.JumpDD     = uidropdown(tb, 'Items', {'Jump to...'}, 'ItemsData', 0, 'Value', 0);

            % ---- hex table -------------------------------------------------------------
            H.Table = uitable(root, 'FontName', T.Font, 'FontSize', 13, 'RowName', {}, ...
                'BackgroundColor', [T.Bg; T.Panel], 'ForegroundColor', T.Text);
            H.Table.Layout.Row = 2;

            % ---- data inspector ----------------------------------------------------------
            pnl = uipanel(root, 'Title', 'Data inspector  -  selected 32-bit word (click a cell; click a bit to flip it)', ...
                'BackgroundColor', T.Panel, 'ForegroundColor', T.Text);
            pnl.Layout.Row = 3;
            ig = uigridlayout(pnl, [3 1], 'BackgroundColor', T.Panel, 'Padding', [8 4 8 4], 'RowSpacing', 2);
            ig.RowHeight = {24, 18, 34};
            info = uigridlayout(ig, [1 6], 'BackgroundColor', T.Panel, 'Padding', [0 0 0 0]);
            info.Layout.Row = 1;
            info.ColumnWidth = {150, 150, 150, 150, 170, '1x'};
            H.InfoLbl = cell(1, 6);
            for k = 1:6
                H.InfoLbl{k} = uilabel(info, 'Text', '', 'FontName', T.Font, 'FontColor', T.Text);
            end
            numRow = uigridlayout(ig, [1 32], 'BackgroundColor', T.Panel, 'Padding', [0 0 0 0], 'ColumnSpacing', 1);
            numRow.Layout.Row = 2;
            btnRow = uigridlayout(ig, [1 32], 'BackgroundColor', T.Panel, 'Padding', [0 0 0 0], 'ColumnSpacing', 1);
            btnRow.Layout.Row = 3;
            H.BitBtn = cell(1, 32);
            for k = 1:32
                bit = 32 - k;
                uilabel(numRow, 'Text', num2str(bit), 'HorizontalAlignment', 'center', 'FontSize', 9, ...
                    'FontColor', T.Dim);
                shade = T.Panel;
                if mod(floor((k - 1) / 8), 2) == 1, shade = T.PanelHi; end   % alternate shading per byte
                H.BitBtn{k} = uibutton(btnRow, 'state', 'Text', '0', 'FontName', T.Font, ...
                    'BackgroundColor', shade, 'FontColor', T.Text);
            end

            % ---- status line -------------------------------------------------------------
            H.Status = uilabel(root, 'Text', 'Ready.', 'FontName', T.Font, 'FontColor', T.Dim);
            H.Status.Layout.Row = 4;

            obj.Fig = f;
            obj.H = H;
        end

        function render(obj, data, nc, width, chg, pend)
            T = ude.Theme;
            tbl = obj.H.Table;
            removeStyle(tbl);
            tbl.ColumnEditable = false;                 % neutral while the column count changes
            tbl.ColumnWidth = 'auto';
            tbl.Data = data;
            names = cell(1, nc + 2);
            names{1} = 'Address';
            for c = 1:nc
                names{c + 1} = sprintf('+0x%X', (c - 1) * width);
            end
            names{nc + 2} = 'ASCII (16 bytes)';
            tbl.ColumnName = names;
            cellW = 104;
            if width == 2, cellW = 64; elseif width == 1, cellW = 44; end
            tbl.ColumnWidth = [{120}, repmat({cellW}, 1, nc), {190}];
            tbl.ColumnEditable = [false, true(1, nc), false];
            addStyle(tbl, uistyle('FontColor', T.Accent), 'column', 1);
            addStyle(tbl, uistyle('FontColor', T.Good), 'column', nc + 2);
            if ~isempty(chg)
                addStyle(tbl, uistyle('BackgroundColor', T.Changed, 'FontColor', [1 1 1], 'FontWeight', 'bold'), 'cell', chg);
            end
            if ~isempty(pend)
                addStyle(tbl, uistyle('BackgroundColor', T.Pending, 'FontColor', [1 1 1], 'FontWeight', 'bold'), 'cell', pend);
            end
        end

        function showInspector(obj, addr, word, ok)
            H = obj.H;
            H.InfoLbl{1}.Text = sprintf('Addr  0x%08X', addr);
            if ~ok
                for k = 2:6, H.InfoLbl{k}.Text = ''; end
                H.InfoLbl{2}.Text = 'not readable';
                for k = 1:32
                    H.BitBtn{k}.Enable = 'off';
                    H.BitBtn{k}.Text = '-';
                end
                return;
            end
            b = typecast(word, 'uint8');
            H.InfoLbl{2}.Text = sprintf('Hex   0x%08X', word);
            H.InfoLbl{3}.Text = sprintf('u32   %u', word);
            H.InfoLbl{4}.Text = sprintf('s32   %d', typecast(word, 'int32'));
            H.InfoLbl{5}.Text = sprintf('f32   %.6g', typecast(word, 'single'));
            H.InfoLbl{6}.Text = ['bytes (memory order)  ' strjoin(arrayfun(@(x) sprintf('%02X', x), b, 'UniformOutput', false), ' ')];
            for k = 1:32
                v = bitget(word, 33 - k);                     % k = 1 is bit 31
                H.BitBtn{k}.Enable = 'on';
                H.BitBtn{k}.Value = logical(v);
                H.BitBtn{k}.Text = char('0' + v);
            end
        end

        function setStatus(obj, txt, level)
            T = ude.Theme;
            col = T.Dim;
            if nargin >= 3
                switch level
                    case 'ok',   col = T.Good;
                    case 'warn', col = T.Warn;
                    case 'bad',  col = T.Bad;
                end
            end
            obj.H.Status.Text = txt;
            obj.H.Status.FontColor = col;
        end

        function setJumpList(obj, names, addrs)
            dd = obj.H.JumpDD;
            dd.ItemsData = [];                       % avoid a length mismatch while Items changes
            dd.Items = [{'Jump to...'}, cellstr(names(:))'];
            dd.ItemsData = [0, double(addrs(:))'];
            dd.Value = 0;
        end
    end
end
