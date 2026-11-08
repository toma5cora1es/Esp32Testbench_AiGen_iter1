function success = esp32_flash(filePath, varargin)
%ESP32_FLASH Compiles and injects OTA/Bridge + Bluetooth SPP support (Core 0) and flashes via Wi-Fi or USB.
%
% CLI EXAMPLES:
%   esp32 flash C:\Users\tomas\persistent_app\persistent_app.ino --wifi
%   esp32 flash C:\Users\tomas\persistent_app\persistent_app.ino --usb COM9
%   esp32 flash C:\Users\tomas\build\app.bin --wifi 192.168.4.1
%
% OOP EXAMPLE:
%   Esp32().Flash('C:\Users\tomas\persistent_app\persistent_app.ino')

    if nargin < 1 || isempty(filePath)
        error('ESP32:FlashPath', 'You must specify the path to the .ino file, sketch folder, or .bin file.');
    end

    filePath = strtrim(char(filePath));
    % Strip surrounding quotes if passed from MATLAB command syntax
    filePath = regexprep(filePath, '^["'']|["'']$', '');

    % If the user passed a sketch folder instead of the .ino file, locate the .ino inside it
    if isfolder(filePath)
        [~, folderName] = fileparts(filePath);
        candidate = fullfile(filePath, [folderName '.ino']);
        if isfile(candidate)
            filePath = candidate;
        else
            inos = dir(fullfile(filePath, '*.ino'));
            if ~isempty(inos)
                filePath = fullfile(inos(1).folder, inos(1).name);
            end
        end
    end

    if ~isfile(filePath)
        error('ESP32:FileNotFound', 'File not found: %s', filePath);
    end

    % Determine method (--wifi or --usb) and target (IP or COMx)
    s = esp32_io('state');
    mode = '';
    target = '';
    injectDaemon = true;

    i = 1;
    while i <= numel(varargin)
        arg = lower(strtrim(char(varargin{i})));
        arg = regexprep(arg, '^["'']|["'']$', '');
        if any(strcmp(arg, {'--wifi', '-w', 'wifi'}))
            mode = 'wifi';
            if i < numel(varargin) && ~startsWith(char(varargin{i+1}), '-')
                target = char(varargin{i+1});
                i = i + 1;
            end
        elseif any(strcmp(arg, {'--usb', '-u', 'usb', 'serial'}))
            mode = 'usb';
            if i < numel(varargin) && ~startsWith(char(varargin{i+1}), '-')
                target = char(varargin{i+1});
                i = i + 1;
            end
        elseif strcmp(arg, '--raw')
            injectDaemon = false; % Do not inject daemon if the user requests a raw binary
        elseif startsWith(upper(arg), 'COM')
            mode = 'usb';
            target = upper(arg);
        elseif ~isempty(regexp(arg, '^\d+\.\d+\.\d+\.\d+$', 'once'))
            mode = 'wifi';
            target = arg;
        end
        i = i + 1;
    end

    % Auto-detect from active session if no flag was specified
    if isempty(mode)
        if strcmp(s.Mode, 'wifi')
            mode = 'wifi';
            target = s.Target;
        elseif strcmp(s.Mode, 'serial')
            mode = 'usb';
            target = s.Target;
        else
            mode = 'wifi';
            target = '192.168.4.1';
        end
    end
    if isempty(target)
        if strcmp(mode, 'wifi'), target = '192.168.4.1';
        else, target = s.Target; end
    end

    [~, ~, ext] = fileparts(filePath);
    acli = find_arduino_cli();

    % FQBN with explicit PartitionScheme=min_spiffs (1.96 MB max app size for Dual OTA + BT + WiFi)
    fqbn = 'esp32:esp32:esp32:PartitionScheme=min_spiffs';

    % =========================================================================
    % STEP 1: If it is an .ino file, prepare temporary build with Auto-Injection
    % =========================================================================
    if strcmpi(ext, '.ino')
        buildRoot = fullfile(tempdir, 'esp32_ota_build');
        sketchDir = fullfile(buildRoot, 'ota_sketch');
        outBinDir = fullfile(buildRoot, 'bin');
        if isfolder(buildRoot), rmdir(buildRoot, 's'); end
        mkdir(sketchDir);
        mkdir(outBinDir);

        userCode = fileread(filePath);
        outInoPath = fullfile(sketchDir, 'ota_sketch.ino');

        if injectDaemon && ~contains(userCode, 'startBridgeDaemon') && ~contains(userCode, 'server.on("/ota"')
            fprintf('[FLASH] Auto-injecting Wi-Fi OTA + Bluetooth SPP + Register Bridge Daemon on Core 0...\n');
            mergedCode = inject_core0_daemon(userCode);
            fid = fopen(outInoPath, 'w', 'n', 'UTF-8');
            fwrite(fid, mergedCode, 'char');
            fclose(fid);
        else
            fprintf('[FLASH] Sketch already contains the OTA/Bridge Daemon (or --raw was requested).\n');
            copyfile(filePath, outInoPath);
        end

        % Compile with min_spiffs partition (1.96MB App0 + 1.96MB App1 OTA)
        fprintf('[FLASH] Compiling with arduino-cli (PartitionScheme=min_spiffs, Max 1.96MB)...\n');
        compileCmd = sprintf('"%s" compile --fqbn %s --build-property "build.partitions=min_spiffs" --build-property "upload.maximum_size=1966080" --output-dir "%s" "%s"', ...
            acli, fqbn, outBinDir, sketchDir);
        [status, cmdout] = system(compileCmd);
        if status ~= 0
            fprintf(2, '%s\n', cmdout);
            error('ESP32:CompileFailed', 'Failed to compile the sketch.');
        end
        fprintf('[FLASH] Compilation successful.\n');
        binFile = fullfile(outBinDir, 'ota_sketch.ino.bin');
    elseif strcmpi(ext, '.bin')
        binFile = filePath;
        sketchDir = '';
    else
        error('ESP32:UnsupportedExt', 'Unsupported file extension (%s). Use .ino or .bin', ext);
    end

    % =========================================================================
    % STEP 2: Upload the firmware via Wi-Fi OTA or USB Serial
    % =========================================================================
    if strcmp(mode, 'wifi')
        fprintf('[FLASH] Uploading binary (%s) via Wi-Fi OTA to http://%s/ota ...\n', binFile, target);
        curlCmd = sprintf('curl.exe -s -S --connect-timeout 5 --max-time 60 -F "image=@%s" http://%s/ota', binFile, target);
        [status, resp] = system(curlCmd);
        if status ~= 0 || ~contains(resp, 'OTA_OK')
            error('ESP32:OtaFailed', ...
                'Wi-Fi OTA upload failed (%s). Make sure you are connected to the "ESP32_LAB" Wi-Fi network and the chip has the base firmware with /ota.', strtrim(resp));
        end
        fprintf('[FLASH] Wi-Fi OTA completed! ESP32 is rebooting (waiting 3s)...\n');
        pause(3.0);
        success = true;
    else
        % USB Serial Mode: If MATLAB has the COM port open, release it before flashing
        wasConnected = strcmp(s.Mode, 'serial') && strcmpi(s.Target, target);
        if wasConnected
            fprintf('[FLASH] Releasing port %s in MATLAB to allow USB flashing...\n', target);
            esp32_io('disconnect');
        end

        fprintf('[FLASH] Flashing via USB on %s...\n', target);
        if ~isempty(sketchDir)
            upCmd = sprintf('"%s" upload -p %s --fqbn %s --input-dir "%s"', acli, target, fqbn, outBinDir);
        else
            error('To flash a precompiled .bin via USB, pass the .ino file or use --wifi.');
        end
        [status, cmdout] = system(upCmd);
        if status ~= 0
            fprintf(2, '%s\n', cmdout);
            error('ESP32:UsbUploadFailed', 'Failed uploading via USB on %s.', target);
        end
        fprintf('[FLASH] USB flashing completed on %s!\n', target);
        pause(1.5);

        if wasConnected
            esp32_io('connect', target);
        end
        success = true;
    end
