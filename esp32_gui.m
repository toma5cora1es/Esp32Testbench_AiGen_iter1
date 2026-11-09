function esp32_gui()
%ESP32_GUI Responsive Graphical Interface styled after PLS UDE® (Backed by esp32_cli & esp32_sfr.json).
%   Opens the visual hardware testbench without blocking the MATLAB console.

    fig = findall(0, 'Type', 'figure', 'Tag', 'ESP32_UDE_GUI');
    if ~isempty(fig)
        figure(fig(1));
        return;
    end

    % Load compiled SFR database (databases/esp32_sfr.json)
    sfrDb = esp32_cli('sfr');
    allRegNames = string(fieldnames(sfrDb.registers));

    fig = uifigure('Name', 'UDE® ESP32 Workbench — SFR Database, CLI & Hardware Testbench', ...
        'Position', [80 80 1180 720], 'Tag', 'ESP32_UDE_GUI', ...
        'Color', [0.12 0.13 0.16]);

    mainGrid = uigridlayout(fig, [3 1]);
    mainGrid.RowHeight = {55, '1x', 42};
    mainGrid.ColumnWidth = {'1x'};
    mainGrid.Padding = [10 10 10 10];
    mainGrid.RowSpacing = 8;

    % =========================================================================
    % 1. TOP BAR: Connection (USB Serial / Bluetooth / Wi-Fi) + Web UI + LED
    % =========================================================================
    topBar = uigridlayout(mainGrid, [1 8]);
    topBar.ColumnWidth = {115, 175, 90, 95, 135, 125, '1x', 135};
    topBar.Padding = [6 6 6 6];

    uilabel(topBar, 'Text', 'Target (COM/BT/IP):', 'FontColor', 'w', 'FontWeight', 'bold');
    s = esp32_io('state');
    defaultTarget = '192.168.4.1';
    if ~isempty(s.Target)
        if strcmp(s.Mode, 'bluetooth')
            defaultTarget = ['bt:' s.Target];
        else
            defaultTarget = s.Target;
        end
    end

    targetDrop = uidropdown(topBar, 'Editable', 'on', ...
        'Items', unique([string(defaultTarget), "192.168.4.1", "bt:ESP32_BT_BRIDGE", "COM9", "COM8", "COM5", serialportlist("all")], 'stable'), ...
        'Value', defaultTarget);

    btnConnect = uibutton(topBar, 'Text', 'Connect', ...
        'BackgroundColor', [0.16 0.62 0.36], 'FontColor', 'w', 'FontWeight', 'bold');
    btnDisconnect = uibutton(topBar, 'Text', 'Disconnect', ...
        'BackgroundColor', [0.65 0.22 0.22], 'FontColor', 'w');
    btnLed2 = uibutton(topBar, 'Text', 'Toggle LED (GPIO 2)', ...
        'BackgroundColor', [0.15 0.45 0.85], 'FontColor', 'w', 'FontWeight', 'bold');
    btnWebUi = uibutton(topBar, 'Text', 'Open Web Portal', ...
        'BackgroundColor', [0.55 0.28 0.72], 'FontColor', 'w', 'FontWeight', 'bold');

    lblStatus = uilabel(topBar, 'Text', sprintf('SFR DB Loaded (%d regs). Ready.', numel(allRegNames)), ...
        'FontColor', [0.75 0.85 1.0], 'FontName', 'Consolas');

    btnScan = uibutton(topBar, 'Text', 'Scan COM / BT', ...
        'BackgroundColor', [0.28 0.30 0.36], 'FontColor', 'w');

    % =========================================================================
    % 2. CENTER TAB PANEL (UDE® Debugger Style Views)
    % =========================================================================
    tabs = uitabgroup(mainGrid);

    % --- TAB 1: Peripheral Registers View (Backed by databases/esp32_sfr.json) ---
    tabRegs = uitab(tabs, 'Title', '1. Peripheral Registers & Bitfields (esp32_sfr.json)');
    regGrid = uigridlayout(tabRegs, [3 1]);
    regGrid.RowHeight = {40, '1.2x', '1x'};

    regCtrl = uigridlayout(regGrid, [1 6]);
    regCtrl.ColumnWidth = {140, 150, 170, 130, 140, '1x'};
    regCtrl.Padding = [0 0 0 0];

    dropPeriph = uidropdown(regCtrl, ...
        'Items', {'Essential GPIO & RTC', 'GPIO', 'IO_MUX', 'LEDC', 'UART', 'SPI', 'I2C', 'TIMG', 'RTC_CNTL', 'SENS', 'DPORT'}, ...
        'Value', 'Essential GPIO & RTC');
    edtSearchSfr = uieditfield(regCtrl, 'text', 'Value', '', 'Placeholder', 'Filter SFR name...');
    btnRefreshRegs = uibutton(regCtrl, 'Text', 'Read Displayed Regs (F11)', ...
        'BackgroundColor', [0.20 0.50 0.80], 'FontColor', 'w', 'FontWeight', 'bold');
    edtCustomAddr = uieditfield(regCtrl, 'text', 'Value', 'GPIO_OUT_REG', 'Placeholder', 'Symbol or 0xAddr');
    edtCustomVal  = uieditfield(regCtrl, 'text', 'Value', '', 'Placeholder', 'Hex Value (opt)');
    btnExecReg    = uibutton(regCtrl, 'Text', 'Read / Write Symbol', ...
        'BackgroundColor', [0.25 0.55 0.40], 'FontColor', 'w');

    tblRegs = uitable(regGrid, ...
        'ColumnName', {'SFR Register Name', 'Address', 'Hex Value (Editable)', 'Bits (31..0)', 'Bitfields Count'}, ...
        'ColumnEditable', [false false true false false], ...
        'ColumnWidth', {220, 105, 145, 300, 'auto'}, ...
        'FontName', 'Consolas', 'SelectionType', 'row');

    pnlBf = uipanel(regGrid, 'Title', 'Selected Register Bitfields Inspector (Double-click "Field Value" to modify bitfield on chip)');
    bfGrid = uigridlayout(pnlBf, [1 1]);
    bfGrid.Padding = [4 4 4 4];
    tblBitfields = uitable(bfGrid, ...
        'ColumnName', {'Parent Register', 'Bitfield Name', 'Bits [MSB:LSB]', 'Access', 'Field Value (Editable)', 'Hex Value'}, ...
        'ColumnEditable', [false false false false true false], ...
        'ColumnWidth', {180, 220, 120, 80, 160, 'auto'}, ...
        'FontName', 'Consolas');

    % --- TAB 2: GPIO Matrix & Quick Pin Control ---
    tabGpio = uitab(tabs, 'Title', '2. GPIO & Buzzer Control');
    gpioGrid = uigridlayout(tabGpio, [2 4]);
    gpioGrid.RowHeight = {'1x', '1x'};
    gpioGrid.ColumnWidth = {'1x', '1x', '1x', '1x'};

    commonPins = [2, 4, 5, 12, 13, 14, 18, 19];
    for idx = 1:numel(commonPins)
        p = commonPins(idx);
        pnl = uipanel(gpioGrid, 'Title', sprintf('GPIO %d %s', p, ternary(p==2, '(Built-in LED)', ternary(p==4, '(Buzzer/Out)', ''))));
        pGrid = uigridlayout(pnl, [3 2]);
        lblPin = uilabel(pGrid, 'Text', 'State: ?', 'FontWeight', 'bold', 'FontName', 'Consolas');
        lblPin.Layout.Column = [1 2];

        bHigh = uibutton(pGrid, 'Text', 'HIGH (1)', 'BackgroundColor', [0.16 0.60 0.35], 'FontColor', 'w');
        bLow  = uibutton(pGrid, 'Text', 'LOW (0)',  'BackgroundColor', [0.65 0.22 0.22], 'FontColor', 'w');
        bTog  = uibutton(pGrid, 'Text', 'TOGGLE',   'BackgroundColor', [0.20 0.45 0.80], 'FontColor', 'w');
        bRead = uibutton(pGrid, 'Text', 'READ PIN', 'BackgroundColor', [0.35 0.35 0.40], 'FontColor', 'w');

        bHigh.ButtonPushedFcn = @(~,~) gpio_action(p, 'high', lblPin);
        bLow.ButtonPushedFcn  = @(~,~) gpio_action(p, 'low',  lblPin);
        bTog.ButtonPushedFcn  = @(~,~) gpio_action(p, 'toggle', lblPin);
        bRead.ButtonPushedFcn = @(~,~) gpio_action(p, 'read', lblPin);
    end

    % --- TAB 3: Time / Value Chart ---
    tabChart = uitab(tabs, 'Title', '3. Time / Value Chart (ADC)');
    chartGrid = uigridlayout(tabChart, [2 1]);
    chartGrid.RowHeight = {40, '1x'};

    chartCtrl = uigridlayout(chartGrid, [1 5]);
    chartCtrl.ColumnWidth = {120, 100, 140, 150, '1x'};
    chartCtrl.Padding = [0 0 0 0];
    uilabel(chartCtrl, 'Text', 'ADC Pin (32-39):', 'FontWeight', 'bold');
    spnAdcPin = uispinner(chartCtrl, 'Limits', [32 39], 'Value', 34);
    btnSampleOnce = uibutton(chartCtrl, 'Text', 'Sample Once', ...
        'BackgroundColor', [0.20 0.50 0.80], 'FontColor', 'w');
    btnBurst = uibutton(chartCtrl, 'Text', 'Burst (20 samples)', ...
        'BackgroundColor', [0.16 0.60 0.35], 'FontColor', 'w', 'FontWeight', 'bold');
    btnClearChart = uibutton(chartCtrl, 'Text', 'Clear Chart');

    ax = uiaxes(chartGrid);
    title(ax, 'Real-Time ADC Signal Monitoring');
    xlabel(ax, 'Sample #');
    ylabel(ax, 'Voltage (V)');
    ylim(ax, [0 3.4]);
    grid(ax, 'on');
    lineObj = animatedline(ax, 'Color', [0.0 0.45 0.74], 'LineWidth', 2, 'Marker', 'o');
    sampleCount = 0;

    % --- TAB 4: Memory Dump & Wi-Fi OTA Flasher (UDE Memtool) ---
    tabFlash = uitab(tabs, 'Title', '4. Memory Dump & Flash OTA (.ino / .bin)');
    flashGrid = uigridlayout(tabFlash, [2 1]);
    flashGrid.RowHeight = {130, '1x'};

    pnlOta = uipanel(flashGrid, 'Title', 'UDE® Memtool — Path-Based Flasher (Wi-Fi OTA or USB Serial)');
    otaGrid = uigridlayout(pnlOta, [2 4]);
    otaGrid.ColumnWidth = {'1x', 130, 140, 160};

    rootDir = fileparts(mfilename('fullpath'));
    edtFlashPath = uieditfield(otaGrid, 'text', ...
        'Value', fullfile(rootDir, 'sketches', 'beep_fast', 'beep_fast.ino'), ...
        'Placeholder', 'Path to .ino or .bin file');
    btnBrowse = uibutton(otaGrid, 'Text', 'Browse File...');
    dropFlashMode = uidropdown(otaGrid, 'Items', {'--wifi (OTA)', '--usb (Serial)'}, 'Value', '--wifi (OTA)');
    btnDoFlash = uibutton(otaGrid, 'Text', 'FLASH NOW', ...
        'BackgroundColor', [0.85 0.38 0.12], 'FontColor', 'w', 'FontWeight', 'bold');

    lblOtaNote = uilabel(otaGrid, 'Text', ...
        'Note: esp32_flash.m automatically injects the Core-0 Web Register Workbench + Wi-Fi OTA + BT SPP Daemon into any .ino sketch.', ...
        'FontAngle', 'italic');
    lblOtaNote.Layout.Column = [1 4];

    pnlDump = uipanel(flashGrid, 'Title', 'Hexadecimal & Symbolic SFR Memory Viewer (esp32_cli dump)');
    dumpGrid = uigridlayout(pnlDump, [2 1]);
    dumpGrid.RowHeight = {36, '1x'};
    dumpCtrl = uigridlayout(dumpGrid, [1 4]);
    dumpCtrl.ColumnWidth = {160, 120, 150, '1x'};
    dumpCtrl.Padding = [0 0 0 0];
    edtDumpBase = uieditfield(dumpCtrl, 'text', 'Value', 'GPIO_OUT_REG');
    spnDumpWords = uispinner(dumpCtrl, 'Limits', [1 64], 'Value', 12);
    btnDump = uibutton(dumpCtrl, 'Text', 'Read Memory Block', ...
        'BackgroundColor', [0.20 0.50 0.80], 'FontColor', 'w');
    uilabel(dumpCtrl, 'Text', 'Accepts symbolic SFR names (e.g. GPIO_OUT_REG) or 0x Hex Addresses.');

    txtDump = uitextarea(dumpGrid, 'Editable', 'off', 'FontName', 'Consolas', 'FontSize', 12);

    % =========================================================================
    % 3. BOTTOM BAR: "CLI Command Echo" (Full Transparency for Students)
    % =========================================================================
    botBar = uigridlayout(mainGrid, [1 2]);
    botBar.ColumnWidth = {170, '1x'};
    botBar.Padding = [4 4 4 4];
    uilabel(botBar, 'Text', 'MATLAB CLI Equivalent:', 'FontColor', [0.4 0.9 0.5], 'FontWeight', 'bold');
    edtCliEcho = uieditfield(botBar, 'text', 'Editable', 'off', ...
        'Value', '>> esp32_cli connect 192.168.4.1', ...
        'FontName', 'Consolas', 'BackgroundColor', [0.08 0.09 0.11], 'FontColor', [0.4 0.95 0.5]);

    % Initialize SFR Table
    populate_sfr_table();

    % =========================================================================
    % CALLBACKS
    % =========================================================================
    function echo_cli(cmdStr)
        edtCliEcho.Value = ['>> ' cmdStr];
        fprintf('CLI Echo: %s\n', cmdStr);
    end

    dropPeriph.ValueChangedFcn = @(~,~) populate_sfr_table();
    edtSearchSfr.ValueChangedFcn = @(~,~) populate_sfr_table();

    function populate_sfr_table()
        grp = dropPeriph.Value;
        q = upper(strtrim(edtSearchSfr.Value));
        if strcmp(grp, 'Essential GPIO & RTC') && isempty(q)
            sel = ["GPIO_OUT_REG", "GPIO_OUT_W1TS_REG", "GPIO_OUT_W1TC_REG", ...
                   "GPIO_ENABLE_REG", "GPIO_ENABLE_W1TS_REG", "GPIO_IN_REG", ...
                   "IO_MUX_GPIO2_REG", "IO_MUX_GPIO4_REG", "RTC_CNTL_STORE0_REG"];
            sel = sel(isfield(sfrDb.registers, sel));
        else
            prefix = string(grp);
            if strcmp(grp, 'Essential GPIO & RTC'), prefix = ""; end
            sel = allRegNames;
            if strlength(prefix) > 0
                sel = sel(startsWith(sel, prefix));
            end
            if ~isempty(q)
                sel = sel(contains(sel, q));
            end
            if numel(sel) > 45
                sel = sel(1:45);
            end
        end

        rows = cell(numel(sel), 5);
        for k = 1:numel(sel)
            rName = char(sel(k));
            rMeta = sfrDb.registers.(rName);
            nBf = numel(fieldnames(rMeta.bitfields));
            rows(k, :) = {rName, char(rMeta.address), '0x00000000', ...
                          '00000000_00000000_00000000_00000000', sprintf('%d fields', nBf)};
        end
        tblRegs.Data = rows;
        if ~isempty(rows)
            populate_bitfields_table(rows{1, 1}, uint32(0));
        end
    end

    tblRegs.SelectionChangedFcn = @(~, evt) on_select_reg_row(evt);
    function on_select_reg_row(evt)
        if isempty(evt.Selection), return; end
        rowIdx = evt.Selection(1);
        rName = tblRegs.Data{rowIdx, 1};
        hexValStr = regexprep(tblRegs.Data{rowIdx, 3}, '^0[xX]', '');
        val = uint32(hex2dec(hexValStr));
        populate_bitfields_table(rName, val);
    end

    function populate_bitfields_table(rName, regVal)
        if ~isfield(sfrDb.registers, rName)
            tblBitfields.Data = {};
            return;
        end
        rMeta = sfrDb.registers.(rName);
        bfs = fieldnames(rMeta.bitfields);
        bRows = cell(numel(bfs), 6);
        for k = 1:numel(bfs)
            bfName = bfs{k};
            bf = rMeta.bitfields.(bfName);
            lsb = double(bf.offset);
            w   = double(bf.width);
            msb = lsb + w - 1;
            mask = bitshift(uint32(2^w - 1), lsb);
            fVal = bitshift(bitand(regVal, mask), -lsb);
            bRows(k, :) = {rName, bfName, sprintf('[%d:%d]', msb, lsb), ...
                           char(bf.access), double(fVal), sprintf('0x%X', fVal)};
        end
        tblBitfields.Data = bRows;
    end

    tblBitfields.CellEditCallback = @(~, evt) on_bitfield_edit(evt);
    function on_bitfield_edit(evt)
        r = evt.Indices(1);
        rName  = tblBitfields.Data{r, 1};
        bfName = tblBitfields.Data{r, 2};
        newVal = uint32(evt.NewData);
        echo_cli(sprintf('esp32_cli bits %s %s %u', rName, bfName, newVal));
        rb = esp32_cli('bits', rName, bfName, newVal);
        populate_bitfields_table(rName, rb);
        on_refresh_regs();
    end

    btnWebUi.ButtonPushedFcn = @(~,~) on_open_web();
    function on_open_web()
        echo_cli('esp32_cli web');
        esp32_cli('web');
    end

    btnScan.ButtonPushedFcn = @(~,~) on_scan();
    function on_scan()
        echo_cli('esp32_cli scan --bt');
        lblStatus.Text = 'Scanning Serial & Bluetooth SPP devices...';
        drawnow;
        avail = esp32_cli('scan', '--bt');
        targetDrop.Items = unique(["192.168.4.1", "bt:ESP32_BT_BRIDGE", "COM9", "COM8", "COM5", avail], 'stable');
        lblStatus.Text = 'Scan complete. Select a target from the dropdown.';
    end

    btnConnect.ButtonPushedFcn = @(~,~) on_connect();
    function on_connect()
        t = strtrim(targetDrop.Value);
        echo_cli(sprintf('esp32_cli connect %s', t));
        lblStatus.Text = sprintf('Connecting to %s...', t);
        drawnow;
        try
            esp32_cli('connect', t);
            st = esp32_cli('status');
            lblStatus.Text = ['Connected: ' st];
            lblStatus.FontColor = [0.4 0.95 0.5];
            on_refresh_regs();
        catch ME
            lblStatus.Text = ['Error: ' ME.message];
            lblStatus.FontColor = [1.0 0.4 0.4];
        end
    end

    btnDisconnect.ButtonPushedFcn = @(~,~) on_disconnect();
    function on_disconnect()
        echo_cli('esp32_cli disconnect');
        esp32_cli('disconnect');
        lblStatus.Text = 'Status: DISCONNECTED';
        lblStatus.FontColor = [0.9 0.7 0.3];
    end

    btnLed2.ButtonPushedFcn = @(~,~) on_led2();
    function on_led2()
        echo_cli('esp32_cli pin 2 toggle');
        st = esp32_cli('pin', 2, 'toggle');
        lblStatus.Text = sprintf('GPIO 2 (LED) = %d', st);
    end

    btnRefreshRegs.ButtonPushedFcn = @(~,~) on_refresh_regs();
    function on_refresh_regs()
        d = tblRegs.Data;
        if isempty(d), return; end
        echo_cli(sprintf('esp32_cli reg %s', d{1, 1}));
        for r = 1:size(d, 1)
            try
                val = esp32_cli('reg', d{r, 2});
                d{r, 3} = sprintf('0x%08X', val);
                raw = dec2bin(val, 32);
                d{r, 4} = sprintf('%s_%s_%s_%s_%s_%s_%s_%s', ...
                    raw(1:4), raw(5:8), raw(9:12), raw(13:16), ...
                    raw(17:20), raw(21:24), raw(25:28), raw(29:32));
            catch
                break;
            end
        end
        tblRegs.Data = d;
        populate_bitfields_table(d{1, 1}, uint32(hex2dec(regexprep(d{1, 3}, '^0[xX]', ''))));
    end

    tblRegs.CellEditCallback = @(~, evt) on_reg_edit(evt);
    function on_reg_edit(evt)
        r = evt.Indices(1);
        rName = tblRegs.Data{r, 1};
        newValStr = evt.NewData;
        echo_cli(sprintf('esp32_cli reg %s %s', rName, newValStr));
        rb = esp32_cli('reg', rName, newValStr);
        tblRegs.Data{r, 3} = sprintf('0x%08X', rb);
        populate_bitfields_table(rName, rb);
        on_refresh_regs();
    end

    btnExecReg.ButtonPushedFcn = @(~,~) on_custom_reg();
    function on_custom_reg()
        aStr = strtrim(edtCustomAddr.Value);
        vStr = strtrim(edtCustomVal.Value);
        if isempty(vStr)
            echo_cli(sprintf('esp32_cli reg %s', aStr));
            v = esp32_cli('reg', aStr);
            edtCustomVal.Value = sprintf('0x%08X', v);
            populate_bitfields_table(upper(aStr), v);
        else
            echo_cli(sprintf('esp32_cli reg %s %s', aStr, vStr));
            v = esp32_cli('reg', aStr, vStr);
            edtCustomVal.Value = sprintf('0x%08X', v);
            populate_bitfields_table(upper(aStr), v);
            on_refresh_regs();
        end
    end

    function gpio_action(pinNum, act, lblHandle)
        echo_cli(sprintf('esp32_cli pin %d %s', pinNum, act));
        st = esp32_cli('pin', pinNum, act);
        lblHandle.Text = sprintf('State: %d', st);
    end

    btnSampleOnce.ButtonPushedFcn = @(~,~) sample_adc(1);
    btnBurst.ButtonPushedFcn      = @(~,~) sample_adc(20);
    btnClearChart.ButtonPushedFcn = @(~,~) clearpoints(lineObj);

    function sample_adc(nSamples)
        p = round(spnAdcPin.Value);
        echo_cli(sprintf('esp32_cli adc %d', p));
        for k = 1:nSamples
            raw = esp32_cli('adc', p);
            v = (double(raw) / 4095.0) * 3.3;
            sampleCount = sampleCount + 1;
            addpoints(lineObj, sampleCount, v);
            drawnow limitrate;
        end
    end

    btnBrowse.ButtonPushedFcn = @(~,~) on_browse();
    function on_browse()
        [f, p] = uigetfile({'*.ino;*.bin', 'ESP32 Files (*.ino, *.bin)'}, 'Select Sketch or Binary');
        if isequal(f, 0), return; end
        edtFlashPath.Value = fullfile(p, f);
    end

    btnDoFlash.ButtonPushedFcn = @(~,~) on_flash();
    function on_flash()
        fPath = strtrim(edtFlashPath.Value);
        flag = '--wifi';
        if contains(dropFlashMode.Value, 'usb'), flag = '--usb'; end
        echo_cli(sprintf('esp32_cli flash "%s" %s', fPath, flag));
        lblStatus.Text = 'Compiling and flashing... check the MATLAB Command Window.';
        drawnow;
        try
            esp32_flash(fPath, flag);
            lblStatus.Text = 'Flashing completed successfully!';
            lblStatus.FontColor = [0.4 0.95 0.5];
        catch ME
            lblStatus.Text = ['Flash Error: ' ME.message];
            lblStatus.FontColor = [1.0 0.4 0.4];
        end
    end

    btnDump.ButtonPushedFcn = @(~,~) on_dump();
    function on_dump()
        bAddr = strtrim(edtDumpBase.Value);
        nW = round(spnDumpWords.Value);
        echo_cli(sprintf('esp32_cli dump %s %d', bAddr, nW));
        vals = esp32_cli('dump', bAddr, nW);
        lines = strings(numel(vals)+2, 1);
        lines(1) = "Word # | Hexadecimal | Decimal    | Binary (31..0)";
        lines(2) = "-------+-------------+------------+------------------------------------";
        for k = 1:numel(vals)
            v = vals(k);
            raw = dec2bin(v, 32);
            bStr = sprintf('%s_%s_%s_%s_%s_%s_%s_%s', ...
                raw(1:4), raw(5:8), raw(9:12), raw(13:16), ...
                raw(17:20), raw(21:24), raw(25:28), raw(29:32));
            lines(k+2) = sprintf('  +%02d  | 0x%08X  | %10u | %s', (k-1)*4, v, v, bStr);
        end
        txtDump.Value = lines;
    end
end

function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end