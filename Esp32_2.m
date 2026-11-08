classdef Esp32_2 < handle
%ESP32 Lightweight Object-Oriented Facade over the esp32.m CLI engine and esp32_flash.m
%   Usage examples:
%     Esp32().Flash('C:\path\my_sketch.ino')
%     dev = Esp32('192.168.4.1');          % Connect via Wi-Fi
%     dev = Esp32('ESP32_BT_BRIDGE');      % Connect via Bluetooth SPP
%     dev = Esp32('COM9');                 % Connect via USB Serial or BT Virtual COM
%     dev.Pin(2, 'high');
%     val = dev.Reg(0x3FF44004);

    methods
        function obj = Esp32(target, varargin)
            if nargin >= 1 && ~isempty(target)
                esp32('connect', target, varargin{:});
            end
        end

        function ok = Connect(~, target, varargin)
            % Connect via Wi-Fi IP, USB COM port, or Bluetooth ('bt:ESP32_BT_BRIDGE')
            ok = esp32('connect', target, varargin{:});
        end

        function ok = ConnectBluetooth(~, btNameOrAddress, channel)
            % Explicit helper for Bluetooth Classic SPP connection
            if nargin < 2 || isempty(btNameOrAddress)
                btNameOrAddress = 'ESP32_BT_BRIDGE';
            end
            target = ['bt:' char(btNameOrAddress)];
            if nargin >= 3 && ~isempty(channel)
                ok = esp32('connect', target, channel);
            else
                ok = esp32('connect', target);
            end
        end

        function Disconnect(~)
            esp32('disconnect');
        end

        function out = Scan(~, varargin)
            out = esp32('scan', varargin{:});
        end

        function ok = Flash(~, pathToFile, varargin)
            % Allows: Esp32().Flash('C:\path\sketch.ino') or Esp32().Flash(path, '--wifi')
            ok = esp32_flash(pathToFile, varargin{:});
        end

        function out = Reg(~, addr, varargin)
            out = esp32('reg', addr, varargin{:});
        end

        function out = Bits(~, addr, msb, lsb, varargin)
            out = esp32('bits', addr, msb, lsb, varargin{:});
        end

        function out = Pin(~, gpio, varargin)
            out = esp32('pin', gpio, varargin{:});
        end

        function out = Led(~, state)
            if nargin < 2, state = 'toggle'; end
            out = esp32('led', state);
        end

        function out = Adc(~, gpio)
            out = esp32('adc', gpio);
        end

        function out = Dump(~, baseAddr, count)
            if nargin < 2, baseAddr = 0x3FF44000; end
            if nargin < 3, count = 8; end
            out = esp32('dump', baseAddr, count);
        end

        function out = Status(~)
            out = esp32('status');
        end

        function Gui(~)
            esp32_gui();
        end
    end
end