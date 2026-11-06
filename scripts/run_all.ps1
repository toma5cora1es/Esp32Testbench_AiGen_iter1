<#
 run_all.ps1 - autonomous start: arduino-cli check -> compile -> USB flash -> MATLAB workbench
 Usage: run_all.cmd [-Port COM8] [-SkipFlash] [-NoMatlab] [-Wifi]
#>
param(
    [string]$Port = "",
    [switch]$SkipFlash,
    [switch]$NoMatlab,
    [switch]$Wifi
)
$ErrorActionPreference = "Stop"
$Root    = Split-Path -Parent $PSScriptRoot
$Sketch  = Join-Path $Root "firmware\agv_matlab_bridge"
$Build   = Join-Path $Sketch "build"
$Exclude = @("COM3", "COM5", "COM6")            # ports of OTHER devices on this PC (same list as ude.Config)
$Fqbns   = @("esp32:esp32:esp32:DebugLevel=none,PartitionScheme=default", "esp32:esp32:esp32")
$IndexUrl = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"

function Step($m) { Write-Host "[run_all] $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[run_all] ERROR: $m" -ForegroundColor Red; exit 1 }
Set-Location $Root

# ---- 0. arduino-cli + ESP32 core ------------------------------------------------------------
if (-not (Get-Command arduino-cli -ErrorAction SilentlyContinue)) {
    $setup = Join-Path $Root "setup_cli.ps1"
    if (-not (Test-Path $setup)) { Fail "arduino-cli not found and setup_cli.ps1 is missing." }
    Step "arduino-cli not found -> running setup_cli.ps1"
    & $setup
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command arduino-cli -ErrorAction SilentlyContinue)) { Fail "arduino-cli still not on PATH. Open a new terminal and retry." }
}
$cores = (& arduino-cli core list) | Out-String
if ($cores -notmatch "esp32:esp32") {
    Step "Installing the esp32 core (first time only, takes a few minutes)"
    & arduino-cli core update-index --additional-urls $IndexUrl
    & arduino-cli core install esp32:esp32 --additional-urls $IndexUrl
    if ($LASTEXITCODE -ne 0) { Fail "core install failed" }
}

# ---- 1. sketch folder hygiene: arduino-cli rejects a second .ino with another name --------------
Get-ChildItem $Sketch -Filter *.ino | Where-Object { $_.Name -ne "agv_matlab_bridge.ino" } | ForEach-Object {
    Step "Deleting duplicate sketch file $($_.Name)"
    Remove-Item $_.FullName -Force
}

# ---- 2. find the board -------------------------------------------------------------------------
function Find-Port {
    try {
        $json  = (& arduino-cli board list --format json) | Out-String | ConvertFrom-Json
        $items = if ($json.detected_ports) { $json.detected_ports } else { $json }
        foreach ($it in @($items)) {
            $p = $it.port
            if ($p -and $p.protocol -eq "serial" -and ($Exclude -notcontains $p.address)) { return $p.address }
        }
    } catch { }
    $names = [System.IO.Ports.SerialPort]::GetPortNames() | Where-Object { $Exclude -notcontains $_ }
    if ($names) { return @($names)[0] }
    return ""
}
if ($Port -eq "") { $Port = Find-Port }
if ($Port -eq "" -and -not $NoMatlab -and $SkipFlash) { Step "No board found; MATLAB will start in auto/sim mode." }
elseif ($Port -eq "") { Fail "No ESP32 found. Plug the USB cable (data cable, not charge-only) and retry, or pass -Port COMx." }
else { Step "Using port $Port" }

# ---- 3. compile + flash ------------------------------------------------------------------------
if (-not $SkipFlash) {
    $flags = "-DBOOT_BLINKS=3 -DFW_BUILD=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $Used = $null
    foreach ($fq in $Fqbns) {
        Step "Compiling ($fq)"
        & arduino-cli compile --fqbn $fq --output-dir $Build --build-property "compiler.cpp.extra_flags=$flags" $Sketch
        if ($LASTEXITCODE -eq 0) { $Used = $fq; break }
    }
    if (-not $Used) { Fail "Compile failed (see messages above)." }

    $uploaded = $false
    foreach ($try in 1..2) {
        Step "Uploading to $Port (attempt $try)"
        & arduino-cli upload -p $Port --fqbn $Used --input-dir $Build $Sketch
        if ($LASTEXITCODE -eq 0) { $uploaded = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $uploaded) { Fail "Upload failed. Close serial monitors / MATLAB serialport objects; if needed hold BOOT while 'Connecting...' is shown." }
    Step "Firmware flashed. Waiting for the board to reboot..."
    Start-Sleep -Seconds 3
}

# ---- 4. optional: join the board's WiFi access point -----------------------------------------------
if ($Wifi) { & (Join-Path $PSScriptRoot "connect_wifi.ps1") }

# ---- 5. start MATLAB ------------------------------------------------------------------------------
if ($NoMatlab) { Step "Done (-NoMatlab)."; exit 0 }
$matlab = (Get-Command matlab -ErrorAction SilentlyContinue).Source
if (-not $matlab) {
    $matlab = Get-ChildItem "C:\Program Files\MATLAB" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "bin\matlab.exe" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $matlab) { Fail "matlab.exe not found. Start MATLAB yourself and run main_workbench (set UDE_PORT=$Port)." }
$env:UDE_PORT = $Port
$env:UDE_SKIP_FLASH = "1"
Step "Starting MATLAB: $matlab"
$arg = "cd('$Root'); main_workbench"
Start-Process -FilePath $matlab -ArgumentList @("-nosplash", "-r", "`"$arg`"")
