@echo off
rem run_all.cmd  -  ONE command: check toolchain -> compile -> flash over USB -> start the MATLAB workbench
rem   run_all.cmd                 auto-detect the board
rem   run_all.cmd -Port COM8      force a port
rem   run_all.cmd -SkipFlash      only start MATLAB (board already running the v2 firmware)
rem   run_all.cmd -NoMatlab       only compile + flash
rem   run_all.cmd -Wifi           also join the ESP32_UDE_BRIDGE access point (PC loses internet while joined)
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run_all.ps1" %*
endlocal
