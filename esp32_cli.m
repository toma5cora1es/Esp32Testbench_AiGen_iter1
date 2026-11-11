function varargout = esp32_cli(cmd, varargin)
%ESP32_CLI CLI-First Workbench for ESP32 (SFR JSON Database, Registers, Pins, ADC, DAC, PWM, Touch, I2C, SPI, Flash OTA, Web, GUI).
%
% CONSOLE USAGE (PURE CLI SYNTAX):
%   esp32_cli scan                              % List COM ports (with Registry & PnP driver info)
%   esp32_cli debug                             % Run autonomous PowerShell & MATLAB hardware diagnostics
%   esp32_cli connect COM8                      % Connect via USB Serial or BT Virtual COM port
%   esp32_cli connect ESP32_BT_BRIDGE           % Connect natively via Bluetooth SPP
%   esp32_cli connect 192.168.4.1               % Connect via Wi-Fi (ESP32_LAB AP)
%   esp32_cli status                            % Display chip status, uptime, and free heap
%   esp32_cli info                              % Display Free Heap RAM, Flash Size, and OTA Partition Size
%   esp32_cli loopback                          % Run autonomous GPIO, DAC, ADC1, Touch & I2C self-test
%   esp32_cli sfr GPIO                          % Search registers matching 'GPIO' in esp32_sfr.json
%   esp32_cli sfr GPIO_OUT_REG                  % Show bitfield map of GPIO_OUT_REG from esp32_sfr.json
%   esp32_cli reg GPIO_OUT_REG                  % Read register by symbolic name (or 0x3FF44004)
%   esp32_cli reg GPIO_OUT_W1TS_REG 0x00000004  % Write register by symbolic name or hex address
%   esp32_cli bits GPIO_OUT_REG GPIO2 1         % Modify bitfield by symbolic name from esp32_sfr.json
%   esp32_cli bits 0x3FF44004 2 2 1             % Modify bits [msb:lsb] numerically
%   esp32_cli pin 2 toggle                      % Toggle GPIO 2 state
%   esp32_cli adc [34 | all]                    % Read ADC1 on GPIO 34 (or scan all 6 ADC1 channels)
%   esp32_cli dac 25 128                        % Output 8-bit analog voltage (0..255 -> 0..3.30V) on GPIO 25 or 26
%   esp32_cli pwm 4 1000 512                    % Output 10-bit hardware PWM (1000 Hz, 50% duty) on GPIO 4
%   esp32_cli touch [32 | all]                  % Read capacitive touch on GPIO 32 (or scan all 9 touch pins)
%   esp32_cli i2c scan                          % Scan I2C bus on D21 (SDA) & D22 (SCL)
%   esp32_cli i2c read 0x68 0x75 1              % Read <n> bytes from I2C <addr> <reg>
%   esp32_cli i2c write 0x68 0x6B 0x00          % Write <val> to I2C <addr> <reg>
%   esp32_cli spi 5 0x9F                        % Transfer byte over VSPI (SCK=18, MISO=19, MOSI=23, CS=5)
%   esp32_cli beep 4 1200 150                   % Emit 1200 Hz tone for 150 ms on GPIO 4
%   esp32_cli dump GPIO_OUT_REG 8               % Display Hex/Binary table starting at symbol/address
%   esp32_cli flash my_sketch.ino --wifi        % Compile, inject Core0 Web+OTA+BT, and flash over Wi-Fi
%   esp32_cli flash my_sketch.ino --usb         % Compile and flash via USB
%   esp32_cli web                               % Open the on-chip Web Register Workbench in browser
%   esp32_cli gui                               % Open the UDE Workbench graphical interface
%   esp32_cli disconnect                        % Close the active connection

    if nargin == 0
        help esp32_cli;
        return;
    end

    action = lower(strtrim(char(cmd)));

    % ESP32 GPIO Base Register Addresses (Technical Reference Manual)
    GPIO_OUT_REG         = uint32(hex2dec('3FF44004'));
    GPIO_OUT_W1TS_REG    = uint32(hex2dec('3FF44008'));
    GPIO_OUT_W1TC_REG    = uint32(hex2dec('3FF4400C'));
    GPIO_ENABLE_W1TS_REG = uint32(hex2dec('3FF44024'));
    GPIO_IN_REG          = uint32(hex2dec('3FF4403C'));

    switch action
        case 'scan'
            ports = serialportlist("all");
            avail = serialportlist("available");
            pnpDesc = get_windows_port_descriptions();
            fprintf('\n=== Detected Serial / Virtual BT Ports ===\n');
            if isempty(ports)
                fprintf('  (No COM ports detected. Check USB data cable or Bluetooth pairing)\n');
            else
                for p = ports
                    tag = "BUSY";
                    if any(p == avail), tag = "AVAILABLE"; end
                    desc = "";
                    if isKey(pnpDesc, char(p))
                        desc = " — " + pnpDesc(char(p));
                    end
                    fprintf('  %-8s [%-9s]%s\n', p, tag, desc);
                end
            end
            fprintf('\n');
            if nargout > 0
                varargout{1} = ports;
            end

        case {'debug', 'diag', 'doctor'}
            run_autonomous_powershell_diagnostics();

        case 'connect'
            if isempty(varargin)
                error('Usage: esp32_cli connect <COMx | IP | bt:DeviceName | ESP32_BT_BRIDGE>');
            end
            ok = esp32_io('connect', varargin{:});
            if nargout > 0, varargout{1} = ok; end

        case 'disconnect'
            esp32_io('disconnect');
            fprintf('[ESP32] Disconnected.\n');

        case {'status', 'ping', 'state'}
            s = esp32_io('state');
            if strcmp(s.Mode, 'none')
                fprintf('[ESP32] Status: DISCONNECTED\n');
                if nargout > 0, varargout{1} = s; end
                return;
            end
            resp = esp32_io('cmd', 'STATUS');
            if nargout == 0
                fprintf('[ESP32] Mode: %s | Target: %s | Response: %s\n', upper(s.Mode), s.Target, resp);
            else
                varargout{1} = resp;
            end

        case 'info'
            respInfo = esp32_io('cmd', 'INFO');
            respStat = esp32_io('cmd', 'STATUS');
            if nargout == 0
                fprintf('\n=== ESP32 On-Chip Memory & Partition Telemetry ===\n');
                fprintf('  Status   : %s\n', respStat);
                fprintf('  Hardware : %s\n\n', respInfo);
            else
                varargout{1} = respInfo;
            end

        case {'raw', 'send', 'cmd'}
            if isempty(varargin)
                error('Usage: esp32_cli raw "<COMMAND>"');
            end
            rawStr = strjoin(string(varargin), ' ');
            resp = esp32_io('cmd', char(rawStr));
            if nargout == 0
                fprintf('  [RAW "%s"] -> %s\n', rawStr, resp);
            else
                varargout{1} = resp;
            end

        case 'sfr'
            db = get_sfr_database();
            regNames = string(fieldnames(db.registers));
            if isempty(varargin)
                fprintf('\n=== ESP32 SFR Database (%s) ===\n', db.derivative);
                fprintf('  Total Compiled Registers: %d\n', numel(regNames));
                fprintf('  Usage: esp32_cli sfr <FILTER_OR_REG_NAME>  (e.g., esp32_cli sfr GPIO)\n\n');
                if nargout > 0, varargout{1} = db; end
                return;
            end

            query = upper(strtrim(string(varargin{1})));
            if isfield(db.registers, query)
                rMeta = db.registers.(query);
                fprintf('\n=== SFR Definition: %s (%s) ===\n', query, rMeta.address);
                bfs = fieldnames(rMeta.bitfields);
                if isempty(bfs)
                    fprintf('  (No individual bitfields defined in header)\n');
                else
                    fprintf('  %-28s | %-10s | %-6s | %-6s\n', 'Bitfield Name', 'Bits', 'Width', 'Access');
                    fprintf('  -----------------------------+------------+--------+-------\n');
                    for k = 1:numel(bfs)
                        bf = rMeta.bitfields.(bfs{k});
                        msb = bf.offset + bf.width - 1;
                        fprintf('  %-28s | [%2d:%2d]    | %-6d | %-6s\n', ...
                            bfs{k}, msb, bf.offset, bf.width, bf.access);
                    end
                end
                fprintf('\n');
                if nargout > 0, varargout{1} = rMeta; end
            else
                matches = regNames(contains(regNames, query, 'IgnoreCase', true));
                fprintf('\n=== SFR Registers matching "%s" (%d found) ===\n', query, numel(matches));
                maxShow = min(numel(matches), 60);
                for k = 1:maxShow
                    rName = matches(k);
                    rMeta = db.registers.(rName);
                    nBf = numel(fieldnames(rMeta.bitfields));
                    fprintf('  %-34s | %-10s | %2d bitfields\n', rName, rMeta.address, nBf);
                end
                if numel(matches) > maxShow
                    fprintf('  ... (%d more registers omitted. Refine your search query)\n', numel(matches) - maxShow);
                end
                fprintf('\n');
                if nargout > 0, varargout{1} = matches; end
            end

        case 'reg'
            if isempty(varargin)
                error('Usage: esp32_cli reg <REG_NAME_OR_HEX_ADDR> [val_hex]');
            end
            [addr, symName, regMeta] = resolve_sfr_address(varargin{1});
            addrHex = sprintf('%08X', addr);
            labelStr = sprintf('0x%08X', addr);
            if strlength(symName) > 0
                labelStr = sprintf('%s (0x%08X)', symName, addr);
            end

            if numel(varargin) == 1
                resp = esp32_io('cmd', ['R ' addrHex]);
                val = parse_num(resp);
                if nargout == 0
                    fprintf('  [REG %s] = 0x%08X (%10u) | Bin: %s\n', ...
                        labelStr, val, val, format_bin32(val));
                    if ~isempty(regMeta) && isfield(regMeta, 'bitfields')
                        print_active_bitfields(regMeta.bitfields, val);
                    end
                else
                    varargout{1} = val;
                end
            else
                val = parse_num(varargin{2});
                valHex = sprintf('%08X', val);
                resp = esp32_io('cmd', sprintf('W %s %s', addrHex, valHex));
                rb = parse_num(resp);
                if nargout == 0
                    fprintf('  [WRITE %s] <= 0x%08X (Readback: 0x%08X)\n', labelStr, val, rb);
                else
                    varargout{1} = rb;
                end
            end

        case 'bits'
            if numel(varargin) < 2
                error('Usage: esp32_cli bits <REG> <BITFIELD_NAME | MSB LSB> [value]');
            end
            [addr, symName, regMeta] = resolve_sfr_address(varargin{1});
            arg2 = strtrim(char(varargin{2}));

            if ~isempty(regMeta) && isfield(regMeta.bitfields, upper(arg2))
                bf = regMeta.bitfields.(upper(arg2));
                lsb = double(bf.offset);
                width = double(bf.width);
                msb = lsb + width - 1;
                bfLabel = sprintf('%s.%s [%d:%d]', symName, upper(arg2), msb, lsb);
                hasNewVal = (numel(varargin) >= 3);
                if hasNewVal, newValArg = varargin{3}; end
            else
                if numel(varargin) < 3
                    error('Usage: esp32_cli bits <REG> <msb> <lsb> [value]');
                end
                msb = double(parse_num(varargin{2}));
                lsb = double(parse_num(varargin{3}));
                width = msb - lsb + 1;
                bfLabel = sprintf('0x%08X [%d:%d]', addr, msb, lsb);
                hasNewVal = (numel(varargin) >= 4);
                if hasNewVal, newValArg = varargin{4}; end
            end

            mask = bitshift(uint32(2^width - 1), lsb);
            curVal = esp32_cli('reg', addr);
            if ~hasNewVal
                fieldVal = bitshift(bitand(curVal, mask), -lsb);
                if nargout == 0
                    fprintf('  [BITS %s] = %u (0x%X)\n', bfLabel, fieldVal, fieldVal);
                else
                    varargout{1} = fieldVal;
                end
            else
                newField = bitand(uint32(parse_num(newValArg)), uint32(2^width - 1));
                cleared = bitand(curVal, bitcmp(mask, 'uint32'));
                updated = bitor(cleared, bitshift(newField, lsb));
                rb = esp32_cli('reg', addr, updated);
                if nargout == 0
                    fprintf('  [BITS %s] <= %u -> New Reg: 0x%08X\n', bfLabel, newField, rb);
                else
                    varargout{1} = rb;
                end
            end

        case {'pin', 'led'}
            if strcmp(action, 'led')
                pinNum = 2;
                pinCmd = 'toggle';
                if ~isempty(varargin), pinCmd = lower(char(varargin{1})); end
            else
                if isempty(varargin), error('Usage: esp32_cli pin <gpio> [high|low|toggle|read]'); end
                pinNum = double(parse_num(varargin{1}));
                pinCmd = 'read';
                if numel(varargin) >= 2, pinCmd = lower(char(varargin{2})); end
            end

            resp = esp32_io('cmd', sprintf('PIN %d %s', pinNum, upper(pinCmd)));
            if startsWith(resp, 'ERR') && pinNum < 32
                mask = bitshift(uint32(1), pinNum);
                if any(strcmp(pinCmd, {'r', 'read'}))
                    inReg = esp32_cli('reg', GPIO_IN_REG);
                    state = double(bitand(inReg, mask) ~= 0);
                else
                    esp32_cli('reg', GPIO_ENABLE_W1TS_REG, mask);
                    if any(strcmp(pinCmd, {'1', 'high', 'on'}))
                        esp32_cli('reg', GPIO_OUT_W1TS_REG, mask);
                        state = 1;
                    elseif any(strcmp(pinCmd, {'0', 'low', 'off'}))
                        esp32_cli('reg', GPIO_OUT_W1TC_REG, mask);
                        state = 0;
                    else
                        curOut = esp32_cli('reg', GPIO_OUT_REG);
                        if bitand(curOut, mask)
                            esp32_cli('reg', GPIO_OUT_W1TC_REG, mask);
                            state = 0;
                        else
                            esp32_cli('reg', GPIO_OUT_W1TS_REG, mask);
                            state = 1;
                        end
                    end
                end
            else
                state = str2double(resp);
            end

            if nargout == 0
                fprintf('  [GPIO %02d] -> State: %d\n', pinNum, state);
            else
                varargout{1} = state;
            end

        case 'adc'
            adcPins = [36, 39, 34, 35, 32, 33];
            adcLabels = {'VP / SVP (Pin 2 below EN)', ...
                'VN / SVN (Pin 3 below EN)', ...
                'D34      (Pin 4 below EN)', ...
                'D35      (Pin 5 below EN)', ...
                'D32      (Pin 6 below EN)', ...
                'D33      (Pin 7 below EN)'};
            if isempty(varargin) || strcmpi(strtrim(char(varargin{1})), 'all')
                fprintf('\n=== ESP32 ADC1 Multi-Channel Scan (Left Header Top-to-Bottom) ===\n');
                fprintf('  GPIO    | Board Silkscreen Position | Raw (12-Bit) | Linear V | Calibrated V (11dB)\n');
                fprintf('  --------+---------------------------+--------------+----------+--------------------\n');
                rawOut = zeros(1, 6);
                for k = 1:6
                    p = adcPins(k);
                    resp = esp32_io('cmd', sprintf('ADC %d', p));
                    r = str2double(resp);
                    rawOut(k) = r;
                    vLin = (r / 4095.0) * 3.30;
                    vCal = 0.0;
                    if r > 0, vCal = min(0.11 + (r / 4095.0) * 3.05, 3.30); end
                    fprintf('  GPIO %2d | %-25s | %4d / 4095  | %6.3f V | %6.3f V (%4.0f mV)\n', ...
                        p, adcLabels{k}, r, vLin, vCal, vCal * 1000);
                end
                fprintf('  (Tip: Connect Power Supply GND (-) to ESP32 GND!)\n\n');
                if nargout > 0, varargout{1} = rawOut; end
                return;
            end

            pinNum = double(parse_num(varargin{1}));
            if ~ismember(pinNum, adcPins)
                warning('ESP32:InvalidAdc1Pin', ...
                    'GPIO %d is not a valid ADC1 pin on ESP-WROOM-32! Valid ADC1 pins (left header): 36 (VP), 39 (VN), 34, 35, 32, 33.', pinNum);
            end
            resp = esp32_io('cmd', sprintf('ADC %d', pinNum));
            raw = str2double(resp);
            voltsLin = (raw / 4095.0) * 3.30;
            voltsCal = 0.0;
            if raw > 0, voltsCal = min(0.11 + (raw / 4095.0) * 3.05, 3.30); end
            if nargout == 0
                fprintf('  [ADC GPIO %02d] = %4d / 4095 | Linear: %.3f V | Calibrated (11dB): %.3f V (%.0f mV)\n', ...
                    pinNum, raw, voltsLin, voltsCal, voltsCal * 1000);
            else
                varargout{1} = raw;
            end

        case 'dac'
            if numel(varargin) < 2
                error('Usage: esp32_cli dac <25|26> <0..255>');
            end
            pinNum = double(parse_num(varargin{1}));
            valNum = min(max(double(parse_num(varargin{2})), 0), 255);
            resp = esp32_io('cmd', sprintf('DAC %d %d', pinNum, valNum));
            vEst = (valNum / 255.0) * 3.30;
            if nargout == 0
                fprintf('  [DAC GPIO %02d] <= %3d / 255 (~%.2f V) -> %s\n', pinNum, valNum, vEst, resp);
            else
                varargout{1} = resp;
            end

        case 'pwm'
            if numel(varargin) < 3
                error('Usage: esp32_cli pwm <pin> <freq_Hz> <duty_0_1023>');
            end
            pinNum  = double(parse_num(varargin{1}));
            freqHz  = double(parse_num(varargin{2}));
            dutyVal = min(max(double(parse_num(varargin{3})), 0), 1023);
            resp = esp32_io('cmd', sprintf('PWM %d %d %d', pinNum, freqHz, dutyVal));
            pct = (dutyVal / 1023.0) * 100.0;
            if nargout == 0
                fprintf('  [PWM GPIO %02d] <= %d Hz | Duty: %d / 1023 (%.1f%%) -> %s\n', ...
                    pinNum, freqHz, dutyVal, pct, resp);
            else
                varargout{1} = resp;
            end

        case 'touch'
            touchPins = [32, 33, 27, 14, 12, 13, 15, 2, 4];
            touchLabels = {'D32 (TOUCH9 - Left)', 'D33 (TOUCH8 - Left)', 'D27 (TOUCH7 - Left)', ...
                           'D14 (TOUCH6 - Left)', 'D12 (TOUCH5 - Left)', 'D13 (TOUCH4 - Left)', ...
                           'D15 (TOUCH3 - Right)', 'D2  (TOUCH2 - Right)', 'D4  (TOUCH0 - Right)'};
            if isempty(varargin) || strcmpi(strtrim(char(varargin{1})), 'all')
                fprintf('\n=== ESP32 Capacitive Touch Sensor Scan (9 Pads on 30-Pin Board) ===\n');
                fprintf('  GPIO    | Board Silkscreen & Touch Ch | Raw Period Count (Lower = Touched)\n');
                fprintf('  --------+-----------------------------+-----------------------------------\n');
                tOut = zeros(1, numel(touchPins));
                for k = 1:numel(touchPins)
                    p = touchPins(k);
                    r = str2double(esp32_io('cmd', sprintf('TOUCH %d', p)));
                    tOut(k) = r;
                    fprintf('  GPIO %2d | %-27s | %4d\n', p, touchLabels{k}, r);
                end
                fprintf('\n');
                if nargout > 0, varargout{1} = tOut; end
                return;
            end
            pinNum = double(parse_num(varargin{1}));
            raw = str2double(esp32_io('cmd', sprintf('TOUCH %d', pinNum)));
            if nargout == 0
                fprintf('  [TOUCH GPIO %02d] = %d (Lower value indicates finger capacitance)\n', pinNum, raw);
            else
                varargout{1} = raw;
            end

        case 'i2c'
            if isempty(varargin)
                subCmd = 'SCAN';
            else
                subCmd = upper(strtrim(char(strjoin(string(varargin), ' '))));
            end
            resp = esp32_io('cmd', ['I2C ' subCmd]);
            if nargout == 0
                fprintf('  [I2C (SDA=D21, SCL=D22) %s] -> %s\n', subCmd, resp);
            else
                varargout{1} = resp;
            end

        case 'spi'
            if numel(varargin) < 2
                error('Usage: esp32_cli spi <cs_pin> <hex_byte>  (e.g., esp32_cli spi 5 0x9F)');
            end
            csPin = double(parse_num(varargin{1}));
            txByte = double(parse_num(varargin{2}));
            resp = esp32_io('cmd', sprintf('SPI %d 0x%02X', csPin, txByte));
            if nargout == 0
                fprintf('  [VSPI (SCK=18, MISO=19, MOSI=23, CS=%d) TX=0x%02X] -> RX=%s\n', csPin, txByte, resp);
            else
                varargout{1} = resp;
            end

        case 'beep'
            pinNum = 4; freqHz = 1200; durMs = 150;
            if numel(varargin) >= 1, pinNum = double(parse_num(varargin{1})); end
            if numel(varargin) >= 2, freqHz = double(parse_num(varargin{2})); end
            if numel(varargin) >= 3, durMs  = double(parse_num(varargin{3})); end
            resp = esp32_io('cmd', sprintf('BEEP %d %d %d', pinNum, freqHz, durMs));
            if nargout == 0
                fprintf('  [BEEP GPIO %02d | %d Hz | %d ms] -> %s\n', pinNum, freqHz, durMs, resp);
            else
                varargout{1} = resp;
            end

        case 'loopback'
            fprintf('\n====================================================================\n');
            fprintf('  ESP32 AUTONOMOUS HARDWARE PERIPHERAL SELF-TEST\n');
            fprintf('====================================================================\n');
            esp32_cli('info');
            fprintf('--- 1. Testing Built-in LED (GPIO 2) & GPIO_OUT_REG ---\n');
            esp32_cli('pin', 2, 'high');
            esp32_cli('reg', 'GPIO_OUT_REG');
            esp32_cli('pin', 2, 'low');

            fprintf('\n--- 2. Testing DAC1 (GPIO 25) Step Sweep & ADC1 Scan ---\n');
            fprintf('  (Tip: Connect a jumper wire from D25 to D34 to see closed-loop voltage!)\n');
            for dacVal = [0, 128, 255]
                esp32_cli('dac', 25, dacVal);
                pause(0.1);
                esp32_cli('adc', 34);
            end
            esp32_cli('dac', 25, 0);

            fprintf('\n--- 3. Scanning Capacitive Touch Pads ---\n');
            esp32_cli('touch', 'all');

            fprintf('--- 4. Scanning I2C Bus (D21=SDA, D22=SCL) ---\n');
            esp32_cli('i2c', 'scan');
            fprintf('====================================================================\n\n');

        case 'dump'
            if isempty(varargin)
                baseAddr = uint32(hex2dec('3FF44000'));
            else
                [baseAddr, ~, ~] = resolve_sfr_address(varargin{1});
            end
            count = 8;
            if numel(varargin) >= 2, count = double(parse_num(varargin{2})); end
            resp = esp32_io('cmd', sprintf('D %08X %d', baseAddr, count));
            if startsWith(resp, 'ERR')
                vals = zeros(1, count, 'uint32');
                for i = 1:count
                    vals(i) = esp32_cli('reg', baseAddr + uint32((i-1)*4));
                end
            else
                hexParts = strsplit(strtrim(resp));
                vals = uint32(hex2dec(hexParts));
            end
            if nargout == 0
                addrMap = get_address_to_name_map();
                fprintf('\n  Address     | SFR Symbol Name              | Hexadecimal | Binary (31..0)\n');
                fprintf('  ------------+------------------------------+-------------+------------------------------------\n');
                for i = 1:numel(vals)
                    a = baseAddr + uint32((i-1)*4);
                    v = vals(i);
                    aKey = sprintf('0x%08X', a);
                    rSym = "";
                    if isKey(addrMap, aKey), rSym = addrMap(aKey); end
                    fprintf('  0x%08X  | %-28s | 0x%08X  | %s\n', a, rSym, v, format_bin32(v));
                end
                fprintf('\n');
            else
                varargout{1} = vals;
            end

        case 'flash'
            if isempty(varargin)
                error('Usage: esp32_cli flash <path_to_file.ino_or_.bin> [--wifi | --usb [COMx]]');
            end
            ok = esp32_flash(varargin{:});
            if nargout > 0, varargout{1} = ok; end

        case 'web'
            s = esp32_io('state');
            ip = '192.168.4.1';
            if strcmp(s.Mode, 'wifi') && ~isempty(s.Target)
                ip = s.Target;
            end
            url = sprintf('http://%s/', ip);
            fprintf('[ESP32] Opening On-Chip Web Register Workbench at %s ...\n', url);
            web(url, '-browser');

        case 'gui'
            esp32_gui();

        otherwise
            error('Unknown command: "%s". Type "help esp32_cli" to view the command list.', action);
    end
