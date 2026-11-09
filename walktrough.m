%[text] ## Step 1: Project Initialization & SFR Database Setup

%%\ 1.1 Set Working Directory and Add All Subfolders to Path
cd('C:\Users\tomas\MATLAB\esp32_workbench_v3');
addpath(genpath(pwd));

%%\ 1.2 Verify or Rebuild the Compiled ESP32 SFR Database (databases/esp32_sfr.json)
% Parses ESP-IDF C headers (*_reg.h + soc.h) into a structured JSON database
if ~isfile(fullfile('databases', 'esp32_sfr.json'))
    if ~isfolder('databases'), mkdir('databases'); end
    buildSfrDatabase(fullfile('databases', 'esp32_sfr.json'));
end

%%\ 1.3 View CLI & OOP Quick Help
help esp32_cli %[output:55c74bfa]
help esp32 %[output:545ed589]
%%
%[text] ## Step 2: Autonomous Hardware Diagnostics & First USB Bootstrap Flash
%[text] Before using Wi-Fi OTA, Bluetooth SPP, or the Web Register Workbench, run the autonomous hardware diagnostic (`esp32_cli debug`) to verify the physical USB cable (`USB-SERIAL CH340 (COM9)`) and flash the base bridge firmware once over USB.

%%\ 2.1 Run Autonomous PowerShell & MATLAB Hardware Diagnostics
% Inspects open MATLAB handles, Registry SERIALCOMM kernel drivers,
% Windows PnP USB-UART bridges (CH340/CP210x), arduino-cli, and Wi-Fi status.
esp32_cli debug %[output:0125afd8]

%%\ 2.2 Scan Available Serial & Virtual Bluetooth Ports
esp32_cli scan %[output:6dc2a3a0]

%%\ 2.3 Flash the Base Bridge Firmware over USB (Auto-Detects COM9!)
% Automatically isolates the build, injects the Core-0 Web + Wi-Fi OTA + BT Daemon,
% and flashes over your physical USB port (COM9).
esp32_cli flash C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\esp32_bridge_ota.ino --usb %[output:7ee75035]

% --- Explicit COM Port or OOP Equivalent ---
% esp32_cli flash C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\esp32_bridge_ota.ino --usb COM9
% esp32().Flash('C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\esp32_bridge_ota.ino', '--usb');
%%
%[text] ## Step 3: Connecting to the ESP32 (All 3 Transport Modes)
%[text] Once the Core-0 daemon is flashed, it runs simultaneously on three interfaces: **USB Serial (****`COM9`****)**, **Bluetooth Classic SPP (****`ESP32_BT_BRIDGE`** **/** **`COM11`****)**, and **Wi-Fi SoftAP (****`ESP32_LAB`** **at** **`192.168.4.1`****)**. Every CLI and OOP command works identically across all three modes.
%[text] 
%[text] **Option A: Connect via Physical USB Serial (****`COM9`****)** 

%%\ 3A. Connect over USB Serial (115200 baud)
esp32_cli connect COM8 %[output:1aad0713]
esp32_cli status %[output:62585460]

% --- Equivalent OOP Syntax ---
dev = esp32('COM8'); %[output:4be5b9fa]
dev.Status() %[output:3169df34]
%[text] **Option B: Connect via Bluetooth Classic SPP (****`ESP32_BT_BRIDGE`** **or** **`COM11`****)**
%[text] Your diagnostic report showed `ESP32_BT_BRIDGE` paired in Windows with virtual serial port `COM11`. You can connect either via native MATLAB Bluetooth SPP or via its virtual COM port:
%[text] 
%%\ 3B.1 Connect via Native MATLAB Bluetooth SPP
esp32_cli connect ESP32_BT_BRIDGE %[output:91361d13]
esp32_cli status %[output:7fbc5b19]

%%\ 3B.2 Or Connect via Bluetooth Virtual COM Port (Fast Serial Transport)
esp32_cli connect COM11 %[output:078fe655]
esp32_cli status %[output:79b531a4]

% --- Equivalent OOP Syntax ---
dev = esp32();
dev.ConnectBluetooth('ESP32_BT_BRIDGE'); %[output:55813cca]
dev.Status() %[output:2501187d]
%[text] 
%[text] **Option C: Connect via Wi-Fi (****`ESP32_LAB`** **SoftAP at** **`192.168.4.1`****)**
%[text] The ESP32 broadcasts the Wi-Fi network **`ESP32_LAB`** (Password: **`12345678`**, IP: **`192.168.4.1`**).
%[text] *(Note: With the updated* *`esp32_io.m`**, running* *`esp32_cli connect 192.168.4.1`* *automatically creates the Windows WLAN profile and switches your PC's Wi-Fi to* *`ESP32_LAB`**.)*
%%\ 3C. Connect over Wi-Fi HTTP Bridge (http://192.168.4.1)
esp32_cli connect 192.168.4.1 %[output:5c9372a5]
esp32_cli status %[output:2c3a6f21]

% --- Equivalent OOP Syntax ---
dev = esp32('192.168.4.1'); %[output:085786d3]
dev.Status() %[output:5722c0ee]
%[text] 
%[text] **Disconnecting**
%%\ 3D. Close Active Connection (Releases COM9 / Bluetooth / Wi-Fi session)
esp32_cli disconnect %[output:8fb8cac8]

% --- Equivalent OOP Syntax ---
dev.Disconnect(); %[output:702cd3f0]
%[text] 
%%
%[text] ## Step 4: Exploring the `esp32_sfr.json` Register Database
%[text] Query the compiled `databases/esp32_sfr.json` database directly from the MATLAB Command Window to inspect register addresses and bitfield definitions (`[MSB:LSB]`) without leaving MATLAB.

%%\ 4.1 Show SFR Database Summary (Derivative & Total Register Count)
esp32_cli sfr %[output:4b0d56c1]

%%\ 4.2 Search Registers by Peripheral Prefix or Keyword
esp32_cli sfr GPIO          % All GPIO matrix registers %[output:26b25698]
esp32_cli sfr IO_MUX        % Pad configuration registers (pull-up, drive strength) %[output:7ce03bce]
esp32_cli sfr LEDC          % PWM / LED Controller registers %[output:9d5288b5]
esp32_cli sfr RTC_CNTL      % RTC Control & scratchpad registers %[output:99c4ae2b]

%%\ 4.3 Inspect the Bitfield Map of Specific Registers
esp32_cli sfr GPIO_OUT_REG %[output:6820bd3e]
esp32_cli sfr IO_MUX_GPIO2_REG %[output:76890b3d]
esp32_cli sfr RTC_CNTL_STORE0_REG %[output:58f09e0c]

% --- Equivalent OOP Syntax ---
regMeta = esp32().Sfr('GPIO_OUT_REG'); %[output:1f1c270e]

%[text] 
%%
%[text] ## Step 5: High-Level Digital GPIO, Built-in LED & ADC Commands
%[text] First, connect over your preferred transport (for example `esp32_cli connect COM9`) and test the hardware pins with high-level commands:
%%\ Ensure we have an active connection
esp32_cli connect COM8 %[output:9c806797]

%%\ 5.1 Built-in LED Shortcuts (Controls GPIO 2)
esp32_cli led on            % Turn built-in LED (GPIO 2) ON %[output:0c4009ae]
pause(0.5);
esp32_cli led off           % Turn built-in LED (GPIO 2) OFF %[output:88e35f65]
pause(0.5);
esp32_cli led toggle        % Toggle built-in LED (GPIO 2) %[output:2c9aec34]

% --- Equivalent OOP Syntax ---
dev = esp32('COM8'); %[output:854aedb9]
dev.Led('on'); %[output:297bc3a2]
dev.Led('off'); %[output:2c16ec5b]
dev.Led('toggle'); %[output:0b758049]

%%\ 5.2 General-Purpose Digital Pin Control (Any GPIO Pin)
esp32_cli pin 2 high        % Set GPIO 2 HIGH (3.3V) %[output:1f1d9639]
esp32_cli pin 2 read        % Read digital state of GPIO 2 (returns 1) %[output:798f2971]
esp32_cli pin 2 low         % Set GPIO 2 LOW  (0V) %[output:8b02e5ad]
esp32_cli pin 2 toggle      % Toggle GPIO 2 %[output:205d0c91]

esp32_cli pin 4 high        % Activate GPIO 4 (Buzzer / External Output) %[output:667809c7]
pause(0.2);
esp32_cli pin 4 low         % Deactivate GPIO 4 %[output:1ec39d2c]

% --- Equivalent OOP Syntax ---
dev.Pin(2, 'high'); %[output:7077c870]
state = dev.Pin(2, 'read');
dev.Pin(2, 'low'); %[output:1ded49e6]

%%\ 5.3 Analog-to-Digital Converter (ADC1 Pins: GPIO 32..39)
esp32_cli adc 34            % Reads 12-bit raw value (0..4095) and Voltage (0.000..3.300 V) %[output:16edbf77]
esp32_cli adc 35 %[output:946641dc]

% --- Equivalent OOP Syntax ---
rawAdc = dev.Adc(34);
%%
%[text] ## Step 6: Direct 32-Bit Register, Bitfield & Memory Manipulation
%[text] This section demonstrates bare-metal hardware access using both **raw hexadecimal addresses** (`0x3FF44004`) and **symbolic SFR names** (`GPIO_OUT_REG`) from `databases/esp32_sfr.json`.
%[text] **6.1. Reading & Writing 32-Bit Registers by Hex Address**
%%\ Read GPIO Output Register (0x3FF44004) and GPIO Input Register (0x3FF4403C)
esp32_cli reg 0x3FF44004 %[output:2b9fad3e]
esp32_cli reg 0x3FF4403C %[output:1ce7dae9]

%%\ Atomic GPIO 2 Control via Set/Clear Hardware Registers (Bit 2 = 0x00000004)
esp32_cli reg 0x3FF44024 0x00000004   % GPIO_ENABLE_W1TS_REG : Enable GPIO 2 as Output %[output:7b0438a3]
esp32_cli reg 0x3FF44008 0x00000004   % GPIO_OUT_W1TS_REG    : Set GPIO 2 HIGH (LED ON) %[output:93bba2df]
esp32_cli reg 0x3FF44004              % Read back GPIO_OUT_REG (verify Bit 2 == 1) %[output:5916f1c1]
esp32_cli reg 0x3FF4400C 0x00000004   % GPIO_OUT_W1TC_REG    : Clear GPIO 2 LOW (LED OFF) %[output:2c6ba377]

% --- Equivalent OOP Syntax ---
val = dev.Reg(0x3FF44004);
dev.Reg(0x3FF44008, 0x00000004); %[output:26f418cf]

%[text] **6.2. Symbolic Register Read & Write (****`esp32_sfr.json`****)**
%%\ Symbolic Read (Automatically decodes and lists non-zero bitfields)
esp32_cli reg GPIO_OUT_REG %[output:9618f5c7]
esp32_cli reg GPIO_ENABLE_REG %[output:203ffd18]

%%\ Symbolic Write
esp32_cli reg GPIO_ENABLE_W1TS_REG 0x00000004 %[output:99234173]
esp32_cli reg GPIO_OUT_W1TS_REG    0x00000004 %[output:8221ca0d]
esp32_cli reg GPIO_OUT_W1TC_REG    0x00000004 %[output:08148da8]

% --- Equivalent OOP Syntax ---
dev.Reg('GPIO_ENABLE_W1TS_REG', 0x00000004); %[output:1c1ad8a1]
dev.Reg('GPIO_OUT_W1TS_REG', 0x00000004); %[output:13c7998f]
%[text] **6.3. Modifying Individual Bitfields (Read-Modify-Write)**
%%\ Method A: Symbolic Bitfield Name (from esp32_sfr.json)
esp32_cli bits GPIO_ENABLE_REG GPIO2 1    % Enable GPIO 2 output driver %[output:9a2c1751]
esp32_cli bits GPIO_OUT_REG    GPIO2 1    % Set GPIO2 bitfield = 1 (LED ON) %[output:2e847a15]
esp32_cli bits GPIO_OUT_REG    GPIO2      % Read only the GPIO2 bitfield %[output:2cbfa15d]
esp32_cli bits GPIO_OUT_REG    GPIO2 0    % Clear GPIO2 bitfield = 0 (LED OFF) %[output:6aea4498]

%%\ Method B: Numeric Bit Range [MSB LSB]
esp32_cli bits 0x3FF44004 2 2 1           % Set bit [2:2] = 1 in 0x3FF44004 %[output:79ef7b10]
esp32_cli bits 0x3FF44004 2 2 0           % Set bit [2:2] = 0 in 0x3FF44004 %[output:72dbbe08]

% --- Equivalent OOP Syntax ---
dev.Bits('GPIO_OUT_REG', 'GPIO2', 1); %[output:3300fe72]
dev.Bits(0x3FF44004, 2, 2, 0); %[output:17e53799]
%[text] **6.4. Contiguous Memory Block Dump**
%%\ Dump 8 consecutive 32-bit registers starting at 0x3FF44000 (DR_REG_GPIO_BASE)
esp32_cli dump 0x3FF44000 8 %[output:229b5032]

%%\ Dump 6 consecutive registers starting at a Symbolic Register Name
esp32_cli dump GPIO_OUT_REG 6 %[output:05e40939]

% --- Equivalent OOP Syntax ---
words = dev.Dump('GPIO_OUT_REG', 6);
%%
%[text] ## Step 7: Flashing Application Sketches (`beep_slow.ino` & `beep_fast.ino`) + Live RAM Register Override
%[text] In your `esp32_workbench_v3` folder, both application sketches are located in `firmware\esp32_bridge_ota\`.
%[text] When `esp32_flash` compiles either sketch, it automatically isolates the sketch in a temporary build folder and injects the Core-0 daemon so you never lose USB, Bluetooth, Web, or Wi-Fi OTA access.
%%
%[text] **7.1. Flash Sketch \#1:** **`beep_slow.ino`** **(3000 ms Interval)**
%[text] You can flash via `--usb` (auto-detects `COM9` and automatically releases/reconnects the MATLAB serial session) or via `--wifi` (when connected to `ESP32_LAB`):
esp32_cli scan %[output:983cfaf2]
%%\ 7.1 Flash beep_slow.ino via USB (COM8) or Wi-Fi (--wifi)
esp32_cli flash C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\beep_slow.ino --usb COM8 %[output:31cf72dd]

%%\ Reconnect (if not already connected) and check status
esp32_cli connect COM8 %[output:4d684dee]
esp32_cli status %[output:65d64f8e]
%[text] - **Physical Verification:** GPIO 4 (buzzer) emits a 1000 Hz tone and GPIO 2 (LED) blinks once every **3000 ms (3 seconds)**. \
%%
%[text] 
%[text] **7.2. Live Register Experiment: Modify Beep Speed in RAM Without Reflashing!**
%[text] `beep_slow.ino` reads its delay period on every cycle from the 32-bit RTC scratchpad register **`RTC_CNTL_STORE0_REG`** **(****`0x3FF4804C`****)**. Overwrite this register live from MATLAB to change the hardware timing on the fly:
%%\ 7.2 Connect and override the beep interval in RAM (RTC_CNTL_STORE0_REG) without reflashing!
esp32_cli connect COM8 %[output:64ba5364]
esp32_cli reg RTC_CNTL_STORE0_REG        % Reads 0x00000BB8 (3000 ms) %[output:71648bbd]
esp32_cli reg RTC_CNTL_STORE0_REG 400    % Speeds up to 400 ms live! %[output:32aafa4f]
esp32_cli reg RTC_CNTL_STORE0_REG 120    % Speeds up to 120 ms live! %[output:21d2f103]
esp32_cli reg RTC_CNTL_STORE0_REG 3000   % Restores 3000 ms %[output:2009a4f2]
%%
%[text] 
%[text] **7.3. Flash Sketch \#2:** **`beep_fast.ino`** **(200 ms High-Pitch Alarm)**
%%\ 7.3 Flash beep_fast.ino
esp32_cli flash C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\beep_fast.ino --usb COM8 %[output:656f03c9]

% --- Equivalent OOP One-Liner ---
% esp32().Flash('C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\beep_fast.ino', '--usb');
%[text] - **Physical Verification:** The ESP32 reboots into the 2400 Hz fast alarm (200 ms interval), and you can still override `RTC_CNTL_STORE0_REG` at any time: \
%%
esp32_cli connect COM8 %[output:0a6ca9c7]
esp32_cli reg RTC_CNTL_STORE0_REG 3000  % alarm to X ms live! %[output:9cbe403b]
%%
%[text] ## Step 8: Sample Scripts for Your `examples/` Folder
%[text] You can save these two standalone scripts inside `C:\Users\tomas\MATLAB\esp32_workbench_v3\examples\` for automated classroom demos.
%[text] **Sample Script 1:** **`examples/demo_register_knight_rider.m`**
%[text] Demonstrates direct symbolic SFR register writes, read-modify-write bitfield operations, and live beep interval control over COMx (or Wi-Fi/BT):
%%\ DEMO 1: Bare-Metal SFR Register & Live Timer Manipulation
% File: C:\Users\tomas\MATLAB\esp32_workbench_v3\examples\demo_register_knight_rider.m

clear; clc;
cd('C:\Users\tomas\MATLAB\esp32_workbench_v3');
addpath(genpath(pwd));

fprintf('=== 1. Connecting to ESP32 ===\n'); %[output:6b627709]
dev = esp32('COM8'); % Or esp32('192.168.4.1') / esp32('ESP32_BT_BRIDGE') %[output:05112290]
dev.Status(); %[output:11d4665d]

fprintf('\n=== 2. Inspecting GPIO_OUT_REG Bitfield Map from esp32_sfr.json ===\n'); %[output:458d69dc]
dev.Sfr('GPIO_OUT_REG'); %[output:87ce2086]

fprintf('\n=== 3. Toggling Built-in LED (GPIO 2) via Atomic W1TS / W1TC Registers ===\n'); %[output:0c593dce]
dev.Reg('GPIO_ENABLE_W1TS_REG', 0x00000004); % Enable GPIO 2 Output %[output:7fba8043]
for k = 1:6 %[output:group:762aa37b]
    dev.Reg('GPIO_OUT_W1TS_REG', 0x00000004); % Atomic Set Bit 2 HIGH %[output:4431df3b] %[output:485fb4da] %[output:03228bcf] %[output:734ea4d1] %[output:6b9f35fe] %[output:40322556]
    pause(0.15);
    dev.Reg('GPIO_OUT_W1TC_REG', 0x00000004); % Atomic Clear Bit 2 LOW %[output:438e52d7] %[output:2162974a] %[output:54e4f3ff] %[output:2cd95e60] %[output:54d4ba8c] %[output:2eafe4ac]
    pause(0.15);
end %[output:group:762aa37b]

fprintf('\n=== 4. Sweeping Dynamic Beep Period via RTC_CNTL_STORE0_REG (0x3FF4804C) ===\n'); %[output:60ec1889]
for periodMs = [800, 400, 200, 100, 1000] %[output:group:48384acf]
    fprintf('  -> Setting RTC_CNTL_STORE0_REG = %d ms\n', periodMs); %[output:762fb676] %[output:169a9de0] %[output:520bc438] %[output:39d8d8e5] %[output:56a82a8d]
    dev.Reg('RTC_CNTL_STORE0_REG', periodMs); %[output:35135f9a] %[output:64f04475] %[output:46b3353f] %[output:8f63e6be] %[output:56df40db]
    pause(2.0);
end %[output:group:48384acf]

fprintf('\n=== 5. Dumping GPIO Peripheral Memory Block ===\n'); %[output:40b772f9]
dev.Dump('GPIO_OUT_REG', 8); %[output:960c4171]
%%
%[text] **Sample Script 2:** **`examples/demo_live_adc_logger.m`**
%[text] Samples ADC1 (`GPIO 34`) in real time and plots the voltage waveform alongside the state of `GPIO_OUT_REG`:
%%\ DEMO 2: Real-Time ADC Voltage Logger & Register Monitor
% File: C:\Users\tomas\MATLAB\esp32_workbench_v3\examples\demo_live_adc_logger.m

clear; clc;
cd('C:\Users\tomas\MATLAB\esp32_workbench_v3');
addpath(genpath(pwd));

dev = esp32('COM8'); %[output:815b5ce0]
adcPin = 39;
nSamples = 400;

volts = zeros(1, nSamples);
timestamps = zeros(1, nSamples);

figure('Name', 'ESP32 Real-Time ADC1 Logger', 'Color', 'w'); %[output:2be79713]
hLine = animatedline('LineWidth', 2, 'Color', [0 0.45 0.74], 'Marker', 'o'); %[output:2be79713]
grid on; xlabel('Time (s)'); ylabel('Voltage (V)'); %[output:2be79713]
title(sprintf('Live ESP32 ADC1 Capture on GPIO %d', adcPin)); %[output:2be79713]
ylim([0 3.4]); %[output:2be79713]

tStart = tic;
for k = 1:nSamples %[output:group:97e21a46]
    raw = dev.Adc(adcPin);
    volts(k) = (double(raw) / 4095.0) * 3.3;
    timestamps(k) = toc(tStart);
    addpoints(hLine, timestamps(k), volts(k)); %[output:2be79713]
    drawnow limitrate;
end %[output:group:97e21a46]
fprintf('Capture complete. Mean Voltage: %.3f V\n', mean(volts)); %[output:0ee5332d]

%%
%[text] ## Step 9: Launching the Visual Interfaces (UDE® MATLAB GUI & On-Chip Web Portal)
%[text] **9.1. Launch the MATLAB UDE® Workbench GUI (****`esp32_gui.m`****)**
%[text] Works over **USB (****`COM9`****)**, **Bluetooth (****`ESP32_BT_BRIDGE`** **/** **`COM11`****)**, or **Wi-Fi (****`192.168.4.1`****)**:
%%\ Open the UDE® ESP32 Visual Workbench in MATLAB
esp32_cli gui

