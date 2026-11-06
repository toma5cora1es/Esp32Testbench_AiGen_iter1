classdef Workbench < handle
    % Workbench  The "UDE-like" launcher: one small control window that opens the tool windows and wires
    %            them together (Map click -> Memory jumps; Patch inject -> Memory shows the new bytes).
    %
    %   wb = ude.Workbench(Reg);   wb.openMemory(Reg.DramAddr);   wb.openAll();
    properties (SetAccess = private)
        Mcu
        Fig
        H struct = struct()
        Memory = []
        Registers = []
        Map = []
        Patch = []
        Ota = []
    end

    methods
        function obj = Workbench(mcu)
            obj.Mcu = mcu;
            obj.build();
        end

        function w = openMemory(obj, addr)
            if nargin < 2 || isempty(addr) || addr == 0, addr = obj.Mcu.DramAddr; end
            if ~isempty(obj.Memory) && obj.Memory.isOpen()
                obj.Memory.jumpTo(addr);
            else
                obj.Memory = ude.MemoryWindow(obj.Mcu, addr);
                obj.Memory.OnAddressChanged = @(a) obj.followMap(a);
                obj.followMap(obj.Memory.Model.Start);
            end
            w = obj.Memory;
        end

        function w = openRegisters(obj)
            if isempty(obj.Registers) || ~obj.Registers.isOpen()
                obj.Registers = ude.RegisterWindow(obj.Mcu);
            else
                figure(obj.Registers.Fig);
            end
            w = obj.Registers;
        end

        function w = openMap(obj)
            if isempty(obj.Map) || ~obj.Map.isOpen()
                obj.Map = ude.MemoryMapWindow(obj.Mcu);
                obj.Map.OnJump = @(a) obj.openMemory(a);
                if ~isempty(obj.Memory) && obj.Memory.isOpen()
                    obj.Map.highlight(obj.Memory.Model.Start);
                end
            else
                figure(obj.Map.Fig);
            end
            w = obj.Map;
        end

        function w = openPatch(obj)
            if isempty(obj.Patch) || ~obj.Patch.isOpen()
                obj.Patch = ude.PatchWindow(obj.Mcu);
                obj.Patch.OnInjected = @() obj.showInjected();
            else
                figure(obj.Patch.Fig);
            end
            w = obj.Patch;
        end

        function w = openOta(obj)
            if isempty(obj.Ota) || ~obj.Ota.isOpen()
                obj.Ota = ude.OtaWindow(obj.Mcu);
            else
                figure(obj.Ota.Fig);
            end
            w = obj.Ota;
        end

        function openAll(obj)
            obj.openMemory(obj.Mcu.DramAddr);
            obj.openMap();
            obj.openRegisters();
            obj.openPatch();
        end

        function closeAll(obj)
            for w = {obj.Memory, obj.Registers, obj.Map, obj.Patch, obj.Ota}
                if ~isempty(w{1}) && isvalid(w{1}), w{1}.close(); end
            end
            if isvalid(obj.Fig), delete(obj.Fig); end
        end
    end

    methods (Access = private)
        function build(obj)
            T = ude.Theme;
            f = uifigure('Name', 'ESP32 UDE-style workbench', 'Position', [60 560 620 330], 'Color', T.Bg);
            g = uigridlayout(f, [4 1], 'BackgroundColor', T.Bg, 'Padding', [10 10 10 10], 'RowSpacing', 8);
            g.RowHeight = {26, 78, 36, '1x'};
            i = obj.Mcu.Info;
            H.Head = uilabel(g, 'FontName', T.Font, 'FontColor', T.Accent, 'FontWeight', 'bold', 'Text', ...
                sprintf('%s on %s  |  FW %s build %s  |  running %s', Esp32.field(i, 'CHIP'), obj.Mcu.Target, ...
                Esp32.field(i, 'FW'), Esp32.field(i, 'BUILD'), Esp32.field(i, 'RUN')));
            bg = uigridlayout(g, [2 3], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'RowSpacing', 6, 'ColumnSpacing', 6);
            H.MemBtn  = ude.Theme.button(bg, 'Memory');
            H.RegBtn  = ude.Theme.button(bg, 'Registers (SFR)');
            H.MapBtn  = ude.Theme.button(bg, 'Memory map');
            H.PatchBtn = ude.Theme.button(bg, 'Live code patcher');
            H.OtaBtn  = ude.Theme.button(bg, 'Wireless update (OTA)');
            H.AllBtn  = ude.Theme.button(bg, 'Open all', 'BackgroundColor', [0.0 0.45 0.74]);
            qg = uigridlayout(g, [1 3], 'BackgroundColor', T.Bg, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            H.BlinkBtn = ude.Theme.button(qg, 'Blink LED (GPIO2)');
            H.ReconBtn = ude.Theme.button(qg, 'Reconnect link');
            H.PingBtn  = ude.Theme.button(qg, 'Ping');
            H.Log = uitextarea(g, 'Editable', 'off', 'FontName', T.Font, 'BackgroundColor', T.Panel, 'FontColor', T.Text);

            H.MemBtn.ButtonPushedFcn   = @(~, ~) obj.run(@() obj.openMemory());
            H.RegBtn.ButtonPushedFcn   = @(~, ~) obj.run(@() obj.openRegisters());
            H.MapBtn.ButtonPushedFcn   = @(~, ~) obj.run(@() obj.openMap());
            H.PatchBtn.ButtonPushedFcn = @(~, ~) obj.run(@() obj.openPatch());
            H.OtaBtn.ButtonPushedFcn   = @(~, ~) obj.run(@() obj.openOta());
            H.AllBtn.ButtonPushedFcn   = @(~, ~) obj.run(@() obj.openAll());
            H.BlinkBtn.ButtonPushedFcn = @(~, ~) obj.run(@() obj.blink());
            H.ReconBtn.ButtonPushedFcn = @(~, ~) obj.run(@() obj.reconnect());
            H.PingBtn.ButtonPushedFcn  = @(~, ~) obj.run(@() obj.ping());
            f.CloseRequestFcn = @(~, ~) obj.closeAll();
            obj.Fig = f;
            obj.H = H;
            obj.say('Workbench ready. Tip: "Open all", then click a block in the Memory map.');
        end

        function say(obj, msg)
            obj.H.Log.Value = [obj.H.Log.Value; {[datestr(now, 'HH:MM:SS') '  ' char(msg)]}];
            scroll(obj.H.Log, 'bottom');
        end

        function run(obj, fcn)
            try
                fcn();
            catch ME
                obj.say(['ERROR: ' ME.message]);
            end
        end

        function followMap(obj, addr)
            if ~isempty(obj.Map) && isvalid(obj.Map) && obj.Map.isOpen(), obj.Map.highlight(addr); end
        end

        function showInjected(obj)
            obj.openMemory(obj.Mcu.IramAddr);
        end

        function blink(obj)
            obj.Mcu.GPIO_ENABLE_REG.GPIO2 = 1;
            for k = 1:4
                obj.Mcu.GPIO_OUT_REG.GPIO2 = mod(k, 2);
                pause(0.15);
            end
            obj.Mcu.GPIO_OUT_REG.GPIO2 = 0;
            obj.say('Blinked GPIO2 through GPIO_ENABLE_REG / GPIO_OUT_REG.');
        end

        function reconnect(obj)
            if obj.Mcu.reconnect(), obj.say('Link re-opened.'); else, obj.say('Could not re-open the link.'); end
        end

        function ping(obj)
            t0 = tic;
            r = obj.Mcu.cmd("PING");
            obj.say(sprintf('%s  (%.0f ms)', r, 1000 * toc(t0)));
        end
    end
end
