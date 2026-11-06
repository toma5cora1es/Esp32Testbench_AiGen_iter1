classdef Frame
    % Frame  Wire format used by the firmware:  @<payload>*<XOR-of-payload-bytes as 2 hex digits>
    %        Lines that do not match (boot-ROM text, panic dumps, log lines) are simply ignored.
    methods (Static)
        function cs = checksum(payload)
            b = uint8(char(payload));
            cs = uint8(0);
            for k = 1:numel(b)
                cs = bitxor(cs, b(k));
            end
        end
        function [ok, payload] = parse(line)
            ok = false;
            payload = '';
            s = strtrim(char(line));
            if numel(s) < 4 || s(1) ~= '@', return; end
            k = find(s == '*', 1, 'last');
            if isempty(k) || numel(s) - k ~= 2, return; end
            p = s(2:k-1);
            want = sscanf(s(k+1:end), '%x', 1);
            if isempty(want) || want ~= double(ude.Frame.checksum(p)), return; end
            ok = true;
            payload = p;
        end
    end
end
