classdef Config
    % Config  Single place for every constant the host tools share.
    properties (Constant)
        SketchName   = "agv_matlab_bridge"
        Fqbn         = "esp32:esp32:esp32"
        % extra options: silence core log lines on UART0 (they would mix with our replies)
        FqbnTuned    = "esp32:esp32:esp32:DebugLevel=none,PartitionScheme=default"
        ExcludePorts = ["COM3", "COM5", "COM6"]   % COM ports of OTHER devices on your PC
        ApSsid       = "ESP32_UDE_BRIDGE"
        ApPass       = "12345678"
        ApIp         = "192.168.4.1"
        CtrlPort     = 3333      % control channel (R/RB/W/EXEC/INFO)
        OtaPort      = 3334      % firmware streaming channel (OTA)
        Baud         = 115200
    end
    methods (Static)
        function r = root()
            % <project>/src/+ude/Config.m  ->  <project>
            r = fileparts(fileparts(fileparts(mfilename('fullpath'))));
        end
        function p = sketchDir()
            p = fullfile(ude.Config.root(), 'firmware', char(ude.Config.SketchName));
        end
        function p = sfrJson()
            p = fullfile(ude.Config.root(), 'databases', 'esp32_sfr.json');
        end
    end
end
