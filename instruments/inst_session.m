function out = inst_session(action, arg1, arg2)
%INST_SESSION Unified VISA instrument session factory (visadev or .NET Ivi.Visa via instruments.json).
    if nargin < 1, action = 'open'; end
    switch lower(strtrim(char(action)))
        case 'open'
            instCfg = wb_config('instruments');
            key = char(arg1);
            meta = instCfg.(key);
            addr = char(meta.visaAddress);
            if nargin >= 3 && ~isempty(arg2), addr = char(arg2); end
            out = open_visa(addr, meta.timeoutMs, instCfg.visaAssemblyPaths);
            out.Key = key;
            out.Idn = inst_session('query', out, '*IDN?');
            fprintf('  [VISA OPEN] %-18s | %s\n', upper(key), out.Idn);
        case 'write'
            if arg1.IsDotNet, arg1.IO.WriteLine(char(arg2)); else, writeline(arg1.Dev, char(arg2)); end
            out = true;
        case 'query'
            if arg1.IsDotNet
                arg1.IO.WriteLine(char(arg2));
                out = strtrim(char(arg1.IO.ReadLine()));
            else
                out = strtrim(char(writeread(arg1.Dev, char(arg2))));
            end
        case 'close'
            try
                if arg1.IsDotNet
                    if ~isempty(arg1.Session), arg1.Session.Dispose(); end
                    if ~isempty(arg1.RM), arg1.RM.Dispose(); end
                else
                    delete(arg1.Dev);
                end
            catch
            end
            out = true;
        otherwise
            error('INST:UnknownAction', 'Unknown inst_session action: %s', action);
    end
end

function h = open_visa(visaAddr, timeoutMs, assemblyGlobs)
    try
        vdev = visadev(visaAddr);
        vdev.Timeout = double(timeoutMs) / 1000.0;
        configureTerminator(vdev, 'LF');
        h = struct('IsDotNet', false, 'Dev', vdev, 'Addr', visaAddr);
        return;
    catch
    end
    NET.addAssembly('Ivi.Visa');
    rm = [];
    try
        try
            NET.addAssembly('Keysight.Visa');
        catch
            for k = 1:numel(assemblyGlobs)
                hits = dir(assemblyGlobs{k});
                if ~isempty(hits), NET.addAssembly(fullfile(hits(1).folder, hits(1).name)); break; end
            end
        end
        rm = Keysight.Visa.ResourceManager();
        sess = rm.Open(visaAddr);
    catch
        sess = Ivi.Visa.GlobalResourceManager.Open(visaAddr);
    end
    sess.TimeoutMilliseconds = int32(timeoutMs);
    sess.TerminationCharacter = uint8(10);
    sess.TerminationCharacterEnabled = true;
    sess.Clear();
    io = Ivi.Visa.FormattedIO.MessageBasedFormattedIO(sess);
    h = struct('IsDotNet', true, 'Session', sess, 'RM', rm, 'IO', io, 'Addr', visaAddr);
end