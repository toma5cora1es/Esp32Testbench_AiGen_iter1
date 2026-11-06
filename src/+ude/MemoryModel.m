classdef MemoryModel < handle
    % MemoryModel  Everything a memory window needs EXCEPT widgets: what is shown, what changed,
    %              what is staged for writing. Talks to the chip only through Mcu.readBlock32Ex /
    %              write32, so it works unchanged on serial, WiFi and simulation links.
    events
        Updated
    end

    properties (Constant)
        BytesPerRow = 16
    end

    properties (SetAccess = private)
        Mcu
        Start uint32 = 0
        Width double = 4              % bytes per cell: 1, 2 or 4   (UDE: Byte / Word / DWord)
        Rows double = 16
        Words uint32
        Bytes uint8
        Valid logical
        Mark string
        Changed logical               % per byte: differs from the previous read
        PrevBytes uint8
        HavePrev logical = false
        Pending                       % containers.Map  address(double) -> struct(val,width)
    end

    properties
        WriteImmediately logical = true
    end

    methods
        function obj = MemoryModel(mcu, startAddr)
            obj.Mcu = mcu;
            obj.Pending = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.Start = bitand(uint32(startAddr), bitcmp(uint32(15)));
            obj.read();
        end

        % ------------------------------------------------------------ navigation
        function setStart(obj, addr)
            obj.Start = bitand(uint32(addr), bitcmp(uint32(15)));
            obj.resetView();
            obj.read();
        end

        function page(obj, direction)
            delta = uint32(obj.Rows * obj.BytesPerRow);
            if direction > 0
                obj.Start = obj.Start + min(delta, intmax('uint32') - obj.Start);
            elseif obj.Start >= delta
                obj.Start = obj.Start - delta;
            else
                obj.Start = uint32(0);
            end
            obj.resetView();
            obj.read();
        end

        function setWidth(obj, w)
            obj.Width = w;
            obj.Pending = containers.Map('KeyType', 'double', 'ValueType', 'any');
            notify(obj, 'Updated');
        end

        function setRows(obj, n)
            obj.Rows = n;
            obj.resetView();
            obj.read();
        end

        % ------------------------------------------------------------ reading
        function read(obj)
            nW = obj.Rows * 4;
            [w, v, m] = obj.Mcu.readBlock32Ex(obj.Start, nW);
            b = typecast(w, 'uint8');
            if obj.HavePrev && numel(obj.PrevBytes) == numel(b)
                obj.Changed = (b ~= obj.PrevBytes) & repelem(v, 4);
            else
                obj.Changed = false(size(b));
            end
            obj.PrevBytes = b;
            obj.HavePrev = true;
            obj.Words = w;  obj.Bytes = b;  obj.Valid = v;  obj.Mark = m;
            notify(obj, 'Updated');
        end

        function [w, ok] = wordAt(obj, addr)
            off = double(addr) - double(obj.Start);
            ok = off >= 0 && off < obj.Rows * obj.BytesPerRow && mod(off, 4) == 0;
            w = uint32(0);
            if ok
                wi = off / 4 + 1;
                ok = obj.Valid(wi);
                w = obj.Words(wi);
            end
        end

        % ------------------------------------------------------------ presentation data
        function [data, nc] = tableData(obj)
            nc = obj.BytesPerRow / obj.Width;
            data = cell(obj.Rows, nc + 2);
            for r = 1:obj.Rows
                data{r, 1} = sprintf('0x%08X', obj.Start + uint32((r - 1) * 16));
                for c = 1:nc
                    data{r, c + 1} = obj.cellText((r - 1) * 16 + (c - 1) * obj.Width);
                end
                data{r, nc + 2} = obj.asciiRow(r);
            end
        end

        function [chg, pend] = styleCells(obj)
            idx = find(obj.Changed) - 1;
            if isempty(idx)
                chg = zeros(0, 2);
            else
                chg = unique([floor(idx(:) / 16) + 1, floor(mod(idx(:), 16) / obj.Width) + 2], 'rows');
            end
            pend = zeros(0, 2);
            ks = keys(obj.Pending);
            for k = 1:numel(ks)
                v = obj.Pending(ks{k});
                off = ks{k} - double(obj.Start);
                if v.width == obj.Width && off >= 0 && off < obj.Rows * 16
                    pend(end + 1, :) = [floor(off / 16) + 1, floor(mod(off, 16) / obj.Width) + 2]; %#ok<AGROW>
                end
            end
        end

        % ------------------------------------------------------------ writing
        function edit(obj, row, col, text)
            off = (row - 1) * 16 + (col - 2) * obj.Width;
            if ~obj.Valid(floor(off / 4) + 1)
                error('Memory:NotMapped', 'That address is not readable memory; nothing to edit.');
            end
            addr = obj.Start + uint32(off);
            val = ude.Hex.parse(text, 8 * obj.Width);
            if obj.WriteImmediately
                obj.writeValue(addr, val, obj.Width);
                obj.read();
            else
                obj.Pending(double(addr)) = struct('val', val, 'width', obj.Width);
                notify(obj, 'Updated');
            end
        end

        function n = commitPending(obj)
            ks = sort(cell2mat(keys(obj.Pending)));
            n = numel(ks);
            for k = 1:n
                v = obj.Pending(ks(k));
                obj.writeValue(uint32(ks(k)), v.val, v.width);
            end
            obj.Pending = containers.Map('KeyType', 'double', 'ValueType', 'any');
            obj.read();
        end

        function discardPending(obj)
            obj.Pending = containers.Map('KeyType', 'double', 'ValueType', 'any');
            notify(obj, 'Updated');
        end

        function toggleBit(obj, wordAddr, bit)
            cur = obj.Mcu.read32(wordAddr);
            obj.Mcu.write32(wordAddr, bitxor(cur, bitshift(uint32(1), bit)));
            obj.read();
        end
    end

    methods (Access = private)
        function resetView(obj)
            obj.HavePrev = false;
            obj.Pending = containers.Map('KeyType', 'double', 'ValueType', 'any');
        end

        function writeValue(obj, addr, val, w)
            % Byte/half-word edits are read-modify-write on the containing 32-bit word
            % (the instruction bus and the SFR bus only accept 32-bit accesses).
            addr = uint32(addr);
            if w == 4
                obj.Mcu.write32(addr, uint32(val));
                return;
            end
            wa = bitand(addr, bitcmp(uint32(3)));
            sh = double(bitand(addr, uint32(3))) * 8;
            mask = uint32((2^(8 * w) - 1) * 2^sh);
            cur = obj.Mcu.read32(wa);
            obj.Mcu.write32(wa, bitor(bitand(cur, bitcmp(mask)), uint32(val * 2^sh)));
        end

        function s = cellText(obj, off)
            wi = floor(off / 4) + 1;
            if ~obj.Valid(wi)
                ch = '-';
                if obj.Mark(wi) == "~~~~~~~~", ch = '~'; end
                s = repmat(ch, 1, 2 * obj.Width);
                return;
            end
            key = double(obj.Start) + off;
            if isKey(obj.Pending, key)
                pv = obj.Pending(key);
                if pv.width == obj.Width
                    s = ude.Hex.fmt(pv.val, obj.Width);
                    return;
                end
            end
            chunk = obj.Bytes(off + 1 : off + obj.Width);
            switch obj.Width
                case 1
                    v = chunk;
                case 2
                    v = typecast(chunk, 'uint16');
                otherwise
                    v = typecast(chunk, 'uint32');
            end
            s = ude.Hex.fmt(v, obj.Width);
        end

        function s = asciiRow(obj, r)
            i0 = (r - 1) * 16;
            b = obj.Bytes(i0 + 1 : i0 + 16);
            s = char(b);
            s(b < 32 | b > 126) = '.';
            bad = ~repelem(obj.Valid((r - 1) * 4 + (1:4)), 4);
            s(bad) = ' ';
        end
    end
end
