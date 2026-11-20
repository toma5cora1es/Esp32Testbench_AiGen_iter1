function cfg = wb_config(section, arg)
%WB_CONFIG Config loader supporting workbench, instruments, and any board in config/boards/.
    persistent cache
    if isempty(cache), cache = struct(); end
    if nargin < 1 || isempty(section), section = 'workbench'; end
    key = lower(strtrim(char(section)));
    if strcmp(key, 'reload'), cache = struct(); cfg = wb_config('workbench'); return; end

    if strcmp(key, 'board')
        bName = 'green_agv_rev52a';
        if nargin >= 2 && ~isempty(arg), bName = char(arg); end
        cKey = ['board_' matlab.lang.makeValidName(bName)];
        if ~isfield(cache, cKey)
            bp = wb_paths('board', bName);
            if ~isfile(bp), error('WB:MissingBoard', 'Board profile not found: %s', bp); end
            cache.(cKey) = jsondecode(fileread(bp));
        end
        cfg = cache.(cKey); return;
    end

    fileMap = struct('workbench', 'workbench_config.json', 'instruments', 'instruments.json');
    if ~isfield(fileMap, key), error('WB:BadCfg', 'Unknown config section: %s', key); end
    if ~isfield(cache, key)
        cp = fullfile(wb_paths('config'), fileMap.(key));
        cache.(key) = jsondecode(fileread(cp));
    end
    cfg = cache.(key);
end
