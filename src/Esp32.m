classdef Esp32 < dynamicprops
    % Esp32 High-performance Hardware Controller, SFR Bridge, and Code Patcher
    properties (SetAccess = private)
        Target string
        Mode string
        RegisterList string
        IramAddr uint32 = 0
        DramAddr uint32 = 0
        WifiIP string = ""
    end

    properties (Access = private)
        ConnObj
        RegDefs struct
        Cache containers.Map
        SimMem containers.Map
    end

    methods
        function obj = Esp32(target, sfrJsonPath)
            arguments
                target string = "auto"
                sfrJsonPath string = "databases/esp32_sfr.json"
            end
            if target == "auto"
                target = Esp32.detectPort();
            end
            obj.Target = target;
            obj.Cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            obj.SimMem = containers.Map('KeyType', 'uint64', 'ValueType', 'uint32');

            if ~isfile(sfrJsonPath)
                buildSfrDatabase(sfrJsonPath);
            end
            rawJson = jsondecode(fileread(sfrJsonPath));
            obj.RegDefs = rawJson.registers;
            obj.RegisterList = string(fieldnames(obj.RegDefs))';

            for regName = obj.RegisterList
                p = obj.addprop(regName);
                p.GetMethod = @(o) o.sfr(regName);
            end

            if lower(target) == "sim"
                obj.Mode = "sim";
                obj.IramAddr = uint32(hex2dec('40080000'));
                obj.DramAddr = uint32(hex2dec('3FFB0000'));
                fprintf('[Esp32] Simulation mode active.\n');
            elseif startsWith(upper(target), "COM")
                obj.Mode = "serial";
                obj.ConnObj = serialport(target, 115200, "Timeout", 8);
                configureTerminator(obj.ConnObj, "CR/LF");
                pause(2.0);
                flush(obj.ConnObj);
                obj.queryBoardInfo();
                fprintf('[Esp32] Connected on %s | IRAM=0x%08X | DRAM=0x%08X | WiFi=%s\n', ...
                    target, obj.IramAddr, obj.DramAddr, obj.WifiIP);
            else
                obj.Mode = "wifi";
                parts = split(target, ":");
                ip = parts(1);
                port = 3333;
                if numel(parts) > 1, port = str2double(parts(2)); end
                obj.ConnObj = tcpclient(ip, port, "Timeout", 8);
                configureTerminator(obj.ConnObj, "LF");
                flush(obj.ConnObj);
                obj.queryBoardInfo();
                fprintf('[Esp32] Connected via WiFi TCP (%s:%d)\n', ip, port);
            end
        end

        function queryBoardInfo(obj)
            infoStr = obj.cmd("INFO");
            tok = regexp(infoStr, 'IRAM=0x([0-9A-Fa-f]+)\s+DRAM=0x([0-9A-Fa-f]+)\s+IP=(\S+)', 'tokens', 'once');
            if ~isempty(tok)
                obj.IramAddr = uint32(hex2dec(tok{1}));
                obj.DramAddr = uint32(hex2dec(tok{2}));
                obj.WifiIP   = string(tok{3});
            end
        end

        function regObj = sfr(obj, regName)
            key = char(regName);
            if ~isKey(obj.Cache, key)
                obj.Cache(key) = SFR(key, obj.RegDefs.(key), obj);
            end
            regObj = obj.Cache(key);
        end

        function resp = cmd(obj, text)
            if obj.Mode == "sim"
                if startsWith(text, "BLE_STATUS")
                    resp = "MAC=A4:C1:38:57:3C:99 RSSI=-55 PID=0x3BD5 CNT=67 RX=4 DEC=1 PROF=1 W=74.80 HR=71 IMP50=548.2 IMP250=489.5 PACKED=0x892A52EC RAW=4859D53B43A1B2C3D4E5F6010203040506010000AA55AA55";
                else
                    resp = "OK";
                end
                return;
            end
            flush(obj.ConnObj);
            writeline(obj.ConnObj, text);
            resp = strtrim(readline(obj.ConnObj));
        end

        function val = read32(obj, addr)
            if obj.Mode == "sim"
                k = uint64(addr);
                val = uint32(0);
                if isKey(obj.SimMem, k), val = obj.SimMem(k); end
                return;
            end
            resp = obj.cmd(sprintf("R %08X", uint32(addr)));
            val = uint32(hex2dec(resp));
        end

        function words = readBlock32(obj, startAddr, count)
            if obj.Mode == "sim"
                words = zeros(1, count, 'uint32');
                for i = 1:count
                    words(i) = obj.read32(uint32(startAddr) + uint32((i - 1) * 4));
                end
                return;
            end
            resp = obj.cmd(sprintf("RB %08X %X", uint32(startAddr), uint32(count)));
            hexParts = split(strtrim(resp));
            words = uint32(hex2dec(hexParts))';
        end

        function write32(obj, addr, val)
            v32 = uint32(bitand(uint64(val), uint64(hex2dec('FFFFFFFF'))));
            if obj.Mode == "sim"
                obj.SimMem(uint64(addr)) = v32;
                return;
            end
            ack = obj.cmd(sprintf("W %08X %08X", uint32(addr), v32));
            assert(ack == "OK", "Write failed at 0x%08X: %s", addr, ack);
        end

        function retVal = execIRAM(obj, addr)
            if nargin < 2, addr = obj.IramAddr; end
            if obj.Mode == "sim"
                retVal = uint32(1337);
                return;
            end
            resp = obj.cmd(sprintf("EXEC %08X", uint32(addr)));
            tok = regexp(resp, 'EXEC_RET=0x([0-9A-Fa-f]+)', 'tokens', 'once');
            if isempty(tok)
                error("Esp32:ExecError", "Unexpected EXEC response: %s", resp);
            end
            retVal = uint32(hex2dec(tok{1}));
        end

        function retVal = patchAndExecGPIO2Toggle(obj, returnConstant)
            arguments
                obj
                returnConstant uint32 = 99
            end
            imm = bitand(uint32(returnConstant), 2047);
            movi_b0 = uint32(hex2dec('22'));
            movi_b1 = bitor(uint32(hex2dec('A0')), bitand(bitshift(imm, -8), 15));
            movi_b2 = bitand(imm, 255);

            word0 = bitor(uint32(hex2dec('00004136')), bitshift(movi_b0, 24));
            word1 = bitor(movi_b1, bitor(bitshift(movi_b2, 8), uint32(hex2dec('F01D0000'))));

            obj.write32(obj.IramAddr, word0);
            obj.write32(obj.IramAddr + 4, word1);

            obj.GPIO_ENABLE_REG.GPIO2 = 1;
            obj.GPIO_OUT_REG.GPIO2 = double(~obj.GPIO_OUT_REG.GPIO2);
            retVal = obj.execIRAM(obj.IramAddr);
        end

        function otaUploadBin(obj, binFilePath)
            assert(isfile(binFilePath), "Binary file not found: %s", binFilePath);
            fid = fopen(binFilePath, 'rb');
            rawBytes = fread(fid, inf, '*uint8');
            fclose(fid);

            fwSize = numel(rawBytes);
            fprintf('[OTA] Streaming %d bytes to OTA partition...\n', fwSize);
            resp = obj.cmd(sprintf("OTA %X", fwSize));
            assert(resp == "READY_FOR_BIN", "Target rejected OTA stream: %s", resp);

            write(obj.ConnObj, rawBytes, "uint8");
            pause(1.0);
            finalResp = strtrim(readline(obj.ConnObj));
            fprintf('[OTA] Bootloader response: %s\n', finalResp);
        end

        function ui = openMemoryViewer(obj, startAddr)
            if nargin < 2
                if obj.DramAddr ~= 0
                    startAddr = obj.DramAddr;
                else
                    startAddr = uint32(hex2dec('3FF44000'));
                end
            end
            ui = UDEMemoryViewer(obj, startAddr);
        end

        function scaleObj = connectXiaomiScale(obj, csvLogPath)
            if nargin < 2
                csvLogPath = "databases/xiaomi_s400_history.csv";
            end
            scaleObj = XiaomiScaleS400(obj, csvLogPath);
        end

        function delete(obj)
            if ~isempty(obj.ConnObj)
                clear obj.ConnObj;
            end
        end
    end

    methods (Static)
        function port = detectPort()
            ports = serialportlist("available");
            usbCandidates = ports(~ismember(ports, ["COM3", "COM5", "COM6"]));
            if ~isempty(usbCandidates)
                port = usbCandidates(1);
            elseif ~isempty(ports)
                port = ports(1);
            else
                warning("No USB serial port detected; falling back to simulation mode.");
                port = "sim";
            end
        end

        function port = flashAndConnect()
            inoFiles = dir(fullfile('firmware', 'agv_matlab_bridge', '*.ino'));
            for k = 1:numel(inoFiles)
                if ~strcmpi(inoFiles(k).name, 'agv_matlab_bridge.ino')
                    delete(fullfile(inoFiles(k).folder, inoFiles(k).name));
                end
            end

            [st, jsonOut] = system('arduino-cli board list --format json');
            port = "";
            if st == 0
                try
                    data = jsondecode(jsonOut);
                    for k = 1:numel(data.detected_ports)
                        p = data.detected_ports(k).port;
                        if contains(string(p.protocol_label), "USB") && p.address ~= "COM3"
                            port = string(p.address);
                            break;
                        end
                    end
                catch
                end
            end
            if port == ""
                port = Esp32.detectPort();
            end

            fprintf('[Flash] Compiling BLE+WiFi+UDE firmware (min_spiffs partition) and uploading to %s...\n', port);
            buildProps = '--build-property build.partitions=min_spiffs --build-property upload.maximum_size=1966080';
            cmdStr = sprintf('arduino-cli compile --fqbn esp32:esp32:esp32 %s firmware/agv_matlab_bridge && arduino-cli upload -p %s --fqbn esp32:esp32:esp32 firmware/agv_matlab_bridge', buildProps, port);
            [status, cmdOut] = system(cmdStr);
            if status ~= 0
                error("Flash failed on %s:\n%s", port, cmdOut);
            end
            fprintf('[Flash] Firmware successfully flashed on %s!\n', port);
        end
    end
end