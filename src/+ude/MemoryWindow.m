classdef MemoryWindow < handle
    % MemoryWindow  Controller (MVC): wires MemoryView widgets to the MemoryModel and a Poller.
    %               Construction of the widgets lives in MemoryView; chip access lives in MemoryModel.
    properties (SetAccess = private)
        Model
        View
        Poller
        Selected uint32 = 0           % address of the selected 32-bit word
        LastKey = []                  % what was drawn last (to skip pointless redraws while polling)
    end
    properties
        OnAddressChanged = @(addr) []   % hook, e.g. so the Memory-map window can follow
    end

    methods
        function obj = MemoryWindow(mcu, startAddr)
            obj.Model = ude.MemoryModel(mcu, startAddr);
            obj.View = ude.MemoryView(sprintf('Memory  -  %s', mcu.Target));
            obj.Selected = obj.Model.Start;
            obj.wire();
            obj.fillJumpList(mcu);
            obj.Poller = ude.Poller(@() obj.poll(), 0.5);
            obj.draw();
        end

        function jumpTo(obj, addr)
            obj.Model.setStart(addr);
            obj.Selected = obj.Model.Start;
            obj.LastKey = [];
            obj.draw();
            figure(obj.View.Fig);
        end

        function tf = isOpen(obj)
            tf = ~isempty(obj.View) && isvalid(obj.View) && isvalid(obj.View.Fig);
        end

        function close(obj)
            if ~isempty(obj.Poller) && isvalid(obj.Poller), delete(obj.Poller); end
            if ~isempty(obj.View) && isvalid(obj.View) && isvalid(obj.View.Fig), delete(obj.View.Fig); end
        end
    end

    methods (Access = private)
        function wire(obj)
            H = obj.View.H;
            H.AddrField.ValueChangedFcn  = @(~, ~) obj.guard(@() obj.onAddr());
            H.PrevBtn.ButtonPushedFcn    = @(~, ~) obj.guard(@() obj.onPage(-1));
            H.NextBtn.ButtonPushedFcn    = @(~, ~) obj.guard(@() obj.onPage(+1));
            H.WidthDD.ValueChangedFcn    = @(s, ~) obj.guard(@() obj.onWidth(s.Value));
            H.RowsDD.ValueChangedFcn     = @(s, ~) obj.guard(@() obj.onRows(s.Value));
            H.RefreshBtn.ButtonPushedFcn = @(~, ~) obj.guard(@() obj.refresh());
            H.LiveChk.ValueChangedFcn    = @(s, ~) obj.onLive(s.Value);
            H.ImmChk.ValueChangedFcn     = @(s, ~) obj.onImmediate(s.Value);
            H.CommitBtn.ButtonPushedFcn  = @(~, ~) obj.guard(@() obj.onCommit());
            H.JumpDD.ValueChangedFcn     = @(s, ~) obj.guard(@() obj.onJump(s.Value));
            H.Table.CellEditCallback     = @(~, e) obj.guard(@() obj.onEdit(e));
            H.Table.CellSelectionCallback = @(~, e) obj.guard(@() obj.onSelect(e));
            for k = 1:32
                H.BitBtn{k}.ValueChangedFcn = @(~, ~) obj.guard(@() obj.onBit(k));
            end
            obj.View.Fig.CloseRequestFcn = @(~, ~) obj.close();
        end

        function guard(obj, fcn)
            try
                fcn();
            catch ME
                if obj.isOpen(), obj.View.setStatus(ME.message, 'bad'); end
            end
        end

        function fillJumpList(obj, mcu)
            names = {'DRAM test buffer (live counter)', 'IRAM exec buffer (injected code)', 'GPIO registers', ...
                     'UART0 registers', 'RTC FAST memory', 'ROM1 (data ROM)', 'ROM0 (boot ROM code)'};
            addrs = [double(mcu.DramAddr), double(mcu.IramAddr), hex2dec('3FF44000'), hex2dec('3FF40000'), ...
                     hex2dec('3FF80000'), hex2dec('3FF90000'), hex2dec('40000000')];
            keep = addrs > 0;
            obj.View.setJumpList(names(keep), addrs(keep));
        end

        function refresh(obj)
            obj.Model.read();
            obj.draw();
        end

        function poll(obj)
            if ~obj.isOpen() || ~isempty(keys(obj.Model.Pending)), return; end   % never overwrite staged edits
            obj.Model.read();
            obj.draw();
        end

        function draw(obj)
            M = obj.Model;
            [data, nc] = M.tableData();
            [chg, pend] = M.styleCells();
            key = {data, chg, pend, M.Width};
            if ~isequal(key, obj.LastKey)
                obj.View.render(data, nc, M.Width, chg, pend);
                obj.LastKey = key;
            end
            [w, ok] = M.wordAt(obj.Selected);
            obj.View.showInspector(obj.Selected, w, ok);
            obj.View.H.AddrField.Value = sprintf('0x%08X', M.Start);
            obj.View.setStatus(sprintf('%s   0x%08X .. 0x%08X   %d bytes   %s', char(M.Mcu.Mode), M.Start, ...
                M.Start + uint32(M.Rows * 16 - 1), M.Rows * 16, datestr(now, 'HH:MM:SS')), 'ok');
            obj.OnAddressChanged(M.Start);
        end

        function onAddr(obj)
            addr = ude.Hex.parse(obj.View.H.AddrField.Value, 32);
            obj.jumpTo(addr);
        end

        function onPage(obj, dir)
            obj.Model.page(dir);
            obj.Selected = obj.Model.Start;
            obj.LastKey = [];
            obj.draw();
        end

        function onWidth(obj, w)
            obj.Model.setWidth(w);
            obj.LastKey = [];
            obj.draw();
        end

        function onRows(obj, n)
            obj.Model.setRows(n);
            obj.LastKey = [];
            obj.draw();
        end

        function onLive(obj, on)
            if on, obj.Poller.start(); else, obj.Poller.stop(); end
        end

        function onImmediate(obj, on)
            obj.Model.WriteImmediately = on;
            if on && ~isempty(keys(obj.Model.Pending))
                obj.Model.discardPending();
                obj.LastKey = [];
                obj.draw();
            end
        end

        function onCommit(obj)
            n = obj.Model.commitPending();
            obj.LastKey = [];
            obj.draw();
            obj.View.setStatus(sprintf('Wrote %d pending value(s).', n), 'ok');
        end

        function onJump(obj, addr)
            if addr ~= 0, obj.jumpTo(addr); end
        end

        function onEdit(obj, e)
            try
                obj.Model.edit(e.Indices(1), e.Indices(2), e.NewData);
            catch ME
                obj.View.setStatus(ME.message, 'bad');
                obj.LastKey = [];          % force a redraw: throws away the rejected text
            end
            obj.draw();
        end

        function onSelect(obj, e)
            if isempty(e.Indices), return; end
            r = e.Indices(1, 1);
            c = e.Indices(1, 2);
            M = obj.Model;
            nc = M.BytesPerRow / M.Width;
            if c >= 2 && c <= nc + 1
                off = (r - 1) * 16 + (c - 2) * M.Width;
            else
                off = (r - 1) * 16;
            end
            obj.Selected = M.Start + uint32(floor(off / 4) * 4);
            [w, ok] = M.wordAt(obj.Selected);
            obj.View.showInspector(obj.Selected, w, ok);
        end

        function onBit(obj, k)
            obj.Model.toggleBit(obj.Selected, 32 - k);
            obj.LastKey = [];
            obj.draw();
        end
    end
end
