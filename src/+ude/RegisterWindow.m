classdef RegisterWindow < handle
    % RegisterWindow  SFR browser (UDE "SFR window"): pick a peripheral register from the JSON built out of
    %                 ESP-IDF's *_reg.h headers, see every bitfield decoded, edit a field or flip a bit.
    properties (SetAccess = private)
        Mcu
        Fig
        H struct = struct()
        Poller
        Names string
        Groups string
        Current string = ""
        Addr uint32 = 0
        F struct = struct('name', strings(0, 1), 'off', zeros(0, 1), 'wid', zeros(0, 1), 'acc', strings(0, 1))
        SelRow double = 0
    end

    methods
        function obj = RegisterWindow(mcu)
            obj.Mcu = mcu;
            obj.Names = mcu.RegisterList;
            obj.Groups = extractBefore(obj.Names + "_", "_");
            obj.build();
            obj.fillList();
            obj.Poller = ude.Poller(@() obj.poll(), 0.5);
        end

        function tf = isOpen(obj)
            tf = ~isempty(obj.Fig) && isvalid(obj.Fig);
        end

        function close(obj)
            if ~isempty(obj.Poller) && isvalid(obj.Poller), delete(obj.Poller); end
            if obj.isOpen(), delete(obj.Fig); end
        end
    end

    methods (Access = private)
        function build(obj)
            T = ude.Theme;
            f = uifigure('Name', sprintf('Registers (SFR)  -  %s', obj.Mcu.Target), ...
                'Position', [140 90 1000 640], 'Color', T.Bg);
            root = uigridlayout(f, [1 2], 'BackgroundColor', T.Bg, 'Padding', [8 8 8 8]);
            root.ColumnWidth = {300, '1x'};

            left = uigridlayout(root, [3 1], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'RowSpacing', 6);
            left.RowHeight = {28, 28, '1x'};
            groups = ["All", unique(obj.Groups(:))'];
            H.Group  = uidropdown(left, 'Items', cellstr(groups), 'Value', 'All');
            H.Search = uieditfield(left, 'text', 'Placeholder', 'search register...');
            H.List   = uilistbox(left, 'Items', {''}, 'FontName', T.Font, 'FontSize', 12, ...
                'BackgroundColor', T.Panel, 'FontColor', T.Text);

            right = uigridlayout(root, [3 1], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'RowSpacing', 6);
            right.RowHeight = {52, 32, '1x'};
            H.Title = uilabel(right, 'Text', 'Select a register on the left', 'FontSize', 15, ...
                'FontWeight', 'bold', 'FontColor', T.Accent, 'FontName', T.Font);
            rr = uigridlayout(right, [1 6], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            rr.ColumnWidth = {70, 130, 70, 100, 100, 120};
            ude.Theme.label(rr, 'Raw  0x');
            H.Raw       = uieditfield(rr, 'text', 'Value', '00000000', 'FontName', T.Font);
            H.ReadBtn   = ude.Theme.button(rr, 'Read');
            H.WriteBtn  = ude.Theme.button(rr, 'Write raw');
            H.LiveChk   = uicheckbox(rr, 'Text', 'Live', 'FontColor', T.Good);
            H.ToggleBtn = ude.Theme.button(rr, 'Toggle bit', 'Tooltip', 'Select a 1-bit field row, then press.');
            H.Table = uitable(right, 'FontName', T.Font, 'FontSize', 13, 'RowName', {}, ...
                'ColumnName', {'Bits', 'Field', 'Acc', 'Value (hex)', 'Dec'}, ...
                'ColumnEditable', [false false false true false], 'ColumnWidth', {80, 240, 50, 110, 120}, ...
                'BackgroundColor', [T.Bg; T.Panel], 'ForegroundColor', T.Text);

            H.Group.ValueChangedFcn   = @(~, ~) obj.fillList();
            H.Search.ValueChangingFcn = @(~, e) obj.fillList(e.Value);
            H.List.ValueChangedFcn    = @(s, ~) obj.guard(@() obj.select(s.Value));
            H.ReadBtn.ButtonPushedFcn   = @(~, ~) obj.guard(@() obj.readCurrent());
            H.WriteBtn.ButtonPushedFcn  = @(~, ~) obj.guard(@() obj.writeRaw());
            H.ToggleBtn.ButtonPushedFcn = @(~, ~) obj.guard(@() obj.toggle());
            H.LiveChk.ValueChangedFcn   = @(s, ~) obj.onLive(s.Value);
            H.Table.CellEditCallback      = @(~, e) obj.guard(@() obj.onEdit(e));
            H.Table.CellSelectionCallback = @(~, e) obj.onSelect(e);
            f.CloseRequestFcn = @(~, ~) obj.close();
            obj.Fig = f;
            obj.H = H;
        end

        function guard(obj, fcn)
            try
                fcn();
            catch ME
                obj.H.Title.Text = ['ERROR: ' ME.message];
                obj.H.Title.FontColor = ude.Theme.Bad;
            end
        end

        function fillList(obj, query)
            if nargin < 2, query = obj.H.Search.Value; end
            mask = true(size(obj.Names));
            g = string(obj.H.Group.Value);
            if g ~= "All", mask = (obj.Groups == g); end
            q = strtrim(string(query));
            if q ~= "", mask = mask & contains(obj.Names, q, 'IgnoreCase', true); end
            items = cellstr(obj.Names(mask));
            if isempty(items), items = {'(no match)'}; end
            obj.H.List.Items = items;
        end

        function select(obj, name)
            if strcmp(name, '(no match)') || isempty(name), return; end
            def = obj.Mcu.registerDef(name);
            obj.Current = string(name);
            obj.Addr = uint32(hex2dec(extractAfter(string(def.address), "0x")));
            fn = fieldnames(def.bitfields);
            n = numel(fn);
            off = zeros(n, 1);  wid = zeros(n, 1);  acc = strings(n, 1);
            for k = 1:n
                bf = def.bitfields.(fn{k});
                off(k) = bf.offset;  wid(k) = bf.width;  acc(k) = string(bf.access);
            end
            if n > 0
                [~, ord] = sortrows([-off, -wid]);        % highest bit first, like the TRM tables
            else
                ord = zeros(0, 1);
            end
            obj.F = struct('name', string(fn(ord)), 'off', off(ord), 'wid', wid(ord), 'acc', acc(ord));
            obj.SelRow = 0;
            obj.readCurrent();
        end

        function readCurrent(obj)
            if obj.Current == "", return; end
            raw = obj.Mcu.read32(obj.Addr);
            obj.H.Title.Text = sprintf('%s   @ 0x%08X   =  0x%08X   (%u)', obj.Current, obj.Addr, raw, raw);
            obj.H.Title.FontColor = ude.Theme.Accent;
            obj.H.Raw.Value = sprintf('%08X', raw);
            n = numel(obj.F.name);
            rows = cell(n, 5);
            for k = 1:n
                v = bitand(bitshift(raw, -obj.F.off(k)), uint32(2^obj.F.wid(k) - 1));
                rows{k, 1} = sprintf('[%2d:%2d]', obj.F.off(k) + obj.F.wid(k) - 1, obj.F.off(k));
                rows{k, 2} = char(obj.F.name(k));
                rows{k, 3} = char(obj.F.acc(k));
                rows{k, 4} = sprintf('%X', v);
                rows{k, 5} = sprintf('%u', v);
            end
            obj.H.Table.Data = rows;
        end

        function poll(obj)
            if obj.isOpen(), obj.readCurrent(); end
        end

        function onLive(obj, on)
            if on, obj.Poller.start(); else, obj.Poller.stop(); end
        end

        function writeRaw(obj)
            obj.Mcu.write32(obj.Addr, uint32(ude.Hex.parse(obj.H.Raw.Value, 32)));
            obj.readCurrent();
        end

        function onSelect(obj, e)
            if ~isempty(e.Indices), obj.SelRow = e.Indices(1, 1); end
        end

        function toggle(obj)
            r = obj.SelRow;
            if r < 1 || r > numel(obj.F.name) || obj.F.wid(r) ~= 1
                error('Registers:Toggle', 'Select a 1-bit field first.');
            end
            raw = obj.Mcu.read32(obj.Addr);
            obj.Mcu.write32(obj.Addr, bitxor(raw, bitshift(uint32(1), obj.F.off(r))));
            obj.readCurrent();
        end

        function onEdit(obj, e)
            r = e.Indices(1);
            try
                if obj.F.acc(r) == "R", error('Registers:ReadOnly', 'Field %s is read-only.', obj.F.name(r)); end
                val = ude.Hex.parse(e.NewData, obj.F.wid(r));
                maskPos = uint32(bitshift(uint64(2^obj.F.wid(r) - 1), obj.F.off(r)));
                raw = obj.Mcu.read32(obj.Addr);
                newRaw = bitor(bitand(raw, bitcmp(maskPos)), uint32(bitshift(uint64(val), obj.F.off(r))));
                obj.Mcu.write32(obj.Addr, newRaw);
            catch ME
                obj.H.Title.Text = ['ERROR: ' ME.message];
                obj.H.Title.FontColor = ude.Theme.Bad;
                return;
            end
            obj.readCurrent();
        end
    end
end
