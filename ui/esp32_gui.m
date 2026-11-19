function esp32_gui()
%ESP32_GUI UDE-Styled ESP32 Workbench GUI (100% English, config-driven).
    fig = findall(0, 'Type', 'figure', 'Tag', 'ESP32_UDE_GUI');
    if ~isempty(fig), figure(fig(1)); return; end

    cfg   = wb_config('workbench');
    board = wb_config('board');
    sfrDb = jsondecode(fileread(wb_paths('sfrDb')));
    allRegs = string(fieldnames(sfrDb.registers));

    fig = uifigure('Name', 'UDE ESP32 Workbench â€” SFR, CLI, Live ADC1 Scope & Flasher', ...
        'Position', [60 60 1260 740], 'Tag', 'ESP32_UDE_GUI', 'Color', [0.12 0.13 0.16]);

    mainGrid = uigridlayout(fig, [3 1]);
    mainGrid.RowHeight = {54, '1x', 38};
    mainGrid.Padding = [10 10 10 10]; mainGrid.RowSpacing = 8;

    topBar = uigridlayout(mainGrid, [1 9]);
    topBar.ColumnWidth = {115, 175, 85, 90, 125, 115, 110, '1x', 110};
    topBar.Padding = [6 6 6 6];

    uilabel(topBar, 'Text', 'Target (COM/BT/IP):', 'FontColor', 'w', 'FontWeight', 'bold');
    s = esp32_io('state');
    defTarget = cfg.transport.wifi.apIp;
    if ~isempty(s.Target)
        defTarget = ternary(strcmp(s.Mode,'bluetooth'), ['bt:' s.Target], s.Target);
    end
    btItem = string(['bt:' cfg.transport.bluetooth.deviceName]);
    targetDrop = uidropdown(topBar, 'Editable', 'on', ...
        'Items', unique([string(defTarget), string(cfg.transport.wifi.apIp), btItem, serialportlist("all")], 'stable'), ...
        'Value', defTarget);

    btnConn   = uibutton(topBar, 'Text', 'Connect',    'BackgroundColor', [0.16 0.62 0.36], 'FontColor', 'w', 'FontWeight', 'bold');
    btnDisc   = uibutton(topBar, 'Text', 'Disconnect', 'BackgroundColor', [0.65 0.22 0.22], 'FontColor', 'w');
    btnLed    = uibutton(topBar, 'Text', 'Toggle LED', 'BackgroundColor', [0.15 0.45 0.85], 'FontColor', 'w', 'FontWeight', 'bold');
    btnWeb    = uibutton(topBar, 'Text', 'Web Portal', 'BackgroundColor', [0.55 0.28 0.72], 'FontColor', 'w', 'FontWeight', 'bold');
    btnVerb   = uibutton(topBar, 'Text', ternary(s.Verbose,'Trace: ON','Trace: OFF'), ...
        'BackgroundColor', ternary(s.Verbose,[0.16 0.55 0.45],[0.35 0.35 0.40]), 'FontColor', 'w', 'FontWeight', 'bold');
    lblStatus = uilabel(topBar, 'Text', sprintf('FSM: %s | SFR: %d regs', s.Phase, numel(allRegs)), ...
        'FontColor', [0.75 0.85 1.0], 'FontName', 'Consolas');
    btnScan   = uibutton(topBar, 'Text', 'Scan Ports', 'BackgroundColor', [0.28 0.30 0.36], 'FontColor', 'w');

    tabs = uitabgroup(mainGrid);

    tabRegs = uitab(tabs, 'Title', '1. Peripheral Registers & Bitfields');
    regGrid = uigridlayout(tabRegs, [3 1]); regGrid.RowHeight = {38, '1.2x', '1x'};
    regCtrl = uigridlayout(regGrid, [1 6]); regCtrl.ColumnWidth = {150, 150, 155, 130, 130, '1x'};
    dropGrp = uidropdown(regCtrl, 'Items', {'Essential GPIO & RTC','GPIO','IO_MUX','LEDC','UART','SPI','I2C','TIMG','RTC_CNTL','SENS','DPORT'}, 'Value', 'Essential GPIO & RTC');
    edtFilt = uieditfield(regCtrl, 'text', 'Placeholder', 'Filter SFR name...');
    btnReadRegs = uibutton(regCtrl, 'Text', 'Read Displayed Regs', 'BackgroundColor', [0.20 0.50 0.80], 'FontColor', 'w', 'FontWeight', 'bold');
    edtSymAddr = uieditfield(regCtrl, 'text', 'Value', 'GPIO_OUT_REG', 'Placeholder', 'Symbol or 0xAddr');
    edtSymVal  = uieditfield(regCtrl, 'text', 'Placeholder', 'Hex Value (opt)');
    btnExecReg = uibutton(regCtrl, 'Text', 'Read / Write Symbol', 'BackgroundColor', [0.25 0.55 0.40], 'FontColor', 'w');

    tblRegs = uitable(regGrid, 'ColumnName', {'Register','Address','Hex Value','Binary (31..0)','Bitfields'}, ...
        'ColumnEditable', [false false true false false], 'ColumnWidth', {210, 100, 125, 300, 'auto'}, ...
        'FontName', 'Consolas', 'SelectionType', 'row');
    pnlBf = uipanel(regGrid, 'Title', 'Selected Register Bitfields (Edit "Field Value" to modify on chip)');
    bfGrid = uigridlayout(pnlBf, [1 1]);
    tblBf = uitable(bfGrid, 'ColumnName', {'Register','Bitfield','Bits','Access','Field Value','Hex'}, ...
        'ColumnEditable', [false false false false true false], 'FontName', 'Consolas');

    tabGpio = uitab(tabs, 'Title', '2. GPIO & Output Control');
    gpioGrid = uigridlayout(tabGpio, [2 4]);
    commonPins = [board.pins.builtinLed, board.pins.motorRightA, board.pins.buttonT1, ...
                  board.pins.motorLeftB, board.pins.motorLeftA, board.pins.servoAux, ...
                  board.pins.encoderLeft, board.pins.encoderRight];
    for idx = 1:numel(commonPins)
        p = commonPins(idx);
        pnl = uipanel(gpioGrid, 'Title', sprintf('GPIO %d', p));
        pg = uigridlayout(pnl, [3 2]);
        lp = uilabel(pg, 'Text', 'State: ?', 'FontWeight', 'bold', 'FontName', 'Consolas');
        lp.Layout.Column = [1 2];
        uibutton(pg, 'Text', 'HIGH', 'BackgroundColor', [0.16 0.60 0.35], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) gpio_op(p,'high',lp));
        uibutton(pg, 'Text', 'LOW',  'BackgroundColor', [0.65 0.22 0.22], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) gpio_op(p,'low',lp));
        uibutton(pg, 'Text', 'TOGGLE','BackgroundColor',[0.20 0.45 0.80], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) gpio_op(p,'toggle',lp));
        uibutton(pg, 'Text', 'READ',  'BackgroundColor',[0.35 0.35 0.40], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) gpio_op(p,'read',lp));
    end

    tabAdc = uitab(tabs, 'Title', '3. Multi-Channel ADC1 Voltmeter & Scope');
    adcGrid = uigridlayout(tabAdc, [2 2]); adcGrid.RowHeight = {44, '1x'}; adcGrid.ColumnWidth = {460, '1x'};
    adcBar = uigridlayout(adcGrid, [1 6]); adcBar.Layout.Row = 1; adcBar.Layout.Column = [1 2];
    adcBar.ColumnWidth = {165, 155, 130, 150, 175, 100};
    btnScanAdc = uibutton(adcBar, 'Text', 'Scan All ADC1 Pins', 'BackgroundColor', [0.15 0.48 0.82], 'FontColor', 'w', 'FontWeight', 'bold');
    btnStream  = uibutton(adcBar, 'Text', 'Start Live Stream',  'BackgroundColor', [0.16 0.62 0.36], 'FontColor', 'w', 'FontWeight', 'bold');
    btnSample  = uibutton(adcBar, 'Text', 'Sample Active Pin',  'BackgroundColor', [0.28 0.32 0.42], 'FontColor', 'w');
    dropPlot   = uidropdown(adcBar, 'Items', {'Selected Pin Only','All 6 ADC1 Pins'}, 'Value', 'Selected Pin Only');
    dropCal    = uidropdown(adcBar, 'Items', {'Calibrated (hw_cal.json)','Raw Linear (3.3V)'}, 'Value', 'Calibrated (hw_cal.json)');
    btnClear   = uibutton(adcBar, 'Text', 'Clear', 'BackgroundColor', [0.55 0.22 0.22], 'FontColor', 'w');

    chs = board.adc1Channels;
    adcPins = [chs.gpio];
    pnlLeft = uipanel(adcGrid, 'Title', 'ADC1 Channels (Config: board_green_agv_rev52a.json)');
    lg = uigridlayout(pnlLeft, [2 1]); lg.RowHeight = {80, '1x'};
    dmmPnl = uipanel(lg, 'BackgroundColor', [0.07 0.09 0.12]);
    dg = uigridlayout(dmmPnl, [2 2]);
    lblDmmPin = uilabel(dg, 'Text', sprintf('GPIO %d (%s)', chs(1).gpio, chs(1).channel), 'FontColor', [0.4 0.8 1], 'FontWeight', 'bold');
    lblDmmV   = uilabel(dg, 'Text', '0.000 V', 'FontColor', [0.3 0.95 0.5], 'FontWeight', 'bold', 'FontSize', 20, 'HorizontalAlignment', 'right');
    lblDmmRaw = uilabel(dg, 'Text', 'Raw: 0 / 4095', 'FontColor', [0.8 0.85 0.9]);
    lblDmmSt  = uilabel(dg, 'Text', 'Min/Max/Mean: --', 'FontColor', [0.75 0.78 0.85], 'HorizontalAlignment', 'right');

    initRows = cell(numel(chs), 5);
    for k = 1:numel(chs)
        initRows(k,:) = {sprintf('GPIO %d', chs(k).gpio), chs(k).silkscreen, chs(k).channel, '0.000 V', 0};
    end
    tblAdc = uitable(lg, 'ColumnName', {'GPIO','Silkscreen','Channel','Voltage','Raw'}, ...
        'ColumnEditable', false(1,5), 'Data', initRows, 'FontName', 'Consolas', 'SelectionType', 'row');
    tblAdc.Selection = 1; selectedIdx = 1;

    pnlScope = uipanel(adcGrid, 'Title', 'Live ADC1 Oscilloscope (FSM: SCOPE_IDLE)');
    sg = uigridlayout(pnlScope, [1 1]);
    ax = uiaxes(sg); ylim(ax, [0 3.4]); grid(ax, 'on'); hold(ax, 'on');
    xlabel(ax, 'Sample #'); ylabel(ax, 'Voltage (V)');
    adcLines = gobjects(1, numel(chs));
    for k = 1:numel(chs)
        adcLines(k) = animatedline(ax, 'LineWidth', 1.8, 'DisplayName', sprintf('GPIO %d', chs(k).gpio));
    end
    legend(ax, 'Location', 'northwest');
    sampleCount = 0; pinHist = [];
    adcTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.25, 'BusyMode', 'drop', 'TimerFcn', @(~,~) on_adc_tick());

    tabFlash = uitab(tabs, 'Title', '4. Build, OTA Flash & Memory Dump');
    fg = uigridlayout(tabFlash, [2 1]); fg.RowHeight = {115, '1x'};
    pnlOta = uipanel(fg, 'Title', 'Manifest-Driven Flasher (esp32_flash)');
    og = uigridlayout(pnlOta, [2 5]); og.ColumnWidth = {'1x', 110, 110, 110, 130};
    edtFlash = uieditfield(og, 'text', 'Value', wb_paths('sketch', cfg.deploy.standaloneSketch));
    btnBrowse = uibutton(og, 'Text', 'Browse...');
    dropRole  = uidropdown(og, 'Items', {'standalone','master','slave'}, 'Value', cfg.deploy.defaultRole);
    dropMode  = uidropdown(og, 'Items', {'--wifi','--usb'}, 'Value', '--wifi');
    btnFlash  = uibutton(og, 'Text', 'FLASH NOW', 'BackgroundColor', [0.85 0.38 0.12], 'FontColor', 'w', 'FontWeight', 'bold');
    lblNote   = uilabel(og, 'Text', 'Select sketch short-name or .ino/.bin path; UI templates inject via config/ui_manifest.json.');
    lblNote.Layout.Column = [1 5];

    pnlDump = uipanel(fg, 'Title', 'SFR Block Memory Dump');
    dg2 = uigridlayout(pnlDump, [2 1]); dg2.RowHeight = {34, '1x'};
    dc = uigridlayout(dg2, [1 4]); dc.ColumnWidth = {160, 100, 140, '1x'};
    edtDumpAddr = uieditfield(dc, 'text', 'Value', 'GPIO_OUT_REG');
    spnWords    = uispinner(dc, 'Limits', [1 64], 'Value', 12);
    btnDump     = uibutton(dc, 'Text', 'Read Memory', 'BackgroundColor', [0.20 0.50 0.80], 'FontColor', 'w');
    uilabel(dc, 'Text', 'Accepts SFR symbol name or hex address.');
    txtDump = uitextarea(dg2, 'Editable', 'off', 'FontName', 'Consolas');

    botBar = uigridlayout(mainGrid, [1 2]); botBar.ColumnWidth = {165, '1x'};
    uilabel(botBar, 'Text', 'MATLAB CLI Equivalent:', 'FontColor', [0.4 0.9 0.5], 'FontWeight', 'bold');
    edtEcho = uieditfield(botBar, 'text', 'Editable', 'off', 'BackgroundColor', [0.08 0.09 0.11], 'FontColor', [0.4 0.95 0.5], 'FontName', 'Consolas');

    fig.CloseRequestFcn = @(~,~) on_close();
    tabs.SelectionChangedFcn = @(~,e) on_tab(e);
    populate_sfr();

    function echo(c), edtEcho.Value = ['>> ' c]; end
    function on_close(), stop_stream(); try delete(adcTimer); catch, end; delete(fig); end
    function on_tab(e), if e.NewValue ~= tabAdc, stop_stream(); end; end

    btnVerb.ButtonPushedFcn = @(~,~) on_verb();
    function on_verb()
        v = ~esp32_io('state').Verbose;
        esp32_cli('verbose', ternary(v,'on','off'));
        btnVerb.Text = ternary(v,'Trace: ON','Trace: OFF');
        btnVerb.BackgroundColor = ternary(v,[0.16 0.55 0.45],[0.35 0.35 0.40]);
    end

    btnScan.ButtonPushedFcn = @(~,~) on_scan();
    function on_scan()
        echo('esp32_cli scan'); avail = esp32_cli('scan');
        targetDrop.Items = unique([string(cfg.transport.wifi.apIp), btItem, avail], 'stable');
    end

    btnConn.ButtonPushedFcn = @(~,~) on_conn();
    function on_conn()
        stop_stream(); t = strtrim(targetDrop.Value); echo(['esp32_cli connect ' t]);
        try
            esp32_cli('connect', t);
            lblStatus.Text = ['OK | ' esp32_cli('status')];
            lblStatus.FontColor = [0.4 0.95 0.5];
            on_read_regs();
        catch ME
            lblStatus.Text = ['Err: ' ME.message]; lblStatus.FontColor = [1 0.4 0.4];
        end
    end

    btnDisc.ButtonPushedFcn = @(~,~) on_disc();
    btnLed.ButtonPushedFcn  = @(~,~) on_led();
    btnWeb.ButtonPushedFcn  = @(~,~) on_web();
    function on_disc(), echo('esp32_cli disconnect'); esp32_cli('disconnect'); lblStatus.Text = 'FSM: DISCONNECTED'; end
    function on_led(),  echo('esp32_cli led toggle'); esp32_cli('led', 'toggle'); end
    function on_web(),  echo('esp32_cli web'); esp32_cli('web'); end

    dropGrp.ValueChangedFcn = @(~,~) populate_sfr();
    edtFilt.ValueChangedFcn = @(~,~) populate_sfr();
    function populate_sfr()
        grp = dropGrp.Value; q = upper(strtrim(edtFilt.Value));
        if strcmp(grp, 'Essential GPIO & RTC') && isempty(q)
            sel = ["GPIO_OUT_REG","GPIO_OUT_W1TS_REG","GPIO_OUT_W1TC_REG","GPIO_ENABLE_REG","GPIO_IN_REG","RTC_CNTL_STORE0_REG","RTC_CNTL_STORE1_REG"];
            sel = sel(isfield(sfrDb.registers, sel));
        else
            sel = allRegs;
            if ~strcmp(grp, 'Essential GPIO & RTC'), sel = sel(startsWith(sel, grp)); end
            if ~isempty(q), sel = sel(contains(sel, q)); end
            if numel(sel) > 40, sel = sel(1:40); end
        end
        rows = cell(numel(sel), 5);
        for k = 1:numel(sel)
            rn = char(sel(k)); rm = sfrDb.registers.(rn);
            rows(k,:) = {rn, char(rm.address), '0x00000000', repmat('0',1,32), sprintf('%d fields', numel(fieldnames(rm.bitfields)))};
        end
        tblRegs.Data = rows;
        if ~isempty(rows), populate_bf(rows{1,1}, uint32(0)); end
    end

    tblRegs.SelectionChangedFcn = @(~,e) on_sel_reg(e);
    function on_sel_reg(e)
        if isempty(e.Selection), return; end
        r = e.Selection(1);
        populate_bf(tblRegs.Data{r,1}, uint32(hex2dec(regexprep(tblRegs.Data{r,3},'^0x',''))));
    end

    function populate_bf(rName, regVal)
        if ~isfield(sfrDb.registers, rName), tblBf.Data = {}; return; end
        bfs = fieldnames(sfrDb.registers.(rName).bitfields);
        bRows = cell(numel(bfs), 6);
        for k = 1:numel(bfs)
            bf = sfrDb.registers.(rName).bitfields.(bfs{k});
            lsb = double(bf.offset); w = double(bf.width);
            fv = bitshift(bitand(regVal, bitshift(uint32(2^w-1), lsb)), -lsb);
            bRows(k,:) = {rName, bfs{k}, sprintf('[%d:%d]', lsb+w-1, lsb), char(bf.access), double(fv), sprintf('0x%X', fv)};
        end
        tblBf.Data = bRows;
    end

    btnReadRegs.ButtonPushedFcn = @(~,~) on_read_regs();
    function on_read_regs()
        d = tblRegs.Data; if isempty(d), return; end
        echo(['esp32_cli reg ' d{1,1}]);
        for r = 1:size(d,1)
            try
                v = esp32_cli('reg', d{r,2});
                d{r,3} = sprintf('0x%08X', v); d{r,4} = dec2bin(v, 32);
            catch, break; end
        end
        tblRegs.Data = d;
        populate_bf(d{1,1}, uint32(hex2dec(regexprep(d{1,3},'^0x',''))));
    end

    tblRegs.CellEditCallback = @(~,e) on_reg_edit(e);
    function on_reg_edit(e)
        rn = tblRegs.Data{e.Indices(1),1}; echo(sprintf('esp32_cli reg %s %s', rn, e.NewData));
        esp32_cli('reg', rn, e.NewData); on_read_regs();
    end

    tblBf.CellEditCallback = @(~,e) on_bf_edit(e);
    function on_bf_edit(e)
        r = e.Indices(1); rn = tblBf.Data{r,1}; bn = tblBf.Data{r,2}; nv = uint32(e.NewData);
        echo(sprintf('esp32_cli bits %s %s %u', rn, bn, nv));
        rb = esp32_cli('bits', rn, bn, nv); populate_bf(rn, rb); on_read_regs();
    end

    btnExecReg.ButtonPushedFcn = @(~,~) on_sym_reg();
    function on_sym_reg()
        a = strtrim(edtSymAddr.Value); v = strtrim(edtSymVal.Value);
        if isempty(v), echo(['esp32_cli reg ' a]); val = esp32_cli('reg', a);
        else, echo(['esp32_cli reg ' a ' ' v]); val = esp32_cli('reg', a, v); end
        edtSymVal.Value = sprintf('0x%08X', val); populate_bf(upper(a), val);
    end

    function gpio_op(p, act, lbl)
        echo(sprintf('esp32_cli pin %d %s', p, act));
        lbl.Text = sprintf('State: %d', esp32_cli('pin', p, act));
    end

    tblAdc.SelectionChangedFcn = @(~,e) on_adc_sel(e);
    function on_adc_sel(e)
        if isempty(e.Selection), return; end
        selectedIdx = e.Selection(1); pinHist = []; sample_adc(false);
    end
    btnScanAdc.ButtonPushedFcn = @(~,~) scan_all_adc(true);
    btnSample.ButtonPushedFcn  = @(~,~) sample_adc(false);
    btnClear.ButtonPushedFcn   = @(~,~) clear_scope();
    btnStream.ButtonPushedFcn  = @(~,~) toggle_stream();

    function clear_scope()
        for k = 1:numel(adcLines), clearpoints(adcLines(k)); end
        sampleCount = 0; pinHist = [];
    end
    function toggle_stream()
        if strcmp(adcTimer.Running, 'off')
            btnStream.Text = 'Stop Live Stream'; btnStream.BackgroundColor = [0.75 0.22 0.22];
            pnlScope.Title = 'Live ADC1 Oscilloscope (FSM: STREAMING)'; start(adcTimer);
        else, stop_stream(); end
    end
    function stop_stream()
        if isvalid(adcTimer) && strcmp(adcTimer.Running,'on'), stop(adcTimer); end
        if isvalid(btnStream), btnStream.Text = 'Start Live Stream'; btnStream.BackgroundColor = [0.16 0.62 0.36]; end
        if isvalid(pnlScope), pnlScope.Title = 'Live ADC1 Oscilloscope (FSM: SCOPE_IDLE)'; end
    end
    function on_adc_tick()
        if ~isvalid(fig), stop_stream(); return; end
        try sample_adc(true); catch, stop_stream(); end
    end
    function v = conv_v(raw)
        if contains(dropCal.Value, 'Calibrated'), v = wb_calibration('adc1_raw_to_volts', raw);
        else, v = (double(raw)/4095.0)*3.30; end
    end
    function scan_all_adc(autoSel)
        d = tblAdc.Data; vals = zeros(1, numel(adcPins)); raws = zeros(1, numel(adcPins));
        sampleCount = sampleCount + 1;
        for k = 1:numel(adcPins)
            raws(k) = double(esp32_cli('adc', adcPins(k))); vals(k) = conv_v(raws(k));
            d{k,4} = sprintf('%.3f V', vals(k)); d{k,5} = raws(k);
            addpoints(adcLines(k), sampleCount, vals(k));
        end
        tblAdc.Data = d;
        if autoSel, [~, selectedIdx] = max(vals); tblAdc.Selection = selectedIdx; pinHist = vals(selectedIdx); end
        upd_dmm(selectedIdx, raws(selectedIdx), vals(selectedIdx)); drawnow limitrate;
    end
    function sample_adc(fromTimer)
        if contains(dropPlot.Value, 'All 6'), scan_all_adc(false); return; end
        idx = selectedIdx; raw = double(esp32_cli('adc', adcPins(idx))); v = conv_v(raw);
        if ~fromTimer, echo(sprintf('esp32_cli adc %d', adcPins(idx))); end
        d = tblAdc.Data; d{idx,4} = sprintf('%.3f V', v); d{idx,5} = raw; tblAdc.Data = d;
        sampleCount = sampleCount + 1; addpoints(adcLines(idx), sampleCount, v);
        upd_dmm(idx, raw, v); drawnow limitrate;
    end
    function upd_dmm(idx, raw, v)
        pinHist(end+1) = v; if numel(pinHist)>100, pinHist = pinHist(end-99:end); end
        lblDmmPin.Text = sprintf('GPIO %d (%s)', chs(idx).gpio, chs(idx).channel);
        lblDmmV.Text   = sprintf('%.3f V', v);
        lblDmmRaw.Text = sprintf('Raw: %d / 4095', raw);
        lblDmmSt.Text  = sprintf('Min %.2f | Max %.2f | Mean %.2f V', min(pinHist), max(pinHist), mean(pinHist));
    end

    btnBrowse.ButtonPushedFcn = @(~,~) on_browse();
    function on_browse()
        [f, p] = uigetfile({'*.ino;*.bin','ESP32 Files (*.ino, *.bin)'});
        if ~isequal(f,0), edtFlash.Value = fullfile(p,f); end
    end
    btnFlash.ButtonPushedFcn = @(~,~) on_flash();
    function on_flash()
        stop_stream();
        echo(sprintf('esp32_cli flash "%s" %s --role %s', edtFlash.Value, dropMode.Value, dropRole.Value));
        esp32_flash(edtFlash.Value, dropMode.Value, '--role', dropRole.Value);
        lblStatus.Text = 'Flash complete!'; lblStatus.FontColor = [0.4 0.95 0.5];
    end
    btnDump.ButtonPushedFcn = @(~,~) on_dump();
    function on_dump()
        a = strtrim(edtDumpAddr.Value); n = round(spnWords.Value);
        echo(sprintf('esp32_cli dump %s %d', a, n));
        vals = esp32_cli('dump', a, n);
        lines = strings(numel(vals), 1);
        for k = 1:numel(vals), lines(k) = sprintf('+%02d | 0x%08X | %s', (k-1)*4, vals(k), dec2bin(vals(k),32)); end
        txtDump.Value = lines;
    end
end
function r = ternary(c, a, b), if c, r = a; else, r = b; end; end