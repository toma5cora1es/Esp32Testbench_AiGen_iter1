classdef OtaUploader < handle
    % OtaUploader  Stream a compiled app image (.bin) to the ESP32 over WiFi, into the IDLE OTA slot.
    %              Independent of the control link (Esp32): it opens its own TCP connection to port 3334.
    %
    %   Protocol:  host -> "OTA <size> <md5>\r\n" + raw bytes
    %              dev  -> "@READY*cc" ... "@OTA_OK*cc"   (or "@ERR ...")  and then it reboots.
    properties
        Host string = ude.Config.ApIp
        Port double = ude.Config.OtaPort
        ChunkBytes double = 1024
        OnStage = @(stage, state) []               % stage: "connect"|"stream"|"verify"   state: "active"|"done"|"fail"
        OnProgress = @(sentBytes, totalBytes) []
        OnLog = @(msg) []
    end

    methods
        function obj = OtaUploader(host)
            if nargin > 0, obj.Host = string(host); end
        end

        function upload(obj, binPath)
            data = obj.readImage(binPath);
            total = numel(data);
            md5 = ude.OtaUploader.md5(data);
            obj.OnLog(sprintf('Image %s: %d bytes, MD5 %s', binPath, total, md5));

            obj.OnStage("connect", "active");
            try
                t = tcpclient(obj.Host, obj.Port, 'Timeout', 10, 'ConnectTimeout', 5);
            catch ME
                obj.OnStage("connect", "fail");
                error('Ota:Connect', ['Cannot reach %s:%d (%s). Is the PC connected to the WiFi network "%s"? ' ...
                    '(run scripts\connect_wifi.ps1)'], obj.Host, obj.Port, ME.message, ude.Config.ApSsid);
            end
            configureTerminator(t, "CR/LF");
            writeline(t, sprintf('OTA %d %s', total, md5));
            reply = ude.OtaUploader.readFrame(t, 8);
            if reply ~= "READY"
                obj.OnStage("connect", "fail");
                error('Ota:Rejected', 'ESP32 refused the update: %s', reply);
            end
            obj.OnStage("connect", "done");
            obj.OnLog('ESP32 erased the idle OTA slot and is ready.');

            obj.OnStage("stream", "active");
            sent = 0;
            while sent < total
                last = min(sent + obj.ChunkBytes, total);
                write(t, data(sent + 1:last), 'uint8');
                sent = last;
                obj.OnProgress(sent, total);
            end
            obj.OnStage("stream", "done");

            obj.OnStage("verify", "active");
            obj.OnLog('Streaming finished. Waiting for MD5 check and boot-slot switch ...');
            reply = ude.OtaUploader.readFrame(t, 30);
            if reply ~= "OTA_OK"
                obj.OnStage("verify", "fail");
                error('Ota:Failed', 'Update failed on the device: %s', reply);
            end
            obj.OnStage("verify", "done");
            obj.OnLog('Device accepted the image and is rebooting into the new slot.');
        end

        function info = waitForReboot(obj, timeoutSec)
            % Poll the control port until the new firmware answers INFO.
            if nargin < 2, timeoutSec = 45; end
            pause(3);                               % the access point disappears while the chip restarts
            t0 = tic;
            info = struct();
            while toc(t0) < timeoutSec
                try
                    info = ude.OtaUploader.queryInfo(obj.Host, ude.Config.CtrlPort);
                    return;
                catch
                    pause(1);
                end
            end
            error('Ota:NoReboot', 'The board did not come back within %d s.', timeoutSec);
        end
    end

    methods (Static)
        function info = queryInfo(host, port)
            % Raw one-shot INFO request (no SFR database, no Esp32 object).
            t = tcpclient(host, port, 'Timeout', 2, 'ConnectTimeout', 2);
            configureTerminator(t, "CR/LF");
            writeline(t, 'INFO');
            info = Esp32.parseKV(ude.OtaUploader.readFrame(t, 3));
        end

        function payload = readFrame(t, timeoutSec)
            t0 = tic;
            while toc(t0) < timeoutSec
                raw = readline(t);
                if isempty(raw) || all(ismissing(raw)), continue; end
                [ok, p] = ude.Frame.parse(raw);
                if ok
                    payload = string(p);
                    return;
                end
            end
            error('Ota:Timeout', 'No reply from the ESP32 within %d s.', timeoutSec);
        end

        function data = readImage(binPath)
            if ~isfile(binPath), error('Ota:NoFile', 'File not found: %s', binPath); end
            fid = fopen(binPath, 'rb');
            data = fread(fid, inf, '*uint8');
            fclose(fid);
            if numel(data) < 1024 || data(1) ~= 233           % 0xE9 = ESP image magic byte
                error('Ota:BadImage', ['"%s" does not look like an ESP32 app image (magic byte 0xE9 missing). ' ...
                    'Use the *.ino.bin from the build folder, not *.bootloader.bin / *.partitions.bin / *.merged.bin.'], binPath);
            end
        end

        function h = md5(data)
            try
                md = java.security.MessageDigest.getInstance('MD5');
                md.update(typecast(data(:), 'int8'));
                d = typecast(md.digest(), 'uint8');
                h = lower(reshape(dec2hex(d, 2)', 1, []));
            catch
                tmp = [tempname '.bin'];
                fid = fopen(tmp, 'wb');  fwrite(fid, data, 'uint8');  fclose(fid);
                [~, out] = system(sprintf('certutil -hashfile "%s" MD5', tmp));
                delete(tmp);
                lines = splitlines(string(out));
                h = char(lower(erase(strtrim(lines(2)), " ")));
            end
        end
    end
end
