@echo off
setlocal EnableDelayedExpansion
title ESP32 Workbench - Autonomous HIL Validation Runner
echo ============================================================================
echo   ESP32 WORKBENCH - COMMAND LINE AUTONOMOUS HIL VALIDATION RUNNER
echo   Directory : C:\Users\tomas\MATLAB\esp32_workbench_gemini
echo ============================================================================

cd /d "C:\Users\tomas\MATLAB\esp32_workbench_gemini"

set MODE=%1
if "%MODE%"=="" set MODE=all

echo [CMD] Checking USB Serial & WLAN Interfaces...
powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity | Where-Object {$_.Name -match 'COM\d+'} | Select-Object Name, Status | Format-Table -AutoSize"

echo [CMD] Launching MATLAB in batch mode to execute esp32_hil('%MODE%')...
matlab -batch "cd('C:\Users\tomas\MATLAB\esp32_workbench_gemini'); addpath(genpath(pwd)); rep = esp32_hil('%MODE%'); exit(~rep.allPassed);"

set EXIT_CODE=%ERRORLEVEL%
echo.
if %EXIT_CODE% EQU 0 (
    echo [HIL RESULT] SUCCESS ^(Exit Code 0^) - All HIL hardware stages passed!
) else (
    echo [HIL RESULT] FAILURE ^(Exit Code %EXIT_CODE%^) - Check hil_report.json and console output above.
)
endlocal
exit /b %EXIT_CODE%