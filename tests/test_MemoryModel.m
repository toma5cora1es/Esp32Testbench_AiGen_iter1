function test_MemoryModel()
% Run from the project root:  addpath('src'); addpath('tests'); test_MemoryModel
    m = FakeMcu();
    base = hex2dec('3FFB0000');
    m.put(base,      hex2dec('DEADBEEF'));
    m.put(base + 4,  hex2dec('41424344'));          % bytes 44 43 42 41 = "DCBA" (little endian)
    mm = ude.MemoryModel(m, base + 5);              % unaligned start is rounded down to 16
    assert(mm.Start == uint32(base));

    [data, nc] = mm.tableData();                    % DWord view
    assert(nc == 4 && size(data, 1) == 16 && size(data, 2) == 6);
    assert(strcmp(data{1, 1}, '0x3FFB0000'));
    assert(strcmp(data{1, 2}, 'DEADBEEF'));
    assert(strcmp(data{1, 3}, '41424344'));
    assert(strcmp(data{1, 6}(5:8), 'DCBA'));        % ASCII column shows memory order, not value order

    mm.setWidth(1);                                 % Byte view: memory order EF BE AD DE
    data = mm.tableData();
    assert(strcmp(data{1, 2}, 'EF') && strcmp(data{1, 3}, 'BE') && strcmp(data{1, 4}, 'AD') && strcmp(data{1, 5}, 'DE'));
    mm.setWidth(2);                                 % Word view: 0xBEEF 0xDEAD
    data = mm.tableData();
    assert(strcmp(data{1, 2}, 'BEEF') && strcmp(data{1, 3}, 'DEAD'));

    % byte write = read-modify-write of the containing word
    mm.setWidth(1);
    mm.edit(1, 2, 'AA');                            % first byte (offset 0) -> 0xDEADBEAA
    assert(m.read32(base) == uint32(hex2dec('DEADBEAA')));
    mm.edit(1, 5, '00');                            % byte at offset 3 -> 0x00ADBEAA
    assert(m.read32(base) == uint32(hex2dec('00ADBEAA')));
    mm.setWidth(2);
    mm.edit(1, 3, '1234');                          % half-word at offset 2 -> 0x1234BEAA
    assert(m.read32(base) == uint32(hex2dec('1234BEAA')));

    % change detection: modify memory behind the model's back, read again
    mm.setWidth(4);
    m.put(base + 8, hex2dec('11223344'));
    mm.read();
    [chg, ~] = mm.styleCells();
    assert(isequal(chg(1, :), [1 4]));              % row 1, column 4 (= +0x8) is highlighted

    % staged (blue) edits: nothing is written until commitPending()
    mm.WriteImmediately = false;
    mm.edit(1, 2, 'CAFEBABE');
    assert(m.read32(base) == uint32(hex2dec('1234BEAA')));
    [~, pend] = mm.styleCells();
    assert(isequal(pend, [1 2]));
    d = mm.tableData();
    assert(strcmp(d{1, 2}, 'CAFEBABE'));
    mm.commitPending();
    assert(m.read32(base) == uint32(hex2dec('CAFEBABE')));

    % bit flip
    mm.toggleBit(base, 0);
    assert(m.read32(base) == uint32(hex2dec('CAFEBABF')));

    % unreadable memory is drawn, not fatal
    mm.setStart(0);
    data = mm.tableData();
    assert(strcmp(data{1, 2}, '--------'));
    try
        mm.edit(1, 2, '0');
        error('edit of unmapped memory should have failed');
    catch err
        assert(strcmp(err.identifier, 'Memory:NotMapped'));
    end
    disp('test_MemoryModel: all tests passed');
end
