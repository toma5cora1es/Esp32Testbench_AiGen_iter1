// ============================================================================
// FILE: firmware/core0_daemon/core0_daemon.cpp
// DESCRIPTION: Non-Blocking Core-0 HIL, Multi-Page Web Portal (/ude & /agv),
//              Atomic SYNC/TELEM Pipeline, ESP-NOW Master/Slave Bridge.
// ============================================================================

#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Update.h>
#include <Wire.h>
#include <SPI.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include "BluetoothSerial.h"
#include "esp_bt.h"
#include "soc/gpio_reg.h"
#include "soc/rtc_cntl_reg.h"
#include "esp_ota_ops.h"

#define _FW_BUILD_ID       "{{FW_BUILD_ID}}"
#define _DEFAULT_NODE_ROLE {{NODE_ROLE_ID}}   // 0 = STANDALONE, 1 = MASTER_HOST, 2 = SLAVE_AGV
#define _DEFAULT_UI_PAGE   {{DEFAULT_UI_ID}}  // 0 = UDE Workbench (web_ui.html), 1 = AGV Cockpit (web_ui_agv.html)

void user_setup();
static WebServer _bgServer(80);
static BluetoothSerial _bgSerialBT;
static volatile bool _otaInProgress = false;
static volatile bool _btActive = false;
static volatile bool _apActive = false;
static size_t _otaWritten = 0;

static volatile uint8_t  _nodeRole      = _DEFAULT_NODE_ROLE;
static volatile uint8_t  _activeUiPage  = _DEFAULT_UI_PAGE;
static volatile uint32_t _espNowTxCount = 0;
static volatile uint32_t _espNowRxCount = 0;
static volatile uint32_t _lastTxMicros  = 0;
static volatile uint32_t _lastRttMicros = 0;
static int               _keysightPin   = 4;
static uint8_t           _bcastMac[6]   = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
static uint8_t           _peerMac[6]    = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

typedef struct __attribute__((packed)) {
  uint8_t  magic;      // 0xA5 = Master->Slave Cmd, 0x5A = Slave->Master Telemetry
  uint8_t  role;       // Sender role
  uint16_t seq;        // Sequence number
  uint32_t store0_cmd; // 0x3FF4804C: [31:28]Magic | [27:24]Mode | [23:16]Aux | [15:8]CmdL | [7:0]CmdR
  uint32_t store1_enc; // 0x3FF48050: [31:16]EncL  | [15:0]EncR
  uint32_t store2_sen; // 0x3FF48054: [31:16]US_mm | [15:8]SenMask  | [7:0]FSM_State
  uint32_t store3_pos; // 0x3FF48058: [31:16]X_mm  | [15:0]Y_mm
  uint32_t store4_vel; // 0x3FF4805C: [31:16]Th_mrad | [15:0]Vel_mms
} EspNowBridgePacket_t;

static void _enablePadInput(int p) {
  static const uint8_t muxOff[40] = {
    0x44,0x88,0x40,0x84,0x48,0x6C,0x60,0x64,0x68,0x54,
    0x58,0x5C,0x34,0x38,0x30,0x3C,0x4C,0x50,0x70,0x74,
    0x78,0x7C,0x80,0x8C,0x90,0x24,0x28,0x2C,0,0,
    0,0,0x1C,0x20,0x14,0x18,0x04,0x08,0x0C,0x10
  };
  if (p >= 0 && p < 40 && muxOff[p] != 0) {
    *(volatile uint32_t*)(0x3FF49000UL + muxOff[p]) |= (1UL << 9);
  }
}

