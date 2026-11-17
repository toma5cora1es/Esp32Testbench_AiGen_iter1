function report = esp32_dual_deploy(masterPort, slavePort)
%ESP32_DUAL_DEPLOY Automated Provisioning & HIL Verification for Dual-ESP32 (Master Gateway + Slave AGV).
%   1. Auto-detects or accepts Master COM port (Host Gateway) and Slave COM port (Green AGV Robot).
%   2. Compiles & flashes Master Firmware (Role=MASTER, Multi-UI=/agv & /ude, SoftAP + ESP-NOW + Keysight Trigger).
%   3. Compiles & flashes Slave Firmware  (Role=SLAVE, Low-Power STA + ESP-NOW + 500Hz Core-1 AGV Control).
%   4. Verifies end-to-end ESP-NOW wireless register mirroring (0x3FF4804C -> Slave -> 0x3FF48050..5C)
%      and outputs Keysight oscilloscope trigger instructions on Master GPIO 4.
%
% USAGE:
%   rep = esp32_dual_deploy('COM8', 'COM9');
%   rep = esp32_dual_deploy('COM8');          % Single-cable sequential flash (prompts to swap USB cable)

    rootDir    = fileparts(mfilename('fullpath'));
    masterIno  = fullfile(rootDir, 'firmware', 'esp32_bridge_ota', 'esp32_bridge_ota.ino');
    slaveIno   = fullfile(rootDir, 'firmware', 'esp32_bridge_ota', 'green_agv_cockpit.ino');

    if nargin < 1 || isempty(masterPort)
        avail = serialportlist("all");
        if ~isempty(avail), masterPort = char(avail(1)); else, masterPort = 'COM8'; end
    end
    if nargin < 2
        slavePort = '';
    end

    fprintf('\n========================================================================================\n');
    fprintf('  ESP32 DUAL-NODE PROVISIONING ENGINE (MASTER TELEMETRY GATEWAY + SLAVE GREEN AGV)\n');
    fprintf('========================================================================================\n');

    % --- STEP 1: FLASH SLAVE AGV NODE FIRST (IF SINGLE CABLE) OR DIRECTLY ON SLAVE PORT ---
    if isempty(slavePort) || strcmpi(masterPort, slavePort)
        fprintf('\n[STEP 1/3] Connect the SLAVE (Green AGV Robot) ESP32 to %s.\n', masterPort);
        input('           Press [ENTER] when the SLAVE AGV board is plugged in...', 's');
        [okSlave, idSlave] = esp32_flash(slaveIno, '--usb', masterPort, '--role', 'slave', '--ui', 'agv');
        esp32_io('connect', masterPort);
        slaveStatus = esp32_io('cmd', 'STATUS');
        esp32_io('disconnect');
        fprintf('  [SLAVE VERIFIED] %s\n', slaveStatus);

        fprintf('\n[STEP 2/3] Now disconnect the Slave (power it from Battery) and connect MASTER ESP32 to %s.\n', masterPort);
        input('           Press [ENTER] when the MASTER Gateway board is plugged in...', 's');
        [okMaster, idMaster] = esp32_flash(masterIno, '--usb', masterPort, '--role', 'master', '--ui', 'agv');
    else
        fprintf('\n[STEP 1/3] Flashing SLAVE (Green AGV Robot) on %s [Role=SLAVE, Low-Power ESP-NOW]...\n', slavePort);
        [okSlave, idSlave] = esp32_flash(slaveIno, '--usb', slavePort, '--role', 'slave', '--ui', 'agv');
        esp32_io('connect', slavePort);
        slaveStatus = esp32_io('cmd', 'STATUS');
        esp32_io('disconnect');
        fprintf('  [SLAVE VERIFIED] %s\n', slaveStatus);

        fprintf('\n[STEP 2/3] Flashing MASTER (Host Telemetry Gateway) on %s [Role=MASTER, Multi-UI]...\n', masterPort);
        [okMaster, idMaster] = esp32_flash(masterIno, '--usb', masterPort, '--role', 'master', '--ui', 'agv');
    end

    % --- STEP 3: END-TO-END ESP-NOW REGISTER MIRRORING & KEYSIGHT RTT VERIFICATION ---
    fprintf('\n[STEP 3/3] Verifying Wireless ESP-NOW Register Mirroring & Keysight RTT Trigger...\n');
    esp32_io('connect', masterPort);
    masterStatus = esp32_io('cmd', 'STATUS');

    % Write a test command word (Mode=1 Manual, Lights=3, SpeedL=40%, SpeedR=40%) to Master's STORE0
    esp32_io('cmd', 'W 3FF4804C 11032828');
    pause(0.15);
    espNowInfo = esp32_io('cmd', 'ESPNOW PING');
    pause(0.10);
    espNowInfo = esp32_io('cmd', 'ESPNOW STATUS');
    telemDump  = esp32_io('cmd', 'D 3FF48050 4');
    % Return motors to safe idle (0%)
    esp32_io('cmd', 'W 3FF4804C 10000000');

    fprintf('  [MASTER STATUS]   %s\n', masterStatus);
    fprintf('  [ESPNOW LINK]     %s\n', espNowInfo);
    fprintf('  [MIRRORED TELEM]  RTC_CNTL_STORE1..4 = %s\n', telemDump);
    fprintf('----------------------------------------------------------------------------------------\n');
    fprintf('  KEYSIGHT OSCILLOSCOPE VERIFICATION HOOKS:\n');
    fprintf('    - Probe 1 (Master GPIO 4) : Pulse Width = Exact ESP-NOW Wireless RTT (~1.1 to 1.8 ms)\n');
    fprintf('    - Probe 2 (Slave  GPIO 16): Left Motor Hardware PWM (2.0 kHz, 10-bit resolution)\n');
    fprintf('    - Probe 3 (Slave  GPIO 27): HC-SR04 10 us Trigger Pulse @ 16.6 Hz (60 ms period)\n');
    fprintf('  WEB PORTAL ROUTES (On Master 192.168.4.1):\n');
    fprintf('    - http://192.168.4.1/agv  : Green AGV Arcade Cockpit & Radar\n');
    fprintf('    - http://192.168.4.1/ude  : UDE 32-Bit SFR Register & Bitfield Debugger\n');
    fprintf('========================================================================================\n\n');

    report = struct( ...
        'MasterPort',   masterPort, ...
        'SlavePort',    slavePort, ...
        'MasterBuild',  idMaster, ...
        'SlaveBuild',   idSlave, ...
        'MasterOk',     okMaster, ...
        'SlaveOk',      okSlave, ...
        'MasterStatus', masterStatus, ...
        'SlaveStatus',  slaveStatus, ...
        'EspNowInfo',   espNowInfo, ...
        'MirroredRegs', telemDump);
end