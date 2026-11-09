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
        'Position', [60 60 1240 760], 'Tag', 'ESP32_UDE_GUI', ...
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
        'Items', unique([string(defaultTarget), "192.168.4.1", "COM9", "bt:ESP32_BT_BRIDGE", "COM11", serialportlist("all")], 'stable'), ...
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

    % =========================================================================
    % --- TAB 3: REDESIGNED MULTI-CHANNEL ADC1 VOLTMETER & LIVE OSCILLOSCOPE ---
    % =========================================================================
    tabChart = uitab(tabs, 'Title', '3. Multi-Channel ADC1 Voltmeter & Live Scope');
    adcMainGrid = uigridlayout(tabChart, [2 2]);
    adcMainGrid.RowHeight = {48, '1x'};
    adcMainGrid.ColumnWidth = {470, '1x'};
    adcMainGrid.ColumnSpacing = 10;
    adcMainGrid.RowSpacing = 8;

    % --- Top Control Bar of Tab 3 ---
    adcTopCtrl = uigridlayout(adcMainGrid, [1 7]);
    adcTopCtrl.Layout.Row = 1;
    adcTopCtrl.Layout.Column = [1 2];
    adcTopCtrl.ColumnWidth = {185, 175, 130, 150, 165, 115, '1x'};
    adcTopCtrl.Padding = [2 2 2 2];

    btnScanAllAdc = uibutton(adcTopCtrl, 'Text', 'Scan All 6 Pins (Auto-Find)', ...
        'BackgroundColor', [0.15 0.48 0.82], 'FontColor', 'w', 'FontWeight', 'bold');
    btnLiveStream = uibutton(adcTopCtrl, 'Text', '▶ Start Live Stream', ...
        'BackgroundColor', [0.16 0.62 0.36], 'FontColor', 'w', 'FontWeight', 'bold');
    btnSampleOnce = uibutton(adcTopCtrl, 'Text', 'Sample Active Pin', ...
        'BackgroundColor', [0.28 0.32 0.42], 'FontColor', 'w');
    dropPlotMode = uidropdown(adcTopCtrl, ...
        'Items', {'Plot Selected Pin Only', 'Plot All 6 ADC1 Pins'}, ...
        'Value', 'Plot Selected Pin Only');
    dropCalMode = uidropdown(adcTopCtrl, ...
        'Items', {'ESP32 11dB Calibrated (V)', 'Raw Linear (raw/4095*3.3V)'}, ...
        'Value', 'ESP32 11dB Calibrated (V)');
    btnClearChart = uibutton(adcTopCtrl, 'Text', 'Clear Scope', ...
        'BackgroundColor', [0.55 0.22 0.22], 'FontColor', 'w');
    lblAdcHint = uilabel(adcTopCtrl, ...
        'Text', 'IMPORTANT: Connect Power Supply GND (-) to ESP32 GND! Only ADC1 (Left Header) works with Wi-Fi.', ...
        'FontColor', [0.95 0.65 0.20], 'FontWeight', 'bold', 'FontSize', 11);

    % --- Left Panel: Physical ESP-WROOM-32 Pinout Order & Live 6-Ch Voltmeters ---
    pnlAdcLeft = uipanel(adcMainGrid, ...
        'Title', 'ESP-WROOM-32 Left Header (Top-to-Bottom below EN) — Click Row to Select');
    pnlAdcLeft.Layout.Row = 2;
    pnlAdcLeft.Layout.Column = 1;

    leftGrid = uigridlayout(pnlAdcLeft, [3 1]);
    leftGrid.RowHeight = {95, '1x', 110};
    leftGrid.Padding = [6 6 6 6];

    % Big Digital Multimeter Readout Box
    pnlDmm = uipanel(leftGrid, 'BackgroundColor', [0.07 0.09 0.12]);
    dmmGrid = uigridlayout(pnlDmm, [2 2]);
    dmmGrid.RowHeight = {'1.3x', '1x'};
    dmmGrid.ColumnWidth = {'1.2x', '1x'};
    dmmGrid.Padding = [8 6 8 6];

    lblDmmPin = uilabel(dmmGrid, 'Text', 'SELECTED: GPIO 36 (Silkscreen: VP)', ...
        'FontColor', [0.40 0.80 1.00], 'FontName', 'Consolas', 'FontWeight', 'bold', 'FontSize', 13);
    lblDmmVoltage = uilabel(dmmGrid, 'Text', '0.000 V  (0 mV)', ...
        'FontColor', [0.30 0.95 0.50], 'FontName', 'Consolas', 'FontWeight', 'bold', 'FontSize', 22, ...
        'HorizontalAlignment', 'right');
    lblDmmRaw = uilabel(dmmGrid, 'Text', 'Raw 12-Bit: 0 / 4095', ...
        'FontColor', [0.80 0.85 0.90], 'FontName', 'Consolas', 'FontSize', 12);
    lblDmmStats = uilabel(dmmGrid, 'Text', 'Min: 0.00V | Max: 0.00V | Mean: 0.00V', ...
        'FontColor', [0.75 0.78 0.85], 'FontName', 'Consolas', 'FontSize', 11, ...
        'HorizontalAlignment', 'right');

    % Physical 6-Pin ADC1 Table (Ordered Top-to-Bottom as on ESP-WROOM-32 Left Header)
    adcPinList    = [36, 39, 34, 35, 32, 33];
    adcBoardLabel = {'Pin 2 (below EN): VP / SVP', ...
                     'Pin 3 (below EN): VN / SVN', ...
                     'Pin 4 (below EN): D34 / GPIO34', ...
                     'Pin 5 (below EN): D35 / GPIO35', ...
                     'Pin 6 (below EN): D32 / GPIO32', ...
                     'Pin 7 (below EN): D33 / GPIO33'};
    adcChannelTag = {'ADC1_CH0', 'ADC1_CH3', 'ADC1_CH6', 'ADC1_CH7', 'ADC1_CH4', 'ADC1_CH5'};

    initAdcRows = cell(6, 6);
    for k = 1:6
        initAdcRows(k, :) = {sprintf('GPIO %d', adcPinList(k)), adcBoardLabel{k}, ...
                             adcChannelTag{k}, '0.000 V', 0, '.......... [0%]'};
    end

    tblAdcChannels = uitable(leftGrid, ...
        'ColumnName', {'GPIO', 'Board Silkscreen Pos', 'Channel', 'Voltage', 'Raw (0-4095)', 'Level Meter'}, ...
        'ColumnEditable', [false false false false false false], ...
        'ColumnWidth', {62, 155, 68, 72, 82, 'auto'}, ...
        'Data', initAdcRows, 'FontName', 'Consolas', 'SelectionType', 'row');
    tblAdcChannels.Selection = 1;
    selectedAdcIdx = 1; % Default to row 1 (GPIO 36 / VP)

    % Wiring Guide & Troubleshooting Box
    pnlGuide = uipanel(leftGrid, 'Title', 'Why did my Power Supply (0.5V / 1.0V) not show up?');
    guideGrid = uigridlayout(pnlGuide, [1 1]);
    guideGrid.Padding = [4 2 4 2];
    uitextarea(guideGrid, 'Editable', 'off', 'FontName', 'Consolas', 'FontSize', 11, ...
        'Value', [ ...
        "1. COMMON GROUND: Connect Power Supply (-) GND to ESP32 [GND] pin! Without common GND, the pin floats (0.1V-0.3V noise spikes)."; ...
        "2. SILKSCREEN NAMES: On ESP-WROOM-32, GPIO 36 is printed as [VP] and GPIO 39 is printed as [VN] (top-left below EN)."; ...
        "3. DO NOT USE ADC2 WITH WI-FI: Pins GPIO 4, 2, 15, 0, 25, 26, 27, 14, 12, 13 are ADC2 and are disabled by hardware when Wi-Fi is on."; ...
        "4. QUICK FIND: Connect your 0.5V or 1.0V wire to any of the 6 pins above and click [Scan All 6 Pins (Auto-Find)]."]);

    % --- Right Panel: Real-Time Oscilloscope Chart ---
    pnlScope = uipanel(adcMainGrid, 'Title', 'Real-Time ADC1 Voltage Oscilloscope');
    pnlScope.Layout.Row = 2;
    pnlScope.Layout.Column = 2;
    scopeGrid = uigridlayout(pnlScope, [1 1]);
    scopeGrid.Padding = [4 4 4 4];

    ax = uiaxes(scopeGrid);
    title(ax, 'Live Voltage Waveform — Click "Scan All 6 Pins" or "Start Live Stream"');
    xlabel(ax, 'Sample #');
    ylabel(ax, 'Voltage (V)');
    ylim(ax, [0 3.4]);
    grid(ax, 'on');
    hold(ax, 'on');

    lineColors = [0.00 0.45 0.74; ... % GPIO 36 (Blue)
                  0.85 0.33 0.10; ... % GPIO 39 (Orange)
                  0.16 0.65 0.35; ... % GPIO 34 (Green)
                  0.75 0.25 0.75; ... % GPIO 35 (Purple)
                  0.93 0.69 0.13; ... % GPIO 32 (Gold)
                  0.30 0.75 0.93];    % GPIO 33 (Cyan)

    adcLines = gobjects(1, 6);
    for k = 1:6
        adcLines(k) = animatedline(ax, 'Color', lineColors(k, :), 'LineWidth', 2.0, ...
            'Marker', 'o', 'MarkerSize', 4, ...
            'DisplayName', sprintf('GPIO %d (%s)', adcPinList(k), adcChannelTag{k}));
    end
    legend(ax, 'Location', 'northwest');
    sampleCount = 0;
    selectedPinHistory = [];

    % Non-blocking Live Stream Timer
    adcTimer = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.25, ...
        'BusyMode', 'drop', 'TimerFcn', @(~,~) on_adc_timer_tick());

    % --- TAB 4: Memory Dump & Wi-Fi OTA Flasher (UDE Memtool) ---
    tabFlash = uitab(tabs, 'Title', '4. Memory Dump & Flash OTA (.ino / .bin)');
    flashGrid = uigridlayout(tabFlash, [2 1]);
    flashGrid.RowHeight = {130, '1x'};

    pnlOta = uipanel(flashGrid, 'Title', 'UDE® Memtool — Path-Based Flasher (Wi-Fi OTA or USB Serial)');
    otaGrid = uigridlayout(pnlOta, [2 4]);
    otaGrid.ColumnWidth = {'1x', 130, 140, 160};

    rootDir = fileparts(mfilename('fullpath'));
    defaultIno = fullfile(rootDir, 'firmware', 'esp32_bridge_ota', 'beep_fast.ino');
    if ~isfile(defaultIno)
        defaultIno = fullfile(rootDir, 'sketches', 'beep_fast', 'beep_fast.ino');
    end
    edtFlashPath = uieditfield(otaGrid, 'text', ...
        'Value', defaultIno, ...
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

    % Clean up timer if window closes or tab changes
    fig.CloseRequestFcn = @(~,~) on_close_gui();
    tabs.SelectionChangedFcn = @(~, evt) on_tab_changed(evt);

    % Initialize SFR Table
    populate_sfr_table();

    % =========================================================================
    % CALLBACKS
    % =========================================================================
    function on_close_gui()
        stop_live_adc_stream();
        try delete(adcTimer); catch, end
        delete(fig);
    end

    function on_tab_changed(evt)
        if evt.NewValue ~= tabChart
            stop_live_adc_stream();
        end
    end

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
        echo_cli('esp32_cli scan');
        lblStatus.Text = 'Scanning Serial & Bluetooth SPP devices...';
        drawnow;
        avail = esp32_cli('scan');
        targetDrop.Items = unique(["192.168.4.1", "COM9", "bt:ESP32_BT_BRIDGE", "COM11", avail], 'stable');
        lblStatus.Text = 'Scan complete. Select a target from the dropdown.';
    end

    btnConnect.ButtonPushedFcn = @(~,~) on_connect();
    function on_connect()
        stop_live_adc_stream();
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
        stop_live_adc_stream();
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

    % =========================================================================
    % --- TAB 3 CALLBACKS: MULTI-CHANNEL ADC1 VOLTMETER & LIVE OSCILLOSCOPE ---
    % =========================================================================
    tblAdcChannels.SelectionChangedFcn = @(~, evt) on_select_adc_channel(evt);
    function on_select_adc_channel(evt)
        if isempty(evt.Selection), return; end
        selectedAdcIdx = evt.Selection(1);
        selectedPinHistory = [];
        p = adcPinList(selectedAdcIdx);
        lblDmmPin.Text = sprintf('SELECTED: GPIO %d (%s)', p, adcBoardLabel{selectedAdcIdx});
        sample_selected_or_all(false);
    end

    btnScanAllAdc.ButtonPushedFcn = @(~,~) scan_all_6_adc_pins(true);
    btnSampleOnce.ButtonPushedFcn = @(~,~) sample_selected_or_all(false);
    btnLiveStream.ButtonPushedFcn = @(~,~) toggle_live_adc_stream();
    btnClearChart.ButtonPushedFcn = @(~,~) clear_adc_scope();

    function clear_adc_scope()
        for idx = 1:6
            clearpoints(adcLines(idx));
        end
        sampleCount = 0;
        selectedPinHistory = [];
        lblDmmStats.Text = 'Min: 0.00V | Max: 0.00V | Mean: 0.00V';
    end

    function toggle_live_adc_stream()
        if strcmp(adcTimer.Running, 'off')
            btnLiveStream.Text = '■ Stop Live Stream';
            btnLiveStream.BackgroundColor = [0.75 0.22 0.22];
            start(adcTimer);
        else
            stop_live_adc_stream();
        end
    end

    function stop_live_adc_stream()
        if isvalid(adcTimer) && strcmp(adcTimer.Running, 'on')
            stop(adcTimer);
        end
        if isvalid(btnLiveStream)
            btnLiveStream.Text = '▶ Start Live Stream';
            btnLiveStream.BackgroundColor = [0.16 0.62 0.36];
        end
    end

    function on_adc_timer_tick()
        if ~isvalid(fig)
            stop_live_adc_stream();
            return;
        end
        try
            sample_selected_or_all(true);
        catch
            stop_live_adc_stream();
        end
    end

    function v = raw_to_volts(rawVal)
        rawVal = double(rawVal);
        if rawVal <= 0
            v = 0.0;
            return;
        end
        if contains(dropCalMode.Value, 'Calibrated')
            % ESP32 11dB attenuation characteristic compensation (~140mV zero offset, ~3.15V saturation)
            v = 0.11 + (rawVal / 4095.0) * 3.05;
            if v > 3.30, v = 3.30; end
        else
            v = (rawVal / 4095.0) * 3.30;
        end
    end

    function barStr = make_level_bar(volts)
        pct = min(max(volts / 3.30, 0), 1);
        nFilled = round(pct * 10);
        barStr = sprintf('%s%s [%3.0f%%]', repmat('#', 1, nFilled), repmat('.', 1, 10 - nFilled), pct * 100);
    end

    function scan_all_6_adc_pins(autoSelectBest)
        echo_cli('esp32_cli adc all');
        d = tblAdcChannels.Data;
        rawVals = zeros(1, 6);
        voltVals = zeros(1, 6);

        sampleCount = sampleCount + 1;
        for idx = 1:6
            p = adcPinList(idx);
            raw = double(esp32_cli('adc', p));
            v = raw_to_volts(raw);
            rawVals(idx) = raw;
            voltVals(idx) = v;
            d{idx, 4} = sprintf('%.3f V', v);
            d{idx, 5} = raw;
            d{idx, 6} = make_level_bar(v);
            addpoints(adcLines(idx), sampleCount, v);
        end
        tblAdcChannels.Data = d;

        % Automatically highlight the pin that has a non-zero test voltage applied
        if autoSelectBest
            % Prefer pins reading in the user's bench supply range (0.20V .. 3.15V)
            inRange = find(voltVals >= 0.20 & voltVals <= 3.15);
            if ~isempty(inRange)
                [~, relIdx] = max(voltVals(inRange));
                bestIdx = inRange(relIdx);
            else
                [~, bestIdx] = max(voltVals);
            end
            selectedAdcIdx = bestIdx;
            tblAdcChannels.Selection = bestIdx;
            selectedPinHistory = voltVals(bestIdx);
        end

        update_dmm_display(adcPinList(selectedAdcIdx), adcBoardLabel{selectedAdcIdx}, ...
            rawVals(selectedAdcIdx), voltVals(selectedAdcIdx));
        drawnow limitrate;
    end

    function sample_selected_or_all(fromTimer)
        if contains(dropPlotMode.Value, 'All 6')
            scan_all_6_adc_pins(false);
            return;
        end
        idx = selectedAdcIdx;
        p = adcPinList(idx);
        if ~fromTimer
            echo_cli(sprintf('esp32_cli adc %d', p));
        end
        raw = double(esp32_cli('adc', p));
        v = raw_to_volts(raw);

        d = tblAdcChannels.Data;
        d{idx, 4} = sprintf('%.3f V', v);
        d{idx, 5} = raw;
        d{idx, 6} = make_level_bar(v);
        tblAdcChannels.Data = d;

        sampleCount = sampleCount + 1;
        addpoints(adcLines(idx), sampleCount, v);
        update_dmm_display(p, adcBoardLabel{idx}, raw, v);
        drawnow limitrate;
    end

    function update_dmm_display(pinNum, boardLbl, raw, v)
        selectedPinHistory(end+1) = v;
        if numel(selectedPinHistory) > 100
            selectedPinHistory = selectedPinHistory(end-99:end);
        end
        lblDmmPin.Text = sprintf('SELECTED: GPIO %d (%s)', pinNum, boardLbl);
        lblDmmVoltage.Text = sprintf('%.3f V  (%4.0f mV)', v, v * 1000);
        lblDmmRaw.Text = sprintf('Raw 12-Bit: %4d / 4095', raw);
        lblDmmStats.Text = sprintf('Min: %.2fV | Max: %.2fV | Mean: %.2fV', ...
            min(selectedPinHistory), max(selectedPinHistory), mean(selectedPinHistory));
        title(ax, sprintf('GPIO %d (%s) — Current: %.3f V (%4.0f mV) | Raw: %d/4095', ...
            pinNum, boardLbl, v, v * 1000, raw));
    end

    % =========================================================================
    % --- TAB 4 CALLBACKS: FLASH & MEMORY DUMP ---
    % =========================================================================
    btnBrowse.ButtonPushedFcn = @(~,~) on_browse();
    function on_browse()
        [f, p] = uigetfile({'*.ino;*.bin', 'ESP32 Files (*.ino, *.bin)'}, 'Select Sketch or Binary');
        if isequal(f, 0), return; end
        edtFlashPath.Value = fullfile(p, f);
    end

    btnDoFlash.ButtonPushedFcn = @(~,~) on_flash();
    function on_flash()
        stop_live_adc_stream();
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