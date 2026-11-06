function db = buildSfrDatabase(outJsonPath, socRegDir)
    % Compiles ESP-IDF C register headers (*_reg.h + soc.h) into esp32_sfr.json
    arguments
        outJsonPath string = "esp32_sfr.json"
        socRegDir string = ""
    end

    if socRegDir == ""
        % Locate headers installed by arduino-cli core install esp32:esp32
        root = fullfile(getenv("LOCALAPPDATA"), "Arduino15", "packages", "esp32");
        hits = dir(fullfile(root, "**", "soc", "esp32", "register", "soc", "gpio_reg.h"));
        if isempty(hits)
            error("buildSfrDatabase:NoHeaders", "ESP32 register headers not found. Run setup_cli.ps1 first.");
        end
        socRegDir = string(hits(1).folder);
    end

    % 1. Parse DR_REG_*_BASE addresses from soc.h
    baseMap = containers.Map('KeyType', 'char', 'ValueType', 'uint32');
    socH = fullfile(socRegDir, "soc.h");
    if isfile(socH)
        txt = fileread(socH);
        tok = regexp(txt, '#define\s+(DR_REG_\w+_BASE)\s+0x([0-9a-fA-F]+)', 'tokens');
        for i = 1:numel(tok)
            baseMap(tok{i}{1}) = uint32(hex2dec(tok{i}{2}));
        end
    end
    % Fallback standard ESP32 peripheral bases if soc.h is in a parent include folder
    defaults = {"DR_REG_DPORT_BASE", '3ff00000'; "DR_REG_UART_BASE", '3ff40000'; ...
                "DR_REG_SPI1_BASE",  '3ff42000'; "DR_REG_SPI0_BASE", '3ff43000'; ...
                "DR_REG_GPIO_BASE",  '3ff44000'; "DR_REG_RTCCNTL_BASE", '3ff48000'; ...
                "DR_REG_RTCIO_BASE", '3ff48400'; "DR_REG_SENS_BASE", '3ff48800'; ...
                "DR_REG_IO_MUX_BASE",'3ff49000'; "DR_REG_I2C_EXT_BASE", '3ff53000'; ...
                "DR_REG_LEDC_BASE",  '3ff59000'; "DR_REG_PWM0_BASE", '3ff5E000'; ...
                "DR_REG_TIMERGROUP0_BASE", '3ff5F000'; "DR_REG_TIMERGROUP1_BASE", '3ff60000'};
    for i = 1:size(defaults, 1)
        if ~isKey(baseMap, defaults{i, 1})
            baseMap(defaults{i, 1}) = uint32(hex2dec(defaults{i, 2}));
        end
    end

    % 2. Parse every *_reg.h in socRegDir
    regFiles = dir(fullfile(socRegDir, "*_reg.h"));
    registers = struct();

    for f = 1:numel(regFiles)
        lines = splitlines(string(fileread(fullfile(regFiles(f).folder, regFiles(f).name))));
        curReg = "";

        for k = 1:numel(lines)
            ln = lines(k);

            % Match #define REG_NAME (DR_REG_X_BASE + 0xOFFSET) or direct 0xADDR
            mBase = regexp(ln, '^\s*#define\s+([A-Z0-9_]+_REG)\s+\(\s*(DR_REG_\w+_BASE)\s*\+\s*0x([0-9a-fA-F]+)\s*\)', 'tokens', 'once');
            mAbs  = regexp(ln, '^\s*#define\s+([A-Z0-9_]+_REG)\s+\(?0x([0-9a-fA-F]{8})\)?', 'tokens', 'once');

            if ~isempty(mBase) && isKey(baseMap, mBase{2})
                curReg = mBase{1};
                addr = baseMap(mBase{2}) + uint32(hex2dec(mBase{3}));
                registers.(curReg) = struct('address', sprintf("0x%08X", addr), 'bitfields', struct());
                continue;
            elseif ~isempty(mAbs)
                curReg = mAbs{1};
                registers.(curReg) = struct('address', "0x" + upper(mAbs{2}), 'bitfields', struct());
                continue;
            end

            % Match ESP-IDF bitfield comment: /* FIELD : R/W ;bitpos:[msb:lsb]
            if curReg ~= ""
                mBf = regexp(ln, '/\*\s*([A-Z0-9_]+)\s*:\s*([A-Z/]+)\s*;bitpos:\[(\d+):(\d+)\]', 'tokens', 'once');
                if ~isempty(mBf)
                    bfName = mBf{1};
                    accRaw = upper(mBf{2});
                    msb = str2double(mBf{3});
                    lsb = str2double(mBf{4});
                    acc = "RW";
                    if accRaw == "RO", acc = "R"; elseif accRaw == "WO", acc = "W"; end
                    registers.(curReg).bitfields.(bfName) = struct( ...
                        'offset', lsb, 'width', msb - lsb + 1, 'access', acc);
                end
            end
        end
    end

    % 3. Expand individual BIT0..BIT31 pin fields on 32-bit GPIO registers for direct pin access
    gpioRegs = ["GPIO_OUT_REG", "GPIO_OUT_W1TS_REG", "GPIO_OUT_W1TC_REG", ...
                "GPIO_ENABLE_REG", "GPIO_ENABLE_W1TS_REG", "GPIO_ENABLE_W1TC_REG", "GPIO_IN_REG"];
    for r = gpioRegs
        if isfield(registers, r)
            acc = "RW";
            if contains(r, "_IN_"), acc = "R"; elseif contains(r, "_W1T"), acc = "W"; end
            for b = 0:31
                registers.(r).bitfields.(sprintf("GPIO%d", b)) = struct('offset', b, 'width', 1, 'access', acc);
            end
        end
    end

    db = struct('derivative', "ESP32_D0WD_V3", 'registers', registers);
    fid = fopen(outJsonPath, 'w');
    fwrite(fid, jsonencode(db, 'PrettyPrint', true), 'char');
    fclose(fid);

    % Self-check assertion on compiled database
    assert(isfield(db.registers, 'GPIO_OUT_REG') && db.registers.GPIO_OUT_REG.address == "0x3FF44004", ...
        "SFR compilation check failed: GPIO_OUT_REG missing or wrong address.");
    fprintf("Compiled %d ESP32 registers from %s into %s\n", numel(fieldnames(registers)), socRegDir, outJsonPath);
end