static String _measurePulse(int pin, uint32_t timeoutUs) {
  if (pin < 0 || pin > 39) return "ERR|INVALID_PIN";
  _enablePadInput(pin);
  volatile uint32_t* inReg = (pin < 32) ? (volatile uint32_t*)GPIO_IN_REG : (volatile uint32_t*)GPIO_IN1_REG;
  uint32_t mask = (pin < 32) ? (1UL << pin) : (1UL << (pin - 32));
  uint32_t t0 = micros();
  bool initState = (*inReg & mask) != 0;
  while (((*inReg & mask) != 0) == initState) {
    if (micros() - t0 > timeoutUs) return String("HI_US:0|LO_US:0|FREQ_HZ:0.0|DUTY_PCT:") + (initState ? "100.0" : "0.0");
  }
  uint32_t tEdge1 = micros();
  bool state1 = !initState;
  while (((*inReg & mask) != 0) == state1) {
    if (micros() - tEdge1 > timeoutUs) return "HI_US:0|LO_US:0|FREQ_HZ:0.0|DUTY_PCT:0.0";
  }
  uint32_t tEdge2 = micros();
  bool state2 = !state1;
  while (((*inReg & mask) != 0) == state2) {
    if (micros() - tEdge2 > timeoutUs) return "HI_US:0|LO_US:0|FREQ_HZ:0.0|DUTY_PCT:0.0";
  }
  uint32_t tEdge3 = micros();
  uint32_t d1 = tEdge2 - tEdge1;
  uint32_t d2 = tEdge3 - tEdge2;
  uint32_t hi = state1 ? d1 : d2;
  uint32_t lo = state1 ? d2 : d1;
  uint32_t per = hi + lo;
  float freq = (per > 0) ? (1000000.0f / (float)per) : 0.0f;
  float duty = (per > 0) ? ((100.0f * (float)hi) / (float)per) : 0.0f;
  char b[96];
  snprintf(b, sizeof(b), "HI_US:%lu|LO_US:%lu|FREQ_HZ:%.1f|DUTY_PCT:%.1f", (unsigned long)hi, (unsigned long)lo, freq, duty);
  return String(b);
}

static const char _WEB_UI_UDE[] PROGMEM = R"rawliteral(
{{WEB_UI_UDE_HTML}}
)rawliteral";

static const char _WEB_UI_AGV[] PROGMEM = R"rawliteral(
{{WEB_UI_AGV_HTML}}
)rawliteral";

static void _onEspNowRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
  if (len != (int)sizeof(EspNowBridgePacket_t)) return;
  const EspNowBridgePacket_t* pkt = (const EspNowBridgePacket_t*)data;
  _espNowRxCount++;
  if (info && info->src_addr) {
    memcpy(_peerMac, info->src_addr, 6);
  }

  if (pkt->magic == 0xA5 && _nodeRole == 2) {
    *(volatile uint32_t*)0x3FF4804CUL = pkt->store0_cmd;
    uint8_t cmdMagic = (pkt->store0_cmd >> 28) & 0x0F;

    if (cmdMagic == 0x0E && !_apActive) {
      setCpuFrequencyMhz(240);
      WiFi.mode(WIFI_AP_STA);
      WiFi.softAP("ESP32_AGV_OTA", "12345678", 1);
      WiFi.setSleep(false);
      _apActive = true;
    } else if (cmdMagic == 0x0D) {
      if (_apActive) { WiFi.softAPdisconnect(true); WiFi.mode(WIFI_STA); _apActive = false; }
      setCpuFrequencyMhz(80);
    }

    EspNowBridgePacket_t reply;
    reply.magic      = 0x5A;
    reply.role       = _nodeRole;
    reply.seq        = pkt->seq;
    reply.store0_cmd = *(volatile uint32_t*)0x3FF4804CUL;
    reply.store1_enc = *(volatile uint32_t*)0x3FF48050UL;
    reply.store2_sen = *(volatile uint32_t*)0x3FF48054UL;
    reply.store3_pos = *(volatile uint32_t*)0x3FF48058UL;
    reply.store4_vel = *(volatile uint32_t*)0x3FF4805CUL;
    esp_now_send(_bcastMac, (const uint8_t*)&reply, sizeof(reply));
  } else if (pkt->magic == 0x5A && _nodeRole != 2) {
    *(volatile uint32_t*)0x3FF48050UL = pkt->store1_enc;
    *(volatile uint32_t*)0x3FF48054UL = pkt->store2_sen;
    *(volatile uint32_t*)0x3FF48058UL = pkt->store3_pos;
    *(volatile uint32_t*)0x3FF4805CUL = pkt->store4_vel;
    _lastRttMicros = micros() - _lastTxMicros;
    if (_keysightPin >= 0 && _keysightPin < 32) {
      *(volatile uint32_t*)GPIO_OUT_W1TC_REG = (1UL << _keysightPin);
    }
  }
}