end

%% --- Internal Autonomous PowerShell Diagnostics & Helpers ---

function run_autonomous_powershell_diagnostics()
    fprintf('\n====================================================================\n');
    fprintf('  ESP32 WORKBENCH — AUTONOMOUS POWERSHELL & MATLAB DIAGNOSTICS\n');
    fprintf('====================================================================\n');

    fprintf('\n[1/5] Checking active MATLAB serialport handles...\n');
    try
        if exist('serialportfind', 'file') || exist('serialportfind', 'builtin')
            objs = serialportfind();
            if isempty(objs)
                fprintf('  No open serialport objects inside MATLAB.\n');
            else
                for k = 1:numel(objs)
                    fprintf('  Found open MATLAB handle on %s -> Releasing it now...\n', objs(k).Port);
                    delete(objs(k));
                end
            end
        end
    catch ME
        fprintf('  (Could not query serialportfind: %s)\n', ME.message);
    end

    fprintf('\n[2/5] Querying Windows Registry HKLM:\\HARDWARE\\DEVICEMAP\\SERIALCOMM...\n');
    [~, regOut] = system('powershell -NoProfile -Command "Get-ItemProperty ''HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'' -ErrorAction SilentlyContinue | Format-List"');
    fprintf('%s\n', strtrim(regOut));

    fprintf('\n[3/5] Querying Windows PnP USB / UART / Serial Devices...\n');
    psPnp = [ ...
        'powershell -NoProfile -Command "' ...
        'Get-CimInstance Win32_PnPEntity | Where-Object { ' ...
        '$_.Name -match ''COM\d+|CP210|CH340|CH341|FTDI|Silicon|USB.*Serial|UART|ESP'' -or $_.ConfigManagerErrorCode -ne 0 ' ...
        '} | Select-Object Status,ConfigManagerErrorCode,Name,DeviceID | Format-Table -AutoSize | Out-String -Width 180"' ...
    ];
    [~, pnpOut] = system(psPnp);
    fprintf('%s\n', strtrim(pnpOut));

    fprintf('\n[4/5] Running arduino-cli board list...\n');
    [~, acliOut] = system('arduino-cli board list');
    fprintf('%s\n', strtrim(acliOut));

    fprintf('\n[5/5] Checking Wi-Fi SSID & ESP32_LAB (192.168.4.1) reachability...\n');
    [~, wifiOut] = system('powershell -NoProfile -Command "netsh wlan show interfaces | Select-String ''SSID|State''; Test-Connection -ComputerName 192.168.4.1 -Count 1 -Quiet"');
    fprintf('%s\n', strtrim(wifiOut));
    fprintf('====================================================================\n\n');
