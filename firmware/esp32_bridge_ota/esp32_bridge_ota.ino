// ============================================================================
// File: firmware/esp32_bridge_ota/esp32_bridge_ota.ino
// Unified Base Firmware: Register Bridge + Atomic GPIO + Wi-Fi OTA + Bluetooth SPP (Core 0)
// Board: ESP32-D0WD-V3 (CH340) - Required Partition: min_spiffs (Dual OTA 1.9MB)
// ============================================================================
#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Update.h>
#include "soc/gpio_reg.h"
#include "soc/io_mux_reg.h"

// Bluetooth Classic (SPP) is enabled by default so you can connect via:
//   esp32 connect ESP32_BT_BRIDGE   (or via Bluetooth Virtual COM port)
// Note: Compile with Partition Scheme "Minimal SPIFFS (1.9MB APP with OTA)" (min_spiffs)
#define ENABLE_BT_CLASSIC

#ifdef ENABLE_BT_CLASSIC
  #include "BluetoothSerial.h"
  BluetoothSerial SerialBT;
#endif

const char* AP_SSID = "ESP32_LAB";
const char* AP_PASS = "12345678";
const char* BT_NAME = "ESP32_BT_BRIDGE";

WebServer server(80);
TaskHandle_t bridgeTaskHandle = NULL;

// --- Low-Level Command Executor (USB Serial / Bluetooth SPP / HTTP) ---
String execBridgeCmd(String line) {
  line.trim();
  if (line.length() == 0) return "";

  // 1. Read 32-bit Register: "R 3FF44004"
  if (line.startsWith("R ") || line.startsWith("r ")) {
    uint32_t addr = strtoul(line.substring(2).c_str(), NULL, 16);
    uint32_t val = *(volatile uint32_t*)addr;
    char buf[16];
    snprintf(buf, sizeof(buf), "0x%08X", val);
    return String(buf);
  }

  // 2. Write 32-bit Register: "W 3FF44004 00000004"
  if (line.startsWith("W ") || line.startsWith("w ")) {
    int sp = line.indexOf(' ', 2);
    if (sp < 0) return "ERR:SYNTAX";
    uint32_t addr = strtoul(line.substring(2, sp).c_str(), NULL, 16);
    uint32_t val  = strtoul(line.substring(sp + 1).c_str(), NULL, 16);
    *(volatile uint32_t*)addr = val;
    uint32_t rb = *(volatile uint32_t*)addr;
    char buf[16];
    snprintf(buf, sizeof(buf), "0x%08X", rb);
    return String(buf);
  }

  // 3. Memory Block Dump: "D 3FF44000 8" (hex address and word count)
  if (line.startsWith("D ") || line.startsWith("d ")) {
    int sp = line.indexOf(' ', 2);
    uint32_t addr = strtoul(line.substring(2, sp > 0 ? sp : line.length()).c_str(), NULL, 16);
    int count = (sp > 0) ? line.substring(sp + 1).toInt() : 4;
    if (count < 1) count = 1;
    if (count > 64) count = 64;
    String out = "";
    char buf[16];
    for (int i = 0; i < count; i++) {
      uint32_t v = *(volatile uint32_t*)(addr + i * 4);
      snprintf(buf, sizeof(buf), "%08X", v);
      if (i > 0) out += " ";
      out += buf;
    }
    return out;
  }

  // 4. Atomic GPIO Control (Fixes the GPIO 2 LED bug):
  //    "PIN 2 1" (HIGH), "PIN 2 0" (LOW), "PIN 2 T" (TOGGLE), "PIN 2 R" (READ)
  if (line.startsWith("PIN ") || line.startsWith("pin ")) {
    int sp1 = line.indexOf(' ', 4);
    int pin = (sp1 > 0) ? line.substring(4, sp1).toInt() : line.substring(4).toInt();
    String act = (sp1 > 0) ? line.substring(sp1 + 1) : "R";
    act.trim();
    act.toUpperCase();

    if (pin < 0 || pin > 39) return "ERR:PIN_RANGE";

    if (act == "R" || act == "READ") {
      return String(digitalRead(pin));
    }
    if (act == "IN" || act == "INPUT") {
      pinMode(pin, INPUT);
      return "OK:IN";
    }
    // Ensure OUTPUT mode and use atomic W1TS/W1TC registers for pins 0..31
    pinMode(pin, OUTPUT);
    if (pin < 32) {
      uint32_t mask = (1UL << pin);
      *(volatile uint32_t*)GPIO_ENABLE_W1TS_REG = mask;
      if (act == "1" || act == "HIGH" || act == "ON") {
        *(volatile uint32_t*)GPIO_OUT_W1TS_REG = mask;
      } else if (act == "0" || act == "LOW" || act == "OFF") {
        *(volatile uint32_t*)GPIO_OUT_W1TC_REG = mask;
      } else if (act == "T" || act == "TOGGLE") {
        uint32_t cur = *(volatile uint32_t*)GPIO_OUT_REG;
        if (cur & mask) *(volatile uint32_t*)GPIO_OUT_W1TC_REG = mask;
        else            *(volatile uint32_t*)GPIO_OUT_W1TS_REG = mask;
      }
      uint32_t state = (*(volatile uint32_t*)GPIO_OUT_REG & mask) ? 1 : 0;
      return String(state);
    } else {
      if (act == "1" || act == "HIGH" || act == "ON") digitalWrite(pin, HIGH);
      else if (act == "0" || act == "LOW" || act == "OFF") digitalWrite(pin, LOW);
      else if (act == "T" || act == "TOGGLE") digitalWrite(pin, !digitalRead(pin));
      return String(digitalRead(pin));
    }
  }

  // 5. ADC Read: "ADC 34"
  if (line.startsWith("ADC ") || line.startsWith("adc ")) {
    int pin = line.substring(4).toInt();
    return String(analogRead(pin));
  }

  // 6. Diagnostics and Status
  if (line == "IP" || line == "ip") return WiFi.softAPIP().toString();
  if (line == "STATUS" || line == "status" || line == "PING") {
    return "ESP32_READY|UPTIME_MS:" + String(millis()) +
           "|IP:" + WiFi.softAPIP().toString() +
           "|BT:" + String(BT_NAME) +
           "|HEAP:" + String(ESP.getFreeHeap());
  }

  return "ERR:UNKNOWN_CMD";
}