end

function acli = find_arduino_cli()
    [st, ~] = system('where arduino-cli >nul 2>&1');
    if st == 0
        acli = 'arduino-cli';
        return;
    end
    defaultPath = 'C:\Program Files\Arduino CLI\arduino-cli.exe';
    if isfile(defaultPath)
        acli = defaultPath;
    else
        error('ESP32:NoArduinoCLI', 'arduino-cli was not found. Please verify your installation.');
    end
end

function merged = inject_core0_daemon(userCode)
    % Renames the user's void setup() to void user_setup() so the Core 0 Daemon starts first
    modifiedUser = regexprep(userCode, '\bvoid\s+setup\s*\(\s*\)', 'void user_setup()', 'once');

    daemonHeader = [
        '#include <Arduino.h>' newline ...
        '#include <WiFi.h>' newline ...
        '#include <WebServer.h>' newline ...
        '#include <Update.h>' newline ...
        '#include "BluetoothSerial.h"' newline ...
        '#include "soc/gpio_reg.h"' newline ...
        'static WebServer _bgServer(80);' newline ...
        'static BluetoothSerial _bgSerialBT;' newline ...
        'static String _bgExec(String line) {' newline ...
        '  line.trim();' newline ...
        '  if (line.startsWith("R ") || line.startsWith("r ")) {' newline ...
        '    uint32_t a = strtoul(line.substring(2).c_str(), NULL, 16);' newline ...
        '    char b[16]; snprintf(b, sizeof(b), "0x%08X", *(volatile uint32_t*)a); return String(b);' newline ...
        '  }' newline ...
        '  if (line.startsWith("W ") || line.startsWith("w ")) {' newline ...
        '    int sp = line.indexOf('' '', 2);' newline ...
        '    uint32_t a = strtoul(line.substring(2, sp).c_str(), NULL, 16);' newline ...
        '    uint32_t v = strtoul(line.substring(sp + 1).c_str(), NULL, 16);' newline ...
        '    *(volatile uint32_t*)a = v;' newline ...
        '    char b[16]; snprintf(b, sizeof(b), "0x%08X", *(volatile uint32_t*)a); return String(b);' newline ...
        '  }' newline ...
        '  if (line.startsWith("D ") || line.startsWith("d ")) {' newline ...
        '    int sp = line.indexOf('' '', 2);' newline ...
        '    uint32_t a = strtoul(line.substring(2, sp > 0 ? sp : line.length()).c_str(), NULL, 16);' newline ...
        '    int c = (sp > 0) ? line.substring(sp + 1).toInt() : 4;' newline ...
        '    if (c < 1) c = 1; if (c > 64) c = 64;' newline ...
        '    String out = ""; char b[16];' newline ...
        '    for (int i = 0; i < c; i++) {' newline ...
        '      snprintf(b, sizeof(b), "%08X", *(volatile uint32_t*)(a + i * 4));' newline ...
        '      if (i > 0) out += " "; out += b;' newline ...
        '    }' newline ...
        '    return out;' newline ...
        '  }' newline ...
        '  if (line.startsWith("PIN ") || line.startsWith("pin ")) {' newline ...
        '    int sp = line.indexOf('' '', 4);' newline ...
        '    int p = (sp > 0) ? line.substring(4, sp).toInt() : line.substring(4).toInt();' newline ...
        '    String act = (sp > 0) ? line.substring(sp + 1) : "R"; act.trim(); act.toUpperCase();' newline ...
        '    if (act == "R" || act == "READ") return String(digitalRead(p));' newline ...
        '    pinMode(p, OUTPUT); uint32_t m = (1UL << p); *(volatile uint32_t*)GPIO_ENABLE_W1TS_REG = m;' newline ...
        '    if (act == "1" || act == "HIGH" || act == "ON") *(volatile uint32_t*)GPIO_OUT_W1TS_REG = m;' newline ...
        '    else if (act == "0" || act == "LOW" || act == "OFF") *(volatile uint32_t*)GPIO_OUT_W1TC_REG = m;' newline ...
        '    else if (act == "T" || act == "TOGGLE") {' newline ...
        '      if (*(volatile uint32_t*)GPIO_OUT_REG & m) *(volatile uint32_t*)GPIO_OUT_W1TC_REG = m;' newline ...
        '      else *(volatile uint32_t*)GPIO_OUT_W1TS_REG = m;' newline ...
        '    }' newline ...
        '    return String((*(volatile uint32_t*)GPIO_OUT_REG & m) ? 1 : 0);' newline ...
        '  }' newline ...
        '  if (line.startsWith("ADC ") || line.startsWith("adc ")) return String(analogRead(line.substring(4).toInt()));' newline ...
        '  if (line == "STATUS" || line == "status") return "ESP32_READY|UPTIME_MS:" + String(millis()) + "|IP:" + WiFi.softAPIP().toString() + "|BT:ESP32_BT_BRIDGE";' newline ...
        '  return "ERR";' newline ...
        '}' newline ...
        'static void _bgTask(void* pv) {' newline ...
        '  _bgSerialBT.begin("ESP32_BT_BRIDGE");' newline ...
        '  WiFi.mode(WIFI_AP); WiFi.softAP("ESP32_LAB", "12345678");' newline ...
        '  _bgServer.on("/", HTTP_GET, [](){ _bgServer.send(200, "application/json", "{\"status\":\"ESP32_READY\"}"); });' newline ...
        '  _bgServer.on("/cmd", HTTP_GET, [](){ _bgServer.send(200, "text/plain", _bgExec(_bgServer.arg("q"))); });' newline ...
        '  _bgServer.on("/ota", HTTP_POST, [](){' newline ...
        '    bool ok = !Update.hasError(); _bgServer.send(ok?200:500, "text/plain", ok?"OTA_OK_REBOOTING":"OTA_FAIL");' newline ...
        '    delay(300); if(ok) ESP.restart();' newline ...
        '  }, [](){' newline ...
        '    HTTPUpload& u = _bgServer.upload();' newline ...
        '    if(u.status == UPLOAD_FILE_START) Update.begin(UPDATE_SIZE_UNKNOWN);' newline ...
        '    else if(u.status == UPLOAD_FILE_WRITE) Update.write(u.buf, u.currentSize);' newline ...
        '    else if(u.status == UPLOAD_FILE_END) Update.end(true);' newline ...
        '  });' newline ...
        '  _bgServer.begin();' newline ...
        '  for(;;) {' newline ...
        '    _bgServer.handleClient();' newline ...
        '    if (Serial.available()) { String r = _bgExec(Serial.readStringUntil(''\n'')); if(r.length()) Serial.println(r); }' newline ...
        '    if (_bgSerialBT.available()) { String r = _bgExec(_bgSerialBT.readStringUntil(''\n'')); if(r.length()) _bgSerialBT.println(r); }' newline ...
        '    vTaskDelay(pdMS_TO_TICKS(2));' newline ...
        '  }' newline ...
        '}' newline
    ];

    daemonFooter = [
        newline ...
        'void setup() {' newline ...
        '  Serial.begin(115200);' newline ...
        '  xTaskCreatePinnedToCore(_bgTask, "OTA_Core0", 8192, NULL, 1, NULL, 0);' newline ...
        '  user_setup();' newline ...
        '}' newline
    ];

    merged = [daemonHeader, newline, modifiedUser, newline, daemonFooter];
end