static void _sendEspNowMasterBurst() {
  EspNowBridgePacket_t pkt;
  pkt.magic      = 0xA5;
  pkt.role       = _nodeRole;
  pkt.seq        = (uint16_t)(++_espNowTxCount);
  pkt.store0_cmd = *(volatile uint32_t*)0x3FF4804CUL;
  pkt.store1_enc = *(volatile uint32_t*)0x3FF48050UL;
  pkt.store2_sen = *(volatile uint32_t*)0x3FF48054UL;
  pkt.store3_pos = *(volatile uint32_t*)0x3FF48058UL;
  pkt.store4_vel = *(volatile uint32_t*)0x3FF4805CUL;

  if (_keysightPin >= 0 && _keysightPin < 32) {
    *(volatile uint32_t*)GPIO_ENABLE_W1TS_REG = (1UL << _keysightPin);
    *(volatile uint32_t*)GPIO_OUT_W1TS_REG    = (1UL << _keysightPin);
  }
  _lastTxMicros = micros();
  esp_now_send(_bcastMac, (const uint8_t*)&pkt, sizeof(pkt));
}

static void _initEspNowSubsystem() {
  if (esp_now_init() != ESP_OK) return;
  esp_now_register_recv_cb(_onEspNowRecv);
  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, _bcastMac, 6);
  peerInfo.channel = 1;
  peerInfo.encrypt = false;
  if (!esp_now_is_peer_exist(_bcastMac)) {
    esp_now_add_peer(&peerInfo);
  }
}