% --- Equivalent OOP Syntax ---
esp32().Gui();
%[text] ## 
%[text] ## 
%[text] ## Quick Reference Card (`esp32_workbench_v3`)
%[text:table]{"columnWidths":[212,-1,-1],"ignoreHeader":true}
%[text] | **Operation** | **Pure CLI Command (****`esp32_cli`****)** | **OOP Facade (****`esp32`****)** |
%[text] | --- | --- | --- |
%[text] | **Autonomous Hardware Debug** | `esp32_cli debug` | — |
%[text] | **Scan Serial & BT Ports** | `esp32_cli scan` | `esp32().Scan()` |
%[text] | **Connect via USB (****`COM9`****)** | `esp32_cli connect COM9` | `dev = esp32('COM9')` |
%[text] | **Connect via Bluetooth** | `esp32_cli connect ESP32_BT_BRIDGE` | `dev = esp32('ESP32_BT_BRIDGE')` |
%[text] | **Connect via Wi-Fi (****`ESP32_LAB`****)** | `esp32_cli connect 192.168.4.1` | `dev = esp32('192.168.4.1')` |
%[text] | **Check Connection Status** | `esp32_cli status` | `dev.Status()` |
%[text] | **Search SFR JSON Database** | `esp32_cli sfr GPIO` | `dev.Sfr('GPIO')` |
%[text] | **Inspect SFR Bitfield Map** | `esp32_cli sfr GPIO_OUT_REG` | `dev.Sfr('GPIO_OUT_REG')` |
%[text] | **Read Register (Symbolic)** | `esp32_cli reg GPIO_OUT_REG` | `val = dev.Reg('GPIO_OUT_REG')` |
%[text] | **Write Register (Symbolic)** | `esp32_cli reg RTC_CNTL_STORE0_REG 400` | `dev.Reg('RTC_CNTL_STORE0_REG', 400)` |
%[text] | **Modify Bitfield (Symbolic)** | `esp32_cli bits GPIO_OUT_REG GPIO2 1` | `dev.Bits('GPIO_OUT_REG', 'GPIO2', 1)` |
%[text] | **Toggle Built-in LED (GPIO 2)** | `esp32_cli led toggle` | `dev.Led('toggle')` |
%[text] | **Set / Read Any GPIO Pin** | `esp32_cli pin 4 high` | `dev.Pin(4, 'high')` |
%[text] | **Read ADC Voltage (****`32..39`****)** | `esp32_cli adc 34` | `raw = dev.Adc(34)` |
%[text] | **Symbolic Memory Dump** | `esp32_cli dump GPIO_OUT_REG 8` | `vals = dev.Dump('GPIO_OUT_REG', 8)` |
%[text] | **Flash** **`.ino`** **via USB (Auto)** | `esp32_cli flash path\app.ino --usb` | `esp32().Flash('path\app.ino', '--usb')` |
%[text] | **Flash** **`.ino`** **via Wi-Fi OTA** | `esp32_cli flash path\app.ino --wifi` | `esp32().Flash('path\app.ino', '--wifi')` |
%[text] | **Open UDE® MATLAB GUI** | `esp32_cli gui` | `dev.Gui()` |
%[text] | **Open On-Chip Web Portal** | `esp32_cli web` | `dev.Web()` |
%[text] | **Disconnect** | `esp32_cli disconnect` | `dev.Disconnect()` |
%[text] |  |  |  |
%[text] |  |  |  |
%[text] |  |  |  |
%[text:table]
%[text] 

