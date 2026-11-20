Here is the complete **Session Retrospective**, the reusable **PowerShell Workbench Skill** (`.agents/skills/esp32-workbench-ops/SKILL.md`), and the **Git Commit & Push** PowerShell script ready to paste into your PyCharm terminal.

---

### 1. Session Retrospective: What We Learned & Proved

| Domain | Mistake / Failure Observed | Root Cause Proven Under the Hood | Permanent Rule Enforced |
| :--- | :--- | :--- | :--- |
| **PowerShell 5.1 Automation** | `$cpp.Replace("...\n...\"...")` threw `ParserError`; split `if (...)` / `else` skipped replacements silently | PS double-quoted strings don't escape `\n`/`\"`; interactive PS treats newline before `else` as end-of-statement | Always use single-quoted here-strings `@' ... '@`, UTF-8 no-BOM (`[UTF8Encoding]::new($false)`), inline `} else {`, and post-write `.Contains()` assertions |
| **MATLAB Runtime & R2026b** | `onCleanup(@() clear_busy())` failed -> `s.Busy` stuck `true` forever; `uilabel` failed in `R2026b` | `onCleanup` destructors cannot mutate `persistent` vars after workspace exit; `uifigure`/`uicomponents` had deferred load issues in `R2026b` | Use `try ... catch ME, s.Busy = false; rethrow(ME); end`; build MATLAB diagnostic UIs with core `figure` + `uicontrol` + `axes` + `CellSelectionCallback` |
| **MATLAB Logging** | Monochrome raw dumps hid bugs; ANSI `\x1b` prints garbage in MATLAB Desktop | Desktop Command Window uses HTML (`<strong>`) + `stderr` (`fprintf(2,...)`), while headless TTY uses ANSI escapes | Centralize in `core/wb_log.m` branching on `usejava('desktop')` with fixed-width aligned columns (`TRACE`/`INFO`/`PASS`/`WARN`/`ERR`) |
| **ESP32-IDF 5.5 (`3.3.12`)** | `GPIO_PIN_MUX_REG` undeclared; `PWM 4 0 0` spammed `E (...) ledc:`; `LoadProhibited` panic in `SIM`; `arduino-ctags` failed on `template<>`; `65f` failed compile | `soc/gpio_periph.h` required; `freq=1Hz` overflows 10-bit LEDC divider; AVR `noInterrupts()` unsafe on dual-core; `num2str(65.0)` omits `.0` | Include `soc/gpio_periph.h`; `ledcDetach` on `freq==0`; use `portMUX_TYPE` + `gpio_get_level()` + `esp_timer_get_time()`; avoid `template<>` in `.ino`; format floats `%.4ff` |
| **ESP32 Silicon & Wiring** | `D34`/`D35` couldn't drive outputs on SIM; floating inputs read phantom `3000 Hz`; `D12`/`D13` swap read `-60%` | `GPIO 34..39` are input-only in silicon (no output/pulldown); unattached inputs couple noise | Cross-wire `SIM D16/D17 -> DUT D34/D35`; use `INPUT_PULLDOWN` + `>= 3` edge + `6 ms` timeout filter; always run `twin verify` to catch 1-pin offsets |
| **Wi-Fi / HTTP / Radio** | `192.168.4.2` gave `ERR_CONNECTION_REFUSED`; `webread` timed out after 4s; heap was 34 KB | PC's own DHCP IP on SoftAP is `192.168.4.2`; `Keep-Alive` exhausted `lwIP`'s 4 TCP slots; Classic BT consumed ~125 KB SRAM + 2.4 GHz airtime | USB-only bench nodes leave `Wi-Fi` uninitialized; send `Connection: close` on every HTTP reply; make `--bt` opt-in (`159 KB` free heap!) |
| **Green AGV Rev 5.2a PCB** | Assumed active-LOW buttons & `GPIO 33` buzzer | Official schematic: `T1/T2` have `10k` pulldowns (**Active HIGH**); LEDs=`25,33,14,23`; Line=`34,32,35` digital `TLC339D`; Buzzer=`D32` (`JP3` shared with `SENS_M`) | Guard `AGV_BUZZER_EN=0` in line mode; keep all pinouts in `config/boards/green_agv_rev52a.json` |
| **System Architecture** | `wb_twin`, `agv`, `SIM`, and `instruments` leaked into `core/` and `ui/` | Feature creep coupled experimental code into core transport/flasher | Pure generic `core/` + dynamic CLI plugin dispatch (`<verb>_cli.m`) + isolated `projects/`, `experiments/`, `instruments/`, `testsequences/` |

---

### 2. Create Reusable Skill + `.gitignore` + Commit & Push (Run in PyCharm PowerShell)

Paste this in `C:\Users\tomas\PycharmProjects\matlab_diff`:

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

# 1. Create reusable PowerShell + ESP32 Workbench Engineering Skill
Write-Wb '.agents\skills\esp32-workbench-ops\SKILL.md' @'
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
```
'@

# 2. Ensure clean .gitignore for temp/results clutter while keeping structure
Write-Wb '.gitignore' @'
*.asv
*.bak
results/*/*.json
!results/*/.gitkeep
firmware/build_last/
'@

foreach ($rdir in @('results\hil_validation', 'results\power_latency_matrix', 'results\adc_dynamic_cal', 'results\interactive_drive')) {
    $gk = Join-Path $root (Join-Path $rdir '.gitkeep')
    if (-not (Test-Path $gk)) { [System.IO.File]::WriteAllText($gk, "", $utf8) }
}

# 3. Git Stage, Inspect, Commit & Push to origin master:gemini_v3
git status -s
git add -A
git commit -m "refactor(arch): decouple generic ESP32 core, add Green AGV project, Digital Twin virtual world & PowerShell skill"
git push origin master:gemini_v3
```

---

### 3. Next Verification Run in MATLAB (Test Virtual Room Digital Twin!)

Once the push finishes, run these 3 lines in MATLAB (note: flash `COM8` back to `green_agv_mainboard` first since `COM8` still had `esp32_sfr_core` from the `hil quick` check):

```matlab
clear functions; init_workbench
esp32_cli('green_agv', 'flash', 'COM8', 'standalone')
esp32_cli('twin', 'world', 'COM8', 'COM7')
```

Drive around the virtual walls, benches, and chairs with `W/A/S/D` or press `L` to watch `LINE PID` follow the oval track while updating the live Occupancy Grid Map from Board A's real hardware telemetry!