static String _bgExec(String line) {
  line.trim();
  if (line.length() == 0) return "";

  // 1. ATOMIC SINGLE-LINE TELEMETRY DUMP FOR MATLAB TEST SEQUENCE RECORDER
  if (line == "TELEM" || line == "telem") {
    char buf[128];
    snprintf(buf, sizeof(buf), "TELEM|%08X %08X %08X %08X %08X|RTT_US:%lu|RX:%lu",
             *(volatile uint32_t*)0x3FF4804CUL,
             *(volatile uint32_t*)0x3FF48050UL,
             *(volatile uint32_t*)0x3FF48054UL,
             *(volatile uint32_t*)0x3FF48058UL,
             *(volatile uint32_t*)0x3FF4805CUL,
             (unsigned long)_lastRttMicros,
             (unsigned long)_espNowRxCount);
    return String(buf);
  }

  // 2. COMBINED WRITE-CMD + READ-TELEMETRY FOR WEB UI (Cut HTTP Requests in Half!)
  if (line.startsWith("SYNC ") || line.startsWith("sync ")) {
    uint32_t v = strtoul(line.substring(5).c_str(), NULL, 16);
    *(volatile uint32_t*)0x3FF4804CUL = v;
    if (_nodeRole == 1) _sendEspNowMasterBurst();
    char buf[64];
    snprintf(buf, sizeof(buf), "%08X %08X %08X %08X",
             *(volatile uint32_t*)0x3FF48050UL,
             *(volatile uint32_t*)0x3FF48054UL,
             *(volatile uint32_t*)0x3FF48058UL,
             *(volatile uint32_t*)0x3FF4805CUL);
    return String(buf);
  }

  if (line.startsWith("R ") || line.startsWith("r ") || line.startsWith("REG ") || line.startsWith("reg ")) {
    int sp = line.indexOf(' ');
    uint32_t a = strtoul(line.substring(sp + 1).c_str(), NULL, 16);
    char b[16]; snprintf(b, sizeof(b), "0x%08X", *(volatile uint32_t*)a); return String(b);
  }
  if (line.startsWith("W ") || line.startsWith("w ")) {
    int sp = line.indexOf(' ', 2);
    uint32_t a = strtoul(line.substring(2, sp).c_str(), NULL, 16);
    uint32_t v = strtoul(line.substring(sp + 1).c_str(), NULL, 16);
    *(volatile uint32_t*)a = v;
    if (a == 0x3FF4804CUL && _nodeRole == 1) {
      _sendEspNowMasterBurst();
    }
    char b[16]; snprintf(b, sizeof(b), "0x%08X", *(volatile uint32_t*)a); return String(b);
  }
  if (line.startsWith("D ") || line.startsWith("d ")) {
    int sp = line.indexOf(' ', 2);
    uint32_t a = strtoul(line.substring(2, sp > 0 ? sp : line.length()).c_str(), NULL, 16);
    int c = (sp > 0) ? line.substring(sp + 1).toInt() : 4;
    if (c < 1) c = 1; if (c > 64) c = 64;
    String out = ""; char b[16];
    for (int i = 0; i < c; i++) {
      snprintf(b, sizeof(b), "%08X", *(volatile uint32_t*)(a + i * 4));
      if (i > 0) out += " "; out += b;
    }
    return out;
  }
  if (line.startsWith("UI ") || line.startsWith("ui ")) {
    String sub = line.substring(3); sub.trim(); sub.toUpperCase();
    if (sub == "AGV" || sub == "1") _activeUiPage = 1;
    else if (sub == "UDE" || sub == "WORKBENCH" || sub == "0") _activeUiPage = 0;
    return String("UI_PAGE:") + (_activeUiPage == 1 ? "AGV_COCKPIT" : "UDE_WORKBENCH");
  }
  if (line.startsWith("ROLE ") || line.startsWith("role ")) {
    String sub = line.substring(5); sub.trim(); sub.toUpperCase();
    if (sub == "MASTER" || sub == "1") _nodeRole = 1;
    else if (sub == "SLAVE" || sub == "2") _nodeRole = 2;
    else _nodeRole = 0;
    return String("ROLE_SET:") + (_nodeRole == 1 ? "MASTER" : (_nodeRole == 2 ? "SLAVE" : "STANDALONE"));
  }
  if (line.startsWith("ESPNOW ") || line.startsWith("espnow ")) {
    String sub = line.substring(7); sub.trim(); sub.toUpperCase();
    if (sub == "BURST" || sub == "PING") {
      uint32_t prevRx = _espNowRxCount;
      _sendEspNowMasterBurst();
      uint32_t tWait = micros();
      while (_espNowRxCount == prevRx && (micros() - tWait < 8000)) {
        delayMicroseconds(100);
      }
    }
    char macStr[24];
    snprintf(macStr, sizeof(macStr), "%02X:%02X:%02X:%02X:%02X:%02X",
             _peerMac[0], _peerMac[1], _peerMac[2], _peerMac[3], _peerMac[4], _peerMac[5]);
    return String("ESPNOW_STAT|ROLE:") + String(_nodeRole) +
           "|CPU_MHZ:" + String(getCpuFrequencyMhz()) +
           "|MY_MAC:" + WiFi.macAddress() +
           "|PEER_MAC:" + String(macStr) +
           "|TX:" + String(_espNowTxCount) +
           "|RX:" + String(_espNowRxCount) +
           "|RTT_US:" + String(_lastRttMicros);
  }
  if (line.startsWith("PIN ") || line.startsWith("pin ")) {
    int sp = line.indexOf(' ', 4);
    int p = (sp > 0) ? line.substring(4, sp).toInt() : line.substring(4).toInt();
    String act = (sp > 0) ? line.substring(sp + 1) : "R"; act.trim(); act.toUpperCase();
    if (act == "R" || act == "READ") { _enablePadInput(p); return String(digitalRead(p)); }
    if (act == "IN" || act == "INPUT") { pinMode(p, INPUT); _enablePadInput(p); return String(digitalRead(p)); }
    pinMode(p, OUTPUT); _enablePadInput(p);
    uint32_t m = (1UL << p); *(volatile uint32_t*)GPIO_ENABLE_W1TS_REG = m;
    if (act == "1" || act == "HIGH" || act == "ON") *(volatile uint32_t*)GPIO_OUT_W1TS_REG = m;
    else if (act == "0" || act == "LOW" || act == "OFF") *(volatile uint32_t*)GPIO_OUT_W1TC_REG = m;
    else if (act == "T" || act == "TOGGLE") {
      if (*(volatile uint32_t*)GPIO_OUT_REG & m) *(volatile uint32_t*)GPIO_OUT_W1TC_REG = m;
      else *(volatile uint32_t*)GPIO_OUT_W1TS_REG = m;
    }
    return String((*(volatile uint32_t*)GPIO_OUT_REG & m) ? 1 : 0);
  }
  if (line.startsWith("DAC ") || line.startsWith("dac ")) {
    int pin = 25, val = 0;
    if (sscanf(line.c_str() + 4, "%d %d", &pin, &val) == 2 && (pin == 25 || pin == 26)) {
      dacWrite(pin, constrain(val, 0, 255));
      return String("DAC_OK|PIN:") + pin + "|VAL:" + constrain(val, 0, 255);
    }
    return "ERR|Use DAC 25 <0..255> or DAC 26 <0..255>";
  }
  if (line.startsWith("PWM ") || line.startsWith("pwm ")) {
    int pin = 4, freq = 1000, duty = 512;
    if (sscanf(line.c_str() + 4, "%d %d %d", &pin, &freq, &duty) == 3) {
      if (freq <= 0 || duty < 0) { ledcDetach(pin); pinMode(pin, OUTPUT); digitalWrite(pin, LOW); return "PWM_OFF"; }
      ledcAttach(pin, freq, 10); _enablePadInput(pin);
      ledcWrite(pin, constrain(duty, 0, 1023));
      return String("PWM_OK|PIN:") + pin + "|FREQ:" + freq + "|DUTY:" + constrain(duty, 0, 1023);
    }
    return "ERR|Use PWM <pin> <freq> <duty_0_1023>";
  }
  if (line.startsWith("PULSE ") || line.startsWith("pulse ")) {
    int pin = 35; unsigned int timeoutUs = 50000;
    sscanf(line.c_str() + 6, "%d %u", &pin, &timeoutUs);
    return _measurePulse(pin, timeoutUs);
  }
  if (line.startsWith("TOUCH ") || line.startsWith("touch ")) {
    int pin = line.substring(6).toInt();
    return String(touchRead(pin));
  }
  if (line.startsWith("I2C ") || line.startsWith("i2c ")) {
    String sub = line.substring(4); sub.trim(); sub.toUpperCase();
    Wire.begin(21, 22, 100000);
    if (sub == "SCAN") {
      String found = "I2C_FOUND:"; int cnt = 0;
      for (uint8_t a = 8; a < 120; a++) {
        Wire.beginTransmission(a);
        if (Wire.endTransmission() == 0) { char b[8]; snprintf(b, sizeof(b), "0x%02X ", a); found += b; cnt++; }
      }
      return cnt ? found : "I2C_FOUND:NONE";
    }
    if (sub.startsWith("READ ")) {
      unsigned int a = 0, r = 0, n = 1;
      if (sscanf(sub.c_str() + 5, "%x %x %u", &a, &r, &n) >= 2) {
        Wire.beginTransmission((uint8_t)a); Wire.write((uint8_t)r);
        if (Wire.endTransmission(false) != 0) return "ERR|I2C_NACK";
        Wire.requestFrom((uint8_t)a, (uint8_t)n); String out = "";
        while (Wire.available()) { char b[8]; snprintf(b, sizeof(b), "0x%02X ", Wire.read()); out += b; }
        out.trim(); return out;
      }
    }
    if (sub.startsWith("WRITE ")) {
      unsigned int a = 0, r = 0, v = 0;
      if (sscanf(sub.c_str() + 6, "%x %x %x", &a, &r, &v) == 3) {
        Wire.beginTransmission((uint8_t)a); Wire.write((uint8_t)r); Wire.write((uint8_t)v);
        return (Wire.endTransmission() == 0) ? "I2C_WRITE_OK" : "ERR|I2C_NACK";
      }
    }
    return "ERR|Use I2C SCAN, I2C READ <addr> <reg> <n>, or I2C WRITE <addr> <reg> <val>";
  }
  if (line.startsWith("SPI ") || line.startsWith("spi ")) {
    int cs = 5; unsigned int tx = 0;
    if (sscanf(line.c_str() + 4, "%d %x", &cs, &tx) == 2) {
      SPI.begin(18, 19, 23, cs); pinMode(cs, OUTPUT); digitalWrite(cs, LOW);
      SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
      uint8_t rx = SPI.transfer((uint8_t)tx);
      SPI.endTransaction(); digitalWrite(cs, HIGH);
      char b[16]; snprintf(b, sizeof(b), "0x%02X", rx); return String(b);
    }
    return "ERR|Use SPI <cs_pin> <hex_byte>";
  }
  if (line.startsWith("BEEP ") || line.startsWith("beep ")) {
    int s1 = line.indexOf(' ', 5); int s2 = line.indexOf(' ', s1 + 1);
    int pin = line.substring(5, s1).toInt();
    int freq = line.substring(s1 + 1, s2).toInt();
    int dur = line.substring(s2 + 1).toInt();
    tone(pin, freq, dur); return "BEEP_OK";
  }
  if (line.startsWith("ADC ") || line.startsWith("adc ")) return String(analogRead(line.substring(4).toInt()));
  if (line == "OTA_PREP" || line == "ota_prep") {
    if (_btActive) { _bgSerialBT.end(); btStop(); _btActive = false; }
    return "OTA_PREP_OK|HEAP_FREE:" + String(ESP.getFreeHeap());
  }
  if (line == "INFO" || line == "info") {
    const esp_partition_t* runPart = esp_ota_get_running_partition();
    const esp_partition_t* nextPart = esp_ota_get_next_update_partition(NULL);
    return String("FW_ID:") + _FW_BUILD_ID +
           "|ROLE:" + (_nodeRole == 1 ? "MASTER" : (_nodeRole == 2 ? "SLAVE" : "STANDALONE")) +
           "|CPU_MHZ:" + String(getCpuFrequencyMhz()) +
           "|UI:" + (_activeUiPage == 1 ? "AGV" : "UDE") +
           "|CORE:" + String(ESP.getSdkVersion()) +
           "|RUN_PART:" + (runPart ? runPart->label : "?") +
           "|NEXT_PART:" + (nextPart ? nextPart->label : "?") +
           "|HEAP_FREE:" + String(ESP.getFreeHeap()) +
           "|FLASH_MB:" + String(ESP.getFlashChipSize()/1048576) +
           "|NEXT_OTA_MAX:" + String(nextPart ? nextPart->size : 0);
  }
  if (line == "STATUS" || line == "status") {
    return String("ESP32_READY|FW_ID:") + _FW_BUILD_ID +
           "|ROLE:" + (_nodeRole == 1 ? "MASTER" : (_nodeRole == 2 ? "SLAVE" : "STANDALONE")) +
           "|UPTIME_MS:" + String(millis()) +
           "|IP:" + (_apActive ? WiFi.softAPIP().toString() : String("0.0.0.0")) +
           "|MAC:" + WiFi.macAddress() +
           "|ESPNOW_RX:" + String(_espNowRxCount) +
           "|RTT_US:" + String(_lastRttMicros) +
           "|BT:" + (_btActive ? "ESP32_BT_BRIDGE" : "OFF") +
           "|HEAP:" + String(ESP.getFreeHeap());
  }
  return "ERR";
}

