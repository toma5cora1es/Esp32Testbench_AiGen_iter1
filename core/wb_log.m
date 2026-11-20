function out = wb_log(level, modTag, stageTag, msg)
%WB_LOG Structured, spaced, color-aware workbench logger.
%   Levels: 'quiet' (errors/results only), 'normal' (user ops), 'trace' (FSM/wire tx/rx).
    persistent state
    if isempty(state)
        state = struct('Level', 'normal', 'History', strings(0,1));
    end

    lvl = lower(strtrim(char(level)));
    if strcmp(lvl, 'set_level')
        val = lower(strtrim(char(modTag)));
        if ismember(val, {'quiet', 'normal', 'trace'}), state.Level = val; end
        out = state.Level; return;
    elseif strcmp(lvl, 'get_level')
        out = state.Level; return;
    elseif strcmp(lvl, 'history')
        fprintf('\n================ WORKBENCH LOG RING BUFFER (%d entries) ================\n', numel(state.History));
        for k = 1:numel(state.History), fprintf('  %s\n', state.History(k)); end
        fprintf('======================================================================\n\n');
        out = state.History; return;
    end

    ts = char(datetime('now', 'Format', 'HH:mm:ss.SSS'));
    uLvl = upper(lvl);
    line = sprintf('[%s] [%-5s] [%-12s] [%-18s] %s', ts, uLvl, upper(char(modTag)), char(stageTag), char(msg));
    state.History(end+1) = string(line);
    if numel(state.History) > 200, state.History = state.History(end-199:end); end

    rank = map_rank(uLvl);
    minRank = map_rank(upper(state.Level));
    if rank < minRank, out = false; return; end

    isDesktop = usejava('desktop');
    if isDesktop
        switch uLvl
            case {'ERR', 'FAIL', 'OPEN'}
                fprintf(2, '  %s\n', line);
            case {'PASS', 'HDR', 'FSM'}
                fprintf(1, '  <strong>%s</strong>\n', line);
            otherwise
                fprintf(1, '  %s\n', line);
        end
    else
        cMap = struct('TRACE','36','INFO','37','TX','33','RX','32','FSM','35','PASS','92','WARN','93','ERR','91','FAIL','91','OPEN','91','HDR','96');
        col = '37'; if isfield(cMap, uLvl), col = cMap.(uLvl); end
        fprintf(1, '  \x1b[%sm%s\x1b[0m\n', col, line);
    end
    out = true;
end

function r = map_rank(u)
    switch u
        case {'TRACE', 'TX', 'RX', 'FSM'}, r = 1;
        case {'NORMAL', 'INFO', 'PASS', 'HDR'}, r = 2;
        otherwise, r = 3; % WARN, ERR, FAIL, OPEN, QUIET
    end
end
