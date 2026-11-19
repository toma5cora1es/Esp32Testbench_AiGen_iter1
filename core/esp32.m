classdef esp32 < handle
%ESP32 Object-Oriented Facade over esp32_cli & esp32_flash.
    methods
        function obj = esp32(target, varargin)
            if nargin >= 1 && ~isempty(target), esp32_cli('connect', target, varargin{:}); end
        end
        function out = Verbose(~, varargin), out = esp32_cli('verbose', varargin{:}); end
        function out = Fsm(~), out = esp32_cli('fsm'); end
        function ok  = Connect(~, target, varargin), ok = esp32_cli('connect', target, varargin{:}); end
        function ok  = ConnectBluetooth(~, nameOrMac, ch)
            cfg = wb_config('workbench');
            if nargin < 2 || isempty(nameOrMac), nameOrMac = cfg.transport.bluetooth.deviceName; end
            if nargin < 3 || isempty(ch), ch = cfg.transport.bluetooth.rfcommChannel; end
            ok = esp32_cli('connect', ['bt:' char(nameOrMac)], ch);
        end
        function Disconnect(~), esp32_cli('disconnect'); end
        function out = Scan(~), out = esp32_cli('scan'); end
        function [ok, bid] = Flash(~, sketchOrPath, varargin), [ok, bid] = esp32_flash(sketchOrPath, varargin{:}); end
        function out = Reg(~, nameOrAddr, varargin), out = esp32_cli('reg', nameOrAddr, varargin{:}); end
        function out = Bits(~, nameOrAddr, fieldOrMsb, varargin), out = esp32_cli('bits', nameOrAddr, fieldOrMsb, varargin{:}); end
        function out = Sfr(~, varargin), out = esp32_cli('sfr', varargin{:}); end
        function out = Pin(~, gpio, varargin), out = esp32_cli('pin', gpio, varargin{:}); end
        function out = Led(~, state)
            if nargin < 2, state = 'toggle'; end
            out = esp32_cli('led', state);
        end
        function out = Adc(~, gpio), out = esp32_cli('adc', gpio); end
        function out = Agv(~, varargin), out = esp32_cli('agv', varargin{:}); end
        function out = Power(~, profile), out = esp32_cli('power', profile); end
        function out = Dump(~, baseAddr, cnt)
            if nargin < 2, baseAddr = 'GPIO_OUT_REG'; end
            if nargin < 3, cnt = 8; end
            out = esp32_cli('dump', baseAddr, cnt);
        end
        function out = Status(~), out = esp32_cli('status'); end
        function out = DualDeploy(~, varargin), out = esp32_dual_deploy(varargin{:}); end
        function out = Ui(~, tpl), out = esp32_cli('ui', tpl); end
        function out = Role(~, r), out = esp32_cli('role', r); end
        function out = EspNow(~, sub)
            if nargin < 2, sub = 'STATUS'; end
            out = esp32_cli('espnow', sub);
        end
        function Web(~), esp32_cli('web'); end
        function Gui(~, varargin), esp32_cli('gui', varargin{:}); end
    end
end