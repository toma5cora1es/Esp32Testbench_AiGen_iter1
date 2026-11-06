$ErrorActionPreference = "Stop"

# 1. Ensure arduino-cli is installed and in PATH
if (-not (Get-Command arduino-cli -ErrorAction SilentlyContinue)) {
    $cliPath = "C:\Program Files\Arduino CLI"
    if (-not (Test-Path "$cliPath\arduino-cli.exe")) {
        winget install ArduinoSA.CLI --accept-package-agreements --accept-source-agreements
    }
    $env:Path += ";$cliPath"
    [Environment]::SetEnvironmentVariable("Path", $env:Path, "User")
}

# 2. Configure ESP32 core if not already installed
if (-not (Test-Path "$env:LOCALAPPDATA\Arduino15\packages\esp32")) {
    arduino-cli config init --overwrite
    arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
    arduino-cli core update-index
    arduino-cli core install esp32:esp32
}

# 3. Auto-detect USB Serial port (ignores Intel AMT COM3 and Bluetooth COM5/COM6)
$boardJson = arduino-cli board list --format json | ConvertFrom-Json
$usbPort = ($boardJson.detected_ports | Where-Object { $_.port.protocol_label -match "USB" } | Select-Object -First 1).port.address
if (-not $usbPort) {
    throw "No USB data port detected. Check that you are plugged into the ESP32 Micro-USB port with a data cable."
}
Write-Host "Detected ESP32 on $usbPort" -ForegroundColor Green

# 4. Compile and flash firmware/esp32_bridge
arduino-cli compile --fqbn esp32:esp32:esp32 firmware/esp32_bridge
arduino-cli upload -p $usbPort --fqbn esp32:esp32:esp32 firmware/esp32_bridge
Write-Host "Bridge firmware flashed on $usbPort." -ForegroundColor Green