function test_frame()
% Run from the project root:  addpath('src'); test_frame
    [ok, p] = ude.Frame.parse('@PONG*16');                      assert(ok && strcmp(p, 'PONG'));
    [ok, p] = ude.Frame.parse(sprintf('@PONG*16\r\n'));         assert(ok && strcmp(p, 'PONG'));
    [ok, ~] = ude.Frame.parse('@PONG*17');                      assert(~ok);            % bad checksum
    [ok, ~] = ude.Frame.parse('ets Jun  8 2016 00:22:57');      assert(~ok);            % boot ROM text
    [ok, ~] = ude.Frame.parse('Guru Meditation Error: Core 1 panic''ed (LoadProhibited)'); assert(~ok);
    [ok, ~] = ude.Frame.parse('@PONG');                         assert(~ok);            % no checksum
    [ok, ~] = ude.Frame.parse('');                              assert(~ok);
    % round trip with the same algorithm the firmware uses
    pl = 'DEADBEEF CAFEBABE 12345678';
    line = sprintf('@%s*%02X', pl, ude.Frame.checksum(pl));
    [ok, p] = ude.Frame.parse(line);                            assert(ok && strcmp(p, pl));

    assert(ude.Hex.parse('0x3FF44004') == hex2dec('3FF44004'));
    assert(ude.Hex.parse('deadbeef') == hex2dec('DEADBEEF'));
    assert(ude.Hex.parse('FF', 8) == 255);
    for bad = {'', '0x', 'xyz', '1FF', '123456789'}
        try
            ude.Hex.parse(bad{1}, 8); error('should have failed: %s', bad{1});
        catch err
            assert(strncmp(err.identifier, 'Hex:', 4), 'unexpected error for "%s": %s', bad{1}, err.message);
        end
    end
    disp('test_frame: all tests passed');
end
