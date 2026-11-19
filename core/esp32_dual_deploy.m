function report = esp32_dual_deploy(masterPort, slavePort)
%ESP32_DUAL_DEPLOY Config-driven Master Gateway + Slave Mainboard provisioning & ESP-NOW verifier.
    cfg   = wb_config('workbench');
    board = wb_config('board');
    masterIno = wb_paths('sketch', cfg.deploy.masterSketch);
    slaveIno  = wb_paths('sketch', cfg.deploy.slaveSketch);

    if nargin < 1 || isempty(masterPort), masterPort = esp32_io('detect_port'); end
    if nargin < 2, slavePort = ''; end

    fprintf('\n================================================================================\n');
    fprintf('  ESP32 DUAL-NODE PROVISIONING (%s -> MASTER | %s -> SLAVE)\n', cfg.deploy.masterSketch, cfg.deploy.slaveSketch);
    fprintf('================================================================================\n');

    if isempty(slavePort) || strcmpi(masterPort, slavePort)
        fprintf('[STEP 1/3] Plug SLAVE (%s) into %s and press [ENTER]...\n', board.boardName, masterPort);
        input('', 's');
        [okSlave, idSlave] = esp32_flash(slaveIno, '--usb', masterPort, '--role', 'slave', '--ui', 'agv');
        esp32_io('connect', masterPort);
        slaveStatus = esp32_io('cmd', 'STATUS');
        esp32_io('disconnect');

        fprintf('[STEP 2/3] Power SLAVE externally, plug MASTER into %s, and press [ENTER]...\n', masterPort);
        input('', 's');
        [okMaster, idMaster] = esp32_flash(masterIno, '--usb', masterPort, '--role', 'master', '--ui', 'agv');
    else
        [okSlave, idSlave] = esp32_flash(slaveIno, '--usb', slavePort, '--role', 'slave', '--ui', 'agv');
        esp32_io('connect', slavePort);
        slaveStatus = esp32_io('cmd', 'STATUS');
        esp32_io('disconnect');
        [okMaster, idMaster] = esp32_flash(masterIno, '--usb', masterPort, '--role', 'master', '--ui', 'agv');
    end

    esp32_io('connect', masterPort);
    masterStatus = esp32_io('cmd', 'STATUS');
    pause(0.6);
    espNowInfo = esp32_io('cmd', 'ESPNOW PING');
    telemDump  = esp32_io('cmd', 'TELEM');
    esp32_cli('agv', 'zero');
    esp32_cli('agv', 'stop');

    fprintf('  [MASTER] %s\n  [SLAVE]  %s\n  [LINK]   %s\n  [TELEM]  %s\n', masterStatus, slaveStatus, espNowInfo, telemDump);
    fprintf('  [SCOPE HOOKS] CH1: Master GPIO %d (RTT) | CH2: Slave GPIO %d (MotLA) | CH3: Slave GPIO %d (US Trig)\n', ...
        board.pins.masterRttStrobe, board.pins.motorLeftA, board.pins.ultrasonicTrig);
    fprintf('  [WEB PORTAL]  http://%s/agv  |  http://%s/ude\n\n', cfg.transport.wifi.apIp, cfg.transport.wifi.apIp);

    report = struct('MasterPort',masterPort,'SlavePort',slavePort,'MasterBuild',idMaster,'SlaveBuild',idSlave, ...
        'MasterOk',okMaster,'SlaveOk',okSlave,'MasterStatus',masterStatus,'SlaveStatus',slaveStatus, ...
        'EspNowInfo',espNowInfo,'MirroredRegs',telemDump);
end