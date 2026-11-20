function paths = init_workbench()
%INIT_WORKBENCH Register generic core, projects, experiments, instruments & testsequences.
    rootDir = fileparts(mfilename('fullpath'));
    setenv('ESP32_WB_ROOT', rootDir);
    dirs = {'core', 'instruments', 'testsequences', 'projects', 'experiments'};
    for k = 1:numel(dirs)
        p = fullfile(rootDir, dirs{k});
        if isfolder(p), addpath(genpath(p)); end
    end
    paths = wb_paths();
    wb_log('info', 'INIT', 'WORKSPACE', sprintf('Root ready: %s', paths.root));
end
