classdef PatchWindow < handle
    % PatchWindow  Live code patching: write assembly, assemble it with ude.xtensaAssemble, inject the bytes
    %              into the 256-byte IRAM sandbox over the control link, and CALL it - no reboot, no flash.
    properties (SetAccess = private)
        Mcu
        Fig
        H struct = struct()
        Presets struct
        Result struct = struct()
    end
    properties
        OnInjected = @() []          % hook: the workbench uses it to show the new bytes in the Memory window
    end

    methods
        function obj = PatchWindow(mcu)
            obj.Mcu = mcu;
            obj.Presets = PatchWindow.presets();
            obj.build();
            obj.loadPreset(1);
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
            f = uifigure('Name', 'Live code patcher (IRAM)', 'Position', [160 100 1020 600], 'Color', T.Bg);
            root = uigridlayout(f, [2 2], 'BackgroundColor', T.Bg, 'Padding', [8 8 8 8], 'RowSpacing', 6);
            root.RowHeight = {'1x', 54};
            root.ColumnWidth = {'1x', '1x'};

            left = uigridlayout(root, [3 1], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'RowSpacing', 6);
            left.RowHeight = {28, '1x', 30};
            H.Preset = uidropdown(left, 'Items', {obj.Presets.name}, 'ItemsData', 1:numel(obj.Presets));
            H.Src = uitextarea(left, 'FontName', T.Font, 'FontSize', 14, 'BackgroundColor', T.Panel, 'FontColor', T.Text);
            bb = uigridlayout(left, [1 3], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            H.AsmBtn  = ude.Theme.button(bb, 'Assemble');
            H.InjBtn  = ude.Theme.button(bb, 'Inject to IRAM');
            H.RunBtn  = ude.Theme.button(bb, 'Execute', 'BackgroundColor', [0.0 0.45 0.74]);

            right = uigridlayout(root, [3 1], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'RowSpacing', 6);
            right.RowHeight = {'1x', 30, 120};
            H.Listing = uitable(right, 'FontName', T.Font, 'FontSize', 12, 'RowName', {}, ...
                'ColumnName', {'Offset', 'Bytes (memory order)', 'Source'}, 'ColumnWidth', {70, 190, 'auto'}, ...
                'BackgroundColor', [T.Bg; T.Panel], 'ForegroundColor', T.Text);
            ag = uigridlayout(right, [1 5], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            ag.ColumnWidth = {70, 110, 70, 110, '1x'};
            ude.Theme.label(ag, 'a2 = 0x', 'FontName', T.Font);
            H.A2 = uieditfield(ag, 'text', 'Value', '00000000', 'FontName', T.Font);
            ude.Theme.label(ag, 'a3 = 0x', 'FontName', T.Font);
            H.A3 = uieditfield(ag, 'text', 'Value', '00000000', 'FontName', T.Font);
            H.Result = uilabel(right, 'Text', 'Pick a preset, press Assemble, Inject, Execute.', 'WordWrap', 'on', ...
                'FontName', T.Font, 'FontSize', 13, 'FontColor', T.Dim, 'VerticalAlignment', 'top');

            H.Help = uilabel(root, 'WordWrap', 'on', 'FontColor', T.Dim, 'FontSize', 11, 'Text', ...
                ['ABI: the C side calls your code as  uint32 f(a2, a3)  with the windowed ABI -> start with "entry a1, 32", ' ...
                 'finish with "retw.n". Result = a2. a0/a1 are protected. Supported: entry movi addi add sub and or xor mov ' ...
                 'slli srli l32i s32i nop memw isync retw.n .word. No jumps (no endless loops). ' ...
                 'Your code runs with full CPU privileges: a stray s32i to an unmapped address resets the chip.']);
            H.Help.Layout.Row = 2;  H.Help.Layout.Column = [1 2];

            H.Preset.ValueChangedFcn = @(s, ~) obj.loadPreset(s.Value);
            H.AsmBtn.ButtonPushedFcn = @(~, ~) obj.guard(@() obj.assemble());
            H.InjBtn.ButtonPushedFcn = @(~, ~) obj.guard(@() obj.inject());
            H.RunBtn.ButtonPushedFcn = @(~, ~) obj.guard(@() obj.execute());
            f.CloseRequestFcn = @(~, ~) obj.close();
            obj.Fig = f;
            obj.H = H;
        end

        function loadPreset(obj, idx)
            p = obj.Presets(idx);
            obj.H.Src.Value = splitlines(string(p.source));
            obj.H.A2.Value = p.a2;
            obj.H.A3.Value = p.a3;
            obj.H.Listing.Data = {};
            obj.say('Preset loaded. Press Assemble.', 'dim');
        end

        function guard(obj, fcn)
            try
                fcn();
            catch ME
                obj.say(ME.message, 'bad');
            end
        end

        function say(obj, txt, level)
            T = ude.Theme;
            col = T.Dim;
            if strcmp(level, 'ok'), col = T.Good; elseif strcmp(level, 'bad'), col = T.Bad; end
            obj.H.Result.Text = txt;
            obj.H.Result.FontColor = col;
        end

        function assemble(obj)
            src = strjoin(string(obj.H.Src.Value), newline);
            obj.Result = ude.xtensaAssemble(src, 256);
            obj.H.Listing.Data = obj.Result.listing;
            obj.say(sprintf('Assembled %d bytes (%d words). Not on the chip yet.', numel(obj.Result.bytes), numel(obj.Result.words)), 'ok');
        end

        function inject(obj)
            if ~isfield(obj.Result, 'words'), obj.assemble(); end
            base = obj.Mcu.IramAddr;
            w = obj.Result.words;
            for k = 1:numel(w)
                obj.Mcu.write32(base + uint32((k - 1) * 4), w(k));
            end
            back = obj.Mcu.readBlock32(base, numel(w));
            if ~isequal(back, w), error('Patch:Verify', 'Read-back differs from what was written.'); end
            obj.say(sprintf('Injected %d bytes at 0x%08X and verified by read-back.', numel(obj.Result.bytes), base), 'ok');
            obj.OnInjected();
        end

        function execute(obj)
            obj.inject();
            a2 = ude.Hex.parse(obj.H.A2.Value, 32);
            a3 = ude.Hex.parse(obj.H.A3.Value, 32);
            ret = obj.Mcu.execIRAM(obj.Mcu.IramAddr, a2, a3);
            obj.say(sprintf('f(0x%08X, 0x%08X)  returned  a2 = 0x%08X  (%u)', a2, a3, ret, ret), 'ok');
            obj.OnInjected();
        end
    end

    methods (Static, Access = private)
        function p = presets()
            p = struct('name', {}, 'source', {}, 'a2', {}, 'a3', {});
            p(end+1) = struct('name', '1. Return a constant (1337)', 'a2', '00000000', 'a3', '00000000', 'source', ...
                sprintf('entry a1, 32\nmovi a2, 1337\nretw.n'));
            p(end+1) = struct('name', '2. Add the two arguments', 'a2', '00001234', 'a3', '00001111', 'source', ...
                sprintf('entry a1, 32\nadd a2, a2, a3\nretw.n'));
            p(end+1) = struct('name', '3. LED ON  (store to GPIO regs)', 'a2', '3FF44000', 'a3', '00000004', 'source', ...
                sprintf(['entry a1, 32\n' ...
                         's32i a3, a2, 36    ; GPIO_ENABLE_W1TS (base+0x24): pin becomes an output\n' ...
                         's32i a3, a2, 8     ; GPIO_OUT_W1TS    (base+0x08): drive it high\n' ...
                         'movi a2, 0\nretw.n']));
            p(end+1) = struct('name', '4. LED OFF (store to GPIO regs)', 'a2', '3FF44000', 'a3', '00000004', 'source', ...
                sprintf(['entry a1, 32\n' ...
                         's32i a3, a2, 12    ; GPIO_OUT_W1TC    (base+0x0C): drive it low\n' ...
                         'movi a2, 0\nretw.n']));
            p(end+1) = struct('name', '5. Read a word (l32i)', 'a2', '3FF44004', 'a3', '00000000', 'source', ...
                sprintf('entry a1, 32\nl32i a2, a2, 0     ; a2 = *(uint32*)a2\nretw.n'));
            p(end+1) = struct('name', '6. Build an address with shifts', 'a2', '00000000', 'a3', '00000000', 'source', ...
                sprintf(['entry a1, 32\n' ...
                         'movi a2, 1023       ; 0x3FF\n' ...
                         'slli a2, a2, 20     ; 0x3FF00000\n' ...
                         'movi a3, 1088       ; 0x440\n' ...
                         'slli a3, a3, 8      ; 0x00044000\n' ...
                         'add a2, a2, a3      ; 0x3FF44000 = GPIO base\n' ...
                         'retw.n']));
        end
    end
end
