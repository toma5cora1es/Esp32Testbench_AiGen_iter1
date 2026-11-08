function varargout = esp32(cmd, varargin)
%ESP32 CLI-First Workbench for ESP32 (Registers, Pins, ADC, Memory, Flash OTA, Bluetooth, and GUI).
%
% CONSOLE USAGE (PURE CLI SYNTAX):
%   esp32 scan                           % List available COM ports (use 'esp32 scan --bt' for Bluetooth)
%   esp32 connect COM9                   % Connect via USB Serial or Bluetooth Virtual COM port
%   esp32 connect ESP32_BT_BRIDGE        % Connect natively via Bluetooth SPP (Name or MAC address)
%   esp32 connect 192.168.4.1            % Connect via Wi-Fi (ESP32_LAB AP)
%   esp32 status                         % Display chip status and uptime
%   esp32 pin 2 high                     % Turn on the built-in LED (GPIO 2)
%   esp32 pin 2 low                      % Turn off the built-in LED (GPIO 2)
%   esp32 pin 2 toggle                   % Toggle GPIO 2 state
%   esp32 adc 34                         % Read ADC on GPIO 34 (0-4095 and Voltage)
%   esp32 reg 0x3FF44004                 % Read register GPIO_OUT_REG
%   esp32 reg 0x3FF44004 0x00000004      % Write to register
%   esp32 bits 0x3FF44004 2 2 1          % Modify bits [msb:lsb] without affecting the rest
%   esp32 dump 0x3FF44000 10             % Display Hex/Binary table of 10 registers
%   esp32 flash my_sketch.ino --wifi     % Compile, inject Core0 OTA+BT, and flash over Wi-Fi
%   esp32 flash my_sketch.ino --usb COM9 % Compile and flash via USB cable
%   esp32 gui                            % Open the UDE Workbench graphical interface
%   esp32 disconnect                     % Close the active port/connection

    if nargin == 0
        help esp32;
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
            fprintf('\n=== Detected Serial / Virtual BT Ports ===\n');
            if isempty(ports)
                fprintf('  (No COM ports detected. Check USB data cable or Bluetooth pairing)\n');
            else
                for p = ports
                    tag = "BUSY";
                    if any(p == avail), tag = "AVAILABLE"; end
                    fprintf('  %-8s [%s]\n', p, tag);
                end
            end

            btTargets = string.empty;
            if ~isempty(varargin) && any(strcmpi(string(varargin), {'--bt', '-b', 'bt', 'bluetooth'}))
                fprintf('\n=== Scanning Native Bluetooth SPP Devices ===\n');
                try
                    btTable = bluetoothlist("Timeout", 4);
                    if isempty(btTable)
                        fprintf('  (No Bluetooth SPP devices found)\n');
                    else
                        for r = 1:height(btTable)
                            bName = string(btTable.Name(r));
                            bAddr = string(btTable.Address(r));
                            fprintf('  %-22s [%s]\n', bName, bAddr);
                            if strlength(bName) > 0 && bName ~= "Unknown"
                                btTargets(end+1) = "bt:" + bName; %#ok<AGROW>
                            else
                                btTargets(end+1) = "bt:" + bAddr; %#ok<AGROW>
                            end
                        end
                    end
                catch
                    fprintf('  (Native bluetoothlist unavailable or Bluetooth adapter is off)\n');
                end
            end

            fprintf('\n  Default Bluetooth SPP Name : ESP32_BT_BRIDGE (Connect with: esp32 connect ESP32_BT_BRIDGE)\n');
            fprintf('  Default Wi-Fi AP           : 192.168.4.1     (SSID: ESP32_LAB / Pass: 12345678)\n\n');
            if nargout > 0
                varargout{1} = unique([avail, "bt:ESP32_BT_BRIDGE", btTargets], 'stable');
            end

        case 'connect'
            if isempty(varargin)
                error('Usage: esp32 connect <COMx | IP | bt:DeviceName | ESP32_BT_BRIDGE>');
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

        case 'reg'
            if isempty(varargin)
                error('Usage: esp32 reg <addr_hex> [val_hex]');
            end
            addr = parse_num(varargin{1});
            addrHex = sprintf('%08X', addr);
            if numel(varargin) == 1
                % Register read
                resp = esp32_io('cmd', ['R ' addrHex]);
                val = parse_num(resp);
                if nargout == 0
                    fprintf('  [REG 0x%08X] = 0x%08X (%10u) | Bin: %s\n', ...
                        addr, val, val, format_bin32(val));
                else
                    varargout{1} = val;
                end
            else
                % Register write
                val = parse_num(varargin{2});
                valHex = sprintf('%08X', val);
                resp = esp32_io('cmd', sprintf('W %s %s', addrHex, valHex));
                rb = parse_num(resp);
                if nargout == 0
                    fprintf('  [WRITE 0x%08X] <= 0x%08X (Readback: 0x%08X)\n', addr, val, rb);
                else
                    varargout{1} = rb;
                end
            end

        case 'bits'
            % Read-Modify-Write of a bitfield: esp32 bits <addr> <msb> <lsb> [newVal]
            if numel(varargin) < 3
                error('Usage: esp32 bits <addr> <msb> <lsb> [value]');
            end
            addr = parse_num(varargin{1});
            msb  = double(parse_num(varargin{2}));
            lsb  = double(parse_num(varargin{3}));
            width = msb - lsb + 1;
            mask = bitshift(uint32(2^width - 1), lsb);
            curVal = esp32('reg', addr);
            if numel(varargin) == 3
                fieldVal = bitshift(bitand(curVal, mask), -lsb);
                if nargout == 0
                    fprintf('  [BITS 0x%08X [%d:%d]] = %u (0x%X)\n', addr, msb, lsb, fieldVal, fieldVal);
                else
                    varargout{1} = fieldVal;
                end
            else
                newField = bitand(uint32(parse_num(varargin{4})), uint32(2^width - 1));
                cleared = bitand(curVal, bitcmp(mask, 'uint32'));
                updated = bitor(cleared, bitshift(newField, lsb));
                rb = esp32('reg', addr, updated);
                if nargout == 0
                    fprintf('  [BITS 0x%08X [%d:%d]] <= %u -> New Reg: 0x%08X\n', addr, msb, lsb, newField, rb);
                else
                    varargout{1} = rb;
                end
            end

        case {'pin', 'led'}
            % Usage: esp32 pin 2 high | low | toggle | read
            % Also supports shortcut: esp32 led on | off | toggle (uses GPIO 2)
            if strcmp(action, 'led')
                pinNum = 2;
                pinCmd = 'toggle';
                if ~isempty(varargin), pinCmd = lower(char(varargin{1})); end
            else
                if isempty(varargin), error('Usage: esp32 pin <gpio> [high|low|toggle|read]'); end
                pinNum = double(parse_num(varargin{1}));
                pinCmd = 'read';
                if numel(varargin) >= 2, pinCmd = lower(char(varargin{2})); end
            end

            % Try the firmware's native PIN command first
            resp = esp32_io('cmd', sprintf('PIN %d %s', pinNum, upper(pinCmd)));
            if startsWith(resp, 'ERR') && pinNum < 32
                % Fallback using Atomic Registers W1TS / W1TC (works even with legacy firmware)
                mask = bitshift(uint32(1), pinNum);
                if any(strcmp(pinCmd, {'r', 'read'}))
                    inReg = esp32('reg', GPIO_IN_REG);
                    state = double(bitand(inReg, mask) ~= 0);
                else
                    % 1. Enable pad as output in GPIO_ENABLE_W1TS_REG (0x3FF44024)
                    esp32('reg', GPIO_ENABLE_W1TS_REG, mask);
                    % 2. Write to W1TS (Set) or W1TC (Clear)
                    if any(strcmp(pinCmd, {'1', 'high', 'on'}))
                        esp32('reg', GPIO_OUT_W1TS_REG, mask);
                        state = 1;
                    elseif any(strcmp(pinCmd, {'0', 'low', 'off'}))
                        esp32('reg', GPIO_OUT_W1TC_REG, mask);
                        state = 0;
                    else % toggle
                        curOut = esp32('reg', GPIO_OUT_REG);
                        if bitand(curOut, mask)
                            esp32('reg', GPIO_OUT_W1TC_REG, mask);
                            state = 0;
                        else
                            esp32('reg', GPIO_OUT_W1TS_REG, mask);
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
            if isempty(varargin), error('Usage: esp32 adc <gpio>'); end
            pinNum = double(parse_num(varargin{1}));
            resp = esp32_io('cmd', sprintf('ADC %d', pinNum));
            raw = str2double(resp);
            volts = (raw / 4095.0) * 3.3;
            if nargout == 0
                fprintf('  [ADC GPIO %02d] = %4d / 4095  (%.3f V)\n', pinNum, raw, volts);
            else
                varargout{1} = raw;
            end

        case 'dump'
            if isempty(varargin), baseAddr = uint32(hex2dec('3FF44000'));
            else, baseAddr = parse_num(varargin{1}); end
            count = 8;
            if numel(varargin) >= 2, count = double(parse_num(varargin{2})); end
            resp = esp32_io('cmd', sprintf('D %08X %d', baseAddr, count));
            if startsWith(resp, 'ERR')
                % Fallback reading register-by-register
                vals = zeros(1, count, 'uint32');
                for i = 1:count
                    vals(i) = esp32('reg', baseAddr + uint32((i-1)*4));
                end
            else
                hexParts = strsplit(strtrim(resp));
                vals = uint32(hex2dec(hexParts));
            end
            if nargout == 0
                fprintf('\n  Address     | Hexadecimal | Decimal    | Binary (31..0)\n');
                fprintf('  ------------+-------------+------------+------------------------------------\n');
                for i = 1:numel(vals)
                    a = baseAddr + uint32((i-1)*4);
                    v = vals(i);
                    fprintf('  0x%08X  | 0x%08X  | %10u | %s\n', a, v, v, format_bin32(v));
                end
                fprintf('\n');
            else
                varargout{1} = vals;
            end

        case 'flash'
            if isempty(varargin)
                error('Usage: esp32 flash <path_to_file.ino_or_.bin> [--wifi | --usb COMx]');
            end
            ok = esp32_flash(varargin{:});
            if nargout > 0, varargout{1} = ok; end

        case 'gui'
            esp32_gui();

        otherwise
            error('Unknown command: "%s". Type "help esp32" to view the command list.', action);
    end
end

function num = parse_num(in)
    if isnumeric(in)
        num = uint32(in);
        return;
    end
    str = strtrim(char(in));
    str = regexprep(str, '^0[xX]', '');
    % If it contains hexadecimal letters or has 8 characters like an ESP32 register
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