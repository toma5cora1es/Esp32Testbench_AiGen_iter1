classdef SFR < dynamicprops & matlab.mixin.CustomDisplay
    % SFR Represents a 32-bit Hardware Register with dynamic bitfield access
    
    properties (SetAccess = private)
        Name string
        Address uint32
        BitfieldList string % List of available bitfield names
    end
    
    properties (Access = private)
        Bitfields struct
        Mcu Esp32
    end
    
    methods
        function obj = SFR(name, regDef, mcu)
            obj.Name = string(name);
            obj.Address = uint32(hex2dec(erase(string(regDef.address), "0x")));
            obj.Bitfields = regDef.bitfields;
            obj.Mcu = mcu;
            
            names = string(fieldnames(obj.Bitfields));
            obj.BitfieldList = names';
            
            % Dynamically attach each bitfield as a property (e.g., Reg.EN1 = 1)
            for i = 1:numel(names)
                bfName = names(i);
                p = obj.addprop(bfName);
                p.GetMethod = @(o) o.GetBitfield(bfName);
                p.SetMethod = @(o, val) o.SetBitfield(bfName, val);
            end
        end
        
        function val = Read(obj)
            % Read raw 32-bit unsigned integer from hardware/sim
            val = obj.Mcu.read32(obj.Address);
        end
        
        function Write(obj, value)
            % Write raw 32-bit unsigned integer to hardware/sim
            obj.Mcu.write32(obj.Address, uint32(value));
        end
        
        function val = GetBitfield(obj, bfName)
            % Read-Modify-Extract a single bitfield value
            bf = obj.Bitfields.(bfName);
            mask = uint32(bitshift(uint64(1), bf.width) - 1);
            val = uint32(bitand(bitshift(obj.Read(), -bf.offset), mask));
        end
        
        function SetBitfield(obj, bfName, value)
            % Read-Modify-Write a single bitfield value
            bf = obj.Bitfields.(bfName);
            if strcmpi(bf.access, "R")
                error("SFR:ReadOnly", "Bitfield %s.%s is Read-Only.", obj.Name, bfName);
            end
            maxVal = uint32(bitshift(uint64(1), bf.width) - 1);
            if value < 0 || value > maxVal
                error("SFR:OutOfRange", "Value %d out of range (0..%d) for %s.", value, maxVal, bfName);
            end
            
            curReg = obj.Read();
            clearMask = bitcmp(bitshift(maxVal, bf.offset), 'uint32');
            newReg = bitor(bitand(curReg, clearMask), bitshift(uint32(value), bf.offset));
            obj.Write(newReg);
        end
        
        function s = GetBitfields(obj)
            % Return a struct of all bitfields and their current values in a single read
            raw = obj.Read();
            s = struct();
            for bfName = obj.BitfieldList
                bf = obj.Bitfields.(bfName);
                mask = uint32(bitshift(uint64(1), bf.width) - 1);
                s.(bfName) = uint32(bitand(bitshift(raw, -bf.offset), mask));
            end
        end
        
        function SetBitfields(obj, varargin)
            % Batch-update multiple bitfields in a SINGLE bus transaction
            % Usage: reg.SetBitfields('GPIO2', 1, 'GPIO4', 1)
            if mod(numel(varargin), 2) ~= 0
                error("SFR:InvalidArgs", "SetBitfields requires Name-Value pairs.");
            end
            curReg = obj.Read();
            for i = 1:2:numel(varargin)
                bfName = string(varargin{i});
                val = uint32(varargin{i+1});
                if ~isfield(obj.Bitfields, bfName)
                    error("SFR:UnknownBitfield", "Bitfield %s does not exist in %s.", bfName, obj.Name);
                end
                bf = obj.Bitfields.(bfName);
                maxVal = uint32(bitshift(uint64(1), bf.width) - 1);
                if val > maxVal
                    error("SFR:OutOfRange", "Value %d exceeds max %d for %s.", val, maxVal, bfName);
                end
                clearMask = bitcmp(bitshift(maxVal, bf.offset), 'uint32');
                curReg = bitor(bitand(curReg, clearMask), bitshift(val, bf.offset));
            end
            obj.Write(curReg);
        end
        
        function Print(obj)
            % Prints register hex value followed by bitfield-by-bitfield breakdown
            raw = obj.Read();
            fprintf('\n======================================================\n');
            fprintf(' %s (0x%08X) = 0x%08X (%u)\n', obj.Name, obj.Address, raw, raw);
            fprintf('======================================================\n');
            for bfName = obj.BitfieldList
                bf = obj.Bitfields.(bfName);
                mask = uint32(bitshift(uint64(1), bf.width) - 1);
                val = bitand(bitshift(raw, -bf.offset), mask);
                msb = bf.offset + bf.width - 1;
                lsb = bf.offset;
                fprintf('  .%-22s [%2d:%2d] (%-2s) = 0x%X (%u)\n', ...
                    bfName, msb, lsb, bf.access, val, val);
            end
            fprintf('------------------------------------------------------\n');
        end
    end
    
    methods (Access = protected)
        function displayScalarObject(obj)
            % Automatically called by MATLAB when printing or leaving off semicolon
            obj.Print();
        end
    end
end