function esp32_gui()
%ESP32_GUI Responsive Graphical Interface styled after PLS UDE® (CLI-Backed).
%   Opens the visual hardware testbench without blocking the MATLAB console.

    fig = findall(0, 'Type', 'figure', 'Tag', 'ESP32_UDE_GUI');
    if ~isempty(fig)
        figure(fig(1));
        return;
    end

    fig = uifigure('Name', 'UDE® ESP32 Workbench — CLI & Hardware Testbench', ...
        'Position', [100 100 1120 680], 'Tag', 'ESP32_UDE_GUI', ...
        'Color', [0.12 0.13 0.16]);

    mainGrid = uigridlayout(fig, [3 1]);
    mainGrid.RowHeight = {55, '1x', 42};
    mainGrid.ColumnWidth = {'1x'};
    mainGrid.Padding = [10 10 10 10];
    mainGrid.RowSpacing = 8;

    % =========================================================================
    % 1. TOP BAR: Connection (USB Serial / Bluetooth / Wi-Fi) + Status + Quick LED
    % =========================================================================
    topBar = uigridlayout(mainGrid, [1 7]);
    topBar.ColumnWidth = {115, 185, 95, 105, 145, '1x', 155};
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

    lblStatus = uilabel(topBar, 'Text', 'Status: Ready (Use CLI or connect above)', ...
        'FontColor', [0.75 0.85 1.0], 'FontName', 'Consolas');

    btnScan = uibutton(topBar, 'Text', 'Scan COM / BT', ...
        'BackgroundColor', [0.28 0.30 0.36], 'FontColor', 'w');

    % =========================================================================
    % 2. CENTER TAB PANEL (UDE® Debugger Style Views)
    % =========================================================================
    tabs = uitabgroup(mainGrid);

    % --- TAB 1: Peripheral Registers View (UDE style) ---
    tabRegs = uitab(tabs, 'Title', '1. Peripheral Registers (SFR)');
    regGrid = uigridlayout(tabRegs, [2 1]);
    regGrid.RowHeight = {40, '1x'};

    regCtrl = uigridlayout(regGrid, [1 5]);
    regCtrl.ColumnWidth = {145, 140, 140, 160, '1x'};
    regCtrl.Padding = [0 0 0 0];

    btnRefreshRegs = uibutton(regCtrl, 'Text', 'Read Registers (F11)', ...
        'BackgroundColor', [0.20 0.50 0.80], 'FontColor', 'w', 'FontWeight', 'bold');
    edtCustomAddr = uieditfield(regCtrl, 'text', 'Value', '0x3FF44004', 'Placeholder', 'Hex Address');
    edtCustomVal  = uieditfield(regCtrl, 'text', 'Value', '', 'Placeholder', 'Hex Value (optional)');
    btnExecReg    = uibutton(regCtrl, 'Text', 'Read / Write Reg', ...
        'BackgroundColor', [0.25 0.55 0.40], 'FontColor', 'w');
    uilabel(regCtrl, 'Text', 'Double-click the "Hex Value" column to write directly to the chip.', ...
        'FontAngle', 'italic');

    regData = {
        'GPIO_OUT_REG',         '0x3FF44004', '0x00000000', '00000000_00000000_00000000_00000000', 'GPIO 0..31 output level (RW)';
        'GPIO_OUT_W1TS_REG',    '0x3FF44008', '0x00000000', '00000000_00000000_00000000_00000000', 'Atomic Write 1 to Set HIGH (WO)';
        'GPIO_OUT_W1TC_REG',    '0x3FF4400C', '0x00000000', '00000000_00000000_00000000_00000000', 'Atomic Write 1 to Clear LOW (WO)';
        'GPIO_ENABLE_REG',      '0x3FF44020', '0x00000000', '00000000_00000000_00000000_00000000', 'Output driver enable 0..31 (RW)';
        'GPIO_ENABLE_W1TS_REG', '0x3FF44024', '0x00000000', '00000000_00000000_00000000_00000000', 'Atomic Write 1 to Enable Output (WO)';
        'GPIO_IN_REG',          '0x3FF4403C', '0x00000000', '00000000_00000000_00000000_00000000', 'Physical pin input level 0..31 (RO)';
        'IO_MUX_GPIO2_REG',     '0x3FF49040', '0x00000000', '00000000_00000000_00000000_00000000', 'Pad / Pull-up configuration GPIO 2 (RW)'
    };

    tblRegs = uitable(regGrid, 'Data', regData, ...
        'ColumnName', {'Register Name', 'Address', 'Hex Value (Editable)', 'Bits (31..0)', 'TRM Description'}, ...
        'ColumnEditable', [false false true false false], ...
        'ColumnWidth', {170, 100, 145, 290, 'auto'}, ...
        'FontName', 'Consolas');

    % --- TAB 2: GPIO Matrix & Quick Pin Control ---
    tabGpio = uitab(tabs, 'Title', '2. GPIO & ADC Control');
    gpioGrid = uigridlayout(tabGpio, [2 4]);
    gpioGrid.RowHeight = {'1x', '1x'};
    gpioGrid.ColumnWidth = {'1x', '1x', '1x', '1x'};

    commonPins = [2, 4, 5, 12, 13, 14, 18, 19];
    for idx = 1:numel(commonPins)
        p = commonPins(idx);
        pnl = uipanel(gpioGrid, 'Title', sprintf('GPIO %d %s', p, ternary(p==2, '(Built-in LED)', '')));
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
    tabChart = uitab(tabs, 'Title', '3. Time / Value Chart (ADC / Reg)');
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

    edtFlashPath = uieditfield(otaGrid, 'text', ...
        'Value', 'C:\Users\tomas\persistent_app\persistent_app.ino', ...
        'Placeholder', 'Path to .ino or .bin file');
    btnBrowse = uibutton(otaGrid, 'Text', 'Browse File...');
    dropFlashMode = uidropdown(otaGrid, 'Items', {'--wifi (OTA)', '--usb (Serial)'}, 'Value', '--wifi (OTA)');
    btnDoFlash = uibutton(otaGrid, 'Text', 'FLASH NOW', ...
        'BackgroundColor', [0.85 0.38 0.12], 'FontColor', 'w', 'FontWeight', 'bold');

    lblOtaNote = uilabel(otaGrid, 'Text', ...
        'Note: When selecting an .ino file, esp32_flash.m automatically injects the Wi-Fi OTA + Bluetooth SPP Daemon on Core 0.', ...
        'FontAngle', 'italic');
    lblOtaNote.Layout.Column = [1 4];

    pnlDump = uipanel(flashGrid, 'Title', 'Hexadecimal Memory Viewer (esp32 dump)');
    dumpGrid = uigridlayout(pnlDump, [2 1]);
    dumpGrid.RowHeight = {36, '1x'};
    dumpCtrl = uigridlayout(dumpGrid, [1 4]);
    dumpCtrl.ColumnWidth = {140, 120, 150, '1x'};
    dumpCtrl.Padding = [0 0 0 0];
    edtDumpBase = uieditfield(dumpCtrl, 'text', 'Value', '0x3FF44000');
    spnDumpWords = uispinner(dumpCtrl, 'Limits', [1 64], 'Value', 12);
    btnDump = uibutton(dumpCtrl, 'Text', 'Read Memory Block', ...
        'BackgroundColor', [0.20 0.50 0.80], 'FontColor', 'w');
    uilabel(dumpCtrl, 'Text', '4-byte aligned 32-bit addresses.');

    txtDump = uitextarea(dumpGrid, 'Editable', 'off', 'FontName', 'Consolas', 'FontSize', 12);

    % =========================================================================
    % 3. BOTTOM BAR: "CLI Command Echo" (Full Transparency for Students)
    % =========================================================================
    botBar = uigridlayout(mainGrid, [1 2]);
    botBar.ColumnWidth = {170, '1x'};
    botBar.Padding = [4 4 4 4];
    uilabel(botBar, 'Text', 'MATLAB CLI Equivalent:', 'FontColor', [0.4 0.9 0.5], 'FontWeight', 'bold');
    edtCliEcho = uieditfield(botBar, 'text', 'Editable', 'off', ...
        'Value', '>> esp32 connect 192.168.4.1', ...
        'FontName', 'Consolas', 'BackgroundColor', [0.08 0.09 0.11], 'FontColor', [0.4 0.95 0.5]);

    % =========================================================================
    % CALLBACKS (Delegate everything to esp32.m for zero duplicated logic)
    % =========================================================================
    function echo_cli(cmdStr)
        edtCliEcho.Value = ['>> ' cmdStr];
        fprintf('CLI Echo: %s\n', cmdStr);
    end

    btnScan.ButtonPushedFcn = @(~,~) on_scan();
    function on_scan()
        echo_cli('esp32 scan --bt');
        lblStatus.Text = 'Scanning Serial & Bluetooth SPP devices...';
        drawnow;
        avail = esp32_cli('scan', '--bt');
        targetDrop.Items = unique(["192.168.4.1", "bt:ESP32_BT_BRIDGE", "COM9", "COM8", "COM5", avail], 'stable');
        lblStatus.Text = 'Scan complete. Select a target from the dropdown.';
    end

    btnConnect.ButtonPushedFcn = @(~,~) on_connect();
    function on_connect()
        t = strtrim(targetDrop.Value);
        echo_cli(sprintf('esp32 connect %s', t));
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
        echo_cli('esp32 disconnect');
        esp32_cli('disconnect');
        lblStatus.Text = 'Status: DISCONNECTED';
        lblStatus.FontColor = [0.9 0.7 0.3];
    end

    btnLed2.ButtonPushedFcn = @(~,~) on_led2();
    function on_led2()
        echo_cli('esp32 pin 2 toggle');
        st = esp32_cli('pin', 2, 'toggle');
        lblStatus.Text = sprintf('GPIO 2 (LED) = %d', st);
    end

    btnRefreshRegs.ButtonPushedFcn = @(~,~) on_refresh_regs();
    function on_refresh_regs()
        echo_cli('esp32 dump 0x3FF44000 10');
        d = tblRegs.Data;
        for r = 1:size(d, 1)
            try
                val = esp32_cli('reg', d{r, 2});
                d{r, 3} = sprintf('0x%08X', val);
                raw = dec2bin(val, 32);
                d{r, 4} = sprintf('%s_%s_%s_%s_%s_%s_%s_%s', ...
                    raw(1:4), raw(5:8), raw(9:12), raw(13:16), ...
                    raw(17:20), raw(21:24), raw(25:28), raw(29:32));
            catch
            end
        end
        tblRegs.Data = d;
    end

    tblRegs.CellEditCallback = @(~, evt) on_reg_edit(evt);
    function on_reg_edit(evt)
        r = evt.Indices(1);
        addrStr = tblRegs.Data{r, 2};
        newValStr = evt.NewData;
        echo_cli(sprintf('esp32 reg %s %s', addrStr, newValStr));
        rb = esp32_cli('reg', addrStr, newValStr);
        tblRegs.Data{r, 3} = sprintf('0x%08X', rb);
        on_refresh_regs();
    end

    btnExecReg.ButtonPushedFcn = @(~,~) on_custom_reg();
    function on_custom_reg()
        aStr = strtrim(edtCustomAddr.Value);
        vStr = strtrim(edtCustomVal.Value);
        if isempty(vStr)
            echo_cli(sprintf('esp32 reg %s', aStr));
            v = esp32_cli('reg', aStr);
            edtCustomVal.Value = sprintf('0x%08X', v);
        else
            echo_cli(sprintf('esp32 reg %s %s', aStr, vStr));
            v = esp32_cli('reg', aStr, vStr);
            edtCustomVal.Value = sprintf('0x%08X', v);
            on_refresh_regs();
        end
    end

    function gpio_action(pinNum, act, lblHandle)
        echo_cli(sprintf('esp32 pin %d %s', pinNum, act));
        st = esp32_cli('pin', pinNum, act);
        lblHandle.Text = sprintf('State: %d', st);
    end

    btnSampleOnce.ButtonPushedFcn = @(~,~) sample_adc(1);
    btnBurst.ButtonPushedFcn      = @(~,~) sample_adc(20);
    btnClearChart.ButtonPushedFcn = @(~,~) clearpoints(lineObj);

    function sample_adc(nSamples)
        p = round(spnAdcPin.Value);
        echo_cli(sprintf('esp32 adc %d', p));
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
        echo_cli(sprintf('esp32 flash "%s" %s', fPath, flag));
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
        echo_cli(sprintf('esp32 dump %s %d', bAddr, nW));
        vals = esp32_cli('dump', bAddr, nW);
        base = uint32(hex2dec(regexprep(bAddr, '^0[xX]', '')));
        lines = strings(numel(vals)+2, 1);
        lines(1) = "Address     | Hexadecimal | Decimal    | Binary (31..0)";
        lines(2) = "------------+-------------+------------+------------------------------------";
        for k = 1:numel(vals)
            a = base + uint32((k-1)*4);
            v = vals(k);
            raw = dec2bin(v, 32);
            bStr = sprintf('%s_%s_%s_%s_%s_%s_%s_%s', ...
                raw(1:4), raw(5:8), raw(9:12), raw(13:16), ...
                raw(17:20), raw(21:24), raw(25:28), raw(29:32));
            lines(k+2) = sprintf('0x%08X  | 0x%08X  | %10u | %s', a, v, v, bStr);
        end
        txtDump.Value = lines;
    end
end

function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end