%[appendix]{"version":"1.0"}
%---
%[metadata:view]
%   data: {"layout":"onright"}
%---
%[output:55c74bfa]
%   data: {"dataType":"text","outputData":{"text":" <strong>esp32_cli<\/strong> CLI-First Workbench for ESP32 (SFR JSON Database, Registers, Pins, ADC, Flash OTA, Web, GUI).\n \n  CONSOLE USAGE (PURE CLI SYNTAX):\n    <strong>esp32_cli<\/strong> scan                              % List COM ports (with Registry & PnP driver info)\n    <strong>esp32_cli<\/strong> debug                             % Run autonomous PowerShell & MATLAB hardware diagnostics\n    <strong>esp32_cli<\/strong> connect COM5                      % Connect via USB Serial or BT Virtual COM port\n    <strong>esp32_cli<\/strong> connect ESP32_BT_BRIDGE           % Connect natively via Bluetooth SPP\n    <strong>esp32_cli<\/strong> connect 192.168.4.1               % Connect via Wi-Fi (ESP32_LAB AP)\n    <strong>esp32_cli<\/strong> status                            % Display chip status and uptime\n    <strong>esp32_cli<\/strong> sfr GPIO                          % Search registers matching 'GPIO' in esp32_sfr.json\n    <strong>esp32_cli<\/strong> sfr GPIO_OUT_REG                  % Show bitfield map of GPIO_OUT_REG from esp32_sfr.json\n    <strong>esp32_cli<\/strong> reg GPIO_OUT_REG                  % Read register by symbolic name (or 0x3FF44004)\n    <strong>esp32_cli<\/strong> reg GPIO_OUT_W1TS_REG 0x00000004  % Write register by symbolic name or hex address\n    <strong>esp32_cli<\/strong> bits GPIO_OUT_REG GPIO2 1         % Modify bitfield by symbolic name from esp32_sfr.json\n    <strong>esp32_cli<\/strong> bits 0x3FF44004 2 2 1             % Modify bits [msb:lsb] numerically\n    <strong>esp32_cli<\/strong> pin 2 toggle                      % Toggle GPIO 2 state\n    <strong>esp32_cli<\/strong> adc 34                            % Read ADC on GPIO 34 (0-4095 and Voltage)\n    <strong>esp32_cli<\/strong> dump GPIO_OUT_REG 8               % Display Hex\/Binary table starting at symbol\/address\n    <strong>esp32_cli<\/strong> flash my_sketch.ino --wifi        % Compile, inject Core0 Web+OTA+BT, and flash over Wi-Fi\n    <strong>esp32_cli<\/strong> flash my_sketch.ino --usb         % Compile and flash via USB\n    <strong>esp32_cli<\/strong> web                               % Open the on-chip Web Register Workbench in browser\n    <strong>esp32_cli<\/strong> gui                               % Open the UDE Workbench graphical interface\n    <strong>esp32_cli<\/strong> disconnect                        % Close the active connection\n\n","truncated":false}}
%---
%[output:545ed589]
%   data: {"dataType":"text","outputData":{"text":" <strong>esp32<\/strong> Lightweight Object-Oriented Facade over the esp32_cli.m engine and esp32_flash.m\n    Usage examples:\n      <strong>esp32<\/strong>().Flash('C:\\Users\\tomas\\MATLAB\\esp32_workbench_v3\\sketches\\beep_fast\\beep_fast.ino')\n      dev = <strong>esp32<\/strong>('192.168.4.1');               % Connect via Wi-Fi\n      dev = <strong>esp32<\/strong>('ESP32_BT_BRIDGE');           % Connect via Bluetooth SPP\n      dev = <strong>esp32<\/strong>('COM8');                      % Connect via USB Serial\n      dev.Pin(2, 'high');                       % Set GPIO 2 HIGH\n      val = dev.Reg('GPIO_OUT_REG');            % Symbolic SFR read via esp32_sfr.json\n      dev.Bits('GPIO_OUT_REG', 'GPIO2', 1);     % Symbolic bitfield write via esp32_sfr.json\n      dev.Web();                                % Open on-chip Web Register Debugger in browser\n\n    <a href=\"matlab:doc esp32\">Documentation for esp32<\/a>\n\n","truncated":false}}
%---
%[output:0125afd8]
%   data: {"dataType":"text","outputData":{"text":"\n====================================================================\n  ESP32 WORKBENCH — AUTONOMOUS POWERSHELL & MATLAB DIAGNOSTICS\n====================================================================\n\n[1\/5] Checking active MATLAB serialport handles...\n  No open serialport objects inside MATLAB.\n\n[2\/5] Querying Windows Registry HKLM:\\HARDWARE\\DEVICEMAP\\SERIALCOMM...\n\\Device\\Serial0   : COM3\n\\Device\\BthModem2 : COM5\n\\Device\\Serial2   : COM8\nPSPath            : Microsoft.PowerShell.Core\\Registry::HKEY_LOCAL_MACHINE\\HARDWARE\\DEVICEMAP\\SERIALCOMM\nPSParentPath      : Microsoft.PowerShell.Core\\Registry::HKEY_LOCAL_MACHINE\\HARDWARE\\DEVICEMAP\nPSChildName       : SERIALCOMM\nPSDrive           : HKLM\nPSProvider        : Microsoft.PowerShell.Core\\Registry\n\n[3\/5] Querying Windows PnP USB \/ UART \/ Serial Devices...\nStatus ConfigManagerErrorCode Name                                                       DeviceID                                                    \n------ ---------------------- ----                                                       --------                                                    \nOK                          0 USB-SERIAL CH340 (COM8)                                    USB\\VID_1A86&PID_7523\\5&2D6A1177&0&5                        \nOK                          0 Intel(R) Active Management Technology - SOL (COM3)         PCI\\VEN_8086&DEV_A0E3&SUBSYS_880D103C&REV_20\\3&11583659&0&B3\nOK                          0 Intel(R) LPC Controller\/eSPI Controller (U Premium) - A082 PCI\\VEN_8086&DEV_A082&SUBSYS_880D103C&REV_20\\3&11583659&0&F8\n\n[4\/5] Running arduino-cli board list...\nPort Protocol Type              Board Name FQBN Core\nCOM3 serial   Serial Port       Unknown\nCOM8 serial   Serial Port (USB) Unknown\n\n[5\/5] Checking Wi-Fi SSID & ESP32_LAB (192.168.4.1) reachability...\nState                  : connected\n    SSID                   : ESP32_LAB\n    AP BSSID               : d4:8c:49:f9:d0:45\nTrue\n====================================================================\n\n","truncated":false}}
%---
%[output:6dc2a3a0]
%   data: {"dataType":"text","outputData":{"text":"\n=== Detected Serial \/ Virtual BT Ports ===\n  COM3     [AVAILABLE] — Intel(R) Active Management Technology - SOL (COM3) [\\Device\\Serial0]\n  COM5     [BUSY     ] — Kernel Device: \\Device\\BthModem2\n  COM8     [AVAILABLE] — USB-SERIAL CH340 (COM8) [\\Device\\Serial2]\n\n","truncated":false}}
%---
%[output:7ee75035]
%   data: {"dataType":"text","outputData":{"text":"[FLASH] Auto-detected physical USB ESP32 port (via arduino-cli): COM8\n[FLASH] Auto-injecting Core-0 Web Register Workbench + Wi-Fi OTA + BT SPP Daemon...\n[FLASH] Compiling with arduino-cli (PartitionScheme=min_spiffs, Max 1.96MB)...\n[FLASH] Compilation successful.\n[FLASH] Flashing via USB on COM8...\n[FLASH] USB flashing completed on COM8!\n","truncated":false}}
%---
%[output:1aad0713]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:607|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:62585460]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: SERIAL | Target: COM8 | Response: ESP32_READY|UPTIME_MS:640|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:4be5b9fa]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:585|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:3169df34]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: SERIAL | Target: COM8 | Response: ESP32_READY|UPTIME_MS:612|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:91361d13]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connecting via Bluetooth SPP to \"ESP32_BT_BRIDGE\" (Channel 1)...\n[ESP32] Connected via Bluetooth SPP (ESP32_BT_BRIDGE) -> ESP32_READY|UPTIME_MS:6048|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:7fbc5b19]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: BLUETOOTH | Target: ESP32_BT_BRIDGE | Response: ESP32_READY|UPTIME_MS:6075|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:078fe655]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM11 -> ESP32_READY|UPTIME_MS:7503|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:79b531a4]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: SERIAL | Target: COM11 | Response: ESP32_READY|UPTIME_MS:7533|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:55813cca]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connecting via Bluetooth SPP to \"ESP32_BT_BRIDGE\" (Channel 1)...\n[ESP32] Connected via Bluetooth SPP (ESP32_BT_BRIDGE) -> ESP32_READY|UPTIME_MS:8030|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:2501187d]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: BLUETOOTH | Target: ESP32_BT_BRIDGE | Response: ESP32_READY|UPTIME_MS:8051|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:5c9372a5]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Wi-Fi at http:\/\/192.168.4.1 -> ESP32_READY|UPTIME_MS:9309|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:2c3a6f21]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: WIFI | Target: 192.168.4.1 | Response: ESP32_READY|UPTIME_MS:9353|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:085786d3]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Wi-Fi at http:\/\/192.168.4.1 -> ESP32_READY|UPTIME_MS:9587|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:5722c0ee]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: WIFI | Target: 192.168.4.1 | Response: ESP32_READY|UPTIME_MS:9644|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:8fb8cac8]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Disconnected.\n","truncated":false}}
%---
%[output:702cd3f0]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Disconnected.\n","truncated":false}}
%---
%[output:4b0d56c1]
%   data: {"dataType":"text","outputData":{"text":"\n=== ESP32 SFR Database (ESP32_D0WD_V3) ===\n  Total Compiled Registers: 991\n  Usage: esp32_cli sfr <FILTER_OR_REG_NAME>  (e.g., esp32_cli sfr GPIO)\n\n","truncated":false}}
%---
%[output:26b25698]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Registers matching \"GPIO\" (402 found) ===\n  DPORT_PRO_GPIO_INTERRUPT_MAP_REG   | 0x3FF0015C |  1 bitfields\n  DPORT_PRO_GPIO_INTERRUPT_NMI_MAP_REG | 0x3FF00160 |  1 bitfields\n  DPORT_APP_GPIO_INTERRUPT_MAP_REG   | 0x3FF00270 |  1 bitfields\n  DPORT_APP_GPIO_INTERRUPT_NMI_MAP_REG | 0x3FF00274 |  1 bitfields\n  DPORT_AHBLITE_MPU_TABLE_GPIO_REG   | 0x3FF00338 |  1 bitfields\n  GPIO_BT_SELECT_REG                 | 0x3FF44000 |  1 bitfields\n  GPIO_OUT_REG                       | 0x3FF44004 | 33 bitfields\n  GPIO_OUT_W1TS_REG                  | 0x3FF44008 | 33 bitfields\n  GPIO_OUT_W1TC_REG                  | 0x3FF4400C | 33 bitfields\n  GPIO_OUT1_REG                      | 0x3FF44010 |  1 bitfields\n  GPIO_OUT1_W1TS_REG                 | 0x3FF44014 |  1 bitfields\n  GPIO_OUT1_W1TC_REG                 | 0x3FF44018 |  1 bitfields\n  GPIO_SDIO_SELECT_REG               | 0x3FF4401C |  1 bitfields\n  GPIO_ENABLE_REG                    | 0x3FF44020 | 33 bitfields\n  GPIO_ENABLE_W1TS_REG               | 0x3FF44024 | 33 bitfields\n  GPIO_ENABLE_W1TC_REG               | 0x3FF44028 | 33 bitfields\n  GPIO_ENABLE1_REG                   | 0x3FF4402C |  1 bitfields\n  GPIO_ENABLE1_W1TS_REG              | 0x3FF44030 |  1 bitfields\n  GPIO_ENABLE1_W1TC_REG              | 0x3FF44034 |  1 bitfields\n  GPIO_STRAP_REG                     | 0x3FF44038 |  1 bitfields\n  GPIO_IN_REG                        | 0x3FF4403C | 33 bitfields\n  GPIO_IN1_REG                       | 0x3FF44040 |  1 bitfields\n  GPIO_STATUS_REG                    | 0x3FF44044 |  1 bitfields\n  GPIO_STATUS_W1TS_REG               | 0x3FF44048 |  1 bitfields\n  GPIO_STATUS_W1TC_REG               | 0x3FF4404C |  1 bitfields\n  GPIO_STATUS1_REG                   | 0x3FF44050 |  1 bitfields\n  GPIO_STATUS1_W1TS_REG              | 0x3FF44054 |  1 bitfields\n  GPIO_STATUS1_W1TC_REG              | 0x3FF44058 |  1 bitfields\n  GPIO_ACPU_INT_REG                  | 0x3FF44060 |  1 bitfields\n  GPIO_ACPU_NMI_INT_REG              | 0x3FF44064 |  1 bitfields\n  GPIO_PCPU_INT_REG                  | 0x3FF44068 |  1 bitfields\n  GPIO_PCPU_NMI_INT_REG              | 0x3FF4406C |  1 bitfields\n  GPIO_CPUSDIO_INT_REG               | 0x3FF44070 |  1 bitfields\n  GPIO_ACPU_INT1_REG                 | 0x3FF44074 |  1 bitfields\n  GPIO_ACPU_NMI_INT1_REG             | 0x3FF44078 |  1 bitfields\n  GPIO_PCPU_INT1_REG                 | 0x3FF4407C |  1 bitfields\n  GPIO_PCPU_NMI_INT1_REG             | 0x3FF44080 |  1 bitfields\n  GPIO_CPUSDIO_INT1_REG              | 0x3FF44084 |  1 bitfields\n  GPIO_PIN0_REG                      | 0x3FF44088 |  3 bitfields\n  GPIO_PIN1_REG                      | 0x3FF4408C |  3 bitfields\n  GPIO_PIN2_REG                      | 0x3FF44090 |  3 bitfields\n  GPIO_PIN3_REG                      | 0x3FF44094 |  3 bitfields\n  GPIO_PIN4_REG                      | 0x3FF44098 |  3 bitfields\n  GPIO_PIN5_REG                      | 0x3FF4409C |  3 bitfields\n  GPIO_PIN6_REG                      | 0x3FF440A0 |  3 bitfields\n  GPIO_PIN7_REG                      | 0x3FF440A4 |  3 bitfields\n  GPIO_PIN8_REG                      | 0x3FF440A8 |  3 bitfields\n  GPIO_PIN9_REG                      | 0x3FF440AC |  3 bitfields\n  GPIO_PIN10_REG                     | 0x3FF440B0 |  3 bitfields\n  GPIO_PIN11_REG                     | 0x3FF440B4 |  3 bitfields\n  GPIO_PIN12_REG                     | 0x3FF440B8 |  3 bitfields\n  GPIO_PIN13_REG                     | 0x3FF440BC |  3 bitfields\n  GPIO_PIN14_REG                     | 0x3FF440C0 |  3 bitfields\n  GPIO_PIN15_REG                     | 0x3FF440C4 |  3 bitfields\n  GPIO_PIN16_REG                     | 0x3FF440C8 |  3 bitfields\n  GPIO_PIN17_REG                     | 0x3FF440CC |  3 bitfields\n  GPIO_PIN18_REG                     | 0x3FF440D0 |  3 bitfields\n  GPIO_PIN19_REG                     | 0x3FF440D4 |  3 bitfields\n  GPIO_PIN20_REG                     | 0x3FF440D8 |  3 bitfields\n  GPIO_PIN21_REG                     | 0x3FF440DC |  3 bitfields\n  ... (342 more registers omitted. Refine your search query)\n\n","truncated":false}}
%---
%[output:7ce03bce]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Registers matching \"IO_MUX\" (1 found) ===\n  DPORT_AHBLITE_MPU_TABLE_IO_MUX_REG | 0x3FF0034C |  1 bitfields\n\n","truncated":false}}
%---
%[output:9d5288b5]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Registers matching \"LEDC\" (105 found) ===\n  DPORT_PRO_LEDC_INT_MAP_REG         | 0x3FF001B0 |  1 bitfields\n  DPORT_APP_LEDC_INT_MAP_REG         | 0x3FF002C4 |  1 bitfields\n  DPORT_AHBLITE_MPU_TABLE_LEDC_REG   | 0x3FF0038C |  1 bitfields\n  LEDC_HSCH0_CONF0_REG               | 0x3FF59000 |  1 bitfields\n  LEDC_HSCH0_HPOINT_REG              | 0x3FF59004 |  1 bitfields\n  LEDC_HSCH0_DUTY_REG                | 0x3FF59008 |  1 bitfields\n  LEDC_HSCH0_CONF1_REG               | 0x3FF5900C |  3 bitfields\n  LEDC_HSCH0_DUTY_R_REG              | 0x3FF59010 |  1 bitfields\n  LEDC_HSCH1_CONF0_REG               | 0x3FF59014 |  1 bitfields\n  LEDC_HSCH1_HPOINT_REG              | 0x3FF59018 |  1 bitfields\n  LEDC_HSCH1_DUTY_REG                | 0x3FF5901C |  1 bitfields\n  LEDC_HSCH1_CONF1_REG               | 0x3FF59020 |  3 bitfields\n  LEDC_HSCH1_DUTY_R_REG              | 0x3FF59024 |  1 bitfields\n  LEDC_HSCH2_CONF0_REG               | 0x3FF59028 |  1 bitfields\n  LEDC_HSCH2_HPOINT_REG              | 0x3FF5902C |  1 bitfields\n  LEDC_HSCH2_DUTY_REG                | 0x3FF59030 |  1 bitfields\n  LEDC_HSCH2_CONF1_REG               | 0x3FF59034 |  3 bitfields\n  LEDC_HSCH2_DUTY_R_REG              | 0x3FF59038 |  1 bitfields\n  LEDC_HSCH3_CONF0_REG               | 0x3FF5903C |  1 bitfields\n  LEDC_HSCH3_HPOINT_REG              | 0x3FF59040 |  1 bitfields\n  LEDC_HSCH3_DUTY_REG                | 0x3FF59044 |  1 bitfields\n  LEDC_HSCH3_CONF1_REG               | 0x3FF59048 |  3 bitfields\n  LEDC_HSCH3_DUTY_R_REG              | 0x3FF5904C |  1 bitfields\n  LEDC_HSCH4_CONF0_REG               | 0x3FF59050 |  1 bitfields\n  LEDC_HSCH4_HPOINT_REG              | 0x3FF59054 |  1 bitfields\n  LEDC_HSCH4_DUTY_REG                | 0x3FF59058 |  1 bitfields\n  LEDC_HSCH4_CONF1_REG               | 0x3FF5905C |  3 bitfields\n  LEDC_HSCH4_DUTY_R_REG              | 0x3FF59060 |  1 bitfields\n  LEDC_HSCH5_CONF0_REG               | 0x3FF59064 |  1 bitfields\n  LEDC_HSCH5_HPOINT_REG              | 0x3FF59068 |  1 bitfields\n  LEDC_HSCH5_DUTY_REG                | 0x3FF5906C |  1 bitfields\n  LEDC_HSCH5_CONF1_REG               | 0x3FF59070 |  3 bitfields\n  LEDC_HSCH5_DUTY_R_REG              | 0x3FF59074 |  1 bitfields\n  LEDC_HSCH6_CONF0_REG               | 0x3FF59078 |  1 bitfields\n  LEDC_HSCH6_HPOINT_REG              | 0x3FF5907C |  1 bitfields\n  LEDC_HSCH6_DUTY_REG                | 0x3FF59080 |  1 bitfields\n  LEDC_HSCH6_CONF1_REG               | 0x3FF59084 |  3 bitfields\n  LEDC_HSCH6_DUTY_R_REG              | 0x3FF59088 |  1 bitfields\n  LEDC_HSCH7_CONF0_REG               | 0x3FF5908C |  1 bitfields\n  LEDC_HSCH7_HPOINT_REG              | 0x3FF59090 |  1 bitfields\n  LEDC_HSCH7_DUTY_REG                | 0x3FF59094 |  1 bitfields\n  LEDC_HSCH7_CONF1_REG               | 0x3FF59098 |  3 bitfields\n  LEDC_HSCH7_DUTY_R_REG              | 0x3FF5909C |  1 bitfields\n  LEDC_LSCH0_CONF0_REG               | 0x3FF590A0 |  1 bitfields\n  LEDC_LSCH0_HPOINT_REG              | 0x3FF590A4 |  1 bitfields\n  LEDC_LSCH0_DUTY_REG                | 0x3FF590A8 |  1 bitfields\n  LEDC_LSCH0_CONF1_REG               | 0x3FF590AC |  3 bitfields\n  LEDC_LSCH0_DUTY_R_REG              | 0x3FF590B0 |  1 bitfields\n  LEDC_LSCH1_CONF0_REG               | 0x3FF590B4 |  1 bitfields\n  LEDC_LSCH1_HPOINT_REG              | 0x3FF590B8 |  1 bitfields\n  LEDC_LSCH1_DUTY_REG                | 0x3FF590BC |  1 bitfields\n  LEDC_LSCH1_CONF1_REG               | 0x3FF590C0 |  3 bitfields\n  LEDC_LSCH1_DUTY_R_REG              | 0x3FF590C4 |  1 bitfields\n  LEDC_LSCH2_CONF0_REG               | 0x3FF590C8 |  1 bitfields\n  LEDC_LSCH2_HPOINT_REG              | 0x3FF590CC |  1 bitfields\n  LEDC_LSCH2_DUTY_REG                | 0x3FF590D0 |  1 bitfields\n  LEDC_LSCH2_CONF1_REG               | 0x3FF590D4 |  3 bitfields\n  LEDC_LSCH2_DUTY_R_REG              | 0x3FF590D8 |  1 bitfields\n  LEDC_LSCH3_CONF0_REG               | 0x3FF590DC |  1 bitfields\n  LEDC_LSCH3_HPOINT_REG              | 0x3FF590E0 |  1 bitfields\n  ... (45 more registers omitted. Refine your search query)\n\n","truncated":false}}
%---
%[output:99c4ae2b]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Registers matching \"RTC_CNTL\" (55 found) ===\n  RTC_CNTL_OPTIONS0_REG              | 0x3FF48000 |  2 bitfields\n  RTC_CNTL_SLP_TIMER0_REG            | 0x3FF48004 |  1 bitfields\n  RTC_CNTL_SLP_TIMER1_REG            | 0x3FF48008 |  1 bitfields\n  RTC_CNTL_TIME_UPDATE_REG           | 0x3FF4800C |  0 bitfields\n  RTC_CNTL_TIME0_REG                 | 0x3FF48010 |  1 bitfields\n  RTC_CNTL_TIME1_REG                 | 0x3FF48014 |  1 bitfields\n  RTC_CNTL_STATE0_REG                | 0x3FF48018 |  0 bitfields\n  RTC_CNTL_TIMER1_REG                | 0x3FF4801C |  4 bitfields\n  RTC_CNTL_TIMER2_REG                | 0x3FF48020 |  2 bitfields\n  RTC_CNTL_TIMER3_REG                | 0x3FF48024 |  4 bitfields\n  RTC_CNTL_TIMER4_REG                | 0x3FF48028 |  4 bitfields\n  RTC_CNTL_TIMER5_REG                | 0x3FF4802C |  4 bitfields\n  RTC_CNTL_ANA_CONF_REG              | 0x3FF48030 |  0 bitfields\n  RTC_CNTL_RESET_STATE_REG           | 0x3FF48034 |  2 bitfields\n  RTC_CNTL_WAKEUP_STATE_REG          | 0x3FF48038 |  2 bitfields\n  RTC_CNTL_INT_ENA_REG               | 0x3FF4803C |  0 bitfields\n  RTC_CNTL_INT_RAW_REG               | 0x3FF48040 |  0 bitfields\n  RTC_CNTL_INT_ST_REG                | 0x3FF48044 |  0 bitfields\n  RTC_CNTL_INT_CLR_REG               | 0x3FF48048 |  0 bitfields\n  RTC_CNTL_STORE0_REG                | 0x3FF4804C |  1 bitfields\n  RTC_CNTL_STORE1_REG                | 0x3FF48050 |  1 bitfields\n  RTC_CNTL_STORE2_REG                | 0x3FF48054 |  1 bitfields\n  RTC_CNTL_STORE3_REG                | 0x3FF48058 |  1 bitfields\n  RTC_CNTL_EXT_XTL_CONF_REG          | 0x3FF4805C |  0 bitfields\n  RTC_CNTL_EXT_WAKEUP_CONF_REG       | 0x3FF48060 |  0 bitfields\n  RTC_CNTL_SLP_REJECT_CONF_REG       | 0x3FF48064 |  1 bitfields\n  RTC_CNTL_CPU_PERIOD_CONF_REG       | 0x3FF48068 |  1 bitfields\n  RTC_CNTL_SDIO_ACT_CONF_REG         | 0x3FF4806C |  1 bitfields\n  RTC_CNTL_CLK_CONF_REG              | 0x3FF48070 |  5 bitfields\n  RTC_CNTL_SDIO_CONF_REG             | 0x3FF48074 |  3 bitfields\n  RTC_CNTL_BIAS_CONF_REG             | 0x3FF48078 |  1 bitfields\n  RTC_CNTL_REG                       | 0x3FF4807C |  5 bitfields\n  RTC_CNTL_PWC_REG                   | 0x3FF48080 |  0 bitfields\n  RTC_CNTL_DIG_PWC_REG               | 0x3FF48084 |  0 bitfields\n  RTC_CNTL_DIG_ISO_REG               | 0x3FF48088 |  0 bitfields\n  RTC_CNTL_WDTCONFIG0_REG            | 0x3FF4808C |  6 bitfields\n  RTC_CNTL_WDTCONFIG1_REG            | 0x3FF48090 |  1 bitfields\n  RTC_CNTL_WDTCONFIG2_REG            | 0x3FF48094 |  1 bitfields\n  RTC_CNTL_WDTCONFIG3_REG            | 0x3FF48098 |  1 bitfields\n  RTC_CNTL_WDTCONFIG4_REG            | 0x3FF4809C |  1 bitfields\n  RTC_CNTL_WDTFEED_REG               | 0x3FF480A0 |  0 bitfields\n  RTC_CNTL_WDTWPROTECT_REG           | 0x3FF480A4 |  1 bitfields\n  RTC_CNTL_TEST_MUX_REG              | 0x3FF480A8 |  1 bitfields\n  RTC_CNTL_SW_CPU_STALL_REG          | 0x3FF480AC |  2 bitfields\n  RTC_CNTL_STORE4_REG                | 0x3FF480B0 |  1 bitfields\n  RTC_CNTL_STORE5_REG                | 0x3FF480B4 |  1 bitfields\n  RTC_CNTL_STORE6_REG                | 0x3FF480B8 |  1 bitfields\n  RTC_CNTL_STORE7_REG                | 0x3FF480BC |  1 bitfields\n  RTC_CNTL_LOW_POWER_ST_REG          | 0x3FF480C0 |  1 bitfields\n  RTC_CNTL_DIAG1_REG                 | 0x3FF480C4 |  1 bitfields\n  RTC_CNTL_HOLD_FORCE_REG            | 0x3FF480C8 |  0 bitfields\n  RTC_CNTL_EXT_WAKEUP1_REG           | 0x3FF480CC |  1 bitfields\n  RTC_CNTL_EXT_WAKEUP1_STATUS_REG    | 0x3FF480D0 |  1 bitfields\n  RTC_CNTL_BROWN_OUT_REG             | 0x3FF480D4 |  2 bitfields\n  RTC_CNTL_DATE_REG                  | 0x3FF4813C |  1 bitfields\n\n","truncated":false}}
%---
%[output:6820bd3e]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Definition: GPIO_OUT_REG (0x3FF44004) ===\n  Bitfield Name                | Bits       | Width  | Access\n  -----------------------------+------------+--------+-------\n  GPIO_OUT_DATA                | [31: 0]    | 32     | RW    \n  GPIO0                        | [ 0: 0]    | 1      | RW    \n  GPIO1                        | [ 1: 1]    | 1      | RW    \n  GPIO2                        | [ 2: 2]    | 1      | RW    \n  GPIO3                        | [ 3: 3]    | 1      | RW    \n  GPIO4                        | [ 4: 4]    | 1      | RW    \n  GPIO5                        | [ 5: 5]    | 1      | RW    \n  GPIO6                        | [ 6: 6]    | 1      | RW    \n  GPIO7                        | [ 7: 7]    | 1      | RW    \n  GPIO8                        | [ 8: 8]    | 1      | RW    \n  GPIO9                        | [ 9: 9]    | 1      | RW    \n  GPIO10                       | [10:10]    | 1      | RW    \n  GPIO11                       | [11:11]    | 1      | RW    \n  GPIO12                       | [12:12]    | 1      | RW    \n  GPIO13                       | [13:13]    | 1      | RW    \n  GPIO14                       | [14:14]    | 1      | RW    \n  GPIO15                       | [15:15]    | 1      | RW    \n  GPIO16                       | [16:16]    | 1      | RW    \n  GPIO17                       | [17:17]    | 1      | RW    \n  GPIO18                       | [18:18]    | 1      | RW    \n  GPIO19                       | [19:19]    | 1      | RW    \n  GPIO20                       | [20:20]    | 1      | RW    \n  GPIO21                       | [21:21]    | 1      | RW    \n  GPIO22                       | [22:22]    | 1      | RW    \n  GPIO23                       | [23:23]    | 1      | RW    \n  GPIO24                       | [24:24]    | 1      | RW    \n  GPIO25                       | [25:25]    | 1      | RW    \n  GPIO26                       | [26:26]    | 1      | RW    \n  GPIO27                       | [27:27]    | 1      | RW    \n  GPIO28                       | [28:28]    | 1      | RW    \n  GPIO29                       | [29:29]    | 1      | RW    \n  GPIO30                       | [30:30]    | 1      | RW    \n  GPIO31                       | [31:31]    | 1      | RW    \n\n","truncated":false}}
%---
%[output:76890b3d]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Registers matching \"IO_MUX_GPIO2_REG\" (0 found) ===\n\n","truncated":false}}
%---
%[output:58f09e0c]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Definition: RTC_CNTL_STORE0_REG (0x3FF4804C) ===\n  Bitfield Name                | Bits       | Width  | Access\n  -----------------------------+------------+--------+-------\n  RTC_CNTL_SCRATCH0            | [31: 0]    | 32     | RW    \n\n","truncated":false}}
%---
%[output:1f1c270e]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Definition: GPIO_OUT_REG (0x3FF44004) ===\n  Bitfield Name                | Bits       | Width  | Access\n  -----------------------------+------------+--------+-------\n  GPIO_OUT_DATA                | [31: 0]    | 32     | RW    \n  GPIO0                        | [ 0: 0]    | 1      | RW    \n  GPIO1                        | [ 1: 1]    | 1      | RW    \n  GPIO2                        | [ 2: 2]    | 1      | RW    \n  GPIO3                        | [ 3: 3]    | 1      | RW    \n  GPIO4                        | [ 4: 4]    | 1      | RW    \n  GPIO5                        | [ 5: 5]    | 1      | RW    \n  GPIO6                        | [ 6: 6]    | 1      | RW    \n  GPIO7                        | [ 7: 7]    | 1      | RW    \n  GPIO8                        | [ 8: 8]    | 1      | RW    \n  GPIO9                        | [ 9: 9]    | 1      | RW    \n  GPIO10                       | [10:10]    | 1      | RW    \n  GPIO11                       | [11:11]    | 1      | RW    \n  GPIO12                       | [12:12]    | 1      | RW    \n  GPIO13                       | [13:13]    | 1      | RW    \n  GPIO14                       | [14:14]    | 1      | RW    \n  GPIO15                       | [15:15]    | 1      | RW    \n  GPIO16                       | [16:16]    | 1      | RW    \n  GPIO17                       | [17:17]    | 1      | RW    \n  GPIO18                       | [18:18]    | 1      | RW    \n  GPIO19                       | [19:19]    | 1      | RW    \n  GPIO20                       | [20:20]    | 1      | RW    \n  GPIO21                       | [21:21]    | 1      | RW    \n  GPIO22                       | [22:22]    | 1      | RW    \n  GPIO23                       | [23:23]    | 1      | RW    \n  GPIO24                       | [24:24]    | 1      | RW    \n  GPIO25                       | [25:25]    | 1      | RW    \n  GPIO26                       | [26:26]    | 1      | RW    \n  GPIO27                       | [27:27]    | 1      | RW    \n  GPIO28                       | [28:28]    | 1      | RW    \n  GPIO29                       | [29:29]    | 1      | RW    \n  GPIO30                       | [30:30]    | 1      | RW    \n  GPIO31                       | [31:31]    | 1      | RW    \n\n","truncated":false}}
%---
%[output:9c806797]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:671|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:0c4009ae]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:88e35f65]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 0\n","truncated":false}}
%---
%[output:2c9aec34]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:854aedb9]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:611|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:297bc3a2]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:2c16ec5b]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 0\n","truncated":false}}
%---
%[output:0b758049]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:1f1d9639]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:798f2971]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:8b02e5ad]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 0\n","truncated":false}}
%---
%[output:205d0c91]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:667809c7]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 04] -> State: 1\n","truncated":false}}
%---
%[output:1ec39d2c]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 04] -> State: 0\n","truncated":false}}
%---
%[output:7077c870]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 1\n","truncated":false}}
%---
%[output:1ded49e6]
%   data: {"dataType":"text","outputData":{"text":"  [GPIO 02] -> State: 0\n","truncated":false}}
%---
%[output:16edbf77]
%   data: {"dataType":"text","outputData":{"text":"  [ADC GPIO 34] =  342 \/ 4095 | Linear: 0.276 V | Calibrated (11dB): 0.365 V (365 mV)\n","truncated":false}}
%---
%[output:946641dc]
%   data: {"dataType":"text","outputData":{"text":"  [ADC GPIO 35] = 4095 \/ 4095 | Linear: 3.300 V | Calibrated (11dB): 3.160 V (3160 mV)\n","truncated":false}}
%---
%[output:2b9fad3e]
%   data: {"dataType":"text","outputData":{"text":"  [REG GPIO_OUT_REG (0x3FF44004)] = 0x00000000 (         0) | Bin: 0000_0000_0000_0000_0000_0000_0000_0000\n    Bitfields: (All bitfields = 0)\n","truncated":false}}
%---
%[output:1ce7dae9]
%   data: {"dataType":"text","outputData":{"text":"  [REG GPIO_IN_REG (0x3FF4403C)] = 0x0000CAAB (     51883) | Bin: 0000_0000_0000_0000_1100_1010_1010_1011\n    Non-zero Bitfields: GPIO_IN_DATA=0xCAAB(51883), GPIO0=0x1(1), GPIO1=0x1(1), GPIO3=0x1(1), GPIO5=0x1(1), GPIO7=0x1(1), GPIO9=0x1(1), GPIO11=0x1(1), GPIO14=0x1(1), GPIO15=0x1(1)\n","truncated":false}}
%---
%[output:7b0438a3]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_ENABLE_W1TS_REG (0x3FF44024)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:93bba2df]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:5916f1c1]
%   data: {"dataType":"text","outputData":{"text":"  [REG GPIO_OUT_REG (0x3FF44004)] = 0x00000004 (         4) | Bin: 0000_0000_0000_0000_0000_0000_0000_0100\n    Non-zero Bitfields: GPIO_OUT_DATA=0x4(4), GPIO2=0x1(1)\n","truncated":false}}
%---
%[output:2c6ba377]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:26f418cf]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:9618f5c7]
%   data: {"dataType":"text","outputData":{"text":"  [REG GPIO_OUT_REG (0x3FF44004)] = 0x00000004 (         4) | Bin: 0000_0000_0000_0000_0000_0000_0000_0100\n    Non-zero Bitfields: GPIO_OUT_DATA=0x4(4), GPIO2=0x1(1)\n","truncated":false}}
%---
%[output:203ffd18]
%   data: {"dataType":"text","outputData":{"text":"  [REG GPIO_ENABLE_REG (0x3FF44020)] = 0x00000F94 (      3988) | Bin: 0000_0000_0000_0000_0000_1111_1001_0100\n    Non-zero Bitfields: GPIO_ENABLE_DATA=0xF94(3988), GPIO2=0x1(1), GPIO4=0x1(1), GPIO7=0x1(1), GPIO8=0x1(1), GPIO9=0x1(1), GPIO10=0x1(1), GPIO11=0x1(1)\n","truncated":false}}
%---
%[output:99234173]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_ENABLE_W1TS_REG (0x3FF44024)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:8221ca0d]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:08148da8]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:1c1ad8a1]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_ENABLE_W1TS_REG (0x3FF44024)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:13c7998f]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:9a2c1751]
%   data: {"dataType":"text","outputData":{"text":"  [BITS GPIO_ENABLE_REG.GPIO2 [2:2]] <= 1 -> New Reg: 0x00000F94\n","truncated":false}}
%---
%[output:2e847a15]
%   data: {"dataType":"text","outputData":{"text":"  [BITS GPIO_OUT_REG.GPIO2 [2:2]] <= 1 -> New Reg: 0x00000004\n","truncated":false}}
%---
%[output:2cbfa15d]
%   data: {"dataType":"text","outputData":{"text":"  [BITS GPIO_OUT_REG.GPIO2 [2:2]] = 1 (0x1)\n","truncated":false}}
%---
%[output:6aea4498]
%   data: {"dataType":"text","outputData":{"text":"  [BITS GPIO_OUT_REG.GPIO2 [2:2]] <= 0 -> New Reg: 0x00000000\n","truncated":false}}
%---
%[output:79ef7b10]
%   data: {"dataType":"text","outputData":{"text":"  [BITS 0x3FF44004 [2:2]] <= 1 -> New Reg: 0x00000004\n","truncated":false}}
%---
%[output:72dbbe08]
%   data: {"dataType":"text","outputData":{"text":"  [BITS 0x3FF44004 [2:2]] <= 0 -> New Reg: 0x00000000\n","truncated":false}}
%---
%[output:3300fe72]
%   data: {"dataType":"text","outputData":{"text":"  [BITS GPIO_OUT_REG.GPIO2 [2:2]] <= 1 -> New Reg: 0x00000004\n","truncated":false}}
%---
%[output:17e53799]
%   data: {"dataType":"text","outputData":{"text":"  [BITS 0x3FF44004 [2:2]] <= 0 -> New Reg: 0x00000000\n","truncated":false}}
%---
%[output:229b5032]
%   data: {"dataType":"text","outputData":{"text":"\n  Address     | SFR Symbol Name              | Hexadecimal | Binary (31..0)\n  ------------+------------------------------+-------------+------------------------------------\n  0x3FF44000  | GPIO_BT_SELECT_REG           | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44004  | GPIO_OUT_REG                 | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44008  | GPIO_OUT_W1TS_REG            | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF4400C  | GPIO_OUT_W1TC_REG            | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44010  | GPIO_OUT1_REG                | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44014  | GPIO_OUT1_W1TS_REG           | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44018  | GPIO_OUT1_W1TC_REG           | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF4401C  | GPIO_SDIO_SELECT_REG         | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n\n","truncated":false}}
%---
%[output:05e40939]
%   data: {"dataType":"text","outputData":{"text":"\n  Address     | SFR Symbol Name              | Hexadecimal | Binary (31..0)\n  ------------+------------------------------+-------------+------------------------------------\n  0x3FF44004  | GPIO_OUT_REG                 | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44008  | GPIO_OUT_W1TS_REG            | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF4400C  | GPIO_OUT_W1TC_REG            | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44010  | GPIO_OUT1_REG                | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44014  | GPIO_OUT1_W1TS_REG           | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44018  | GPIO_OUT1_W1TC_REG           | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n\n","truncated":false}}
%---
%[output:983cfaf2]
%   data: {"dataType":"text","outputData":{"text":"\n=== Detected Serial \/ Virtual BT Ports ===\n  COM3     [AVAILABLE] — Intel(R) Active Management Technology - SOL (COM3) [\\Device\\Serial0]\n  COM5     [BUSY     ] — Kernel Device: \\Device\\BthModem2\n  COM8     [BUSY     ] — USB-SERIAL CH340 (COM8) [\\Device\\Serial2]\n  COM10    [AVAILABLE] — Standard Serial over Bluetooth link (COM10) [\\Device\\BthModem1]\n  COM11    [AVAILABLE] — Standard Serial over Bluetooth link (COM11) [\\Device\\BthModem0]\n\n","truncated":false}}
%---
%[output:31cf72dd]
%   data: {"dataType":"text","outputData":{"text":"[FLASH] Closing open MATLAB serial handle on COM8...\n[FLASH] Auto-injecting Core-0 Web Register Workbench + Wi-Fi OTA + BT SPP Daemon...\n[FLASH] Compiling with arduino-cli (PartitionScheme=min_spiffs, Max 1.96MB)...\n[FLASH] Compilation successful.\n[FLASH] Releasing port COM8 in MATLAB to allow USB flashing...\n[FLASH] Flashing via USB on COM8...\n[FLASH] USB flashing completed on COM8!\n[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:673|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:4d684dee]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:591|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:65d64f8e]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: SERIAL | Target: COM8 | Response: ESP32_READY|UPTIME_MS:609|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:64ba5364]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:592|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:71648bbd]
%   data: {"dataType":"text","outputData":{"text":"  [REG RTC_CNTL_STORE0_REG (0x3FF4804C)] = 0x00000BB8 (      3000) | Bin: 0000_0000_0000_0000_0000_1011_1011_1000\n    Non-zero Bitfields: RTC_CNTL_SCRATCH0=0xBB8(3000)\n","truncated":false}}
%---
%[output:32aafa4f]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x00000190 (Readback: 0x00000190)\n","truncated":false}}
%---
%[output:21d2f103]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x00000078 (Readback: 0x00000078)\n","truncated":false}}
%---
%[output:2009a4f2]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x00000BB8 (Readback: 0x00000BB8)\n","truncated":false}}
%---
%[output:656f03c9]
%   data: {"dataType":"text","outputData":{"text":"[FLASH] Closing open MATLAB serial handle on COM8...\n[FLASH] Auto-injecting Core-0 Web Register Workbench + Wi-Fi OTA + BT SPP Daemon...\n[FLASH] Compiling with arduino-cli (PartitionScheme=min_spiffs, Max 1.96MB)...\n","truncated":false}}
%---
%[output:0a6ca9c7]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:592|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:9cbe403b]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x00000BB8 (Readback: 0x00000BB8)\n","truncated":false}}
%---
%[output:6b627709]
%   data: {"dataType":"text","outputData":{"text":"=== 1. Connecting to ESP32 ===\n","truncated":false}}
%---
%[output:05112290]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:591|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:11d4665d]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Mode: SERIAL | Target: COM8 | Response: ESP32_READY|UPTIME_MS:609|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:458d69dc]
%   data: {"dataType":"text","outputData":{"text":"\n=== 2. Inspecting GPIO_OUT_REG Bitfield Map from esp32_sfr.json ===\n","truncated":false}}
%---
%[output:87ce2086]
%   data: {"dataType":"text","outputData":{"text":"\n=== SFR Definition: GPIO_OUT_REG (0x3FF44004) ===\n  Bitfield Name                | Bits       | Width  | Access\n  -----------------------------+------------+--------+-------\n  GPIO_OUT_DATA                | [31: 0]    | 32     | RW    \n  GPIO0                        | [ 0: 0]    | 1      | RW    \n  GPIO1                        | [ 1: 1]    | 1      | RW    \n  GPIO2                        | [ 2: 2]    | 1      | RW    \n  GPIO3                        | [ 3: 3]    | 1      | RW    \n  GPIO4                        | [ 4: 4]    | 1      | RW    \n  GPIO5                        | [ 5: 5]    | 1      | RW    \n  GPIO6                        | [ 6: 6]    | 1      | RW    \n  GPIO7                        | [ 7: 7]    | 1      | RW    \n  GPIO8                        | [ 8: 8]    | 1      | RW    \n  GPIO9                        | [ 9: 9]    | 1      | RW    \n  GPIO10                       | [10:10]    | 1      | RW    \n  GPIO11                       | [11:11]    | 1      | RW    \n  GPIO12                       | [12:12]    | 1      | RW    \n  GPIO13                       | [13:13]    | 1      | RW    \n  GPIO14                       | [14:14]    | 1      | RW    \n  GPIO15                       | [15:15]    | 1      | RW    \n  GPIO16                       | [16:16]    | 1      | RW    \n  GPIO17                       | [17:17]    | 1      | RW    \n  GPIO18                       | [18:18]    | 1      | RW    \n  GPIO19                       | [19:19]    | 1      | RW    \n  GPIO20                       | [20:20]    | 1      | RW    \n  GPIO21                       | [21:21]    | 1      | RW    \n  GPIO22                       | [22:22]    | 1      | RW    \n  GPIO23                       | [23:23]    | 1      | RW    \n  GPIO24                       | [24:24]    | 1      | RW    \n  GPIO25                       | [25:25]    | 1      | RW    \n  GPIO26                       | [26:26]    | 1      | RW    \n  GPIO27                       | [27:27]    | 1      | RW    \n  GPIO28                       | [28:28]    | 1      | RW    \n  GPIO29                       | [29:29]    | 1      | RW    \n  GPIO30                       | [30:30]    | 1      | RW    \n  GPIO31                       | [31:31]    | 1      | RW    \n\n","truncated":false}}
%---
%[output:0c593dce]
%   data: {"dataType":"text","outputData":{"text":"\n=== 3. Toggling Built-in LED (GPIO 2) via Atomic W1TS \/ W1TC Registers ===\n","truncated":false}}
%---
%[output:7fba8043]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_ENABLE_W1TS_REG (0x3FF44024)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:4431df3b]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:438e52d7]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:485fb4da]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:2162974a]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:03228bcf]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:54e4f3ff]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:734ea4d1]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:2cd95e60]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:6b9f35fe]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:54d4ba8c]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:40322556]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TS_REG (0x3FF44008)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:2eafe4ac]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE GPIO_OUT_W1TC_REG (0x3FF4400C)] <= 0x00000004 (Readback: 0x00000000)\n","truncated":false}}
%---
%[output:60ec1889]
%   data: {"dataType":"text","outputData":{"text":"\n=== 4. Sweeping Dynamic Beep Period via RTC_CNTL_STORE0_REG (0x3FF4804C) ===\n","truncated":false}}
%---
%[output:762fb676]
%   data: {"dataType":"text","outputData":{"text":"  -> Setting RTC_CNTL_STORE0_REG = 800 ms\n","truncated":false}}
%---
%[output:35135f9a]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x00000320 (Readback: 0x00000320)\n","truncated":false}}
%---
%[output:169a9de0]
%   data: {"dataType":"text","outputData":{"text":"  -> Setting RTC_CNTL_STORE0_REG = 400 ms\n","truncated":false}}
%---
%[output:64f04475]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x00000190 (Readback: 0x00000190)\n","truncated":false}}
%---
%[output:520bc438]
%   data: {"dataType":"text","outputData":{"text":"  -> Setting RTC_CNTL_STORE0_REG = 200 ms\n","truncated":false}}
%---
%[output:46b3353f]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x000000C8 (Readback: 0x000000C8)\n","truncated":false}}
%---
%[output:39d8d8e5]
%   data: {"dataType":"text","outputData":{"text":"  -> Setting RTC_CNTL_STORE0_REG = 100 ms\n","truncated":false}}
%---
%[output:8f63e6be]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x00000064 (Readback: 0x00000064)\n","truncated":false}}
%---
%[output:56a82a8d]
%   data: {"dataType":"text","outputData":{"text":"  -> Setting RTC_CNTL_STORE0_REG = 1000 ms\n","truncated":false}}
%---
%[output:56df40db]
%   data: {"dataType":"text","outputData":{"text":"  [WRITE RTC_CNTL_STORE0_REG (0x3FF4804C)] <= 0x000003E8 (Readback: 0x000003E8)\n","truncated":false}}
%---
%[output:40b772f9]
%   data: {"dataType":"text","outputData":{"text":"\n=== 5. Dumping GPIO Peripheral Memory Block ===\n","truncated":false}}
%---
%[output:960c4171]
%   data: {"dataType":"text","outputData":{"text":"\n  Address     | SFR Symbol Name              | Hexadecimal | Binary (31..0)\n  ------------+------------------------------+-------------+------------------------------------\n  0x3FF44004  | GPIO_OUT_REG                 | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44008  | GPIO_OUT_W1TS_REG            | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF4400C  | GPIO_OUT_W1TC_REG            | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44010  | GPIO_OUT1_REG                | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44014  | GPIO_OUT1_W1TS_REG           | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44018  | GPIO_OUT1_W1TC_REG           | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF4401C  | GPIO_SDIO_SELECT_REG         | 0x00000000  | 0000_0000_0000_0000_0000_0000_0000_0000\n  0x3FF44020  | GPIO_ENABLE_REG              | 0x00000F94  | 0000_0000_0000_0000_0000_1111_1001_0100\n\n","truncated":false}}
%---
%[output:815b5ce0]
%   data: {"dataType":"text","outputData":{"text":"[ESP32] Connected via Serial on COM8 -> ESP32_READY|UPTIME_MS:658|IP:192.168.4.1|BT:ESP32_BT_BRIDGE\n","truncated":false}}
%---
%[output:2be79713]
%   data: {"dataType":"image","outputData":{"dataUri":"data:image\/png;base64,iVBORw0KGgoAAAANSUhEUgAAAjAAAAFRCAYAAABqsZcNAAAQAElEQVR4Aey9D6xV133vuZzhiT+FGjLDf1u5EJ5cB4OnUXB4cWWSFiJXUUXGHcsFeYRttRRUa4paao2bR0tlZdAEkIwUC4ZoTG7kwrM8YkxHUT2FTgwaRxCidAyKI7\/BcCP+Q8YwhvJHj5Hf\/eyyTvfdnHPvufeec\/af80Gsu9dea+21fr\/Pb5+9v2ftdc75zKf+k4AEJCABCUhAAiUj8JngPwlIQAISkIAEhknA5nkTUMDkHQHHl4AEJCABCUhg2AQUMMNG5gESkIAE8iegBRLodgIKmG4\/A\/RfAhKQgAQkUEICCpgSBk2TJZA\/AS2QgAQkkC8BBUy+\/B1dAhKQgAQkIIEREFDAjACah+RPQAskIAEJSKC7CShgujv+uXm\/fv36MHfu3HDgwIGGNjTTpuHBTVTs2LEjsQE76iXq090cP348PProo7VjlixZEi5dulRrEu3N9sUxHBsbXr9+PaxcubLWD3nKYj1bxk73Mxgn2scUbajXJ7Zic7rfmK\/Xnj6xG\/tjO7bYRl02xf4Zg3y2PruPT\/SXTpRl27k\/OIEY8zTHbIzqtaE9sSXGjEDMiF26jHJSveObiRVtGCcm9ukvpjhmrGecWOdWAkMRUMAMRahuvYXdRoCL\/LPPPhuuXbtWc\/306dPh6aefHiBiapWpDMdwLH1QvHHjxnD48GGySSK\/evXqEEUMN5\/vfOc7SV38Q3324h\/r4pb+9+\/fn+z+\/Oc\/D6dOnUryzfzBhm984xsDfMGO5cuXD\/CZvrCtnuChHCa0GSpxo8KnbDvKqMuWj3afPofiN9oxOn18vPnv3bv3nqGJRb0YZRtmz81s\/WBjDBUrzsc\/\/\/M\/H9Alx8Q40Devn\/Q5gy\/EasBB7kigAQEFTAMwFudPYMuWLeHkyZNh6dKlbTXmpZdeSsZhrHRas2ZNbdz33nsvuZE\/9dRTSVtu+A8++GDg4nvs2LFaOzI7d+5M2tAXdYsXL06OpQ8u2kePHg2TJk0K+\/btS4QM\/UTBgYg5dOgQ3YTYD2NS8M4777BpmOifGxLt2fb29tZty3jYj30k8pThCzcQDuLms337drI1O2gLKwo5hkQem7lZxmMpGyxxA6NtZEC\/JOzmOEQY45MfbRqubaMdr1PH49e6deuS84\/zi\/MMhqR6MYp2xXOKdhzDsZwrnDuxTXqLEOK84Pwg3hxHoh\/aEUfiST6b6JO+iSvHRLviecyx9I0N2EL\/jNPK+Gdtcr8ABFpoggKmhTDtqrUEeCfG1DIXSBJ5yuIoiIHslHdsR1sSswixfSu2iA\/GnTZtWjh48GAiVAYTWBMnTgxPPPFEMvSJEydCPO79998PCxYsSMr5M3ny5DB9+vRk1gQxw4V84cKFVIUnn3wy2Q72hxsawofj\/uRP\/iQs7hdN0dbBjqMOm7773e8mooo+6CvefLjppP1D1HFDiuW05V01N58HHngg6YM+B0vxBrZ169YBDJiZwu50OUKGRxrEMqYYU+JA\/El\/+7d\/W3skxz51aduwBzsRWn19fYE2JNpRR1vqGIsxSeQp++M\/\/uOkb\/K0G8k5xnkb7WcbfWDs9Fhvv\/12MhZtGJ862mQTs2vxPHn11VcD51lsw2wfHGOMYnl2yzHpczNbDxvOIYQm5wfnSWzDOUH\/7Md4kk8nzhWEC29E0uXz5s1L7yavD2yh\/xUrViRi\/+LFiwPauCOBegQUMPWoWFY4AtzMuTlzQeXCioG8a+Md3LJly5IbITcWblLUxcQ7yPTNIpant7ThhpFO2ZvH448\/ntycGY+bQ7yZpfupl+eGhyigLnvhxl76os8NGzYk4gZRg7hBHHFB57h4gxhMyMQb2qJFi8KcOXOSmwL98i6XPoZKiCdE1NmzZ8ONGzcCYotjsjZTxg2JmxP5mHhH\/tprr8Xdhlt4nDt3LmHJmOmG3MR2795dm3Ejzi+++GJyQ0u3Y2YofWPHT\/jFNuzzaOJXv\/pVLBrxFmHGjAAdzJo1K5kxG845hr+cK9k4cM4haug3Jsb6sz\/7s7ib+L1p06bao8VaRX+GGzyzG8Q7nif9xcn\/yDEbo6Qy9QfbGp2bNIuvr\/nz5yfnFGXpFF8T6ddkuj7mGQcG+Mz5jsCKdWyxgTYk8pTF8498i5PdVYiAAqZCwayyK1ykuVhzc+LCiq\/pGzsXv9dff53i2iMPbgiInj179gxY25E0GuYfhAUzA\/Ew+kZUZW9C1HODi2KINrTlXSwXfOpjSl+ksR0fYl3cIr64+XHhJ8Xy7JbHRdzQoshhlgTfuSHU6zd7fNy\/evVq6OvrC4iMWDbYNt4seUc+WLtYhzhCJMX9wbbEHCHHu3gScYcBfnIDTx\/LbABtYI3fnCecHwgrjqEteQTShAkT2G06cRx9M0NEnDgwlsXxGp1j1JOIP48M6Yct+wijtBBL90v\/7MMKZuTTKX3uxHL6QnjHc48t50+sZ9vsuUnboRICFNE7VDvsxw\/awYJEPp6j7PM6IZGnziSBZggoYJqhZJtCEFi1alXyzp0bE+\/OeefHzYoLX\/oiGS\/S3Li4kXFTzt7w0g7Fmx83l5iYBUG0pNtxk6aeC28sR1xkbxKxLm6xkZtVtj\/eIcf+uHC\/8cYb8ZBkS7+8a+X47GOCpMHdP5EFu1nfeczA7Ax1ZU0IMN7BE2c4Zf2AT4wJoofHELSpd5OnfDiJvhmXY0ZyjkUb1q5dm8wShv6OOA+YNUSI8aiuvyj5nx6LMdlPKur8qTczVqfZkEWMUe\/cHPLA\/ga8pnht9WcH\/U9MEKJRuL3yyivJGwrK33rrrYANdICogwt5kwSaIaCAaYaSbQpBgEcjTGcjXLjoIk6YleFC2EkDeYQShQfjxpsUeRLvnqmPiYt3tJHHRrwz5obMjZn2cdYk3U9avHCRj8fTPpuYmYBFtpx9bpLMzpAfLMWbEe+oe3p6kkdQtEcssk0nZp2wL13WbB4\/iBl2pW\/eHA8PuMCIfYQZ61T4dBQCDj8RpdS1InHzxW\/6SosT9mOaPXt2GO6MTTx2uNvhjMXsBzd8XgtwYiyEEcKb8w5RTlk2DXZuZttGEdVIBBM\/4kg8iWv6+BhLzvUYz\/j6TXPnOF4f2Iztv\/mbv5l00yqBlnTmn8oSUMBUNrTVc4zHFSw65GbNmgcu4MzK4Ck3GW4A5LMXaS6MXNypG0mqdzGmn5FcZOONJ31TiCIh9scFn5kX\/MsunmTcbIrHZ\/1mtoJ3t6mbXPbQZB\/\/WGvBzYjZC24qPO5ifGaYsCdp2P+HPGXYR76\/aNj\/o2DLrmVhBgqb+egtj0MYh1jHG2QjkUEb2mIIvvDYjDw8OWdYu8J+NuFvFDCII\/rJtknvj+Qcwwb6SPuKbwhw+MKZ+uGmOXPmBMQ8NrPeJ4oY+qF\/xiM\/msR5AHs4sW6FfmN\/xJ5zgP0YT\/IxpbnH85OZQM57RDKvA\/rjkRciFftJPIqDC\/WxL7cSaERAAdOIjOUdIRAfefBOLaZ4QatnABd8LnDUcQHnQk6eC+YLL7xANmT75F09N7akss4fLsRx7PQ2HkffCCcOTffNcZTVu4BTXi8hpJgm56bAd6wwHjdfhAaPQbiIM8XOsek2tGPmg\/J04ibAzZDjececros3IG5yjBHr2Gcmgz5JHIdwoA9soB128tiDfNpn8pRxPIn8cBOP4hgn61\/kCR\/Gjzd\/bMdOxsP2euNxLG3q+RLbYzsx\/fTTT0MUu5RxHNvYrtGW82C45xg2k9K+Enf2o5+NxhusHFuYlSJmMGEM\/CDF\/nmd8HoZrJ+h6pjJYQzspV\/6J0VexJF41uuHNxfYEOPH8fQTRTKvXV7D0X58ID8aLvXssKy6BBQw1Y1t8TxrgUXc2LjA0RWiggs5eRIXUmYhyMfERZGydLtYN5wt61XoJ3sMZYybLR9sn0dQXPhjG24Q8TFRMzMB8Ti2g03jUx\/FFbMSzGBQVi9hD1P5iJ5Yj89x3UIsY8tNjcWwo2EKA9jRXzpRRh1lcMUu8iTy1JOP7+rJw49ybpZxP\/JkPzIgz2LS++67L8SbP2Wk+NFz8oMlbGKsdJvBzjEYwQrb08fAMPqZLh9OnlgRM\/rKHkfZaGce6TOOkbWfOjgM5gOvVWbVYlw4Brs4r8jDJhsH6gfrk+NMEogEFDCRhNuOEuAixXPveomLMhfO2IabRtq4WB4vhOk62qb75ObBhTLdJuY5Pt02m88em+2b9pTF\/qJd6bJYl93GtvQR\/aUNx1JWL3EMbdIp+lCvjnaxP3xhbQtjNds3x3MT4kaYPoYxqcum2JYxiF+2PrsfbUv3TVm6HX7FevLUs08+3Y6Zl2hndvx4DMfFOuwjTxmJx1Ywog\/8IJGnLHv+pPvj2Hpt0raRx17axpRmWG+saB82kqePRom+Yr9xS1m6fRwf29Pl6TzjMB5+Y1O6Lh4f+2c7WF\/xWPqhP9qTsnbFMakjZetjP24lUI9ANwmYev5bJgEJSEACEpBACQkoYEoYNE2WgAQkIAEJdI5AMUdSwBQzLlolAQkMQSA+fuCxB\/khmlstAQlUjIACpmIB1R0JSEACVSOgPxKoR0ABU4+KZRKQgAQkIAEJFJqAAmaI8Jw5cyZs27YtsB2iaamq79y5E65cuRLYlsrwIYzFH\/0aAlKBqssRr5EBq6pv+jWy8yGvo6oaL3gqYKAwSEK4VFXA8JXenNyDuF+6KvzRr\/KErarxIgJV9U2\/iG55UlXjRQQUMFAwSaDABDRNAhKQgATuJaCAuZeJJRKQgAQkIAEJFJyAAqbgAcrfPC2QgAQkIAEJFI+AAqZ4MdEiCUhAAhKQgASGIFB4ATOE\/VZLQAISkIAEJNCFBBQwXRh0XZaABCQggcoTqLyDCpjKh1gHJSABCUhAAtUjoICpXkz1SAISkED+BLRAAm0moIBpM2C7l4AEJCABCUig9QQUMK1nao8SkED+BLRAAhKoOAEFTMUDrHsSkIAEJCCBKhJQwFQxqvqUPwEtkIAEJCCBthJQwLQVr51LQAISkIAEJNAOAgqYdlDNv08tkIAEJCABCVSagAKm0uHVOQlIQAISkEA1CbRHwFSTlV5JQAISkIAEJFAQAgqYggRCMyQgAQlIQAISaJ6AAqZ5VraUgAQkIAEJSKAgBBQwBQmEZkhAAhLIn4AWSKA8BBQw5YmVlkpAAhKQgAQkcJeAAuYuCDcSkED+BLRAAhKQQLMEFDDNkrKdBCQgAQlIQAKFIaCAKUwoNCR\/AlogAQlIQAJlIaCAKUuktFMCEpCABCQggRqBrhQw169fDytXrgxz585N0vr162tA8sw4tgQkIAEJSEACzRHoSgGzcePGMGvWrHDy5Mlw+PDhcPTo0bBjx47miNlKAhKQgAQkIIHcCaQETO62dMyALVu2BBIDTps2LSxatCicOHGCXZMEJCABCUhAAiUg0JUCJh2XS5cuJTMwTz75ZLrYvAQkIAEJSKA5ArbKhUBXCxjWvixevDjMnj07sM0lAg4qWEJyVQAAEABJREFUAQlIQAISkMCwCXS1gOExEutgWA+zevXqwOLeRgSPHDmSrJdhzUxfX1+4detW6dPt27fDzZs3S+9HNhb6Va5zs6rx4rzskG8dfw3rV7leY3fu3Gl0ayt1eVcLmBi5VatWhTNnzoRTp07Fonu227ZtSz65xKeXent7w\/nz50udLly4EC5fvhwuXrxYaj+ycdCvcp2XVY0X52VVfdOv8r3Gbty4cc89rQoFCpj+KHITv++++8L06dP79+r\/37x5c9i9e3eSEDwzZ84MZU74OnXq1DBjxoxS+5GNgX7lcF6O4rVQ1XhxXlbVN\/0q32tswoQJ9W9sJS\/tSgHD2hcSseOx0euvv558EolPJFFWL8V1MqyV6enpCePGjSt1Gj9+fBg7dmypfagXA\/0q13lZ1XhxblbVN\/0q32tszJgx9W5rpS\/rSgHD98CcO3cu+RK7hQsXJkGkLMn4p2wEtFcCEpCABLqQQFcKmIkTJyaPgljAS+LREGVdGH9dloAEJCABCZSSQFcKmJZGys4kIAEJSEACEug4AQVMx5E7oAQkIAEJSEACoyWggBktQY+XgAQkIAEJSKDjBBQwHUfugBKQgAQkkD8BLSg7AQVM2SOo\/RKQgAQkIIEuJKCA6cKg67IEJJA\/AS2QgARGR0ABMzp+Hi0BCUhAAhKQQA4EFDA5QHdICeRPQAskIAEJlJuAAqbc8dN6CUhAAhKQQFcSUMB0Zdjzd1oLJCABCUhAAqMhoIAZDT2PlYAEJCABCUggFwJdKmByYe2gEpCABCQgAQm0iIACpkUg7UYCEpCABCRQeQIFclABU6BgaIoEJCABCUhAAs0RUMA0x8lWEpCABCSQPwEtkECNgAKmhsKMBCQgAQlIQAJlIaCAKUuktFMCEsifgBZIQAKFIaCAKUwoNEQCEpCABCQggWYJKGCaJWU7CeRPQAskIAEJSOAuAQXMXRBuJCABCUhAAhIoDwEFTHlilb+lWiABCUhAAhIoCAEFTEECoRkSkIAEJCABCTRPoEwCpnmvbCkBCUhAAhKQQKUJKGAqHV6dk4AEJCABCVSTgAKmmnHVKwlIQAISkEClCShgKh1enZOABCSQPwEtkEA7CChg2kHVPiUgAQlIQAISaCsBBUxb8dq5BCSQPwEtkIAEqkhAAVPFqOqTBCQgAQlIoOIEFDAVD7Du5U9ACyQgAQlIoPUEKiNgLl26FJYsWRLmzp2bpJUrV4br16\/XJUY59bEt2\/Xr19dta6EEJCABCUhAAsUjUAkBgyBZt25dWLFiRTh58mQ4duxYQnrjxo3JNvvnxo0b4dq1a2Hfvn1Je47ZsmVLtllF9nVDAhKQgAQkUD0ClRAwEydODLt37w5r1qxJIsT+E088Ec6dO1d3FubixYtJu+nTpydb\/0hAAhKQgAQkUC4CbRcwRcSBgPnkk0+KaJo2SUACEpCABCTQBIFKChjWw+zZsycwC8NsTJbDiRMnwunTp8PixYuT9TKsneGYbLv0\/pEjR8Lhw4eT1NfXF27dulX6dPv27XDz5s3S+5GNhX6V69ysarw4L6vqm3515DXWsmvznTt30rezyuQrJ2DiepjZs2eHZ599tm6gEDCIF9bKsP5l0aJFgTU0HFv3gP7Cbdu2BRb+knp7e8P58+dLnS5cuBAuX74cmI0quy9p+\/WrXOdlVePFOVlV3\/SrfK8x1n3238Yq979SAgYBsnr16iRIO3fuDPVmX6hkwS5rZmL9qlWrwpkzZ8KpU6eorps2b96crLPhONrPnDkzlDmx\/mfq1KlhxowZpfYjGwP9Ktd5WdV4cV6W3rcG1zj9Kt9rbMKECXXva2UvrIyAieJl1qxZidCI4qTZAN1\/\/\/2BF2aj9szoMGtD6unpCePGjSt1Gj9+fBg7dmypfagXA\/0q13lZ1XhxblbVN\/0q32tszJgxjW5tpS6vjICJH5mO20ZRQejwGGjHjh1JE\/Y3bdoUHnrooTBt2rSkzD8SkEDuBDRAAhKQwKAEKiFgWIB79OjRZIHtwoULk4W5fDldXJyLSEG0HDhwIHmsxOOlQ4cOJe1oD6GhhA9tTBKQgAQkIAEJFINAJQQMMycHDx6sfSkdC3NJlFHH4yTWrixdujShHvdpQ6KOsqTSPxKAgEkCEpCABApNoBICptCENU4CEpCABCQggZYTUMC0HGlLOrQTCUhAAhLIgUDfxzfD94+eD1\/b\/rNRp7\/5h8afbM3BtcoNqYCpXEh1SAISkIAEBiPQ9\/Gte0TK7+76IKx4+3xY9r3j4fk3fxHe\/ejqqNPGfgEz59s\/HiCEFDWDRWZ4dfUFzPD6sLUEJCABCUigFAQQL8yu1BMpR87eCmeutfZba\/uu3BoghKKoKQWsghupgCl4gDRPAhKQgARaQwDx8vybHwRERWt6vLeXZkoYn5mZZtrapjEBBUxjNtZIQAISkECFCLz70ZVkNqQILiFiWGtTBFvKaoMCpqyR024JSEAC9xCwYDACvT89P1h1x+sOfnS142NWaUAFTJWiqS8SkIAEJFAaAswIlcbYAhqqgClgUDRJAmUloN0SKDKBninjC2Vez2fHFcqeshmjgClbxLRXAhKQgARGRGDJ5yeP6Lh2HbTqSzPb1XVX9KuA6Yowd4uT+ikBCUigMYHnFs0MXy2IiOmZMi5gT2NrrRmKgAJmKELWS0ACEpBAZQjseuYLuYsYxMuP1n6xMkzzckQB00LydiUBCUhAAsUmwLoTxMPGr8+pGYqg+K3PTQxfnj0uETfM0mTTc\/2PezgmlrO\/65mHw6dbfjuky2N9vW085tS3vhKwo2aAmRER+MyIjvIgCUhAAhKQQIkJ\/HVKwHz181PC\/j9aGPZ8c2b4++e\/EBA42bTrDx4OHBPL2Y+PgNLlsb7eNn1MidG1w\/QR9amAGRE2D5KABCQgAQlIIE8CCpg86Tu2BCQgAQnkT0ALSklAAVPKsGm0BCQgAQlIoLsJKGC6O\/56LwEJ5E9ACyQggREQUMCMAJqHSEACEpCABCSQLwEFTL78HV0C+RPQAgl0IYG+j291odfVclkBU6146o0EJCABCUigKwgoYLoizIV2UuMkIAEJSEACwyaggBk2Mg+QgAQkIAEJSCBvAgqYvCPg+BKQgAQkIAEJDJtAYQTMjh07wty5c+sm6obtmQdIQAISkIAEmiDg7xI1AalOk7yLchUwly5dCkuWLElECyBOnjwZ6iXqEDePPvpoOH78OLsmCUhAAhKQgAS6mEBuAgbxsm7duvDWW28lomXNmjUNw0Adwmb\/\/v1h06ZNDdtZIQEJSEAC3UJAP7udQG4CZtq0aWH37t2BbbNBoC3HNNvedhKQgAQkIAEJVJNAbgKmmjj1SgIS6BYC+ikBCeRLIDcBwyOkuP5l\/fr1HaWQHpu1NStXrgzXr1\/vqA0OJgEJSEACEpDAyAnkJmB4HHTw4MHw1FNPhb179yYLeTuxSBehwtqbFStWJGtvjh07ltDbuHFjsvWPBMpBQCslIAEJdDeB3ARMxL5ly5ZESBw+fDhMnjw5LF++PBEz7ZqVmThxYrL2hoXB2MD+E088Ec6dO+csDEBMEpCABCQggRIQyF3AREZxRoZPG+3bty\/wiSMe73RiViba4LZ5AraUgAQkIAEJ5EmgMAImDWHBggXh\/fffT2Zmtm7dGl588cXAupV0m1bl6XfPnj2BWRhmYxr1e+TIkcAsEamvry\/cunWr9On27dvh5s2bpfcjGwv9Kte5WdV4cV5W1bcq+HXnzp3a5f4\/9eerHK+0rzWnK5AppIDhy+qYeWEGZvXq1WHDhg2Zj1u3hnxcDzN79uzw7LPPDtrptm3bAot9Sb29veH8+fOlThcuXAiXL18OFy9eLLUf2TjoV7nOy6rGi\/Oyqr5Vxa+j\/\/F07Zp\/\/dq1UBW\/OPfSCb9u3LhR87VKmcIIGMQE4gDRwjqY+fPnBxbY8khp6dKlLWfOeIgjOt65c2cYbPaFNps3b07WzvA9NKtWrQozZ84sdZo+fXqYOnVqmDFjRqn9yMZBv8p1XlY1XpyXVfWtKn5NmTKZS3uSJk6aFKriF+deOuHXhAkTEj+TPxX6k7uAYbEuomXhwoXJIxrEBKIFoTCUqBhpHKJ4mTVrViJKmhmHWZrFixcHUk9PTxg3blyp0\/jx48PYsWNL7UO9GOhXuc7LqsaLc7OqvlXJr3gP+TdjxoQq+cX5FxN+jen3L1TwX24ChrUnfA8MH6FGFLRztiUbt40bNyZFcZvs+EcCEpCABNpNwP4l0DICuQkY1l\/wsWkWxTY724Lo4THTaLynj6NHjyazPcz6MPtDQkxRN5q+PVYCEpCABCQggc4QyE3AsMble9\/7Xnj66aeT7305cOBAQ4937NiRtFm2bFl4+eWXG7ZrpiL9cW0eVcV08ODBtiwUbsYm20hAAh0i4DASqEPgc1PG1Sm1qOgEchMwgEmLiXfeeScRKcyGZBNtERp8tJqPWLNvkoAEJCABCUigewnkKmDS2OM38iJUsil+a266vXkJlJCAJktAAhKQQIsIFEbAtMgfu5GABCQgAQlIoAsIKGC6IMg1F81IQAISkIAEKkJAAVORQOqGBCQgAQlIoJsIdFLAdBNXfZWABCQgAQlIoI0EFDBthGvXEpCABCQggdETsId6BBQw9ahYJgEJSEACEpBAoQkUSsDEL6zje2D4Yjv2+eZdfruo0BQ1TgISkECFCVTRtb6Pb1XRra7yqTAChh91PHToUPjHf\/zH8OCDDyZBePbZZ5Otv1mUYPCPBCQgAQlIQAJ3CRRCwPAbRPw+0QsvvBB+7dd+7a5pIfAr0ZRRR5tahRkJSKCLCOiqBCQggXsJFELA3GuWJRKQgAQkIAEJSKAxgUIIGH4TacWKFeH1118P\/\/zP\/1yzllmXV155JVBHm1qFGQl0kIBDSUAC1SbQ81l\/zLGMES6EgAEcv3fE46Lf+Z3fCadPnw6rV68OixcvTsQLdbQxSUACEpCABCQgAQgURsBgzNKlS4M\/5AiJdDIvAQlIQAISkECWQKEETNY49yUgAQlIQAISkEA9AkMKmHoHtbqMtS5LliwJfP\/LYImPWrd6bPuTgAQkIAEJSKB8BAohYFigy0Jdvv\/l8OHDtcdI5Cl76aWXwrFjx8K5c+eCIqZ8J5kWS0ACEuhCArrcZgKFEDDMwOzZsyds2LAhIGaiz+Qpo+7GjRuBRb58J0ysdysBCUhAAhKQQHcSKISA6U70ei0BCUigjQTsWgIVJ1AIAcNMC4+Q+M4XZmMic\/KUUUebEydOhNmzZ8dqtxKQgAQkIAEJdCmBQggY2PNdLzwu4rtf4kJe8pRRxw87bt++Pbz88ss0N0lAAsUmoHUSkIAE2kqgMAIGL+t9Dwxl1CFi3n\/\/\/bBgwQJ2TRKQgAQkIIERE\/jlFX+NesTwCnJgoQRMQZhoRhUI6IMEJCABCVSaQGEEzPHjx8Ojjz5a97tg+I4Y1sNUOhI6J679IPUAABAASURBVAEJSEACEpBA0wQKIWCuX78eNm3aFNauXZt83wtrX3bu3Bni98CwDoZFvKE8\/7RUAhKQgAQkIIE2EiiEgOE7Xs6ePRvmzZsXJk6cGGbNmhX4xBGiBfHy+uuvB0ROGznYtQQkIAEJSEACuRNo3oBCCJisuQgZBEwsR9wgcuK+WwlIQAJVIND38a3w\/aPnw9e2\/6yW\/uYfTtV1bTht63bQxsJO2NbOMXqmjG8jHbtuF4FCCBhmWhYtWhTeeeedxE8EDN+4y7oXhAzf\/TJhwoSkzj8SkIAEGhGod5NLi4NO5n931wdhxdvnw7LvHauJk3rjP\/\/mL8K7H12tpY39AmbOt39c95jhtK03VivKGvnVCdtaOQbCMZ5HvT89H7PBTHkIFELAgGvjxo3Jbx3xfS98dBpBw1qY+N0vPFqiXTOJ30uin0ZteRy1cuXKAQuGOaZRe8slIIHiE0C8cIPO3uTS4qDT+SNnb4X\/65fXa+IkO35fg4\/yUj6attljW72f9Qt7650hlLdqbPpq5Rjp\/hCND2\/9Wb3uLSswgcIIGATK7t27w5o1axJcW7ZsSX7Ucbjf\/YIQ2bt3b9JHoz88jrp27VrYt29fMsbJkycD4zVqb7kEJFBsAoiX59\/8IKRvSsW2uJF1ludFgHPniR+czmt4xx0BgUIIGB4V8VHpAwcO3OMCZdTR5p7KVAH1tPvwww\/D\/PnzUzX3Zi9evJgUTp8+Pdn6RwISKDeBdz+6ksxylNsLrc+bwJlrd8J\/OH4lbzMcv0kChRAwTdo6ZLPXXnst8MvVkyZNGrQtAuaTTz4ZtI2VEuhGAmX12TUMZY1c8ew++NHV4hmlRXUJ5CpgWKfC7x6x1uX06dNh9erVA9alUEcZ62FY6FvXg7uF1D\/yyCN39wbfsDCY8RiXMZi5YQZn8KOslYAEJCCBqhNgNq\/qPlbFv1wFDOtdWH8Sv7COL69jP5tavT4FAYN4OXbsWLIGBoG0bt26Qb9r5siRI8kX62FrX19fuHXrVunT7du3w82bNwvkR2uY6ldrOHbqHG9FvGZP+jdVuSbrR84EHvj1MZW7Jt65cydnqu0ZPlcBE11i9uTgwYOBTx\/FsnZuEUQsGGbhMOOsWrUqnDlzJpw6Vf\/7F2izbdu2wCeXSL29veH8+fOlThcuXAiXL18OPE4ruy9p+\/WrXOdlq+L1X\/+XvEpNEhg9geXzxpf62p6+HpLnNcYHV0ZPpng95CZgeGTDoxse4QyVaEf7duK7\/\/77w2CLejdv3hwQPSQEz8yZM0OZE75OnTo1zJgxo9R+ZGOgX+U6L1sVrxe\/9m\/DVz8\/uZ2XCPvuAgIPTBoT\/vDfPVi5a2JVv0ctNwETZ12yj4vq7R\/sn52hfSteP\/E7YFh\/Q3\/s8ztMDz30UBhsDL5Mj8dOpJ6enjBu3LhSp\/Hjx4exY8eW2od6MdCvcp2XrYzXrme+EBQxXNVMIyUwu\/\/xUb3rSpnLeI2NGTNmpEiaPS6XdrkJmE56i0jh0Q8fyeaxEWttDh06lCwYXrhwYWIKX6SXZPwjAQmUkkDPZ8eFH639YnjuSzNr9vdMGZeIGoRNJxPj1ozoz8SxG5XH+uFus\/31D5X8p3y4fTXb\/rc+NzF8eXbruWJzYnzmD+XN2taoHX2ku43tsuX\/7W8M\/gnWdB\/m8yfwmfxN+FcLmBXJPk6i7F9bDJ1DoPCYhwXCsXUsi2ts4n6c7aE9ZbG9WwlIoLwEVi2aUTP+r78+JxE1CJtOplPf+koinKIhfBstX7bHl6XFMm6eo7WJcTb2+xhvyIi3Xc88HCgfbd+Njt\/\/RwvDnm\/ODH\/\/\/BdayhabR+xLv3BtZC\/l9A2jyL5ePHh89Pu\/MTE2cVsCAoURMAgVvsOFT\/lEYUGeMupKwFITJSABCdQIbF8+J5mpiAX1xEusG802LdJ2\/cHD4blFM0fTXa7HttOX7CPGbDz2\/9GCXH138OETKISAYYEuQmXDhg0D1qGwJoUy6mgzfPc8QgISkEDbCdQdoOez45OZim\/99oPJbAwzAOkZkp7+R151D7SwLQTgzWxMo1menv54tWVgO20bgUIImLZ5Z8cSkIAEcibw7\/sFDDdOUtlnSHJG2ZLh2znL0xID7aRpAoUQMMy0rFixIrzyyishPdNCnjLqaNO0VzaUQDcR0NcBBFhrMqDAHQlIoJIECiFgIMuiW4QKH1OOC3nJU0YdbUwSkIAEhkOgx8c0w8FlWwmUikBhBAzUECpxAW\/cUkadqbAENEwCEpCABCTQcQK5CRgeD\/ENu8y2rF+\/vuOOO6AEJCABCUhAAuUlkJuAYU0L37D71FNPhb179yZfKvfoo4+G48ePD4+mrSUgAQlIQAIS6DoCuQmYSJofVuRxEd\/5Mnny5LB8+fJEzDgrEwm5lYAEhkPgl1duDae5bSXQtQTK7njuAiYCjDMyiJl9+\/aF\/fv3J0LGWZlIyK0EJCABCUhAApFAYQRMNIjtggULwvvvvx8QM1u3bg0vvvjigI9X08YkAQlIQAJlJqDtEhgdgUIKGNbBMPPCAt\/Vq1cHvo2XGZrRuerREpBAtxHomTK+21zWXwl0DYHCCJj4i9GIFtbBzJ8\/Pxw7diyZhYk\/wtg1UdFRCUig7QQcQAISKDeB3AUMi3URLQsXLgws5N25c2ciWnbv3h0mTvSXQct9emm9BCQgAQlIoD0EchMw8Xtg+Ag137jrbEt7AmyvRSWgXRKQgAQkMBoCuQkYjH7ttdecbQGESQISaBkBfwupZSjtSAKFJpCbgGFR7iOPPFJoOFU2Tt8k0A0E\/C2kboiyPnYrgdwETLcC128JSEACEpCABEZPICcBM3rD7UECEpCABCQgge4loIDp3tjruQQkIAEJlI2A9tYIKGBqKMxIQAJVINB35WYV3NAHCUhgCAIKmCEAWS0BCUhAAjUCZiRQGAIKmMKEQkMkIIFWEuiZMq6V3dmXBCRQMAIKmIIFRHMkIIFBCFglAQlI4C4BBcxdEG4kIAEJSEACEigPAQVMeWKlpfkT0AIJSEACEigIAQVMQQKhGRKQgAQkIAEJNE9AAdM8q\/xbaoEEJDAkAX8LaUhENpBAJQgoYCoRRp2QgAQkIAEJdBeB4QiYSpJZv3592LFjRyV90ykJdDMBf8ixm6Ov791AoKsFDOJl79693RBnfZSABCQggdwIOHA7CHSlgLl06VJYsmRJ+PDDD8P8+fPbwdU+JSABCUhAAhJoI4GuFDDwfO2118KePXvCpEmT2DVJQAIVIdB35VZFPGmdG\/YkgSoS6EoBM23atPDII48E\/0lAAhKQgAQkUE4CXSlgRhKqI0eOhMOHDyepr68v3Lp1q\/Tp9u3b4ebNm6X3IxsL\/SrauTm4Pa2OV3x937lzJ\/dzu9W+Zc\/1vPb1a\/BzOq+4NBqX10J8XVRpq4BpMprbtm0LK1euTFJvb284f\/58qdOFCxfC5cuXw8WLF0vpx9H\/eDp890f\/T\/jq9p\/V0v+w74NQdr8anVed9qsR30b2jbQ87Verxowv6enjQ67ndtq3kfIp4nH6Va5rP\/G6ceNGfFlUaquAaTKcmzdvDrt3707SqlWrwsyZM0udpk+fHqZOnRpmzJhReD9uj50c\/o8zIax4+3wtrfzfzoe\/+MfL4cjZW7W07ejVsOzNS+G\/f+9O+O\/+98u1tunjypp\/7u8\/7qhfjfg+8YPTLeWa9qtVY8aXNOfG\/3z8Vm7nd5leY8O5nulXua79xGvChAnxZVGprQKmyXDOnj07LF68OEk9PT1h3LhxpU7jx48PY8eOLbwPF\/rfOPzurl+EtftO1YQKN6Yz1+7UjRzl\/\/evPg0\/vfifBrTnmLKnTvoFx3qAKW81x+gXfbdizNgH\/f1Ph86Hh7f+LJfzvCyvseFey\/SrXNd+4jVmzJj4sqjUVgHT9nA6wEgJ8JXwz7\/5QfBTJSMl6HEQ4PyZ8+0fkzVJQAIVItDVAmbixInJI6E1a9ZUKKTVceXdj66Edz+6Wh2H9CQ3AoiY7x89n9v4DiwBCYyAwBCHdLWAGYKN1TkT6P2pN5ycQ1Cp4Q8qhisVT52RgALGc0ACEugKAszodYWjOtkqAvZTcAIKmIIHqJvN65kyvpvd1\/cWE\/DHHVsM1O4kkDMBBUzOAXD4xgSWfH5y40prJDBMAqu+NHOYR+Tc3OElIIFBCShgBsVjZZ4Enls0M3xVEZNnCCozds+UcYHzqTIO6YgEJBAUMJ4EhSaw65kvKGLyiVBlRkW8\/GjtFyvjj45IQAL\/QkAB8y8c\/FtQAqxb4Oaz8etzahZyQ2JmJp0oqzVIZShPt2tVnn5Twwwry7HRDvLDOvhuY46LfRRti213zRywoTxr6299bmL48uxxiUjN1qX3OXZAZ5kd6tPtyT\/X\/8ho1zMPh1Pf+krgPMoc4q4EJFByAgqYkgewsuZnHPvrfgHDTYpibkaImnTiJoXIiTfE9M0r3a5V+TgeN0oS47HFvmzCbupoE2+o0Y56\/SRt\/vIryU092xf79BePL+K2oU\/9QiJr7\/4\/Whj2fHNm+PvnvxCyddl9GOJ\/NjXisesPHg4+NsrScl8C1SGggKlOLLveE0ROvCFu\/+actt+8GC\/eZLlZkkdEcaMlZQULberdULP90CaKtNgfwuz3f2Ni+N7v\/9tSzCjU82k0J2iWR5Yv9aPp32MlIIHyEVDA1I+ZpRIYEYFW37hjfwizzb8zNTz7m1NHZFdVDoo8EIuNBGFVfNUPCUhgcAIKmMH5WCsBCUhAAhKQQNMEOtdQAdM51o4kAQlIQAISkECLCChgWgTSbtpPgB\/ka\/8ojiABCZSZgLZ3DwEFTPfEWk8lIAEJSEAClSGggKlMKHVEAhLIn4AWSEACnSKggOkUacdpGYEef+SxZSztSAISkEBZCShgyho57ZZAHQIWSUACEugWAgqYbom0fkpAAhKQgAQqREABU6Fg5u+KFkhAAhKQgAQ6Q0AB0xnOjiIBCUhAAhKQQAsJVErAtJCLXRWMQN\/HtwpmkeZIQAISkECeBBQwedJ3bAlIQAISkED+BEppgQKmlGHTaAlIQAISkEB3E1DAdHf8S+l9z2fHldJujZaABBoQsFgCIyCggBkBNA+RgAQkIAEJSCBfAgqYfPk7ugQkkD8BLZCABEpIQAFTwqBpsgQkIAEJSKDbCShguv0M0P\/8CWiBBCQgAQkMm4ACZtjIPCAPAn1XbuYxrGNKQAISkEBBCShgChqYDprlUBKQgAQkIIHSEaiUgNmxY0eYO3duksg3isb169fDypUrk3ax\/fr16xs1t1wCEpCABCQggYIRyF\/AtAjI8ePHw+7du8O+ffuSRJ6yet3fuHEjXLt2LWl38uTJQNqyZUu9ppYVkMDnpvg9MAUMiyZJQAIS6CiBygiY9957LzzwwANhzpw5YcGCBeGxxx4LlNWjefHixaR4+vTpydY\/EpCABCQggbIR6HZ7KyNgTpw4EWbNmhXkj9dOAAAQAElEQVQmTpxYiylltZ1UBgHzySefpErMSkACEpCABCRQJgKVETBAnzdvHpskpfNJQeoPwub06dNh8eLFyTqYJUuWhEuXLqVa3Js9cuRIOHz4cJL6+vrCrVu3Sp9u374dbt68WQo\/7ty5UwsK+cH4l8mvwfzI1ulX+V5z1Y5ZOa4d2dfRYPtVjRfXzNoFtEKZSgmYZuOCgEG8HDt2LFn\/smjRorBu3brA4t5GfWzbti1Z+Mvi397e3nD+\/PlSpwsXLoTLly8HZqPK4Mvly7+qhebq1asN2ZfNr2bZ61f5Xm\/GrFwxq3K8WPdZu4BWKFMpAYMwibFJ52NZ3LJgl0W+8XHTqlWrwpkzZ8KpU6dik3u2mzdvThYJcxztZ86cGcqcWP8zderUMGPGjFL4MWXK5FpMJk+e3NDmsvnV7DmkX\/e+3ppll1c7Y1aumFU5XhMmTKhdP6uUqYyAqffIqF5Zo+Ddf\/\/9gRO4Uf3s2bOTR07M3PT09IRx48aVOo0fPz6MHTu2ND5cuPGvkRkzZkxDu8vmV7PnkX6V7\/VmzMoVsyrHi2tmqOC\/ygiYxx9\/PPzkJz8JfHSaRJ6ybMx4TMRjoPg9Mexv2rQpPPTQQ2HatGnZ5u5LoAEBiyUgAQlIIE8ClREwfHQaYbJ8+fJAIk8ZcBEp7B84cCD5lNLOnTvDoUOHkgW8CxcupEnYuHFjsvVP8Qn0fNbvgSl+lLRQAhKQQHsJVEbAgGnNmjXJoly+mI48ZSTWurB2ZenSpewmIoZ92pHI0yapLMkfzZSABCQgAQl0M4FKCZhuDqS+S0ACEpCABLqJwAgFTDch0lcJSEACEpCABIpGQAFTtIhojwQkIAEJVJeAnrWMgAKmZSjtSAISkIAEJCCBThFQwHSKtOOMisAvr9wa1fEeLAEJJAT8I4HKEFDA5BjKvo9vhe8fPR++tv1ntfQ3\/9D424BzNNWhJSABCUhAAoUioIDJKRyIF4TL82\/+Irz70dVa2tgvYOZ8+8c5WeWwEmgzAbuXgAQk0CICCpgWgRxON4iX59\/8IPTdfSzSM2VcIMU+KFfERBr3bnumjL+30BIJSEACEugqAgqYHML97kdXkhkXhv7q5yeHU9\/6yr+kv\/xKYJ9yRAyPl8ibWkbAjiQgAQlIoCIEFDA5BLL3p+eTUXv6Z152PfOFJM8fviL\/R2u\/SDZJB\/sfLSUZ\/0hAAhKQgAQkMICAAmYAjjbv1Oke0fL8f\/hFuG\/9\/5kkmiBs2DJTw9YkAQlIQAISkMBAAgqYgTw6stdzdw0Hj4lYD5MelH3KKUPcsDVJQAISkIAEuplAPd8VMPWotLlsyecn10ZgMW9tpz+T3l\/1pZn9Jf6HAMKOrUkCEpCABCQAAQUMFDqcnls0s7ZYl49Qf\/\/umhjMYJ9tz5RxgXbkTRKQgAQkkCcBxy4iAQVMTlFh8W78xFHWBMRLejFvtt59CUhAAhKQQLcTUMDkdAawvgWRsvHrcwZ8Bwz7fKya+pxMK\/ywsil8iDSwxQTsTgISuJeAAuZeJh0t+et+AZN+VJReH9NRQxxMAhKQgAQkUCICCpgCBOtzU8YVwApNkEAjApZLQAISKB4BBUzxYqJFEpCABCQgAQkMQUABMwSgTlf7ceF7iVsiAQlIQAISyBJQwGSJuF9IAn1XbhbSLo2SgAQkIIF8CChghuTe\/gZ+qqb9jB1BAhKQgASqRUABU7B4\/vLKrY5bxGOr7x89H762\/We19Df\/cKrjdjigBCQgAQlUiECbXVHAtBlwM9333P1tpEZthyswhtO+7+ObiWh5\/s1fBL4FOKaN\/QJmzrd\/XDNpOH3Gg+odM1qR1OMntiJetxKQgAS6moACpqDhz978GwmMrCCIMylDtf\/dXR+EFW+fD8u+dzzUfjyyXxykBQLliBhsYZzB+mTGhjbZlD0mCiS2USRxDMenQ8GY0Rfq2U\/Xm5eABCQwBAGrK05AAVOwAHOjJnHTjjd\/hEQ9MylHCMSEIOAYyptpf+TsrXDm2p0BTflivXtEzP\/445rIGdC4f4exGJ+x2aYTdf1NBv1PG47heMQSfseEL9SRaEdHcUveJAEJSEAC3UtAAZNz7BEr7350pWYFeW7gedyoGRPRwLZmUAczjItYIZGPQ6cFFWUIHbYmCRSagMZJQAJtJaCAaSvewTtHvCBWEA2xJTduUtwv0jYrJDppW\/qHL+HD46VOju9YEpCABCRQLAIKmJzigXh5\/s0PGj6aycmsQYdFOAzaoE2VjMusTLr7gx9dTe+av5eAJRKQgAQqTaBrBcyOHTvC3Llzk0S+01HmUVG8KTO7kOfsRqd9b8V43\/\/p+VZ0Yx8SkIAEJFBSAl0pYI4fPx52794d9u3blyTylHUyhr13b8AIl13PfKGTQ3dmrA6MUm8tzIULF8IPfvCDwLYDJnRsCPzRr47hbslAxqwlGDvWifHqGOqWDdSVAua9994LDzzwQJgzZ05YsGBBeOyxxwJlLaM6zI78Jt5hArvbnEdL2bUwXIR6e3srKWD0627gS7LxXCxJoO6aabzugijRpqoCZtAQnDhxIsyaNStMnDix1o6y2k4HMj13v7yOmzDrYb76+SkdGLUaQ\/RMGVdzxLUwNRRmJCABCXQVga4UMER43rx5bJKUzicFdf4cOXIkHD58uGVp3rjrtVFYzPvHPf9fWDrz\/6+VmWlM4MzZMyGKmDcOHR8Qk7NnzyYHtjperYz9SPrSr9a99kbCfyTHGLNyxazq8UoujE39KU+jrhUwzYaIR01f\/vKXw7Zt28LKlStblv6XP3smjLv8YWIGi3n\/3f96Ixw4\/18k+9k\/Y278KlvU1ft3JvxXgZkrIIz55\/93QEz+4i\/+guKWx6uVsR9JX\/q1ckCcR8Kw08cYs3LFrMrx4h7GvSy5OFboT9cKmPQjo3Q+G1uCvnnz5mTRL4t9W5n2r18Wvvr5ydkh79nnhn1P4TAL4ozFMA8rfPN\/\/998qS2xaWWc7Wu3Mdotg2ZfB7Zr\/bnCPYx7WeEv6MM0sCsFTL1HRvXKIksCv3jx4tDq9FsL5oUfrf1i2Pj1OYmQQcw896WZST6O3aotPxHQqr6a7Qd\/6rVtVF6v7WBliLJvfXNRy+PS6jjbX+tfOzKVqedA8+cA97DBrqVlretKAfP444+Hn\/zkJ4GPTpPIU5ZXEBEXCBnSrj94OBE1rbrJR5+ef\/MXMduxLY\/G6g3WqLxe20ZliBd4Naq3XAIjI+BREpBAWQh0pYDho9M8D1++fHkgkaesSEHju2EaiRhu3tRlU5y9oTzmR+sTY9HXrmceDqf+8ittmR1q1sYBtnzrK8GPnzdLznYSkIAEqkegKwUMYVyzZk04efJkkshTVqTEzZkZhuzjpURI9N+8qcumOHtDecynj4\/CJl0WxcmnW377nkdZcSz6em7RzFDPJvqMib7SfQ9WTlv6T7ePZc3YUqRYtdIW+5KABCQggeYIfKa5ZrbKi0D28RJCYji2pI+PwiZdFsUJfTYqpy6d0u3oMyb6qldXr5wyfEm3j2WM1aicOpMEJCABCUhAATPIObB+\/frkt5L4zaQDBw4M0rJ8VdevX08+ljrQr\/L5kbaY9UyPPvpoLWbEL11f1vylS5fCkiVLan7l8dtd7WbHeYiP+NrusdrdPz7gC9eNmKoSM\/yIPvHonetIu3m2u\/968cJHYkhdu8dvd\/9cB\/GHRL7d43WyfwVMA9pcUI8ePZp8SdrOnTvDK6+8EqpwMuMuF53Vq1cnvrFfhURsXnzxxbB169bksSBfPEb8uOCW2T9itW7durBixYrEL36\/a\/v27YHzs8x+pW0ndry+0mVlzl+8eDH8+q\/\/evL6KvJj6uEy5pzj3OMcxC++zXzjxo3D7aZw7adNmxYOHjyYvL7w69ixY8knG3nNUVc4g4dhENe\/c+fOBXyqyjUx7f5n0jt554s0\/jvvvBMWLVoUOIH5uN7s2bOTk6BINo7EFmYp4ieuHnzwwZF0UchjiBMXoaVLlyb2sU\/8BvuOn6Rhwf\/wcxd8L0Zcp8Xvd82fPz+U3a809r1794ZJkyali0qdR8Dgz4QJE0rtR9Z4rolr165Nfj+Oui1btgQS+SqlN954I3Hn2WefTbZl\/sN1AqHJdaQq18R0PBQwaRp387zrRbVmvxuGk+Fuk9JuOJHffvvt8Oqrr5bWh242\/NSpU+HMmTMhitCys0BQ\/9M\/\/VP4wz\/8w7K7UrO\/CteJmjN3M8ySMaOZvSbera7MBj\/37NkTXnjhhQG\/lVcCB+uaSLy4l3FPwzdi+OSTT9ZtW8ZCBcwgUSP4VHPTR8WSL3viHTyp7H4MZT83xv3794eqvFi5ALHmgI\/9P\/bYY7V3wUNxKHp9b29vePrppytxs4isETBM1y9cuDBZt0TciF+sL+uWx2LMLsV1ZlXxKx0PZgOZbV+8eHG6uLR5Zm4RY5yLy5YtC9\/97ndDnKUurVMpwxUwKRhmq0GAdxqsh+EFW5UXKyKaR0k8y+YdVRUW47GmgjOuKjHCF4QK8XnqqaeSNRXEi\/IqrBX55JNPwg9\/+MPw3nvv1R6n1\/zCyZInYnfo0KHwxBNPVEZQc514\/fXXk3gRt02bNgXWxZQ8VDXzFTA1FPdmeCdFKSc2FyXypmITQLzwjp71L1V8Po+Q4R0VU8H4WuxoNLaO19Rbb70VVq1a1bhRCWuID0IznnvsVyFeMRT4gk8k8mU\/D6NfbG\/cuBGuXbtWmcezXB+ID3EiXiTyPCKjDp\/LnhQwdSJIoOs9MoqPlOocYlEBCPCiRLzw6YF4AymAWS03AWHNNHeZF4mylofHLDwS4+OdfCru9OnTgVkzHv8NE1rhm5c9Xpxr+JAFTRl12fIy7jNbxizT9OnTy2h+V9qsgGkQdtZORKXKhfbs2bOB54gNmlucMwHe0a9bty755BjPfXM2p2XD4xdrDeK0LyKN87Ls09z8dMf777+fPGbho6t8VQGfimPdEnUtA9jhjogP3x8SH4+xz0fEyx4v3tThA48jOCdJ5CmjrsOY2zIcbwyYueXTOm0ZoMOd4gf+ECfiRSJPGXUdNqctwylgGmDluTyBZjEX7w43bNiQfKS6QXOLcybAO\/qf\/\/zngUV4vKOPiZs\/L9y2mtfGzrk58IkxRAs+cT5yXlZJpLURX8e75sbAozFES9XixTmHYOGNHIlZaso6DrlNAyJg2tR1bt3GNUrEi0TMqjQ7rYAZ5NQi0Lw7JCFoBmlauioutAcPHqzMinTetaff0RMzEusREAGlC1DK4Bgr\/CFxXqaqK5Hl9cX5iK9ldwgf8IVYkaoULwQLPpGq5BfnHP6QyFclce3jGki8SFXzTwFT\/jNVDyQgAQlIQAJdR0AB03Uh12EJSEACEpBA+QmMXsCUn4EeSEACEpCABCRQMgIKmJIFTHMlIAEJSKAaBPRidAQUMKPj59ESkIAEJCABCeRAQAGTA3SHlIAEJJA\/AS2QQLkJKGDKv\/eYzwAAA9BJREFUHT+tl4AEJCABCXQlAQVMV4ZdpyUwNAG+0j\/+8jBfylYv8c2efLkZbYfucWCL0ezxTbfNfEkhdv3e7\/1e4BtxRzOex0pAAsUjoIApXky0SAKFIJD9csCnnnoqkPhCrJj4cTh+wZe2nTIaMbJt27bw8ssvD\/mrwdj1jW98I3znO9\/plHmOIwEJdIiAAqZDoB2maAS0p6wE+LmIhx56KCBOmvEB0fXhhx8GZmOaaW8bCUigHAQUMOWIk1ZKoJAEEAXxERIzI\/yQ4datW0N89MSWNvwYZXwElX30w+OgWMeWto2cZQx+F4ofW41t+K0r+uRYUhwz1vPV\/szC9Pb2xiK3EpBABQgoYHIKosNKoKoE\/u7v\/i7s378\/8Jhp2bJlYfny5Ymr7B8+fDicPXs2vPHGG0kZYoUfPqQ81iNQKE8aZP4cO3YsKeGH6ZJM\/x9+sI4fqeN40tq1a8OmTZsCwqa\/Ovk\/b968cPToUdfCJDT8I4FqEFDAVCOOeiGBwhBYsWJFYNYDg5gpefDBB5O1M+xPmDAhzJ49m2wiMFg\/s2HDhlp7jmMfEcNsS9Iw9YdfDOZ4+qEYkXLu3DmytcQPDvIDdvyQXSycPn16+PTTT8PFixdjkVsJSKCcBGpWK2BqKMxIQAKtIMBsRzP93LhxI5mNWb16deDRT0zsN3M8bRApLCRmXQzHZx8f0YaEgLnvvvsUMMAwSaAiBBQwFQmkbkigbASYDbl69WrYuXNn8riJxz8xHTx4sDYrM5RfS5cuTY7n8dL8+fOTR1aNhMxQfVkvgSEJ2KAwBBQwhQmFhkiguwgwKzJ58uTAY6FWeM5sDI+OopB57733at0ilniExJi1QjMSkECpCShgSh0+jZdAeQmw3oX1Mtu3bx\/wEef169cHPlXE+pasd48\/\/ni4du1a4PETdbShLcewTzp16lQ4c+ZMoC37JATMfffdFyogYHDHJAEJ9BNQwPRD8L8EJJAPARbc8qkhPqnEGhYSi3J5rMSMStaqOXPmhEmTJgVmWaijzauvvpp8wohjSfT1V3\/1VwO+J+add94JixYtavqxFH2bJCCBYhNQwBQ7PlongcIQ2LJlS9jSn9IG8WVyfJKILTMqrF1hTUpsQ54y6ihDcPCYB+HCPol8XPvClnraUZdNlPO9MwiSWEffjMGxMTFurOfTTHyR3apVq2KRWwlIoAIEFDAVCKIuSKCbCAz3m3X5hNJwvrm3m1jqqwTKTEABU+bodZ\/teiyB5DHQn\/7pn97zZXX10PAtwD\/84Q\/DSy+9VK\/aMglIoMQE\/jMAAAD\/\/9IDsOgAAAAGSURBVAMAxzyZKOW\/OIwAAAAASUVORK5CYII=","height":337,"width":560}}
%---
%[output:0ee5332d]
%   data: {"dataType":"text","outputData":{"text":"Capture complete. Mean Voltage: 1.081 V\n","truncated":false}}
%---
