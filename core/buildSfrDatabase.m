function db = buildSfrDatabase(outJsonPath, socRegDir)
%BUILDSFRDATABASE Compile ESP-IDF C register headers (*_reg.h + soc.h) into databases/esp32_sfr.json.
    arguments
        outJsonPath string = ""
        socRegDir string = ""
    end
    if outJsonPath == "", outJsonPath = string(wb_paths('sfrDb')); end
    cfg = wb_config('workbench');

    if socRegDir == ""
        sdkRoot = char(cfg.toolchain.sdkPackagesRoot);
        tokens = regexp(sdkRoot, '%([^%]+)%', 'tokens');
        for k = 1:numel(tokens)
            val = getenv(tokens{k}{1});
            if ~isempty(val), sdkRoot = strrep(sdkRoot, ['%' tokens{k}{1} '%'], val); end
        end
        hits = dir(fullfile(sdkRoot, '**', 'soc', 'esp32', 'register', 'soc', 'gpio_reg.h'));
        if isempty(hits), error('buildSfrDatabase:NoHeaders', 'ESP32 SDK register headers not found under %s', sdkRoot); end
        socRegDir = string(hits(1).folder);
    end

    baseMap = containers.Map('KeyType', 'char', 'ValueType', 'uint32');
    socH = fullfile(socRegDir, 'soc.h');
    if isfile(socH)
        tok = regexp(fileread(socH), '#define\s+(DR_REG_\w+_BASE)\s+0x([0-9a-fA-F]+)', 'tokens');
        for i = 1:numel(tok), baseMap(tok{i}{1}) = uint32(hex2dec(tok{i}{2})); end
    end
    defaults = {'DR_REG_DPORT_BASE','3ff00000';'DR_REG_UART_BASE','3ff40000';'DR_REG_SPI1_BASE','3ff42000'; ...
                'DR_REG_SPI0_BASE','3ff43000';'DR_REG_GPIO_BASE','3ff44000';'DR_REG_RTCCNTL_BASE','3ff48000'; ...
                'DR_REG_RTCIO_BASE','3ff48400';'DR_REG_SENS_BASE','3ff48800';'DR_REG_IO_MUX_BASE','3ff49000'; ...
                'DR_REG_I2C_EXT_BASE','3ff53000';'DR_REG_LEDC_BASE','3ff59000';'DR_REG_PWM0_BASE','3ff5E000'; ...
                'DR_REG_TIMERGROUP0_BASE','3ff5F000';'DR_REG_TIMERGROUP1_BASE','3ff60000'};
    for i = 1:size(defaults,1)
        if ~isKey(baseMap, defaults{i,1}), baseMap(defaults{i,1}) = uint32(hex2dec(defaults{i,2})); end
    end

    regFiles = dir(fullfile(socRegDir, '*_reg.h'));
    registers = struct();
    for f = 1:numel(regFiles)
        lines = splitlines(string(fileread(fullfile(regFiles(f).folder, regFiles(f).name))));
        curReg = '';
        for k = 1:numel(lines)
            ln = lines(k);
            mBase = regexp(ln, '^\s*#define\s+([A-Z0-9_]+_REG)\s+\(\s*(DR_REG_\w+_BASE)\s*\+\s*0x([0-9a-fA-F]+)\s*\)', 'tokens', 'once');
            mAbs  = regexp(ln, '^\s*#define\s+([A-Z0-9_]+_REG)\s+\(?0x([0-9a-fA-F]{8})\)?', 'tokens', 'once');
            if ~isempty(mBase) && isKey(baseMap, mBase{2})
                curReg = char(mBase{1});
                addr = baseMap(mBase{2}) + uint32(hex2dec(mBase{3}));
                registers.(curReg) = struct('address', sprintf('0x%08X', addr), 'bitfields', struct());
                continue;
            elseif ~isempty(mAbs)
                curReg = char(mAbs{1});
                registers.(curReg) = struct('address', ['0x' upper(char(mAbs{2}))], 'bitfields', struct());
                continue;
            end
            if ~isempty(curReg)
                mBf = regexp(ln, '/\*\s*([A-Z0-9_]+)\s*:\s*([A-Z/]+)\s*;bitpos:\[(\d+):(\d+)\]', 'tokens', 'once');
                if ~isempty(mBf)
                    acc = 'RW';
                    if upper(mBf{2}) == "RO", acc = 'R'; elseif upper(mBf{2}) == "WO", acc = 'W'; end
                    msb = str2double(mBf{3}); lsb = str2double(mBf{4});
                    registers.(curReg).bitfields.(char(mBf{1})) = struct('offset', lsb, 'width', msb - lsb + 1, 'access', acc);
                end
            end
        end
    end

    gpioRegs = ["GPIO_OUT_REG","GPIO_OUT_W1TS_REG","GPIO_OUT_W1TC_REG","GPIO_ENABLE_REG","GPIO_ENABLE_W1TS_REG","GPIO_ENABLE_W1TC_REG","GPIO_IN_REG"];
    for r = gpioRegs
        if isfield(registers, r)
            acc = 'RW';
            if contains(r,'_IN_'), acc='R'; elseif contains(r,'_W1T'), acc='W'; end
            for b = 0:31
                registers.(r).bitfields.(sprintf('GPIO%d',b)) = struct('offset',b,'width',1,'access',acc);
            end
        end
    end

    if ~isfolder(fileparts(outJsonPath)), mkdir(fileparts(outJsonPath)); end
    db = struct('derivative', 'ESP32_D0WD_V3', 'registers', registers);
    fid = fopen(outJsonPath, 'w', 'n', 'UTF-8');
    fwrite(fid, jsonencode(db, 'PrettyPrint', true), 'char');
    fclose(fid);
    fprintf('[SFR DB] Compiled %d registers -> %s\n', numel(fieldnames(registers)), outJsonPath);
end