end

function pnpMap = get_windows_port_descriptions()
    pnpMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
    if ~ispc, return; end
    psCmd = [ ...
        'powershell -NoProfile -Command "' ...
        'Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match ''\(COM\d+\)''} | ForEach-Object { ''PNP|'' + $_.Name }; ' ...
        '$reg = Get-ItemProperty ''HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'' -ErrorAction SilentlyContinue; ' ...
        'if ($reg) { $reg.PSObject.Properties | Where-Object {$_.Value -match ''^COM\d+$''} | ForEach-Object { ''REG|'' + $_.Value + ''|'' + $_.Name } }"' ...
    ];
    [st, out] = system(psCmd);
    if st ~= 0, return; end
    lines = splitlines(string(strtrim(out)));
    for k = 1:numel(lines)
        ln = strtrim(lines(k));
        if startsWith(ln, "PNP|")
            desc = extractAfter(ln, "PNP|");
            tok = regexp(desc, '\((COM\d+)\)', 'tokens', 'once');
            if ~isempty(tok)
                pnpMap(char(tok{1})) = char(desc);
            end
        elseif startsWith(ln, "REG|")
            parts = split(ln, "|");
            if numel(parts) >= 3
                cPort = char(strtrim(parts(2)));
                devName = char(strtrim(parts(3)));
                if isKey(pnpMap, cPort)
                    pnpMap(cPort) = [pnpMap(cPort) ' [' devName ']'];
                else
                    pnpMap(cPort) = ['Kernel Device: ' devName];
                end
            end
        end
    end
