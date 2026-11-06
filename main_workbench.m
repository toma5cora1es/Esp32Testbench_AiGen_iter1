%% ESP32 Embedded Workbench: Memory Engine & Live Code Patcher
addpath('src');
clear; clc;

%% 1. Autonomous Compile, Flash, and Link
doFlash = true; % Set to false to connect directly without reflashing
if doFlash
    port = Esp32.flashAndConnect();
else
    port = "auto";
end

%% 2. Instantiate MCU Session
Reg = Esp32(port, "databases/esp32_sfr.json");

%% 3. Hardware Bitfield Manipulation
fprintf('\n--- 1. Testing Peripheral Special Function Registers ---\n');
Reg.GPIO_ENABLE_REG.GPIO2 = 1;
Reg.GPIO_OUT_REG.GPIO2 = 1; % Turn blue LED ON
pause(0.25);
Reg.GPIO_OUT_REG.GPIO2 = 0; % Turn blue LED OFF
Reg.GPIO_OUT_REG.Print();

%% 4. Live IRAM Machine Code Injection (Zero-Reboot)
fprintf('\n--- 2. Live Xtensa LX6 Code Injection into IRAM ---\n');
injectedReturnConstant = 1337;
ret = Reg.patchAndExecGPIO2Toggle(injectedReturnConstant);
fprintf('[+] Executed dynamically assembled stub at 0x%08X! CPU Returned: %u\n', ...
    Reg.IramAddr, ret);

%% 5. Launch PLS UDE 2026-Style Memory Window
fprintf('\n--- 3. Launching Interactive UDE Memory Viewer ---\n');
% Opens inspection at the test buffer in DRAM (0x3FFBxxxx)
viewer = Reg.openMemoryViewer(Reg.DramAddr);