// --- HTTP and OTA Endpoint Configuration ---
void setupBridgeServer() {
  server.on("/", HTTP_GET, []() {
    String json = "{\"status\":\"ESP32_READY\",\"ip\":\"" + WiFi.softAPIP().toString() +
                  "\",\"bt\":\"" + String(BT_NAME) +
                  "\",\"uptime_ms\":" + String(millis()) +
                  ",\"free_heap\":" + String(ESP.getFreeHeap()) + "}";
    server.send(200, "application/json", json);
  });

  // Universal CLI command endpoint: /cmd?q=PIN%202%201
  server.on("/cmd", HTTP_GET, []() {
    if (!server.hasArg("q")) {
      server.send(400, "text/plain", "ERR:MISSING_Q");
      return;
    }
    String res = execBridgeCmd(server.arg("q"));
    server.send(200, "text/plain", res);
  });

  // Backward compatibility with /reg?addr=3FF44004&val=...
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

  // Wi-Fi OTA Endpoint: POST /ota with multipart binary file "image"
  server.on("/ota", HTTP_POST, []() {
    bool ok = !Update.hasError();
    server.sendHeader("Connection", "close");
    server.send(ok ? 200 : 500, "text/plain", ok ? "OTA_OK_REBOOTING" : "OTA_FAIL");
    delay(300);
    if (ok) ESP.restart();
  }, []() {
    HTTPUpload& upload = server.upload();
    if (upload.status == UPLOAD_FILE_START) {
      Update.begin(UPDATE_SIZE_UNKNOWN);
    } else if (upload.status == UPLOAD_FILE_WRITE) {
      Update.write(upload.buf, upload.currentSize);
    } else if (upload.status == UPLOAD_FILE_END) {
      Update.end(true);
    }
  });

  server.begin();
}

// --- Daemon Task on Core 0 (Protocol CPU) ---
void bridgeDaemonTask(void* pvParameters) {
  Serial.begin(115200);
  #ifdef ENABLE_BT_CLASSIC
    SerialBT.begin(BT_NAME);
  #endif

  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  setupBridgeServer();

  Serial.println("ESP32_READY");

  for (;;) {
    server.handleClient();
    if (Serial.available()) {
      String cmd = Serial.readStringUntil('\n');
      String out = execBridgeCmd(cmd);
      if (out.length() > 0) Serial.println(out);
    }
    #ifdef ENABLE_BT_CLASSIC
    if (SerialBT.available()) {
      String cmd = SerialBT.readStringUntil('\n');
      String out = execBridgeCmd(cmd);
      if (out.length() > 0) SerialBT.println(out);
    }
    #endif
    vTaskDelay(pdMS_TO_TICKS(2)); // Yield CPU to prevent Watchdog Trigger
  }
}

void startBridgeDaemon() {
  if (bridgeTaskHandle == NULL) {
    xTaskCreatePinnedToCore(
      bridgeDaemonTask,
      "BridgeOTA_Core0",
      8192,
      NULL,
      1,
      &bridgeTaskHandle,
      0 // Pinned to Core 0 to leave Core 1 free for user/student code
    );
  }
}

// ============================================================================
// USER / STUDENT CODE (Runs on Core 1)
// ============================================================================
void setup() {
  startBridgeDaemon();
  pinMode(2, OUTPUT);
}

void loop() {
  // Core 1 remains completely free for user logic without blocking Bridge, BT, or OTA
  delay(100);
}