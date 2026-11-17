classdef esp32 < handle
%ESP32 Lightweight Object-Oriented Facade over the esp32_cli.m engine and esp32_flash.m
%   Usage examples:
%     esp32().Verbose('on');                    % Enable live FSM & Wire-Protocol tracing
%     esp32().Fsm();                            % Display current FSM state
%     esp32().Flash('C:\Users\tomas\MATLAB\esp32_workbench_gemini\firmware\esp32_bridge_ota\beep_fast.ino')
%     dev = esp32('192.168.4.1');               % Connect via Wi-Fi
%     dev = esp32('ESP32_BT_BRIDGE');           % Connect via Bluetooth SPP
%     dev = esp32('COM8');                      % Connect via USB Serial
%     dev.Pin(2, 'high');                       % Set GPIO 2 HIGH
%     val = dev.Reg('GPIO_OUT_REG');            % Symbolic SFR read via esp32_sfr.json
%     dev.Bits('GPIO_OUT_REG', 'GPIO2', 1);     % Symbolic bitfield write via esp32_sfr.json
%     dev.Web();                                % Open on-chip Web Register Debugger in browser

    methods
        function obj = esp32(target, varargin)
            if nargin >= 1 && ~isempty(target)
                esp32_cli('connect', target, varargin{:});
            end
        end

        function out = Verbose(~, varargin)
            if nargout > 0
                out = esp32_cli('verbose', varargin{:});
            else
                esp32_cli('verbose', varargin{:});
            end
        end

        function out = Fsm(~)
            if nargout > 0
                out = esp32_cli('fsm');
            else
                esp32_cli('fsm');
            end
        end

        function ok = Connect(~, target, varargin)
            ok = esp32_cli('connect', target, varargin{:});
        end

        function ok = ConnectBluetooth(~, btNameOrAddress, channel)
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
            ok = esp32_flash(pathToFile, varargin{:});
        end

        function out = Reg(~, nameOrAddr, varargin)
            if nargout > 0
                out = esp32_cli('reg', nameOrAddr, varargin{:});
            else
                esp32_cli('reg', nameOrAddr, varargin{:});
            end
        end

        function out = Bits(~, nameOrAddr, fieldOrMsb, varargin)
            if nargout > 0
                out = esp32_cli('bits', nameOrAddr, fieldOrMsb, varargin{:});
            else
                esp32_cli('bits', nameOrAddr, fieldOrMsb, varargin{:});
            end
        end

        function out = Sfr(~, varargin)
            if nargout > 0
                out = esp32_cli('sfr', varargin{:});
            else
                esp32_cli('sfr', varargin{:});
            end
        end

        function out = Pin(~, gpio, varargin)
            if nargout > 0
                out = esp32_cli('pin', gpio, varargin{:});
            else
                esp32_cli('pin', gpio, varargin{:});
            end
        end

        function out = Led(~, state)
            if nargin < 2, state = 'toggle'; end
            if nargout > 0
                out = esp32_cli('led', state);
            else
                esp32_cli('led', state);
            end
        end

        function out = Adc(~, gpio)
            if nargout > 0
                out = esp32_cli('adc', gpio);
            else
                esp32_cli('adc', gpio);
            end
        end

        function out = Dump(~, baseAddr, count)
            if nargin < 2, baseAddr = 0x3FF44000; end
            if nargin < 3, count = 8; end
            if nargout > 0
                out = esp32_cli('dump', baseAddr, count);
            else
                esp32_cli('dump', baseAddr, count);
            end
        end

        function out = Status(~)
            if nargout > 0
                out = esp32_cli('status');
            else
                esp32_cli('status');
            end
        end

        function out = DualDeploy(~, varargin)
            out = esp32_dual_deploy(varargin{:});
        end

        function out = Ui(~, templateName)
            out = esp32_cli('ui', templateName);
        end

        function out = Role(~, roleName)
            out = esp32_cli('role', roleName);
        end

        function out = EspNow(~, subCmd)
            if nargin < 2, subCmd = 'STATUS'; end
            out = esp32_cli('espnow', subCmd);
        end

        function out = Slam(~, targetEndpoint)
            if nargin < 2, targetEndpoint = '192.168.4.1'; end
            out = green_agv_slam_mapper(targetEndpoint);
        end

        function Web(~)
            esp32_cli('web');
        end

        function Gui(~)
            esp32_gui();
        end
    end
end