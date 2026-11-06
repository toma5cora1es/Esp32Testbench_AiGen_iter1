classdef FirmwareBuilder
    % FirmwareBuilder  Compile the sketch with arduino-cli and flash it over USB.
    %                  (Wireless flashing is a different class on purpose: ude.OtaUploader.)
    methods (Static)
        function port = pickUsbPort()
            % First serial port reported by arduino-cli that is not in Config.ExcludePorts.
            port = "";
            [st, out] = system('arduino-cli board list --format json');
            if st == 0
                try
                    d = jsondecode(out);
                    if isstruct(d) && isfield(d, 'detected_ports'), L = d.detected_ports; else, L = d; end
                    for k = 1:numel(L)
                        if iscell(L), it = L{k}; else, it = L(k); end
                        addr = string(it.port.address);
                        if string(it.port.protocol) == "serial" && ~ismember(addr, ude.Config.ExcludePorts)
                            port = addr;
                            return;
                        end
                    end
                catch
                end
            end
            port = Esp32.detectPort();
        end

        function removeDuplicateSketches(sketchDir)
            % arduino-cli refuses a sketch folder that contains a second .ino with another name.
            keep = [char(ude.Config.SketchName) '.ino'];
            f = dir(fullfile(sketchDir, '*.ino'));
            for k = 1:numel(f)
                if ~strcmpi(f(k).name, keep)
                    fprintf('[Build] Deleting duplicate sketch file: %s\n', f(k).name);
                    delete(fullfile(f(k).folder, f(k).name));
                end
            end
        end

        function [binPath, fqbnUsed, log] = compile(opts)
            % binPath = ude.FirmwareBuilder.compile('BootBlinks', 5)
            arguments
                opts.BootBlinks (1,1) double = 3
            end
            sketch = ude.Config.sketchDir();
            ude.FirmwareBuilder.removeDuplicateSketches(sketch);
            outDir = fullfile(sketch, 'build');
            flags = sprintf('-DBOOT_BLINKS=%d -DFW_BUILD=%.0f', opts.BootBlinks, floor(posixtime(datetime('now', 'TimeZone', 'UTC'))));
            st = 1;  log = '';  fqbnUsed = "";
            for fq = [ude.Config.FqbnTuned, ude.Config.Fqbn]       % fall back to the plain board if an option name differs
                cmdStr = sprintf('arduino-cli compile --fqbn "%s" --output-dir "%s" --build-property "compiler.cpp.extra_flags=%s" "%s"', ...
                    fq, outDir, flags, sketch);
                fprintf('[Build] %s\n', cmdStr);
                [st, log] = system(cmdStr);
                if st == 0, fqbnUsed = fq; break; end
            end
            if st ~= 0
                error('FirmwareBuilder:Compile', 'arduino-cli compile failed:\n%s', log);
            end
            binPath = fullfile(outDir, [char(ude.Config.SketchName) '.ino.bin']);
            if ~isfile(binPath)
                error('FirmwareBuilder:NoBin', 'Compile succeeded but %s was not produced.', binPath);
            end
        end

        function port = flashUsb(port, opts)
            % Compile + upload over USB. Returns the port that was used.
            arguments
                port string = ""
                opts.BootBlinks (1,1) double = 3
            end
            if port == "", port = ude.FirmwareBuilder.pickUsbPort(); end
            [~, fqbn] = ude.FirmwareBuilder.compile('BootBlinks', opts.BootBlinks);
            sketch = ude.Config.sketchDir();
            fprintf('[Flash] Uploading to %s ...\n', port);
            cmdStr = sprintf('arduino-cli upload -p %s --fqbn "%s" --input-dir "%s" "%s"', port, fqbn, fullfile(sketch, 'build'), sketch);
            [st, out] = system(cmdStr);
            if st ~= 0
                error('FirmwareBuilder:Upload', ['Upload to %s failed:\n%s\n' ...
                    'Tip: close every program using the port (serial monitor, a previous MATLAB serialport), ' ...
                    'and if it still fails hold the BOOT button while "Connecting..." is shown.'], port, out);
            end
            fprintf('[Flash] Firmware flashed on %s.\n', port);
        end
    end
end