end

function db = get_sfr_database()
    persistent cachedDb
    if ~isempty(cachedDb)
        db = cachedDb;
        return;
    end
    rootDir = fileparts(mfilename('fullpath'));
    jsonPath = fullfile(rootDir, 'databases', 'esp32_sfr.json');
    if ~isfile(jsonPath)
        jsonPathAlt = fullfile(rootDir, 'esp32_sfr.json');
        if isfile(jsonPathAlt)
            jsonPath = jsonPathAlt;
        elseif exist('buildSfrDatabase', 'file') == 2
            if ~isfolder(fullfile(rootDir, 'databases'))
                mkdir(fullfile(rootDir, 'databases'));
            end
            cachedDb = buildSfrDatabase(jsonPath);
            db = cachedDb;
            return;
        else
            cachedDb = struct('derivative', 'ESP32', 'registers', struct());
            db = cachedDb;
            return;
        end
    end
    cachedDb = jsondecode(fileread(jsonPath));
    db = cachedDb;
end

function addrMap = get_address_to_name_map()
    persistent cachedMap
    if ~isempty(cachedMap)
        addrMap = cachedMap;
        return;
    end
    cachedMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
    db = get_sfr_database();
    fns = fieldnames(db.registers);
    for i = 1:numel(fns)
        r = db.registers.(fns{i});
        if isfield(r, 'address')
            aKey = upper(char(r.address));
            aKey = strrep(aKey, '0X', '0x');
            if ~isKey(cachedMap, aKey)
                cachedMap(aKey) = fns{i};
            end
        end
    end
    addrMap = cachedMap;
