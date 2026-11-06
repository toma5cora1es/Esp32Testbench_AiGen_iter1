% main_workbench.m  -  entry point of the ESP32 UDE-style workbench.
% Normally started by run_all.cmd (which already compiled + flashed the board and passes the COM port in the
% environment). You can also run it by hand from MATLAB: set doFlash = true to compile + flash from here.
addpath(fullfile(fileparts(mfilename('fullpath')), 'src'));
clear; clc;

doFlash = isempty(getenv('UDE_SKIP_FLASH'));     % run_all.cmd sets UDE_SKIP_FLASH=1 (it flashed already)
port    = string(getenv('UDE_PORT'));            % ... and UDE_PORT=COMx
if doFlash
    port = ude.FirmwareBuilder.flashUsb();       % compile + upload over USB (arduino-cli)
elseif port == ""
    port = "auto";
end

% 1. Connect the root object "Reg" to the physical ESP32 (use "sim" to try the windows without a board)
Reg = Esp32(port, "databases/esp32_sfr.json");

% 2. Register & bitfield syntax:  Reg.<REGISTER>.<BITFIELD> = value
Reg.GPIO_ENABLE_REG.GPIO2 = 1;
Reg.GPIO_OUT_REG.GPIO2 = 1;                       % blue D2 LED on
pause(0.3);
Reg.GPIO_OUT_REG.GPIO2 = 0;
Reg.GPIO_OUT_REG.Print();                         % hex value + every bitfield

% 3. Open the workbench: Memory, Memory map, Registers and Live code patcher.
%    The wireless-update console is one click away ("Wireless update (OTA)").
wb = ude.Workbench(Reg);
wb.openAll();
