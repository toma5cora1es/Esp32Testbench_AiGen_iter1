classdef UDEMemoryViewer < handle
    % UDEMemoryViewer Professional PLS UDE-Style Real-Time Memory Window
    properties
        Mcu
        StartAddr uint32
        NumRows double = 16
        Fig
        Table
        AddrEditField
        AutoPollCheckbox
        StatusLabel
        RefreshTimer timer
        PrevWords uint32
        PendingWrites containers.Map
    end

    methods
        function obj = UDEMemoryViewer(mcu, initialAddr)
            obj.Mcu = mcu;
            if nargin < 2 || isempty(initialAddr)
                obj.StartAddr = uint32(hex2dec('3FF44000'));
            else
                obj.StartAddr = uint32(initialAddr);
            end
            obj.PrevWords = zeros(1, obj.NumRows * 4, 'uint32');
            obj.PendingWrites = containers.Map('KeyType', 'char', 'ValueType', 'uint32');
            obj.createUI();
            obj.refreshMemory();
        end

        function createUI(obj)
            % Main window designed to match standard embedded debugger aesthetics
            obj.Fig = uifigure('Name', sprintf('Memory <%s> - PLS UDE Inspector', obj.Mcu.Target), ...
                'Position', [150 150 960 520], 'Color', [0.94 0.94 0.94], ...
                'CloseRequestFcn', @(s,e) obj.onClose());

            % Navigation Toolbar Panel
            navPanel = uipanel(obj.Fig, 'Position', [10 465 940 48], ...
                'BackgroundColor', [0.88 0.88 0.90], 'BorderType', 'line');

            uilabel(navPanel, 'Text', 'Address:', 'Position', [10 12 55 22], ...
                'FontWeight', 'bold', 'FontSize', 12);
            obj.AddrEditField = uieditfield(navPanel, 'text', ...
                'Value', sprintf('0x%08X', obj.StartAddr), ...
                'Position', [70 11 110 24], 'FontName', 'Consolas', ...
                'ValueChangedFcn', @(s,e) obj.onAddrEntered());

            uibutton(navPanel, 'Text', 'Read', 'Position', [185 11 60 24], ...
                'ButtonPushedFcn', @(s,e) obj.refreshMemory());

            obj.AutoPollCheckbox = uicheckbox(navPanel, 'Text', 'Live Poll (5 Hz)', ...
                'Position', [255 12 110 22], 'Value', false, ...
                'ValueChangedFcn', @(s,e) obj.togglePolling());

            % Address Jump Bookmarks
            uibutton(navPanel, 'Text', 'GPIO SFRs', 'Position', [380 11 85 24], ...
                'ButtonPushedFcn', @(s,e) obj.jumpTo(hex2dec('3FF44000')));
            uibutton(navPanel, 'Text', 'DRAM Buffer', 'Position', [470 11 95 24], ...
                'ButtonPushedFcn', @(s,e) obj.jumpTo(obj.Mcu.DramAddr));
            uibutton(navPanel, 'Text', 'IRAM Exec', 'Position', [570 11 85 24], ...
                'ButtonPushedFcn', @(s,e) obj.jumpTo(obj.Mcu.IramAddr));

            % Write Commit Button for Pending Edits
            uibutton(navPanel, 'Text', 'Apply Changes', 'Position', [810 11 115 25], ...
                'BackgroundColor', [0.12 0.45 0.75], 'FontColor', 'w', ...
                'FontWeight', 'bold', 'ButtonPushedFcn', @(s,e) obj.commitPendingWrites());

            % Main Memory Display Table (UDE Exact Column Presentation)
            colNames = {'Address', '+00 (Word 0)', '+04 (Word 1)', '+08 (Word 2)', '+0C (Word 3)', 'ASCII Dump'};
            obj.Table = uitable(obj.Fig, 'Position', [10 40 940 415], ...
                'ColumnName', colNames, ...
                'ColumnWidth', {110, 120, 120, 120, 120, 310}, ...
                'ColumnEditable', [false true true true true false], ...
                'FontName', 'Consolas', 'FontSize', 12, ...
                'RowName', [], ...
                'CellEditCallback', @(s,e) obj.onCellEdited(e));

            % Status Bar
            obj.StatusLabel = uilabel(obj.Fig, 'Position', [15 10 930 20], ...
                'Text', 'Ready. Double-click any Hex word to edit. Changed cells turn Blue until committed.', ...
                'FontName', 'Segoe UI', 'FontSize', 11, 'FontColor', [0.2 0.2 0.2]);

            % Auto-refresh timer
            obj.RefreshTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.2, ...
                'TimerFcn', @(~,~) obj.refreshMemory());
        end

        function jumpTo(obj, targetAddr)
            if targetAddr == 0, return; end
            obj.StartAddr = uint32(targetAddr);
            obj.AddrEditField.Value = sprintf('0x%08X', obj.StartAddr);
            obj.PrevWords = zeros(1, obj.NumRows * 4, 'uint32');
            obj.PendingWrites.remove(keys(obj.PendingWrites));
            obj.refreshMemory();
        end

        function onAddrEntered(obj)
            cleanHex = erase(upper(strtrim(string(obj.AddrEditField.Value))), "0X");
            val = hex2dec(cleanHex);
            if ~isnan(val)
                obj.jumpTo(val);
            end
        end

        function refreshMemory(obj)
            if ~isvalid(obj.Fig), return; end
            totalWords = obj.NumRows * 4;
            words = obj.Mcu.readBlock32(obj.StartAddr, totalWords);
            if numel(words) < totalWords
                return;
            end

            data = cell(obj.NumRows, 6);
            removeStyle(obj.Table);

            % UDE standard styles: Blue = Pending/User-Modified; Amber = Live MCU Hardware Update
            pendingStyle = uistyle('BackgroundColor', [0.75 0.88 1.0], 'FontColor', [0.0 0.2 0.6], 'FontWeight', 'bold');
            liveChangedStyle = uistyle('BackgroundColor', [1.0 0.93 0.70], 'FontWeight', 'bold');

            for r = 1:obj.NumRows
                rowBase = obj.StartAddr + uint32((r - 1) * 16);
                data{r, 1} = sprintf('0x%08X', rowBase);
                rowWords = words((r-1)*4 + (1:4));

                for c = 1:4
                    wordAddr = rowBase + uint32((c - 1) * 4);
                    key = sprintf('%08X', wordAddr);

                    if isKey(obj.PendingWrites, key)
                        data{r, c + 1} = sprintf('%08X', obj.PendingWrites(key));
                        addStyle(obj.Table, pendingStyle, 'cell', [r, c + 1]);
                    else
                        data{r, c + 1} = sprintf('%08X', rowWords(c));
                        idx = (r - 1) * 4 + c;
                        if any(obj.PrevWords ~= 0) && rowWords(c) ~= obj.PrevWords(idx)
                            addStyle(obj.Table, liveChangedStyle, 'cell', [r, c + 1]);
                        end
                    end
                end

                % Replicate PLS UDE ASCII right-pane dump
                bytes = typecast(rowWords, 'uint8');
                asciiChars = char(bytes);
                asciiChars(bytes < 32 | bytes > 126) = '.';
                data{r, 6} = asciiChars;
            end

            obj.Table.Data = data;
            obj.PrevWords = words;
        end

        function onCellEdited(obj, event)
            r = event.Indices(1);
            c = event.Indices(2);
            if c < 2 || c > 5, return; end

            wordOffset = ((r - 1) * 4 + (c - 2)) * 4;
            targetAddr = obj.StartAddr + uint32(wordOffset);
            cleanHex = erase(upper(strtrim(string(event.NewData))), "0X");
            newVal = uint32(hex2dec(cleanHex));

            key = sprintf('%08X', targetAddr);
            obj.PendingWrites(key) = newVal;
            obj.StatusLabel.Text = sprintf('Queued write: [0x%08X] = 0x%08X (Click Apply Changes to write)', targetAddr, newVal);
            obj.refreshMemory();
        end

        function commitPendingWrites(obj)
            k = keys(obj.PendingWrites);
            if isempty(k)
                obj.StatusLabel.Text = 'No pending modifications to commit.';
                return;
            end
            for i = 1:numel(k)
                addr = uint32(hex2dec(k{i}));
                val = obj.PendingWrites(k{i});
                obj.Mcu.write32(addr, val);
            end
            obj.PendingWrites.remove(k);
            obj.StatusLabel.Text = sprintf('Successfully committed %d register/RAM location(s) to hardware.', numel(k));
            obj.refreshMemory();
        end

        function togglePolling(obj)
            if obj.AutoPollCheckbox.Value
                start(obj.RefreshTimer);
                obj.StatusLabel.Text = 'Real-time live memory polling active (5 Hz)...';
            else
                stop(obj.RefreshTimer);
                obj.StatusLabel.Text = 'Live polling paused.';
            end
        end

        function onClose(obj)
            if ~isempty(obj.RefreshTimer) && isvalid(obj.RefreshTimer)
                stop(obj.RefreshTimer);
                delete(obj.RefreshTimer);
            end
            delete(obj.Fig);
        end
    end
end