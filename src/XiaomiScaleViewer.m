classdef XiaomiScaleViewer < handle
    % XiaomiScaleViewer Real-Time BLE MiBeacon Inspector & Dual-Frequency BIA Dashboard
    properties
        Scale XiaomiScaleS400
        Fig
        KeyField
        HeightField
        AgeField
        SexDrop
        MacLbl
        FrameLbl
        BitfieldTable
        BiaTable
        WeightBigLbl
        HrBigLbl
        Imp50BigLbl
        Imp250BigLbl
        StatusLbl
        PollCheck
        PollTimer timer
    end

    methods
        function obj = XiaomiScaleViewer(scaleObj)
            obj.Scale = scaleObj;
            obj.buildUI();
            obj.refreshDashboard();
        end

        function buildUI(obj)
            obj.Fig = uifigure('Name', 'Xiaomi Body Composition Scale S400 (0x3BD5) - BLE MiBeacon & BIA Workbench', ...
                'Position', [180 120 960 560], 'Color', [0.11 0.12 0.15], ...
                'CloseRequestFcn', @(s,e) obj.onClose());

            % Top Configuration Bar (Bindkey + User Profile + Sim Trigger)
            topPanel = uipanel(obj.Fig, 'Title', '1. Xiaomi S400 AES-CCM Decryption Key & User Profile', ...
                'Position', [15 470 930 78], 'BackgroundColor', [0.16 0.17 0.21], 'ForegroundColor', 'w', 'FontWeight', 'bold');

            uilabel(topPanel, 'Text', 'Bindkey (16B):', 'Position', [10 28 85 22], 'FontColor', 'w');
            obj.KeyField = uieditfield(topPanel, 'text', 'Value', obj.Scale.BindKey, ...
                'Position', [95 28 250 24], 'FontName', 'Consolas');
            uibutton(topPanel, 'Text', 'Set Key', 'Position', [352 28 65 24], ...
                'ButtonPushedFcn', @(s,e) obj.onSetKey());

            uilabel(topPanel, 'Text', 'Height(cm):', 'Position', [430 28 70 22], 'FontColor', 'w');
            obj.HeightField = uieditfield(topPanel, 'numeric', 'Value', obj.Scale.UserHeightCm, ...
                'Position', [500 28 50 24], 'ValueChangedFcn', @(s,e) obj.onProfileChange());

            uilabel(topPanel, 'Text', 'Age:', 'Position', [560 28 30 22], 'FontColor', 'w');
            obj.AgeField = uieditfield(topPanel, 'numeric', 'Value', obj.Scale.UserAge, ...
                'Position', [590 28 45 24], 'ValueChangedFcn', @(s,e) obj.onProfileChange());

            obj.SexDrop = uidropdown(topPanel, 'Items', {'male', 'female'}, 'Value', obj.Scale.UserSex, ...
                'Position', [645 28 70 24], 'ValueChangedFcn', @(s,e) obj.onProfileChange());

            uibutton(topPanel, 'Text', 'Simulate S400 Weigh-In (Hardware AES-CCM)', ...
                'Position', [725 26 195 28], 'BackgroundColor', [0.0 0.55 0.40], 'FontColor', 'w', ...
                'FontWeight', 'bold', 'ButtonPushedFcn', @(s,e) obj.onSimulate());

            % Primary Metric Cards
            cardPanel = uipanel(obj.Fig, 'Title', '2. Live Decrypted Primary Biometrics (Object 0x6E16)', ...
                'Position', [15 355 930 105], 'BackgroundColor', [0.14 0.15 0.18], 'ForegroundColor', [0.4 0.85 1.0], 'FontWeight', 'bold');

            obj.WeightBigLbl = uilabel(cardPanel, 'Text', '0.0 kg', 'Position', [25 18 200 60], ...
                'FontSize', 30, 'FontWeight', 'bold', 'FontColor', [0.3 1.0 0.5]);
            obj.HrBigLbl = uilabel(cardPanel, 'Text', '-- bpm', 'Position', [250 18 200 60], ...
                'FontSize', 26, 'FontWeight', 'bold', 'FontColor', [1.0 0.45 0.45]);
            obj.Imp50BigLbl = uilabel(cardPanel, 'Text', '50kHz: -- Ohm', 'Position', [460 18 220 60], ...
                'FontSize', 20, 'FontWeight', 'bold', 'FontColor', [1.0 0.85 0.35]);
            obj.Imp250BigLbl = uilabel(cardPanel, 'Text', '250kHz: -- Ohm', 'Position', [700 18 220 60], ...
                'FontSize', 20, 'FontWeight', 'bold', 'FontColor', [0.55 0.80 1.0]);

            % Raw MiBeacon Packet & Bitfield Inspector
            pktPanel = uipanel(obj.Fig, 'Title', '3. BLE Service 0xFE95 Frame & 32-Bit Packed Bitfield Breakdown', ...
                'Position', [15 195 930 150], 'BackgroundColor', [0.16 0.17 0.21], 'ForegroundColor', 'w', 'FontWeight', 'bold');

            obj.MacLbl = uilabel(pktPanel, 'Text', 'MAC: -- | RSSI: -- dBm | Product ID: 0x3BD5 | Frame Counter: 0', ...
                'Position', [12 102 900 22], 'FontColor', [0.8 0.9 1.0], 'FontName', 'Consolas', 'FontSize', 12);
            obj.FrameLbl = uilabel(pktPanel, 'Text', 'Raw 0xFE95 (24B): --', ...
                'Position', [12 78 900 22], 'FontColor', [1.0 0.85 0.4], 'FontName', 'Consolas', 'FontSize', 12);

            obj.BitfieldTable = uitable(pktPanel, 'Position', [12 8 905 66], ...
                'ColumnName', {'32-Bit Packed Hex', 'Bits [10:0] Weight*10', 'Bits [17:11] (HR-50)', 'Bits [31:18] Imp*10', 'Profile Slot', 'AES-CCM Auth'}, ...
                'ColumnWidth', {140, 150, 150, 150, 120, 150}, ...
                'RowName', [], 'FontName', 'Consolas', 'FontSize', 12);

            % Dual-Frequency BIA Body Composition Table
            biaPanel = uipanel(obj.Fig, 'Title', '4. Dual-Frequency BIA Body Composition (Auto-Saved to CSV)', ...
                'Position', [15 45 930 140], 'BackgroundColor', [0.16 0.17 0.21], 'ForegroundColor', 'w', 'FontWeight', 'bold');

            obj.BiaTable = uitable(biaPanel, 'Position', [12 10 905 102], ...
                'ColumnName', {'BMI', 'Body Fat %', 'Muscle (kg)', 'Total Water %', 'ECW (50kHz) %', 'ICW (250kHz) %', 'Bone (kg)', 'Visceral Fat', 'BMR (kcal)', 'Metabolic Age'}, ...
                'ColumnWidth', {75, 90, 95, 100, 105, 105, 80, 85, 85, 95}, ...
                'RowName', [], 'FontName', 'Consolas', 'FontSize', 12);

            % Footer Controls
            obj.PollCheck = uicheckbox(obj.Fig, 'Text', 'Live BLE Poll (1 Hz)', 'Value', true, ...
                'Position', [20 12 140 24], 'FontColor', [0.4 1.0 0.4], ...
                'ValueChangedFcn', @(s,e) obj.togglePoll());

            uibutton(obj.Fig, 'Text', 'Open CSV Log in MATLAB', 'Position', [170 12 160 24], ...
                'ButtonPushedFcn', @(s,e) edit(obj.Scale.CsvPath));

            obj.StatusLbl = uilabel(obj.Fig, 'Text', sprintf('Logging weigh-ins to: %s', obj.Scale.CsvPath), ...
                'Position', [350 12 580 24], 'FontColor', [0.75 0.82 0.90], 'FontName', 'Consolas');

            obj.PollTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', 1.0, ...
                'TimerFcn', @(~,~) obj.refreshDashboard());
            start(obj.PollTimer);
        end

        function onSetKey(obj)
            obj.Scale.setBindKey(obj.KeyField.Value);
            obj.StatusLbl.Text = 'Updated 16-byte AES-CCM Bindkey on ESP32.';
        end

        function onProfileChange(obj)
            obj.Scale.UserHeightCm = obj.HeightField.Value;
            obj.Scale.UserAge      = obj.AgeField.Value;
            obj.Scale.UserSex      = string(obj.SexDrop.Value);
            obj.refreshDashboard();
        end

        function onSimulate(obj)
            obj.Scale.triggerSimulatedWeighIn();
            obj.refreshDashboard();
            obj.StatusLbl.Text = 'Injected & decrypted S400 MiBeacon v5 test frame on ESP32 + updated DRAM buffer!';
        end

        function refreshDashboard(obj)
            if ~isvalid(obj.Fig), return; end
            try
                d = obj.Scale.pollTelemetry();
            catch
                return;
            end

            obj.WeightBigLbl.Text = sprintf('%.1f kg', d.WeightKg);
            obj.HrBigLbl.Text     = sprintf('%d bpm', d.HeartRateBpm);
            obj.Imp50BigLbl.Text  = sprintf('50kHz: %.1f Ω', d.Impedance50kHz);
            obj.Imp250BigLbl.Text = sprintf('250kHz: %.1f Ω', d.Impedance250kHz);

            obj.MacLbl.Text = sprintf('MAC: %s | RSSI: %d dBm | Product ID: %s | Frame Counter: %u | Packets Rx: %u', ...
                d.MAC, d.RSSI, d.ProductID, d.FrameCounter, d.RxCount);
            obj.FrameLbl.Text = sprintf('Raw 0xFE95 (24B): %s', d.RawMiBeaconHex);

            authStr = "WAITING / LOCKED";
            if d.DecryptedOK, authStr = "AES-CCM OK (0x6E16)"; end

            obj.BitfieldTable.Data = { ...
                sprintf('0x%08X', d.PackedU32), ...
                sprintf('%u (%.1f kg)', d.Bitfield_WeightRaw, d.WeightKg), ...
                sprintf('%u (+50 = %u bpm)', d.Bitfield_HrRaw, d.HeartRateBpm), ...
                sprintf('%u (%.1f Ω)', d.Bitfield_ImpRaw, double(d.Bitfield_ImpRaw)*0.1), ...
                sprintf('User %u', d.ProfileID), ...
                char(authStr) ...
            };

            b = d.BIA;
            obj.BiaTable.Data = { ...
                sprintf('%.1f', b.BMI), ...
                sprintf('%.1f %%', b.BodyFatPct), ...
                sprintf('%.2f kg', b.MuscleMassKg), ...
                sprintf('%.1f %%', b.WaterPct), ...
                sprintf('%.1f %%', b.ECWPct), ...
                sprintf('%.1f %%', b.ICWPct), ...
                sprintf('%.2f kg', b.BoneMassKg), ...
                sprintf('%d', b.VisceralFat), ...
                sprintf('%d kcal', b.BMR), ...
                sprintf('%d yrs', b.MetabolicAge) ...
            };
        end

        function togglePoll(obj)
            if obj.PollCheck.Value
                start(obj.PollTimer);
            else
                stop(obj.PollTimer);
            end
        end

        function onClose(obj)
            if ~isempty(obj.PollTimer) && isvalid(obj.PollTimer)
                stop(obj.PollTimer);
                delete(obj.PollTimer);
            end
            delete(obj.Fig);
        end
    end
end