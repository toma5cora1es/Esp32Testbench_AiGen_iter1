classdef FakeMcu < handle
    % FakeMcu  Stand-in for Esp32 in unit tests: word memory in a Map, addresses below 0x1000 "unmapped".
    properties
        Mem
        Mode = "fake"
        Target = "fake"
    end
    methods
        function obj = FakeMcu()
            obj.Mem = containers.Map('KeyType', 'double', 'ValueType', 'double');
        end
        function put(obj, addr, w)
            obj.Mem(double(addr)) = double(w);
        end
        function v = read32(obj, addr)
            k = double(addr);
            if isKey(obj.Mem, k), v = uint32(obj.Mem(k)); else, v = uint32(0); end
        end
        function write32(obj, addr, val)
            obj.Mem(double(addr)) = double(val);
        end
        function [words, valid, mark] = readBlock32Ex(obj, startAddr, count)
            words = zeros(1, count, 'uint32');
            valid = true(1, count);
            mark = cell(1, count);
            for k = 1:count
                a = double(startAddr) + 4 * (k - 1);
                if a < 4096, valid(k) = false; mark{k} = '--------'; else, words(k) = obj.read32(a); end
            end
            mark = string(mark);
        end
    end
end
