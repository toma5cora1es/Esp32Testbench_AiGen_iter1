classdef Theme
    % Theme  Dark, UDE-like look shared by every window.
    properties (Constant)
        Bg      = [0.10 0.11 0.13]
        Panel   = [0.15 0.16 0.19]
        PanelHi = [0.22 0.24 0.29]
        Text    = [0.86 0.89 0.93]
        Dim     = [0.55 0.60 0.67]
        Accent  = [0.35 0.65 1.00]
        Good    = [0.35 0.80 0.50]
        Warn    = [0.95 0.72 0.25]
        Bad     = [0.92 0.35 0.35]
        Changed = [0.60 0.15 0.15]   % value changed since last poll (red)
        Pending = [0.10 0.30 0.78]   % staged edit, not yet written (blue, as in the UDE manual)
        Font    = 'Consolas'
    end
    methods (Static)
        function lbl = label(parent, txt, varargin)
            lbl = uilabel(parent, 'Text', txt, 'FontColor', ude.Theme.Text, varargin{:});
        end
        function btn = button(parent, txt, varargin)
            btn = uibutton(parent, 'Text', txt, 'BackgroundColor', ude.Theme.PanelHi, ...
                'FontColor', ude.Theme.Text, varargin{:});
        end
        function g = grid(parent, sz, varargin)
            g = uigridlayout(parent, sz, 'BackgroundColor', ude.Theme.Bg, 'Padding', [8 8 8 8], varargin{:});
        end
    end
end
