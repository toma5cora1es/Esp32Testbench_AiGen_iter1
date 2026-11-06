classdef Hex
    % Hex  Strict hexadecimal parsing/formatting for text fields.
    methods (Static)
        function v = parse(text, bits)
            if nargin < 2, bits = 32; end
            t = upper(strtrim(char(text)));
            t = strrep(t, '_', '');
            if strncmp(t, '0X', 2), t = t(3:end); end
            if isempty(t) || any(~ismember(t, '0123456789ABCDEF'))
                error('Hex:Invalid', '"%s" is not a hexadecimal number.', char(text));
            end
            if numel(t) > ceil(bits / 4)
                error('Hex:Range', '"%s" does not fit in %d bits.', char(text), bits);
            end
            v = hex2dec(t);
            if v >= 2^bits
                error('Hex:Range', '"%s" does not fit in %d bits.', char(text), bits);
            end
        end
        function s = fmt(v, nbytes)
            s = sprintf(['%0' num2str(2 * nbytes) 'X'], v);
        end
    end
end
