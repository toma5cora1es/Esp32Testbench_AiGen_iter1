function test_xtensaAssemble()
% Run from the project root:  addpath('src'); test_xtensaAssemble
% The expected bytes were produced by the real xtensa-esp32-elf-as (GCC 12.2.0_20230208)
% from exactly this source, so the MATLAB assembler is checked against the reference tool.
    src = strjoin({ ...
        'entry a1, 32', 'movi a2, 1337', 'movi a3, -5', 'movi a4, 2047', 'movi a5, -2048', ...
        'addi a6, a2, -8', 'addi a7, a2, 127', 'add a2, a2, a3', 'add a5, a6, a7', 'sub a2, a2, a3', ...
        'and a2, a3, a4', 'or a2, a3, a4', 'xor a2, a3, a4', 'mov a4, a5', ...
        'l32i a2, a2, 0', 'l32i a2, a3, 1020', 's32i a3, a2, 36', 's32i a3, a2, 8', ...
        'slli a2, a2, 20', 'slli a2, a3, 1', 'slli a2, a3, 31', 'srli a2, a3, 4', 'srli a2, a3, 15', ...
        'nop', 'memw', 'isync', 'nop.n', 'retw.n', '.word 0xDEADBEEF'}, newline);
    want = '36410022A53932AFFB42A7FF52A80062C2F872C27F3022807056803022C04023104023204023305045202222002223FF326209326202C02201F02311102301302441302F41F02000C020000020003DF01DF0EFBEADDE';
    res  = ude.xtensaAssemble(src, 512);
    got  = upper(reshape(dec2hex(res.bytes, 2)', 1, []));
    assert(strcmp(got, want), 'machine code differs from xtensa-esp32-elf-as output');

    % the default stub burned into the firmware: entry a1,32 / movi a2,42 / retw.n
    r = ude.xtensaAssemble(sprintf('entry a1, 32\nmovi a2, 42\nretw.n'));
    assert(isequal(r.words, uint32([hex2dec('22004136') hex2dec('F01D2AA0')])), 'default stub mismatch');

    % comments and blank lines
    r = ude.xtensaAssemble(sprintf('; header\n\nentry a1, 32   // frame\nmovi a2, 7 ; seven\nretw.n'));
    assert(numel(r.bytes) == 8);

    % guard rails
    expectError(@() ude.xtensaAssemble('movi a2, 1'),                          'xtensaAssemble:Abi');
    expectError(@() ude.xtensaAssemble(sprintf('entry a1, 32\nmovi a2, 1')),   'xtensaAssemble:Abi');
    expectError(@() ude.xtensaAssemble(sprintf('entry a1, 32\nmovi a1, 1\nretw.n')), 'xtensaAssemble:Syntax');
    expectError(@() ude.xtensaAssemble(sprintf('entry a1, 32\nmovi a2, 5000\nretw.n')), 'xtensaAssemble:Syntax');
    expectError(@() ude.xtensaAssemble(sprintf('entry a1, 32\nj 4\nretw.n')),   'xtensaAssemble:Syntax');
    big = ['entry a1, 32' newline repmat(['nop' newline], 1, 100) 'retw.n'];
    expectError(@() ude.xtensaAssemble(big, 256), 'xtensaAssemble:Size');
    disp('test_xtensaAssemble: all tests passed');
end

function expectError(fcn, id)
    try
        fcn();
    catch err
        assert(strcmp(err.identifier, id), 'expected %s but got %s', id, err.identifier);
        return;
    end
    error('expected error %s but nothing was thrown', id);
end
