function res = xtensaAssemble(src, maxBytes)
% XTENSAASSEMBLE  Tiny assembler for a SAFE subset of the Xtensa LX6 ISA (ESP32, windowed ABI).
%
%   res = ude.xtensaAssemble(sourceText)
%
% Returns a struct with:
%   bytes    1xN uint8   machine code, in memory order (little-endian)
%   words    1xM uint32  the same bytes packed for the 32-bit-only IRAM bus
%   listing  Kx3 cell    {offset, hex bytes, source text} for display
%
% Supported:  entry, movi, addi, add, sub, and, or, xor, mov, slli, srli,
%             l32i, s32i, nop, nop.n, memw, isync, retw.n, .word
% Deliberately NOT supported: branches/jumps/calls -> no infinite loops, no stray PCs.
% Rules enforced (because the C side calls the code with the *windowed* ABI):
%   - the first instruction must be  entry a1, <frame>   and the last  retw.n
%   - a0 (return address) and a1 (stack pointer) may not be overwritten
% Calling convention seen by your code: a2 = first argument, a3 = second, a2 = return value.
%
% Encodings follow the Xtensa ISA Reference Manual and were cross-checked against
% the output of xtensa-esp32-elf-as (see tests/test_xtensaAssemble.m).

    if nargin < 2, maxBytes = 256; end
    src = char(src);
    lines = regexp(src, '\r?\n', 'split');

    bytes = zeros(1, 0, 'uint8');
    listing = cell(0, 3);
    mnems = {};

    for i = 1:numel(lines)
        raw = lines{i};
        ln = strtrim(regexprep(raw, '(;|//).*$', ''));   % strip comments
        if isempty(ln), continue; end
        try
            [enc, mn] = encodeLine(ln);
        catch err
            error('xtensaAssemble:Syntax', 'Line %d "%s": %s', i, strtrim(raw), err.message);
        end
        hexStr = strjoin(arrayfun(@(b) sprintf('%02X', b), enc, 'UniformOutput', false), ' ');
        listing(end+1, :) = {sprintf('+0x%02X', numel(bytes)), hexStr, ln}; %#ok<AGROW>
        bytes = [bytes, enc]; %#ok<AGROW>
        mnems{end+1} = mn; %#ok<AGROW>
    end

    if isempty(mnems)
        error('xtensaAssemble:Empty', 'Nothing to assemble.');
    end
    if ~strcmp(mnems{1}, 'entry')
        error('xtensaAssemble:Abi', ['The first instruction must be "entry a1, 32": the C caller uses the windowed ABI ' ...
                                     '(callx8), and ENTRY rotates the register window and allocates the stack frame.']);
    end
    realIdx = find(~strcmp(mnems, '.word'));
    if ~strcmp(mnems{realIdx(end)}, 'retw.n')
        error('xtensaAssemble:Abi', 'The last instruction must be "retw.n" (windowed return). Without it the CPU runs into garbage.');
    end
    if numel(bytes) > maxBytes
        error('xtensaAssemble:Size', 'Program is %d bytes; the IRAM exec buffer holds %d.', numel(bytes), maxBytes);
    end

    padded = [bytes, zeros(1, mod(-numel(bytes), 4), 'uint8')];
    res.bytes = bytes;
    res.words = typecast(padded, 'uint32');
    res.listing = listing;
end

