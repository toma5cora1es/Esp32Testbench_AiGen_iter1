% run_all_tests.m  -  host-side checks that need neither the board nor the toolchain.
%   From the project root:   run('tests/run_all_tests.m')
addpath('src'); addpath('tests');
test_frame();              % framing/checksum shared with the firmware
test_xtensaAssemble();     % machine code identical to xtensa-esp32-elf-as
test_MemoryModel();        % byte/half-word/word views, read-modify-write, change + pending marking
disp('ALL HOST TESTS PASSED  (C++ side: g++ -std=c++17 tests/test_bridge_proto.cpp -I firmware/agv_matlab_bridge)');
