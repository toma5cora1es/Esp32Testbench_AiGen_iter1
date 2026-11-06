#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include "BluetoothSerial.h"

WebServer server(80);
BluetoothSerial SerialBT;

const char* AP_SSID = "ESP32_LAB";
const char* AP_PASS = "12345678";

String execCmd(String line) {
  line.trim();
  if (line.startsWith("R ")) {
    uint32_t addr = strtoul(line.substring(2).c_str(), NULL, 16);
    uint32_t val = *(volatile uint32_t*)addr;
    char buf[16];
    snprintf(buf, sizeof(buf), "%08X", val);
    return String(buf);
  }
  if (line.startsWith("W ")) {
    int sp = line.indexOf(' ', 2);
    uint32_t addr = strtoul(line.substring(2, sp).c_str(), NULL, 16);
    uint32_t val  = strtoul(line.substring(sp + 1).c_str(), NULL, 16);
    *(volatile uint32_t*)addr = val;
    return "OK";
  }
  if (line == "IP") return WiFi.softAPIP().toString();
  if (line == "STATUS") return "UPTIME_MS:" + String(millis());
  return "ERR";
}

void setup() {
  Serial.begin(115200);
  SerialBT.begin("ESP32_BT_BRIDGE");

  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);

  server.on("/", HTTP_GET, []() {
    server.send(200, "application/json", "{\"status\":\"ESP32_READY\",\"ip\":\"" + WiFi.softAPIP().toString() + "\"}");
  });

  server.on("/reg", HTTP_GET, []() {
    if (!server.hasArg("addr")) {
      server.send(400, "application/json", "{\"error\":\"missing addr\"}");
      return;
    }
    uint32_t addr = strtoul(server.arg("addr").c_str(), NULL, 16);
    if (server.hasArg("val")) {
      uint32_t val = strtoul(server.arg("val").c_str(), NULL, 16);
      *(volatile uint32_t*)addr = val;
    }
    uint32_t cur = *(volatile uint32_t*)addr;
    char hexVal[16];
    snprintf(hexVal, sizeof(hexVal), "0x%08X", cur);
    server.send(200, "application/json", "{\"address\":\"" + server.arg("addr") + "\",\"value\":\"" + String(hexVal) + "\"}");
  });

  server.begin();
}

void loop() {
  server.handleClient();
  if (Serial.available()) {
    Serial.println(execCmd(Serial.readStringUntil('\n')));
  }
  if (SerialBT.available()) {
    SerialBT.println(execCmd(SerialBT.readStringUntil('\n')));
  }
}
