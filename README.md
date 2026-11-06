# ESP32 UDE-style workbench (MATLAB) — memory viewer, register browser, live code patching, OTA

A small debugger-like workbench for an ESP32, written in MATLAB. It copies the *ideas* of the PLS UDE
(Universal Debug Engine) windows — memory window, SFR window, memory map — and adds two things UDE does not
do over a plain USB cable: **live machine-code injection** and **wireless firmware update (OTA)**.

## Quick start (Windows)

```bat
run_all.cmd                 :: compile -> flash over USB -> start MATLAB workbench
run_all.cmd -SkipFlash      :: board already runs this firmware
run_all.cmd -Port COM8      :: force a port
run_all.cmd -Wifi           :: also join the ESP32_UDE_BRIDGE access point (needed for OTA)
```

By hand, from MATLAB: `main_workbench` (set `doFlash` logic in the file, or use `Esp32("sim")` to try the windows without a board).

## Layout

| Path | What it is |
|---|---|
| `firmware/agv_matlab_bridge/agv_matlab_bridge.ino` | Firmware v2: framed line protocol, address guard, IRAM sandbox, OTA server |
| `firmware/agv_matlab_bridge/bridge_proto.h` | Hardware-independent half of the protocol (unit-tested on the PC) |
| `src/Esp32.m` | Device link (serial / WiFi / sim) + register access. No UI, no flashing |
| `src/SFR.m`, `buildSfrDatabase.m` | Register objects and the JSON built from ESP-IDF `*_reg.h` (unchanged) |
| `src/+ude/Memory{Model,View,Window}.m` | Memory window as model / view / controller |
| `src/+ude/RegisterWindow.m` | SFR browser with decoded bitfields |
| `src/+ude/MemoryMapWindow.m` | Address map picture driven by the firmware's own guard table |
| `src/+ude/PatchWindow.m`, `xtensaAssemble.m` | Live code patching: assembler + injector + caller |
| `src/+ude/FirmwareBuilder.m` | `arduino-cli` compile + **USB** flash |
| `src/+ude/OtaUploader.m`, `OtaWindow.m` | **WiFi** flash (separate class and port from the control link) |
| `src/+ude/Workbench.m` | Launcher that opens and wires the windows together |
| `scripts/run_all.ps1`, `connect_wifi.ps1` | Autonomous start, WiFi join |
| `tests/` | Host-side tests (no board needed) |

## Two channels on purpose

* **Control** — USB serial (115200) or TCP `:3333`. Commands: `PING INFO MAP PART R RB W EXEC REBOOT`.
* **OTA** — TCP `:3334`. `OTA <size> <md5>` + raw `.bin`. Separate so that flashing never shares state with debugging.

Every reply is `@<payload>*<XOR checksum>` — boot text, log lines and panic dumps are ignored by the host.

## Safety model

The ESP32 has no memory protection: reading an unmapped address ends in a *Guru Meditation Error* and a reboot.
The firmware therefore only touches ranges from the Technical Reference Manual (chapter *System and Memory*),
answers `--------` for unmapped words, refuses to read UART FIFO registers (reading pops data), keeps IRAM
read-only except the 256-byte exec buffer, and only `EXEC`utes inside that buffer.

## Tests

```matlab
run('tests/run_all_tests.m')      % frame/checksum, assembler vs real toolchain, memory model
```
```bash
g++ -std=c++17 tests/test_bridge_proto.cpp -I firmware/agv_matlab_bridge -o test_proto && ./test_proto
```

## Troubleshooting

* *Upload fails / port busy*: close serial monitors and any MATLAB `serialport`; hold **BOOT** while "Connecting...".
* *OTA cannot connect*: the PC must be on `ESP32_UDE_BRIDGE` (password `12345678`) — `scripts\connect_wifi.ps1`.
* *Never OTA a firmware that has no OTA server in it* — you would need a USB re-flash to recover.
* *Board resets when you poke a register*: you wrote something the chip needed (UART0, clocks, RTC). That is what a debugger does.