% =============================================================================
function [enc, mn] = encodeLine(ln)
    tk = regexp(ln, '^([\w\.]+)\s*(.*)$', 'tokens', 'once');
    if isempty(tk), error('cannot parse line'); end
    mn = lower(tk{1});
    argstr = strtrim(tk{2});
    if isempty(argstr), args = {}; else, args = strtrim(strsplit(argstr, ',')); end

    switch mn
        case 'entry'      % ENTRY as, framesize   : BRI12  imm12 = framesize/8
            need(args, 2);  s = reg(args{1});  fs = num(args{2});
            if s ~= 1, error('only "entry a1, <frame>" is supported (a1 is the stack pointer)'); end
            if mod(fs, 8) ~= 0 || fs < 0 || fs > 32760, error('frame size must be a multiple of 8 in 0..32760'); end
            enc = le(orAll([bitshift(fs / 8, 12), bitshift(s, 8), hex2dec('36')]), 3);

        case 'movi'       % MOVI at, imm12 (signed)
            need(args, 2);  t = free(reg(args{1}));  v = num(args{2});
            if v < -2048 || v > 2047, error('movi takes -2048..2047 (use slli to build bigger constants)'); end
            u = mod(v, 4096);
            enc = le(orAll([bitshift(bitand(u, 255), 16), hex2dec('A000'), bitshift(bitshift(u, -8), 8), bitshift(t, 4), 2]), 3);

        case 'addi'       % ADDI at, as, imm8 (signed)
            need(args, 3);  t = free(reg(args{1}));  s = reg(args{2});  v = num(args{3});
            if v < -128 || v > 127, error('addi takes -128..127'); end
            enc = le(orAll([bitshift(mod(v, 256), 16), hex2dec('C000'), bitshift(s, 8), bitshift(t, 4), 2]), 3);

        case {'add', 'sub', 'and', 'or', 'xor'}   % RRR: op2 selects the operation
            need(args, 3);  r = free(reg(args{1}));  s = reg(args{2});  t = reg(args{3});
            enc = le(rrr(mn, r, s, t), 3);

        case 'mov'        % pseudo-instruction: or at, as, as
            need(args, 2);  r = free(reg(args{1}));  s = reg(args{2});
            enc = le(rrr('or', r, s, s), 3);

        case 'slli'       % SLLI ar, as, 1..31   (sa = 32 - shift)
            need(args, 3);  r = free(reg(args{1}));  s = reg(args{2});  sh = num(args{3});
            if sh < 1 || sh > 31, error('slli shift must be 1..31'); end
            sa = 32 - sh;
            enc = le(orAll([bitshift(double(sa >= 16), 20), hex2dec('10000'), bitshift(r, 12), bitshift(s, 8), bitshift(mod(sa, 16), 4)]), 3);

        case 'srli'       % SRLI ar, at, 0..15
            need(args, 3);  r = free(reg(args{1}));  t = reg(args{2});  sh = num(args{3});
            if sh < 0 || sh > 15, error('srli shift must be 0..15'); end
            enc = le(orAll([hex2dec('410000'), bitshift(r, 12), bitshift(sh, 8), bitshift(t, 4)]), 3);

        case {'l32i', 's32i'}   % L32I/S32I at, as, byteoffset (multiple of 4, 0..1020)
            need(args, 3);  t = reg(args{1});  s = reg(args{2});  off = num(args{3});
            if off < 0 || off > 1020 || mod(off, 4) ~= 0, error('offset must be a multiple of 4 in 0..1020'); end
            if strcmp(mn, 'l32i'), free(t); rcode = hex2dec('2000'); else, rcode = hex2dec('6000'); end
            enc = le(orAll([bitshift(off / 4, 16), rcode, bitshift(s, 8), bitshift(t, 4), 2]), 3);

        case 'nop',    need(args, 0);  enc = le(hex2dec('0020F0'), 3);
        case 'memw',   need(args, 0);  enc = le(hex2dec('0020C0'), 3);
        case 'isync',  need(args, 0);  enc = le(hex2dec('002000'), 3);
        case 'nop.n',  need(args, 0);  enc = le(hex2dec('F03D'), 2);
        case 'retw.n', need(args, 0);  enc = le(hex2dec('F01D'), 2);

        case '.word'
            need(args, 1);  v = num(args{1});
            if v < 0 || v > 4294967295, error('.word takes a 32-bit unsigned value'); end
            enc = le(v, 4);

        otherwise
            error('unsupported mnemonic "%s"', mn);
    end
end

% ----------------------------------------------------------------------------- helpers
function w = rrr(mn, r, s, t)
    switch mn
        case 'and', op2 = 1;  case 'or', op2 = 2;  case 'xor', op2 = 3;
        case 'add', op2 = 8;  case 'sub', op2 = 12;
    end
    w = orAll([bitshift(op2, 20), bitshift(r, 12), bitshift(s, 8), bitshift(t, 4)]);
end

function w = orAll(v)
    w = 0;
    for k = 1:numel(v), w = bitor(w, v(k)); end
end

function b = le(w, nbytes)       % little-endian bytes, as the chip stores them
    b = zeros(1, nbytes, 'uint8');
    for k = 1:nbytes
        b(k) = uint8(bitand(bitshift(w, -8 * (k - 1)), 255));
    end
end

function need(args, n)
    if numel(args) ~= n, error('expected %d operand(s), got %d', n, numel(args)); end
end

function n = reg(t)
    tk = regexp(lower(strtrim(t)), '^a(\d+)$', 'tokens', 'once');
    if isempty(tk), error('"%s" is not a register (a0..a15)', t); end
    n = str2double(tk{1});
    if n > 15, error('"%s" is not a register (a0..a15)', t); end
end

function n = free(n)             % destination must not be a0 / a1
    if n == 0 || n == 1
        error('a0 (return address) and a1 (stack pointer) must not be overwritten');
    end
end

function v = num(t)
    t = lower(strtrim(t));
    if ~isempty(regexp(t, '^[+-]?0x[0-9a-f]+$', 'once'))
        neg = (t(1) == '-');
        v = hex2dec(regexprep(t, '^[+-]?0x', ''));
        if neg, v = -v; end
    elseif ~isempty(regexp(t, '^[+-]?\d+$', 'once'))
        v = str2double(t);
    else
        error('"%s" is not a number', t);
    end
end
