function varargout = twin_cli(varargin)
%TWIN_CLI Isolated Digital-Twin Experiment Plugin (invoked via 'esp32_cli twin <flash|verify|world|disconnect>').
    if isempty(varargin), sub = 'verify'; else, sub = lower(strtrim(char(varargin{1}))); end
    persistent simSp
    cfg = wb_config('workbench');

    switch sub
        case 'flash'
            simPort = iif(numel(varargin)>=2, char(varargin{2}), esp32_io('detect_port'));
            ino = fullfile(wb_paths('experiments'), 'digital_twin', 'green_agv_plant_sim.ino');
            [ok, bid] = esp32_flash(ino, '--usb', simPort, '--board', 'green_agv_rev52a', '--radio', 'off');
            if nargout>0, varargout{1}=struct('ok',ok,'buildId',bid); end

        case 'get_sim_handle'
            simSp = open_sim(simSp, char(varargin{2}), cfg);
            varargout{1} = simSp;

        case 'sync_raw'
            varargout{1} = send_sim(varargin{2}, varargin{3}, varargin{4}, varargin{5}, varargin{6});

        case {'world', 'map'}
            dutPort = iif(numel(varargin)>=2, char(varargin{2}), 'COM8');
            simPort = iif(numel(varargin)>=3, char(varargin{3}), 'COM7');
            twin_world_ui(dutPort, simPort);

        case 'verify'
            dutPort = char(varargin{2});
            simPort = char(varargin{3});
            esp32_cli('connect', dutPort);
            stStr = esp32_cli('status');
            if ~contains(stStr, 'BLD_GREENAGV', 'IgnoreCase', true)
                wb_log('warn', 'TWIN', 'WRONG_FW', sprintf('%s is NOT running green_agv_mainboard (%s). Reflash with: esp32_cli(''green_agv'',''flash'',''%s'',''standalone'')', dutPort, stStr, dutPort));
            end
            simSp = open_sim(simSp, simPort, cfg);

            wb_log('hdr', 'TWIN', 'WIRE_AUDIT', sprintf('Testing DUT=%s <-> SIM=%s', dutPort, simPort));
            send_sim(simSp, 0, 0, 5, 350);
            green_agv_cli('drive', 60, 60, 3);
            pause(0.25);
            simT = send_sim(simSp, 0, 0, 5, 350);
            dutT = green_agv_cli('telem');
            green_agv_cli('stop'); green_agv_cli('lights', 0);

            checks = {
                'Motor L PWM (A:D13 -> B:D13)',   abs(simT.pwmL-60)<=5 && simT.freqL>1500, iif(simT.pwmL<-50, sprintf('%d%% @ %d Hz (WIRED TO B:D12! Move to B:D13)', simT.pwmL, simT.freqL), sprintf('%d%% @ %d Hz', simT.pwmL, simT.freqL));
                'Motor R PWM (A:D4  -> B:D4)',    abs(simT.pwmR-60)<=5 && simT.freqR>1500, sprintf('%d%% @ %d Hz', simT.pwmR, simT.freqR);
                'LEDs (A:25,33,14,23->B)',        simT.ledMask==15,                         sprintf('Mask=0x%X (exp 0xF)', simT.ledMask);
                'Line L/M/R (B:16,32,17->A:34,32,35)', dutT.lineMask==5,                   sprintf('Read=%s (exp 101)', dec2bin(dutT.lineMask,3));
                'Ultrasonic (D27 Trig / D26 Echo)', simT.trigCount>0 && abs(dutT.us_mm-350)<=35, sprintf('Trig=%d Meas=%d mm (exp 350)', simT.trigCount, dutT.us_mm)
            };
            allOk = true;
            for k = 1:size(checks, 1)
                ok = checks{k,2}; if ~ok, allOk = false; end
                wb_log(iif(ok,'pass','open'), 'TWIN', checks{k,1}, checks{k,3});
            end
            if nargout>0, varargout{1} = struct('allPassed',allOk,'checks',{checks},'dut',dutT,'sim',simT); end

        case 'disconnect'
            if ~isempty(simSp) && isvalid(simSp), try delete(simSp); catch, end; end; simSp = [];

        otherwise
            error('TWIN:BadSub', 'Usage: esp32_cli twin <flash SIM_PORT | verify DUT_PORT SIM_PORT | world DUT_PORT SIM_PORT | disconnect>');
    end
end

function sp = open_sim(spOld, port, cfg)
    if ~isempty(spOld) && isvalid(spOld) && strcmpi(spOld.Port, port), sp = spOld; return; end
    if ~isempty(spOld) && isvalid(spOld), try delete(spOld); catch, end; end
    try objs=serialportfind('Port',upper(string(port))); for k=1:numel(objs), delete(objs(k)); end; catch, end
    sp = serialport(port, cfg.transport.serial.defaultBaud, 'Timeout', 1.2);
    configureTerminator(sp, "LF"); pause(0.35); flush(sp);
    writeline(sp, 'STATUS'); resp = drain(sp);
    if ~contains(resp, 'USB_ONLY'), delete(sp); error('TWIN:BadSim', 'Port %s is not USB_ONLY SIM: %s', port, resp); end
    wb_log('pass', 'TWIN', 'SIM_READY', sprintf('%s -> %s', port, resp));
end

function s = send_sim(sp, autoTrk, btns, lineMask, distMm)
    w0 = bitor(bitor(bitshift(uint32(1),28), bitshift(uint32(autoTrk),24)), ...
               bitor(bitshift(uint32(btns),20), bitor(bitshift(uint32(lineMask),16), uint32(min(max(distMm,40),3000)))));
    flush(sp); writeline(sp, sprintf('SYNC %08X', w0)); raw = drain(sp);
    hp = regexp(raw,'[0-9A-Fa-f]{8}','match');
    s = struct('pwmL',0,'pwmR',0,'freqL',0,'freqR',0,'ledMask',0,'trigCount',0,'encL',0,'encR',0);
    if numel(hp)<4, return; end
    w1=uint32(hex2dec(hp{1})); w2=uint32(hex2dec(hp{2})); w3=uint32(hex2dec(hp{3})); w4=uint32(hex2dec(hp{4}));
    s.pwmL=i16(bitshift(w1,-16)); s.pwmR=i16(bitand(w1,65535));
    s.freqL=double(bitshift(w2,-16)); s.freqR=double(bitand(w2,65535));
    s.ledMask=double(bitand(bitshift(w3,-16),15)); s.trigCount=double(bitand(w3,65535));
    s.encL=i16(bitshift(w4,-16)); s.encR=i16(bitand(w4,65535));
end

function ln = drain(sp)
    bp = ["ets ","rst:","mode:","load:","entry ","configsip:","clk_drv:","ho 0 ","E (","W (","I (","D ("];
    for k=1:25
        lastwarn(''); ln=strtrim(char(readline(sp))); [wm,~]=lastwarn;
        if isempty(ln) && ~isempty(wm), error('TWIN:Timeout','Timeout on %s',sp.Port); end
        if ~isempty(ln) && ~any(startsWith(string(ln),bp)) && ~strcmp(ln,'ESP32_READY'), return; end
    end
    error('TWIN:NoData','No payload from SIM');
end
function v = i16(u), v=double(int32(u)); if v>=32768, v=v-65536; end; end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end