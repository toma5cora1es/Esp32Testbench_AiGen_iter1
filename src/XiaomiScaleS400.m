classdef XiaomiScaleS400 < handle
    % XiaomiScaleS400 BLE MiBeacon v5 Controller & Dual-Frequency BIA Calculator
    % Supports Xiaomi Body Composition Scale S400 (Model MJTZC01YM / PID 0x3BD5)
    properties
        Mcu Esp32
        CsvPath string
        UserHeightCm double = 178
        UserAge double = 24
        UserSex string = "male" % "male" or "female"
        BindKey string = "1E67663E21E07BB5A50D88AD0AE47570"
        LastRxCount uint32 = 0
    end

    methods
        function obj = XiaomiScaleS400(mcu, csvPath)
            arguments
                mcu Esp32
                csvPath string = "databases/xiaomi_s400_history.csv"
            end
            obj.Mcu = mcu;
            obj.CsvPath = csvPath;
            obj.initCsvFile();
        end

        function initCsvFile(obj)
            if ~isfile(obj.CsvPath)
                folder = fileparts(obj.CsvPath);
                if folder ~= "" && ~isfolder(folder)
                    mkdir(folder);
                end
                fid = fopen(obj.CsvPath, 'w');
                fprintf(fid, 'Timestamp,MAC,ProductID,ProfileID,Weight_kg,HeartRate_bpm,Imp50kHz_Ohm,Imp250kHz_Ohm,BMI,BodyFat_Pct,MuscleMass_kg,TotalWater_Pct,ECW_Pct,ICW_Pct,BoneMass_kg,VisceralFat,BMR_kcal,MetabolicAge\n');
                fclose(fid);
            end
        end

        function setBindKey(obj, hexKey32)
            cleanKey = upper(erase(strtrim(string(hexKey32)), ["0X", " ", ":", "-"]));
            assert(strlength(cleanKey) == 32, "Xiaomi S400 Bindkey must be exactly 32 hexadecimal characters (16 bytes).");
            obj.BindKey = cleanKey;
            resp = obj.Mcu.cmd("BLE_KEY " + cleanKey);
            fprintf('[XiaomiScaleS400] Set AES-CCM Bindkey response: %s\n', resp);
        end

        function triggerSimulatedWeighIn(obj)
            % Instructs the ESP32 to encrypt & decrypt a realistic S400 MiBeacon v5 dual-packet weigh-in
            obj.Mcu.cmd("BLE_SIM");
        end

        function data = pollTelemetry(obj)
            rawLine = obj.Mcu.cmd("BLE_STATUS");
            tok = regexp(rawLine, ...
                'MAC=(\S+)\s+RSSI=(-?\d+)\s+PID=0x([0-9A-Fa-f]+)\s+CNT=(\d+)\s+RX=(\d+)\s+DEC=(\d+)\s+PROF=(\d+)\s+W=([\d\.]+)\s+HR=(\d+)\s+IMP50=([\d\.]+)\s+IMP250=([\d\.]+)\s+PACKED=0x([0-9A-Fa-f]+)\s+RAW=(\S+)', ...
                'tokens', 'once');

            if isempty(tok)
                error("XiaomiScaleS400:ParseError", "Unexpected BLE_STATUS format: %s", rawLine);
            end

            data = struct();
            data.Timestamp        = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
            data.MAC              = string(tok{1});
            data.RSSI             = str2double(tok{2});
            data.ProductID        = "0x" + upper(string(tok{3}));
            data.FrameCounter     = uint8(str2double(tok{4}));
            data.RxCount          = uint32(str2double(tok{5}));
            data.DecryptedOK      = logical(str2double(tok{6}));
            data.ProfileID        = uint8(str2double(tok{7}));
            data.WeightKg         = str2double(tok{8});
            data.HeartRateBpm     = str2double(tok{9});
            data.Impedance50kHz   = str2double(tok{10});
            data.Impedance250kHz  = str2double(tok{11});
            data.PackedU32        = uint32(hex2dec(tok{12}));
            data.RawMiBeaconHex   = string(tok{13});

            % Bitfield breakdown of PackedU32 (Object 0x6E16)
            data.Bitfield_WeightRaw = bitand(data.PackedU32, uint32(2047));
            data.Bitfield_HrRaw     = bitand(bitshift(data.PackedU32, -11), uint32(127));
            data.Bitfield_ImpRaw    = bitand(bitshift(data.PackedU32, -18), uint32(16383));

            % Compute Dual-Frequency BIA Body Composition
            data.BIA = obj.computeDualFrequencyBIA(data.WeightKg, data.Impedance50kHz, data.Impedance250kHz);

            % Auto-append to CSV when a new decrypted weigh-in arrives
            if data.DecryptedOK && data.WeightKg > 10 && data.RxCount > obj.LastRxCount
                obj.LastRxCount = data.RxCount;
                obj.appendToCsv(data);
            end
        end

        function bia = computeDualFrequencyBIA(obj, weightKg, imp50, imp250)
            bia = struct('BMI', 0, 'BodyFatPct', 0, 'MuscleMassKg', 0, ...
                         'WaterPct', 0, 'ECWPct', 0, 'ICWPct', 0, ...
                         'BoneMassKg', 0, 'VisceralFat', 0, 'BMR', 0, 'MetabolicAge', 0);
            if weightKg <= 0
                return;
            end

            hM = obj.UserHeightCm / 100.0;
            bia.BMI = weightKg / (hM ^ 2);

            isMale = strcmpi(obj.UserSex, "male");
            effImp = imp50;
            if effImp <= 0, effImp = 500; end
            if imp250 <= 0, imp250 = effImp * 0.89; end

            % Lean Body Mass (LBM) taking advantage of 50 kHz / 250 kHz intracellular/extracellular ratio
            freqRatio = imp250 / effImp;
            lbm = (obj.UserHeightCm ^ 2 / effImp) * 0.401 + (weightKg * 0.382) + (1.0 - freqRatio) * 18.5;
            if isMale
                lbm = lbm + 5.4 - (obj.UserAge * 0.07);
            else
                lbm = lbm - 1.8 - (obj.UserAge * 0.05);
            end
            lbm = min(max(lbm, weightKg * 0.55), weightKg * 0.94);

            fatMass = max(weightKg - lbm, weightKg * 0.05);
            bia.BodyFatPct   = (fatMass / weightKg) * 100.0;
            bia.BoneMassKg   = max(1.8, lbm * 0.048);
            bia.MuscleMassKg = lbm - bia.BoneMassKg;
            bia.WaterPct     = (lbm * 0.732 / weightKg) * 100.0;

            % Dual-frequency split: 50 kHz measures ECW; 250 kHz penetrates cell membranes (ECW + ICW)
            bia.ECWPct = bia.WaterPct * (0.38 * freqRatio / 0.89);
            bia.ICWPct = max(0, bia.WaterPct - bia.ECWPct);

            if isMale
                bia.BMR = round(88.36 + (13.4 * weightKg) + (4.8 * obj.UserHeightCm) - (5.7 * obj.UserAge));
            else
                bia.BMR = round(447.6 + (9.2 * weightKg) + (3.1 * obj.UserHeightCm) - (4.3 * obj.UserAge));
            end

            bia.VisceralFat  = max(1, round((bia.BMI * 0.45) + (obj.UserAge * 0.12) - (isMale * 2.5 + 4.0)));
            bia.MetabolicAge = max(16, round(obj.UserAge + (bia.BodyFatPct - (isMale * 16 + (~isMale) * 23)) * 0.6));
        end

        function appendToCsv(obj, d)
            fid = fopen(obj.CsvPath, 'a');
            b = d.BIA;
            fprintf(fid, '%s,%s,%s,%u,%.2f,%u,%.1f,%.1f,%.2f,%.1f,%.2f,%.1f,%.1f,%.1f,%.2f,%d,%d,%d\n', ...
                d.Timestamp, d.MAC, d.ProductID, d.ProfileID, d.WeightKg, d.HeartRateBpm, ...
                d.Impedance50kHz, d.Impedance250kHz, b.BMI, b.BodyFatPct, b.MuscleMassKg, ...
                b.WaterPct, b.ECWPct, b.ICWPct, b.BoneMassKg, b.VisceralFat, b.BMR, b.MetabolicAge);
            fclose(fid);
            fprintf('[CSV Logger] Saved S400 weigh-in (%.2f kg) to %s\n', d.WeightKg, obj.CsvPath);
        end

        function ui = openViewer(obj)
            ui = XiaomiScaleViewer(obj);
        end
    end
end