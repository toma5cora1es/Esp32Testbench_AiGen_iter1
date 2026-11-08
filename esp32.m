classdef esp32 < handle
%ESP32 Lightweight Object-Oriented Facade over the esp32.m CLI engine and esp32_flash.m
%   Usage examples:
%     esp32_cli().Flash('C:\path\my_sketch.ino')
%     dev = esp32_cli('192.168.4.1');          % Connect via Wi-Fi
%     dev = esp32_cli('ESP32_BT_BRIDGE');      % Connect via Bluetooth SPP
%     dev = esp32_cli('COM9');                 % Connect via USB Serial or BT Virtual COM
%     dev.Pin(2, 'high');
%     val = dev.Reg(0x3FF44004);

    methods
        function obj = esp32_cli(target, varargin)
            if nargin >= 1 && ~isempty(target)
                esp32_cli('connect', target, varargin{:});
            end
        end

        function ok = Connect(~, target, varargin)
            % Connect via Wi-Fi IP, USB COM port, or Bluetooth ('bt:ESP32_BT_BRIDGE')
            ok = esp32_cli('connect', target, varargin{:});
        end

        function ok = ConnectBluetooth(~, btNameOrAddress, channel)
            % Explicit helper for Bluetooth Classic SPP connection
            if nargin < 2 || isempty(btNameOrAddress)
                btNameOrAddress = 'ESP32_BT_BRIDGE';
            end
            target = ['bt:' char(btNameOrAddress)];
            if nargin >= 3 && ~isempty(channel)
                ok = esp32_cli('connect', target, channel);
            else
                ok = esp32_cli('connect', target);
            end
        end

        function Disconnect(~)
            esp32_cli('disconnect');
        end

        function out = Scan(~, varargin)
            out = esp32_cli('scan', varargin{:});
        end

        function ok = Flash(~, pathToFile, varargin)
            % Allows: esp32_cli().Flash('C:\path\sketch.ino') or esp32_cli().Flash(path, '--wifi')
            ok = esp32_flash(pathToFile, varargin{:});
        end

        function out = Reg(~, addr, varargin)
            out = esp32_cli('reg', addr, varargin{:});
        end

        function out = Bits(~, addr, msb, lsb, varargin)
            out = esp32_cli('bits', addr, msb, lsb, varargin{:});
        end

        function out = Pin(~, gpio, varargin)
            out = esp32_cli('pin', gpio, varargin{:});
        end

        function out = Led(~, state)
            if nargin < 2, state = 'toggle'; end
            out = esp32_cli('led', state);
        end

        function out = Adc(~, gpio)
            out = esp32_cli('adc', gpio);
        end

        function out = Dump(~, baseAddr, count)
            if nargin < 2, baseAddr = 0x3FF44000; end
            if nargin < 3, count = 8; end
            out = esp32_cli('dump', baseAddr, count);
        end

        function out = Status(~)
            out = esp32_cli('status');
        end

        function Gui(~)
            esp32_gui();
        end
    end
end