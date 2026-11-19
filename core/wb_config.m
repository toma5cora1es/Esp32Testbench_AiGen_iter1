function cfg = wb_config(section, action)
%WB_CONFIG Config loader and cache for workbench, instruments, board, and UI manifests.
    persistent cache
    if nargin < 1 || isempty(section), section = 'workbench'; end
    if nargin >= 2 && strcmpi(action, 'reload'), cache = []; end
    if isempty(cache), cache = struct(); end

    key = lower(strtrim(char(section)));
    if strcmp(key, 'reload')
        cache = struct(); cfg = wb_config('workbench'); return;
    end

    fileMap = struct( ...
        'workbench',   'workbench_config.json', ...
        'instruments', 'instruments.json', ...
        'board',       'board_green_agv_rev52a.json', ...
        'ui_manifest', 'ui_manifest.json');

    if ~isfield(fileMap, key)
        error('WB:UnknownConfigSection', 'Unknown config section "%s".', key);
    end

    if ~isfield(cache, key)
        cfgPath = fullfile(wb_paths('config'), fileMap.(key));
        if ~isfile(cfgPath), error('WB:MissingConfigFile', 'Config missing: %s', cfgPath); end
        cache.(key) = jsondecode(fileread(cfgPath));
    end
    cfg = cache.(key);
end