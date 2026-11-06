classdef Poller < handle
    % Poller  Re-entrancy-safe timer for live views. A tick is DROPPED when the previous one is still
    %         running, and errors never escape (they are kept in LastError) -> no flood of red text.
    properties (SetAccess = private)
        Timer
        Fcn
        InTick logical = false
        LastError string = ""
    end
    methods
        function obj = Poller(fcn, period)
            obj.Fcn = fcn;
            obj.Timer = timer('ExecutionMode', 'fixedSpacing', 'Period', period, 'BusyMode', 'drop', ...
                'Tag', 'ude.Poller', 'TimerFcn', @(~, ~) obj.tick());
        end
        function tick(obj)
            if obj.InTick, return; end
            obj.InTick = true;
            guard = onCleanup(@() obj.leave());
            try
                obj.Fcn();
                obj.LastError = "";
            catch ME
                obj.LastError = string(ME.message);
            end
        end
        function leave(obj)
            obj.InTick = false;
        end
        function start(obj)
            if isvalid(obj.Timer) && strcmp(obj.Timer.Running, 'off'), start(obj.Timer); end
        end
        function stop(obj)
            if isvalid(obj.Timer) && strcmp(obj.Timer.Running, 'on'), stop(obj.Timer); end
        end
        function delete(obj)
            try
                stop(obj.Timer);
                delete(obj.Timer);
            catch
            end
        end
    end
end
