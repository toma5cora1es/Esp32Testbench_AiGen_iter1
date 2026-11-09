// File: C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\esp32_bridge_ota.ino
// Description: Standalone Base Firmware with On-Chip Web Register Workbench (http://192.168.4.1/),
//              REST/CLI Backend (/cmd, /reg), Wi-Fi OTA (/ota), USB Serial, and Bluetooth SPP.

#include <Arduino.h>

void setup() {
  // Default state: GPIO 2 (LED) and GPIO 4 (Buzzer) configured as outputs
  pinMode(2, OUTPUT);
  pinMode(4, OUTPUT);
}

void loop() {
  // Core 1 idle loop (Core 0 runs the Web Portal + OTA + Serial + Bluetooth Daemon injected by esp32_flash.m)
  delay(20);
}