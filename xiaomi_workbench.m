%% ESP32 Embedded Workbench: UDE Memory Viewer + Xiaomi Scale S400 BLE Bridge
addpath('src');
clear; clc;

%% 1. Autonomous Compile, Flash, and Link
doFlash = true; % Set false to skip reflashing
if doFlash
    port = Esp32.flashAndConnect();
else
    port = "auto";
end

%% 2. Connect Root Object "Reg" to the Physical ESP32
Reg = Esp32(port, "databases/esp32_sfr.json");

%% 3. Hardware Bitfield Manipulation & Live IRAM Code Injection
Reg.GPIO_ENABLE_REG.GPIO2 = 1;
Reg.GPIO_OUT_REG.GPIO2 = 1;
pause(0.2);
Reg.GPIO_OUT_REG.GPIO2 = 0;

ret = Reg.patchAndExecGPIO2Toggle(1337);
fprintf('[+] Live IRAM code injected at 0x%08X and executed! Return value = %u\n', Reg.IramAddr, ret);

%% 4. Initialize Xiaomi Body Composition Scale S400 (0x3BD5) Module
Scale = Reg.connectXiaomiScale("databases/xiaomi_s400_history.csv");

% Trigger an initial hardware AES-CCM encrypted S400 weigh-in on the ESP32
% (Populates dram_test_buf[8..18] and logs the first entry to CSV)
Scale.triggerSimulatedWeighIn();

%% 5. Launch Both Interactive Engineering Windows
% Window 1: PLS UDE 2026 Live Memory Viewer (Inspects DRAM including Scale words at +0x20..+0x48)
memViewer = Reg.openMemoryViewer(Reg.DramAddr);

% Window 2: Xiaomi S400 BLE MiBeacon & Dual-Frequency BIA Dashboard
scaleViewer = Scale.openViewer();