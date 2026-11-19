function paths = init_workbench()
%INIT_WORKBENCH Register all modular workbench directories onto the MATLAB path.
    rootDir = fileparts(mfilename('fullpath'));
    setenv('ESP32_WB_ROOT', rootDir);
    subdirs = {'core', 'instruments', 'ui', 'testsequences'};
    for k = 1:numel(subdirs)
        p = fullfile(rootDir, subdirs{k});
        if isfolder(p), addpath(p); end
    end
    paths = wb_paths();
    fprintf('[WORKBENCH] Initialized root: %s\n', paths.root);
end