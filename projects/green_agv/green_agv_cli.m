function varargout = green_agv_cli(varargin)
%GREEN_AGV_CLI Project plugin for Green AGV Mainboard (invoked via 'esp32_cli green_agv ...').
    if isempty(varargin), sub = 'telem'; else, sub = lower(strtrim(char(varargin{1}))); end
    persistent auxState
    if isempty(auxState), auxState = uint32(0); end

    switch sub
        case 'flash'
            port = iif(numel(varargin)>=2, char(varargin{2}), esp32_io('detect_port'));
            role = iif(numel(varargin)>=3, char(varargin{3}), 'standalone');
            radio = iif(strcmpi(role,'slave'), 'sta_now', 'ap_now');
            uiHtml = fullfile(wb_paths('projects'), 'green_agv', 'web_ui_agv.html');
            inoPath = fullfile(wb_paths('projects'), 'green_agv', 'green_agv_mainboard.ino');
            [ok, bid] = esp32_flash(inoPath, '--usb', port, '--board', 'green_agv_rev52a', '--role', role, '--radio', radio, '--ui-file', uiHtml);
            if nargout > 0, varargout{1} = struct('ok',ok,'buildId',bid); end
            return;
        case 'stop',  w0 = pack(1, 0, auxState, 0, 0);
        case 'line',  w0 = pack(1, 2, auxState, 0, 0);
        case 'zero',  w0 = pack(15, 1, auxState, 0, 0);
        case 'lights'
            auxState = bitor(bitand(auxState, uint32(252)), bitand(uint32(str2double(string(varargin{2}))), uint32(3)));
            w0 = pack(1, 1, auxState, 0, 0);
        case 'drive'
            cL = int32(min(max(str2double(string(varargin{2})), -100), 100));
            cR = int32(min(max(str2double(string(varargin{3})), -100), 100));
            if numel(varargin) >= 4, auxState = uint32(str2double(string(varargin{4}))); end
            w0 = pack(1, 1, auxState, cL, cR);
        case 'telem'
            t = decode_t(esp32_io('cmd', 'TELEM'));
            print_t(t); if nargout>0, varargout{1}=t; end; return;
        otherwise
            error('AGV:BadSub', 'Usage: esp32_cli green_agv <flash|drive L R|line|stop|zero|lights 0..3|telem>');
    end

    t = decode_t(esp32_io('cmd', sprintf('SYNC %08X', w0)));
    print_t(t); if nargout>0, varargout{1}=t; end
end

function w = pack(m, md, aux, l, r)
    w = bitor(bitor(bitshift(uint32(m),28), bitshift(uint32(md),24)), ...
              bitor(bitshift(bitand(uint32(aux),255),16), bitor(bitshift(uint32(bitand(int32(l),255)),8), uint32(bitand(int32(r),255)))));
end
function t = decode_t(raw)
    hp = regexp(raw,'[0-9A-Fa-f]{8}','match'); if numel(hp)==5, hp=hp(2:5); end
    t = struct('encL',0,'encR',0,'us_mm',0,'lineMask',0,'btnT1',0,'btnT2',0,'fsm',0,'x_mm',0,'y_mm',0,'theta_deg',0,'vel_mms',0,'rtt_us',NaN,'loss',NaN);
    if numel(hp)<4, wb_log('err','AGV','BAD_RX',raw); return; end
    w1=uint32(hex2dec(hp{1})); w2=uint32(hex2dec(hp{2})); w3=uint32(hex2dec(hp{3})); w4=uint32(hex2dec(hp{4}));
    t.encL=i16(bitshift(w1,-16)); t.encR=i16(bitand(w1,65535)); t.us_mm=double(bitshift(w2,-16));
    msk=double(bitand(bitshift(w2,-8),255)); t.lineMask=bitand(msk,7); t.btnT1=bitand(bitshift(msk,-3),1); t.btnT2=bitand(bitshift(msk,-4),1);
    t.fsm=double(bitand(w2,255)); t.x_mm=i16(bitshift(w3,-16)); t.y_mm=i16(bitand(w3,65535));
    t.theta_deg=rad2deg(i16(bitshift(w4,-16))/1000.0); t.vel_mms=i16(bitand(w4,65535));
    rm=regexp(raw,'RTT_US:(\d+)','tokens','once'); if~isempty(rm), t.rtt_us=str2double(rm{1}); end
    lm=regexp(raw,'LOSS:(\d+)','tokens','once'); if~isempty(lm), t.loss=str2double(lm{1}); end
end
function print_t(t)
    wb_log('info','AGV',sprintf('FSM=%d',t.fsm),sprintf('Vel=%d mm/s | Pose=(%d, %d mm, %.1f deg) | Enc=%d/%d | US=%d mm | Line=%s T=%d%d | RTT=%.0fus', ...
        t.vel_mms,t.x_mm,t.y_mm,t.theta_deg,t.encL,t.encR,t.us_mm,dec2bin(t.lineMask,3),t.btnT1,t.btnT2,t.rtt_us));
end
function v = i16(u), v=double(int32(u)); if v>=32768, v=v-65536; end; end
function r = iif(c,a,b), if c, r=a; else, r=b; end; end
