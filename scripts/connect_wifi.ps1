<#
 connect_wifi.ps1 - join the ESP32 access point so MATLAB can reach it (control :3333, OTA :3334)
 The PC has NO internet while joined. To go back:  netsh wlan disconnect   (then pick your normal network)
 To forget the profile:                            netsh wlan delete profile name=ESP32_UDE_BRIDGE
#>
param(
    [string]$Ssid = "ESP32_UDE_BRIDGE",
    [string]$Pass = "12345678",
    [string]$Ip   = "192.168.4.1"
)
$xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$Ssid</name>
  <SSIDConfig><SSID><name>$Ssid</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication><encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passphrase</keyType><protected>false</protected><keyMaterial>$Pass</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>
"@
$tmp = Join-Path $env:TEMP "$Ssid.xml"
$xml | Out-File -FilePath $tmp -Encoding ascii
netsh wlan add profile filename="$tmp" | Out-Null
Write-Host "[wifi] Connecting to $Ssid ..." -ForegroundColor Cyan
netsh wlan connect name="$Ssid" | Out-Null
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Connection -ComputerName $Ip -Count 1 -Quiet) {
        Write-Host "[wifi] Board reachable at $Ip" -ForegroundColor Green
        exit 0
    }
}
Write-Host "[wifi] Joined (or trying) but $Ip does not answer yet. Is the board powered and running the v2 firmware?" -ForegroundColor Yellow
exit 1
