---
name: esp32-workbench-ops
description: Safe PowerShell repository refactoring, MATLAB R2026b scripting, and ESP32 Arduino-Core 3.x (ESP-IDF 5.5) hardware/firmware workflows for this repository.
---

# ESP32 Workbench PowerShell & Architecture Skill

Use this skill whenever modifying files via PowerShell, editing MATLAB core/plugins, or updating ESP32 firmware in `matlab_diff`.

## 1. Mandatory PowerShell 5.1 File-Editing Rules
1. **Single-Quoted Here-Strings Only**: Never embed C++, MATLAB, or JS inside double-quoted `"..."` PowerShell strings (`\"` and `\n` fail in PS). Always use `@' ... '@` single-quoted here-strings.
2. **UTF-8 Without BOM**: Always write files with `[System.IO.UTF8Encoding]::new($false)` and Unix LF (`$txt -replace "`r`n","`n"`) so `arduino-cli`, `bash`, and JSON parsers never choke on BOMs.
3. **Interactive Console Safety**: Never place `else` on a new line after `}` when generating pasteable PowerShell snippets. Put `} else {` on the same line or use guarded `if` blocks.
4. **Post-Write Verification**: After any `.Replace(...)`, assert `$content.Contains($expectedToken)` and throw immediately if the replacement did not match.

## 2. Clean Repository Boundaries (Zero Core Pollution)
- `core/`: Pure generic ESP32 transport (`esp32_io.m`), build/flash (`esp32_flash.m`), CLI router (`esp32_cli.m`), structured logger (`wb_log.m`), paths/config/calibration/results. **Never** add project-specific (`agv`, `drone`) or experimental (`twin`) logic inside `core/`.
- `config/boards/<board>.json`: Board macros (`macros` object injected by `esp32_flash` as `#define KEY VAL`).
- `projects/<name>/`: Self-contained application firmware, optional HTML UI (`--ui-file`), and `<name>_cli.m` plugin.
- `experiments/<name>/`: Experimental harnesses (e.g., `digital_twin`) and visualizations isolated from `core/`.
- `instruments/` & `testsequences/`: Bench VISA/SCPI drivers (`Keysight`, `LeCroy`, `Tektronix`) and validation suites. **Never** call instruments from `core/` or UIs.

## 3. MATLAB R2026b Hard Rules
1. **No `onCleanup` on `persistent` Variables**: Modifying a `persistent` struct inside an `onCleanup` closure causes workspace destruction errors and permanent mutex locks. Always use `try ... catch ME, s.Busy = false; rethrow(ME); end`.
2. **Core Graphics Over `uicomponents`**: Prefer native `figure` + `uipanel` + `uicontrol` + `axes` + `uitable` (`CellSelectionCallback`, `WindowKeyPressFcn`) over `uifigure`/`uilabel` to avoid `R2026b` component resolution failures.
3. **Logging**: Route all diagnostic output through `wb_log(level, modTag, stageTag, msg)` (`quiet` | `normal` | `trace`). Never print raw ANSI escapes inside MATLAB Desktop (`usejava('desktop')`).

## 4. ESP32-WROOM-32 & Core 3.3.x Firmware Rules
1. **Core 3.x APIs**: Use `ledcAttach(pin, freq, res)` + `ledcDetach(pin)` (never pass `freq <= 1 Hz` at 10-bit), `esp_now_recv_info_t*`, `#include "soc/gpio_periph.h"` for `GPIO_PIN_MUX_REG[]`, and `#include "esp_log.h"` with `esp_log_level_set("*", ESP_LOG_NONE)`.
2. **Concurrency**: Never call `noInterrupts()`/`interrupts()` in `loop()` on dual-core ESP32; use `portMUX_TYPE` (`portENTER_CRITICAL_ISR` / `portENTER_CRITICAL`), `gpio_get_level()`, and `esp_timer_get_time()`.
3. **`.ino` Preprocessor**: Avoid `template<...>` functions above `IRAM_ATTR` ISRs in `.ino` files; use explicit wrapper functions.
4. **Silicon & Radio**: `GPIO 34..39` are input-only; unused capture pins must use `INPUT_PULLDOWN` + multi-edge filtering; USB-only bench nodes must leave `Wi-Fi` uninitialized; HTTP responses must include `Connection: close`; keep `--bt` opt-in.

## 5. PowerShell Patch Template
```powershell
$root = 'C:\Users\tomas\PycharmProjects\matlab_diff'
$utf8 = [System.Text.UTF8Encoding]::new($false)
function Write-Wb($rel, $txt) {
    $p = Join-Path $root $rel
    $d = Split-Path -Parent $p
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllText($p, ($txt -replace "`r`n","`n"), $utf8)
    Write-Host "  [WROTE] $rel" -ForegroundColor Green
}