end

function [addr, symName, regMeta] = resolve_sfr_address(in)
    symName = "";
    regMeta = [];
    if isnumeric(in)
        addr = uint32(in);
        addrMap = get_address_to_name_map();
        aKey = sprintf('0x%08X', addr);
        if isKey(addrMap, aKey)
            symName = string(addrMap(aKey));
            db = get_sfr_database();
            regMeta = db.registers.(symName);
        end
        return;
    end
    str = strtrim(char(in));
    db = get_sfr_database();
    uStr = upper(str);
    if isfield(db.registers, uStr)
        symName = string(uStr);
        regMeta = db.registers.(uStr);
        addr = parse_num(regMeta.address);
        return;
    end
    if isfield(db.registers, [uStr '_REG'])
        symName = string([uStr '_REG']);
        regMeta = db.registers.([uStr '_REG']);
        addr = parse_num(regMeta.address);
        return;
    end
    addr = parse_num(str);
    addrMap = get_address_to_name_map();
    aKey = sprintf('0x%08X', addr);
    if isKey(addrMap, aKey)
        symName = string(addrMap(aKey));
        regMeta = db.registers.(symName);
    end
end

function print_active_bitfields(bitfieldsStruct, regVal)
    bfs = fieldnames(bitfieldsStruct);
    if isempty(bfs), return; end
    activeList = strings(0, 1);
    for i = 1:numel(bfs)
        bf = bitfieldsStruct.(bfs{i});
        lsb = double(bf.offset);
        w   = double(bf.width);
        mask = bitshift(uint32(2^w - 1), lsb);
        fv = bitshift(bitand(regVal, mask), -lsb);
        if fv ~= 0
            activeList(end+1) = sprintf('%s=0x%X(%u)', bfs{i}, fv, fv); %#ok<AGROW>
        end
    end
    if isempty(activeList)
        fprintf('    Bitfields: (All bitfields = 0)\n');
    else
        fprintf('    Non-zero Bitfields: %s\n', strjoin(activeList, ', '));
    end
end

function num = parse_num(in)
    if isnumeric(in)
        num = uint32(in);
        return;
    end
    str = strtrim(char(in));
    str = regexprep(str, '^0[xX]', '');
    if any(ismember(upper(str), 'ABCDEF')) || length(str) >= 7
        num = uint32(hex2dec(str));
    else
        valDec = str2double(str);
        if isnan(valDec)
            num = uint32(hex2dec(str));
        else
            num = uint32(valDec);
        end
    end
end

function b = format_bin32(val)
    raw = dec2bin(val, 32);
    b = sprintf('%s_%s_%s_%s_%s_%s_%s_%s', ...
        raw(1:4), raw(5:8), raw(9:12), raw(13:16), ...
        raw(17:20), raw(21:24), raw(25:28), raw(29:32));
end