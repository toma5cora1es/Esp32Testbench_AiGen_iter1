classdef esp32 < handle
%ESP32 OO Facade over generic esp32_cli & esp32_flash.
    methods
        function obj = esp32(t, varargin), if nargin>=1 && ~isempty(t), esp32_cli('connect', t, varargin{:}); end; end
        function out = Verbose(~, varargin), out = esp32_cli('verbose', varargin{:}); end
        function out = Fsm(~), out = esp32_cli('fsm'); end
        function out = Scan(~), out = esp32_cli('scan'); end
        function ok  = Connect(~, t, varargin), ok = esp32_cli('connect', t, varargin{:}); end
        function Disconnect(~), esp32_cli('disconnect'); end
        function [ok, bid] = Flash(~, s, varargin), [ok, bid] = esp32_flash(s, varargin{:}); end
        function out = Reg(~, r, varargin), out = esp32_cli('reg', r, varargin{:}); end
        function out = Bits(~, r, f, varargin), out = esp32_cli('bits', r, f, varargin{:}); end
        function out = Pin(~, g, varargin), out = esp32_cli('pin', g, varargin{:}); end
        function out = Adc(~, g), out = esp32_cli('adc', g); end
        function out = Status(~), out = esp32_cli('status'); end
        function Web(~), esp32_cli('web'); end
    end
end
