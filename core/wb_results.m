function filePath = wb_results(suiteName, configTag, payload)
%WB_RESULTS Persist differentiated test suite outputs to results/<suite>/<timestamp>_<tag>.json.
    suiteDir = wb_paths('results_suite', suiteName);
    safeTag = regexprep(char(configTag), '[^a-zA-Z0-9_\-]', '_');
    ts = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    filePath = fullfile(suiteDir, sprintf('%s_%s.json', ts, safeTag));

    envelope = struct( ...
        'suite',     char(suiteName), ...
        'configTag', char(configTag), ...
        'timestamp', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        'payload',   payload);

    fid = fopen(filePath, 'w', 'n', 'UTF-8');
    fwrite(fid, jsonencode(envelope, 'PrettyPrint', true), 'char');
    fclose(fid);
    fprintf('  [RESULTS] Saved %s output -> %s\n', suiteName, filePath);
end