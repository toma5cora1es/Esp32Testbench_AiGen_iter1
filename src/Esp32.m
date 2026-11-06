classdef Esp32 < dynamicprops
    % Esp32  Link to the ESP32 bridge firmware + register/bitfield access (Reg.GPIO_OUT_REG.GPIO2 = 1).
    %
    %   Responsibilities of THIS class:   talk to the chip (serial, WiFi TCP or simulation),
    %                                     read/write memory, call code in the IRAM sandbox.
    %   NOT here any more:                windows        -> +ude/Workbench and friends
    %                                     USB flashing   -> ude.FirmwareBuilder
    %                                     WiFi flashing  -> ude.OtaUploader
    %
    %   Esp32("COM8") | Esp32("192.168.4.1") | Esp32("sim") | Esp32("auto")

    properties (Constant)
        MaxBlockWords = 64        % words per RB request (the firmware accepts up to 128)
    end

    properties (SetAccess = private)
        Target string = ""
        Mode string = ""
        RegisterList string
        Info struct = struct()
        IramAddr uint32 = 0       % 256-byte executable buffer (MALLOC_CAP_EXEC)
        DramAddr uint32 = 0       % dram_test_buf[16]
        WifiIP string = ""
    end

    properties (Access = private)
        ConnObj = []
        RegDefs struct
        Cache
        SimMem
        Busy logical = false
    end

    methods
        function obj = Esp32(target, sfrJsonPath)
            arguments
                target string = "auto"
                sfrJsonPath string = ""
            end
            warning('off', 'serialport:serialport:ReadWarning');   % we poll with short timeouts on purpose
            warning('off', 'transportlib:client:ReadWarning');

            if target == "auto", target = Esp32.detectPort(); end
            obj.Target = target;
            obj.Cache  = containers.Map('KeyType', 'char',   'ValueType', 'any');
            obj.SimMem = containers.Map('KeyType', 'double', 'ValueType', 'any');

            if sfrJsonPath == "", sfrJsonPath = string(ude.Config.sfrJson()); end
            if ~isfile(sfrJsonPath), buildSfrDatabase(sfrJsonPath); end
            raw = jsondecode(fileread(sfrJsonPath));
            obj.RegDefs = raw.registers;
            obj.RegisterList = string(fieldnames(obj.RegDefs))';
            for regName = obj.RegisterList
                p = obj.addprop(regName);
                p.GetMethod = @(o) o.sfr(regName);
            end

            if lower(target) == "sim"
                obj.Mode = "sim";
                obj.refreshInfo();
                fprintf('[Esp32] Simulation mode active.\n');
            else
                obj.openLink();
                obj.refreshInfo();
                fprintf('[Esp32] Connected on %s | IRAM=0x%08X | DRAM=0x%08X | WiFi=%s | FW=%s build %s\n', ...
                    target, obj.IramAddr, obj.DramAddr, obj.WifiIP, Esp32.field(obj.Info, 'FW'), Esp32.field(obj.Info, 'BUILD'));
            end
        end

        % ------------------------------------------------------------------ link management
        function openLink(obj)
            obj.ConnObj = [];
            t = obj.Target;
            if startsWith(upper(t), "COM") || startsWith(t, "/dev/")
                obj.Mode = "serial";
                obj.ConnObj = serialport(t, ude.Config.Baud, "Timeout", 1);
                configureTerminator(obj.ConnObj, "CR/LF");
                pause(2.0);              % opening the port pulses DTR/RTS: the board resets and boots
                flush(obj.ConnObj);
            else
                obj.Mode = "wifi";
                parts = split(t, ":");
                port = ude.Config.CtrlPort;
                if numel(parts) > 1, port = str2double(parts(2)); end
                obj.ConnObj = tcpclient(parts(1), port, "Timeout", 1, "ConnectTimeout", 5);
                configureTerminator(obj.ConnObj, "CR/LF");
                flush(obj.ConnObj);
            end
        end

        function ok = reconnect(obj)
            % Re-open the port after a USB glitch or a chip reset (panic, brown-out, OTA reboot).
            ok = false;
            if obj.Mode == "sim", ok = true; return; end
            for k = 1:10
                try
                    obj.openLink();
                    obj.refreshInfo();
                    ok = true;
                    return;
                catch
                    obj.ConnObj = [];
                    pause(1);
                end
            end
        end

        function refreshInfo(obj)
            s = Esp32.parseKV(obj.cmd("INFO"));
            obj.Info = s;
            if isfield(s, 'IRAM'), obj.IramAddr = uint32(hex2dec(erase(s.IRAM, "0x"))); end
            if isfield(s, 'DRAM'), obj.DramAddr = uint32(hex2dec(erase(s.DRAM, "0x"))); end
            if isfield(s, 'IP'),   obj.WifiIP = s.IP; end
        end

        % ------------------------------------------------------------------ protocol
        function payload = cmd(obj, text, timeoutSec)
            % One request, one framed reply. Read-only requests are retried; writes/EXEC never are.
            arguments
                obj
                text (1,1) string
                timeoutSec (1,1) double = 3
            end
            if obj.Mode == "sim", payload = obj.simCmd(text); return; end
            if obj.Busy
                error('Esp32:Busy', 'The link is busy with another command.');
            end
            obj.Busy = true;
            guard = onCleanup(@() obj.releaseLink());

            idempotent = any(startsWith(text, ["R ", "RB ", "INFO", "PING", "MAP", "PART"]));
            attempts = 1 + 2 * idempotent;
            lastErr = [];
            for a = 1:attempts
                try
                    payload = obj.transact(text, timeoutSec);
                    if startsWith(payload, "ERR")
                        error('Esp32:Device', 'Device refused "%s": %s', text, payload);
                    end
                    return;
                catch ME
                    lastErr = ME;
                    if strcmp(ME.identifier, 'Esp32:Device'), rethrow(ME); end
                    if a < attempts
                        obj.Busy = false;            % reconnect() issues commands itself
                        obj.reconnect();
                        obj.Busy = true;
                    end
                end
            end
            rethrow(lastErr);
        end

        function releaseLink(obj)
            obj.Busy = false;
        end

        % ------------------------------------------------------------------ memory access
        function val = read32(obj, addr)
            addr = uint32(addr);
            if obj.Mode == "sim", val = obj.simRead(addr); return; end
            val = uint32(hex2dec(obj.cmd(sprintf('R %08X', addr))));
        end

        function words = readBlock32(obj, startAddr, count)
            % Strict variant: errors if any word is unreadable.
            [words, valid] = obj.readBlock32Ex(startAddr, count);
            if ~all(valid)
                error('Esp32:Range', 'Part of 0x%08X..+%d words is not readable memory.', uint32(startAddr), count);
            end
        end

        function [words, valid, mark] = readBlock32Ex(obj, startAddr, count)
            % Tolerant variant for viewers. Unreadable words come back as valid=false and
            % mark="--------" (unmapped) or "~~~~~~~~" (reading would have a side effect).
            count = double(count);
            words = zeros(1, count, 'uint32');
            valid = false(1, count);
            mark  = repmat("", 1, count);
            startAddr = bitand(uint32(startAddr), bitcmp(uint32(3)));
            done = 0;
            while done < count
                n = min(Esp32.MaxBlockWords, count - done);
                a = startAddr + uint32(done * 4);
                if obj.Mode == "sim"
                    for k = 1:n
                        words(done + k) = obj.simRead(a + uint32((k - 1) * 4));
                        valid(done + k) = true;
                    end
                else
                    resp = obj.cmd(sprintf('RB %08X %X', a, n));
                    parts = split(strtrim(string(resp)));
                    parts = parts(:);
                    parts = parts(parts ~= "");
                    if numel(parts) ~= n
                        error('Esp32:Protocol', 'Expected %d words, received %d.', n, numel(parts));
                    end
                    for k = 1:n
                        tk = parts(k);
                        if all(isstrprop(char(tk), 'xdigit'))
                            words(done + k) = uint32(hex2dec(tk));
                            valid(done + k) = true;
                        else
                            mark(done + k) = tk;
                        end
                    end
                end
                done = done + n;
            end
        end

        function write32(obj, addr, val)
            v32 = uint32(bitand(uint64(val), uint64(4294967295)));
            addr = uint32(addr);
            if obj.Mode == "sim"
                obj.SimMem(double(addr)) = v32;
                return;
            end
            ack = obj.cmd(sprintf('W %08X %08X', addr, v32));
            if ack ~= "OK", error('Esp32:Write', 'Write failed at 0x%08X: %s', addr, ack); end
        end

        function retVal = execIRAM(obj, addr, a2, a3)
            % Call machine code in the IRAM sandbox: retVal = f(a2, a3)  (windowed ABI)
            if nargin < 2, addr = obj.IramAddr; end
            if nargin < 3, a2 = 0; end
            if nargin < 4, a3 = 0; end
            if obj.Mode == "sim", retVal = uint32(0); return; end
            resp = obj.cmd(sprintf('EXEC %08X %08X %08X', uint32(addr), uint32(a2), uint32(a3)));
            tok = regexp(resp, 'EXEC_RET=0x([0-9A-Fa-f]+)', 'tokens', 'once');
            if isempty(tok), error('Esp32:ExecError', 'Unexpected EXEC reply: %s', resp); end
            retVal = uint32(hex2dec(tok{1}));
        end

        % ------------------------------------------------------------------ board metadata
        function T = memoryMap(obj)
            % The table the firmware's address guard enforces (single source of truth).
            items = split(string(obj.cmd("MAP")), ";");
            items = items(:);
            items = items(strlength(items) > 0);
            n = numel(items);
            Name = strings(n, 1);  Lo = zeros(n, 1);  Hi = zeros(n, 1);  Writable = false(n, 1);
            for k = 1:n
                f = split(items(k), ":");
                Name(k) = f(1);  Lo(k) = hex2dec(f(2));  Hi(k) = hex2dec(f(3));  Writable(k) = f(4) == "1";
            end
            T = sortrows(table(Name, Lo, Hi, Writable), 'Lo');
        end

        function T = partitions(obj)
            % Flash partition table as the running firmware sees it.
            items = split(string(obj.cmd("PART")), ";");
            items = items(:);
            items = items(strlength(items) > 0);
            n = numel(items);
            Label = strings(n, 1);  Type = zeros(n, 1);  Sub = zeros(n, 1);  Offset = zeros(n, 1);  Size = zeros(n, 1);
            for k = 1:n
                f = split(items(k), ":");
                Label(k) = f(1);  Type(k) = hex2dec(f(2));  Sub(k) = hex2dec(f(3));
                Offset(k) = hex2dec(f(4));  Size(k) = hex2dec(f(5));
            end
            T = sortrows(table(Label, Type, Sub, Offset, Size), 'Offset');
        end

        % ------------------------------------------------------------------ registers
        function regObj = sfr(obj, regName)
            key = char(regName);
            if ~isKey(obj.Cache, key)
                obj.Cache(key) = SFR(key, obj.RegDefs.(key), obj);
            end
            regObj = obj.Cache(key);
        end

        function def = registerDef(obj, regName)
            def = obj.RegDefs.(char(regName));
        end

        function ui = openMemoryViewer(obj, startAddr)
            % Backward-compatible entry point -> opens the new workbench with a Memory window.
            if nargin < 2, startAddr = obj.DramAddr; end
            ui = ude.Workbench(obj);
            ui.openMemory(startAddr);
        end

        function delete(obj)
            obj.ConnObj = [];
        end
    end

    methods (Access = private)
        function payload = transact(obj, text, timeoutSec)
            flush(obj.ConnObj);
            writeline(obj.ConnObj, text);
            t0 = tic;
            while toc(t0) < timeoutSec
                raw = readline(obj.ConnObj);
                if isempty(raw) || all(ismissing(raw)), continue; end
                [ok, p] = ude.Frame.parse(raw);
                if ok
                    payload = string(p);
                    return;
                end                       % anything else (boot text, logs) is discarded
            end
            error('Esp32:Timeout', 'No valid reply to "%s" within %.1f s.', text, timeoutSec);
        end

        % ---- simulation (no board attached) ----
        function v = simRead(obj, addr)
            k = double(addr);
            if isKey(obj.SimMem, k)
                v = obj.SimMem(k);
            else
                v = uint32(mod(k * 2654435761, 2^32));    % deterministic fake content
            end
        end

        function p = simCmd(obj, text)
            t = split(strtrim(text));
            switch char(t(1))
                case 'PING'
                    p = "PONG";
                case 'INFO'
                    p = "FW=sim BUILD=0 BLINKS=0 IRAM=0x40094000 EXECLEN=256 DRAM=0x3FFBDB60 IP=0.0.0.0 RUN=app0 NEXT=app1 CHIP=ESP32-SIM REV=0 CPU=240 FLASH=4194304 HEAP=0 UP=0";
                case 'MAP'
                    p = "DPORT:3FF00000:3FF10000:1;PERIPH:3FF40000:3FF80000:1;RTC_FAST_D:3FF80000:3FF82000:1;ROM1:3FF90000:3FFA0000:0;DRAM:3FFAE000:40000000:1;ROM0:40000000:40060000:0;IRAM:40080000:400C0000:0;RTC_FAST_I:400C0000:400C2000:1;RTC_SLOW:50000000:50002000:1;EXEC_BUF:40094000:40094100:1;";
                case 'PART'
                    p = "nvs:01:02:9000:5000;otadata:01:00:E000:2000;app0:00:10:10000:140000;app1:00:11:150000:140000;spiffs:01:82:290000:160000;coredump:01:03:3F0000:10000;";
                otherwise
                    p = "OK";
            end
        end
    end

    methods (Static)
        function port = detectPort()
            ports = serialportlist("available");
            usb = ports(~ismember(ports, ude.Config.ExcludePorts));
            if ~isempty(usb)
                port = usb(1);
            elseif ~isempty(ports)
                port = ports(1);
            else
                warning("No free COM port detected; starting in 'sim' mode.");
                port = "sim";
            end
        end

        function s = parseKV(str)
            % "A=1 B=two" -> struct('A',"1",'B',"two")
            s = struct();
            toks = split(strtrim(string(str)));
            for k = 1:numel(toks)
                kv = split(toks(k), "=");
                if numel(kv) == 2 && kv(1) ~= ""
                    s.(matlab.lang.makeValidName(kv(1))) = kv(2);
                end
            end
        end

        function v = field(s, name)
            if isfield(s, name), v = char(s.(name)); else, v = '?'; end
        end

        function port = flashAndConnect()
            % Kept so old scripts keep working; the logic lives in ude.FirmwareBuilder.
            port = ude.FirmwareBuilder.flashUsb();
        end
    end
end