static void _bgTask(void* pv) {
  esp_bt_controller_mem_release(ESP_BT_MODE_BLE);
  Serial.setTimeout(15); // Fast 15ms timeout so Serial never stalls HTTP or ESP-NOW

  if (_nodeRole == 2) {
    setCpuFrequencyMhz(80);
    WiFi.mode(WIFI_STA);
    esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);
    esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
    _btActive = false;
    _apActive = false;
  } else {
    _bgSerialBT.begin("ESP32_BT_BRIDGE");
    _btActive = true;
    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP("ESP32_LAB", "12345678", 1);
    WiFi.setSleep(false);
    _apActive = true;
  }

  _initEspNowSubsystem();

  _bgServer.enableCORS(true);
  _bgServer.on("/", HTTP_GET, [](){
    if (_bgServer.hasArg("json")) {
      _bgServer.send(200, "application/json", "{\"status\":\"ESP32_READY\",\"fw_id\":\"" _FW_BUILD_ID "\",\"ip\":\"" + WiFi.softAPIP().toString() + "\"}");
    } else if (_bgServer.hasArg("ui")) {
      String u = _bgServer.arg("ui"); u.toLowerCase();
      if (u == "agv") _activeUiPage = 1; else if (u == "ude") _activeUiPage = 0;
      _bgServer.send_P(200, "text/html", (_activeUiPage == 1) ? _WEB_UI_AGV : _WEB_UI_UDE);
    } else {
      _bgServer.send_P(200, "text/html", (_activeUiPage == 1) ? _WEB_UI_AGV : _WEB_UI_UDE);
    }
  });
  _bgServer.on("/ude", HTTP_GET, [](){ _activeUiPage = 0; _bgServer.send_P(200, "text/html", _WEB_UI_UDE); });
  _bgServer.on("/agv", HTTP_GET, [](){ _activeUiPage = 1; _bgServer.send_P(200, "text/html", _WEB_UI_AGV); });
  _bgServer.on("/switch", HTTP_GET, [](){
    _activeUiPage = (_activeUiPage == 0) ? 1 : 0;
    _bgServer.sendHeader("Location", "/");
    _bgServer.send(302, "text/plain", "Switching UI template...");
  });
  _bgServer.on("/cmd", HTTP_GET, [](){
    _bgServer.sendHeader("Connection", "close");
    _bgServer.send(200, "text/plain", _bgExec(_bgServer.arg("q")));
  });
  _bgServer.on("/reg", HTTP_GET, [](){
    uint32_t a = strtoul(_bgServer.arg("addr").c_str(), NULL, 16);
    if (_bgServer.hasArg("val")) *(volatile uint32_t*)a = strtoul(_bgServer.arg("val").c_str(), NULL, 16);
    char b[16]; snprintf(b, sizeof(b), "0x%08X", *(volatile uint32_t*)a);
    _bgServer.send(200, "application/json", "{\"address\":\"" + _bgServer.arg("addr") + "\",\"value\":\"" + String(b) + "\"}");
  });
  _bgServer.on("/ota", HTTP_OPTIONS, [](){
    _bgServer.sendHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
    _bgServer.send(204);
  });
  _bgServer.on("/ota", HTTP_POST, [](){
    bool ok = !Update.hasError();
    _bgServer.sendHeader("Connection", "close");
    _bgServer.send(ok ? 200 : 500, "text/plain", ok ? ("OTA_OK_REBOOTING|" _FW_BUILD_ID) : "OTA_FAIL");
    _bgServer.client().flush();
    delay(800);
    _otaInProgress = false;
    if (ok) ESP.restart();
  }, [](){
    HTTPUpload& u = _bgServer.upload();
    if (u.status == UPLOAD_FILE_START) {
      _otaInProgress = true; _otaWritten = 0;
      if (_btActive) { _bgSerialBT.end(); btStop(); _btActive = false; }
      Update.begin(UPDATE_SIZE_UNKNOWN);
    } else if (u.status == UPLOAD_FILE_WRITE) {
      Update.write(u.buf, u.currentSize);
      _otaWritten += u.currentSize;
      vTaskDelay(1);
    } else if (u.status == UPLOAD_FILE_END) {
      Update.end(true);
    }
  });
  _bgServer.begin();

  static String serialLine = "";
  static String btLine = "";
  uint32_t lastEspNowTick = millis();

  for(;;) {
    if (_apActive) {
      _bgServer.handleClient();
    }
    if (!_otaInProgress) {
      // Non-blocking character accumulator for UART0 Serial
      while (Serial.available()) {
        char c = (char)Serial.read();
        if (c == '\n' || c == '\r') {
          if (serialLine.length() > 0) {
            String r = _bgExec(serialLine);
            serialLine = "";
            if (r.length() > 0) Serial.println(r);
          }
        } else if (serialLine.length() < 120) {
          serialLine += c;
        }
      }
      // Non-blocking character accumulator for Bluetooth SPP
      while (_btActive && _bgSerialBT.available()) {
        char c = (char)_bgSerialBT.read();
        if (c == '\n' || c == '\r') {
          if (btLine.length() > 0) {
            String r = _bgExec(btLine);
            btLine = "";
            if (r.length() > 0) _bgSerialBT.println(r);
          }
        } else if (btLine.length() < 120) {
          btLine += c;
        }
      }
      uint32_t syncPeriodMs = (_btActive && _bgSerialBT.hasClient()) ? 50 : 25;
      if (_nodeRole == 1 && (millis() - lastEspNowTick >= syncPeriodMs)) {
        lastEspNowTick = millis();
        _sendEspNowMasterBurst();
      }
      vTaskDelay(pdMS_TO_TICKS(1));
    }
  }
}

{{USER_SKETCH_CODE}}

void setup() {
  Serial.begin(115200);
  xTaskCreatePinnedToCore(_bgTask, "OTA_Core0", 12288, NULL, 2, NULL, 0);
  user_setup();
}