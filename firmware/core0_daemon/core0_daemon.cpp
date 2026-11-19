#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Update.h>
#include <Wire.h>
#include <SPI.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_arduino_version.h>
#include <BluetoothSerial.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include "soc/io_mux_reg.h"
#include "soc/gpio_periph.h"
#include "esp_log.h"

#ifndef WB_BUILD_ID
#define WB_BUILD_ID "{{FW_BUILD_ID}}"
#endif
#define WB_NODE_ROLE      {{NODE_ROLE_ID}}
#define WB_DEFAULT_UI     {{DEFAULT_UI_ID}}
#define WB_AP_SSID        "{{WB_AP_SSID}}"
#define WB_AP_PASS        "{{WB_AP_PASS}}"
#define WB_BT_NAME        "{{WB_BT_NAME}}"
#define WB_ESPNOW_CH      {{WB_ESPNOW_CH}}
#define WB_MASTER_RTT_PIN {{WB_MASTER_RTT_PIN}}

void user_setup();

static const char* HTML_UDE_UI = R"WB_UI_UDE({{WEB_UI_UDE_HTML}})WB_UI_UDE";
static const char* HTML_AGV_UI = R"WB_UI_AGV({{WEB_UI_AGV_HTML}})WB_UI_AGV";

static WebServer g_http(80);
static BluetoothSerial g_bt;
static portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;

static volatile uint8_t  g_role      = WB_NODE_ROLE;
static volatile uint8_t  g_uiId      = WB_DEFAULT_UI;
static volatile bool     g_httpUp    = false;
static volatile bool     g_btUp      = false;
static volatile bool     g_hasPeer   = false;
static volatile bool     g_otaArmed  = false;
static volatile bool     g_pongWait  = false;

static uint8_t           g_peerMac[6]   = {0};
static uint8_t           g_bcastMac[6]  = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
static volatile uint16_t g_seq          = 0;
static volatile uint32_t g_txPkts       = 0;
static volatile uint32_t g_rxPkts       = 0;
static volatile uint32_t g_lossPkts     = 0;
static volatile uint32_t g_rttUs        = 0;
static volatile uint32_t g_pingTxUs     = 0;
static volatile uint32_t g_lastTelemMs  = 0;
static volatile bool     g_syncPending  = false;
static uint32_t          g_lastStore0   = 0x10000000;

enum WbMsgType : uint8_t {
  PKT_BEACON = 1,
  PKT_CMD    = 2,
  PKT_TLM    = 3,
  PKT_PING   = 4,
  PKT_PONG   = 5
};

typedef struct __attribute__((packed)) {
  uint32_t magic;
  uint8_t  type;
  uint8_t  role;
  uint16_t seq;
  uint32_t txUs;
  uint32_t s0;
  uint32_t s1;
  uint32_t s2;
  uint32_t s3;
  uint32_t s4;
  uint32_t crc;
} WbEspNowFrame;

static uint32_t calcFrameCrc(const WbEspNowFrame& f) {
  const uint8_t* p = reinterpret_cast<const uint8_t*>(&f);
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < sizeof(WbEspNowFrame) - sizeof(uint32_t); ++i) {
    h ^= p[i];
    h *= 16777619u;
  }
  return h;
}

static inline void writeLedc(uint8_t pin, uint8_t ch, uint32_t freq, uint8_t res, uint32_t duty) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcDetach(pin);
  if (freq == 0 || duty == 0) {
    pinMode(pin, OUTPUT);
    digitalWrite(pin, LOW);
  } else {
    ledcAttach(pin, freq, res);
    ledcWrite(pin, duty);
    if (pin >= 0 && pin < SOC_GPIO_PIN_COUNT && GPIO_PIN_MUX_REG[pin]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);
  }
#else
  ledcSetup(ch, freq, res);
  ledcAttachPin(pin, ch);
  ledcWrite(ch, duty);
  if (pin >= 0 && pin < SOC_GPIO_PIN_COUNT && GPIO_PIN_MUX_REG[pin]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);
#endif
  (void)ch;
}

static const char* roleName(uint8_t r) {
  return (r == 1) ? "MASTER" : ((r == 2) ? "SLAVE" : "STANDALONE");
}

static void applyPowerProfile(const String& prof) {
  String p = prof;
  p.toUpperCase();
  if (p == "ECO") {
    setCpuFrequencyMhz(80);
    esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
    if (g_btUp) { g_bt.end(); g_btUp = false; }
  } else if (p == "BALANCED") {
    setCpuFrequencyMhz(160);
    esp_wifi_set_ps(WIFI_PS_NONE);
    if (g_btUp) { g_bt.end(); g_btUp = false; }
  } else {
    setCpuFrequencyMhz(240);
    esp_wifi_set_ps(WIFI_PS_NONE);
  }
}

static void ensurePeerAdded(const uint8_t* mac) {
  if (esp_now_is_peer_exist(mac)) return;
  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, mac, 6);
  peer.channel = WB_ESPNOW_CH;
  peer.ifidx   = WIFI_IF_STA;
  peer.encrypt = false;
  esp_now_add_peer(&peer);
}

static void sendEspNowFrame(uint8_t type, uint32_t txUsOverride = 0) {
  WbEspNowFrame f = {};
  f.magic = 0x57424E31u;
  f.type  = type;
  f.role  = g_role;
  f.seq   = ++g_seq;
  f.txUs  = txUsOverride ? txUsOverride : micros();
  f.s0    = REG_READ(RTC_CNTL_STORE0_REG);
  f.s1    = REG_READ(RTC_CNTL_STORE1_REG);
  f.s2    = REG_READ(RTC_CNTL_STORE2_REG);
  f.s3    = REG_READ(RTC_CNTL_STORE3_REG);
  f.s4    = REG_READ(RTC_CNTL_STORE4_REG);
  f.crc   = calcFrameCrc(f);

  const uint8_t* dst = (g_hasPeer && type != PKT_BEACON) ? g_peerMac : g_bcastMac;
  if (esp_now_send(dst, reinterpret_cast<const uint8_t*>(&f), sizeof(f)) == ESP_OK) {
    g_txPkts++;
  }
}

static void handleMagicBits(uint32_t s0) {
  uint8_t magic = (s0 >> 28) & 0x0F;
  if (magic == 0xD) {
    applyPowerProfile("ECO");
  } else if (magic == 0xE) {
    applyPowerProfile("TURBO");
    if (g_role == 2 && !g_httpUp) {
      WiFi.mode(WIFI_AP_STA);
      WiFi.softAP(WB_AP_SSID, WB_AP_PASS, WB_ESPNOW_CH);
      g_http.begin();
      g_httpUp = true;
    }
  }
}

#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
static void onEspNowRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
  const uint8_t* mac = info ? info->src_addr : nullptr;
#else
static void onEspNowRecv(const uint8_t* mac, const uint8_t* data, int len) {
#endif
  if (!mac || len != (int)sizeof(WbEspNowFrame)) return;
  WbEspNowFrame f;
  memcpy(&f, data, sizeof(f));
  if (f.magic != 0x57424E31u || f.crc != calcFrameCrc(f)) return;

  portENTER_CRITICAL_ISR(&g_mux);
  if (!g_hasPeer && f.role != g_role && f.role != 0) {
    memcpy(g_peerMac, mac, 6);
    g_hasPeer = true;
  }
  g_rxPkts++;
  portEXIT_CRITICAL_ISR(&g_mux);

  ensurePeerAdded(mac);

  if (g_role == 2) {
    if (f.type == PKT_CMD) {
      REG_WRITE(RTC_CNTL_STORE0_REG, f.s0);
      handleMagicBits(f.s0);
      sendEspNowFrame(PKT_TLM, f.txUs);
    } else if (f.type == PKT_PING) {
      sendEspNowFrame(PKT_PONG, f.txUs);
    }
  } else if (g_role == 1) {
    if (f.type == PKT_TLM || f.type == PKT_PONG) {
      uint32_t nowUs = micros();
      if (g_role == 1) digitalWrite(WB_MASTER_RTT_PIN, LOW);
      g_rttUs = nowUs - f.txUs;
      if (f.type == PKT_TLM) {
        REG_WRITE(RTC_CNTL_STORE1_REG, f.s1);
        REG_WRITE(RTC_CNTL_STORE2_REG, f.s2);
        REG_WRITE(RTC_CNTL_STORE3_REG, f.s3);
        REG_WRITE(RTC_CNTL_STORE4_REG, f.s4);
        g_syncPending = false;
      }
      g_pongWait = false;
      g_lastTelemMs = millis();
    }
  }
}

static bool parseHexAddr(const String& tok, uint32_t& out) {
  String s = tok;
  s.trim();
  if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2);
  if (s.length() == 0) return false;
  char* endp = nullptr;
  out = strtoul(s.c_str(), &endp, 16);
  return (endp != s.c_str());
}

static String processCommand(const String& rawIn) {
  String cmd = rawIn;
  cmd.trim();
  if (cmd.length() == 0) return "";

  int sp = cmd.indexOf(' ');
  String op = (sp < 0) ? cmd : cmd.substring(0, sp);
  String rest = (sp < 0) ? "" : cmd.substring(sp + 1);
  op.toUpperCase();
  rest.trim();

  if (op == "STATUS") {
    char buf[196];
    snprintf(buf, sizeof(buf), "ESP32_READY|ROLE:%s|UI:%s|ID:%s|IP:%s|MHZ:%u|PEER:%d",
      roleName(g_role), (g_uiId == 1 ? "AGV" : "UDE"), WB_BUILD_ID,
      WiFi.softAPIP().toString().c_str(), (unsigned)getCpuFrequencyMhz(), g_hasPeer ? 1 : 0);
    return String(buf);
  }
  if (op == "INFO") {
    char buf[220];
    snprintf(buf, sizeof(buf), "ID:%s ROLE:%s HEAP_FREE:%u FLASH_MB:%u SKETCH_KB:%u OTA_FREE_KB:%u MHZ:%u",
      WB_BUILD_ID, roleName(g_role), (unsigned)ESP.getFreeHeap(),
      (unsigned)(ESP.getFlashChipSize() / 1048576u),
      (unsigned)(ESP.getSketchSize() / 1024u),
      (unsigned)(ESP.getFreeSketchSpace() / 1024u),
      (unsigned)getCpuFrequencyMhz());
    return String(buf);
  }
  if (op == "R" || op == "REG") {
    uint32_t addr = 0;
    if (!parseHexAddr(rest, addr) || (addr & 3) || addr < 0x3FF00000u || addr > 0x3FF80000u) return "ERR_ADDR";
    uint32_t val = *reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(addr));
    char out[12];
    snprintf(out, sizeof(out), "%08X", (unsigned)val);
    return String(out);
  }
  if (op == "W") {
    int s2 = rest.indexOf(' ');
    if (s2 < 0) return "ERR_ARGS";
    uint32_t addr = 0, val = 0;
    if (!parseHexAddr(rest.substring(0, s2), addr) || !parseHexAddr(rest.substring(s2 + 1), val)) return "ERR_HEX";
    if ((addr & 3) || addr < 0x3FF00000u || addr > 0x3FF80000u) return "ERR_ADDR";
    *reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(addr)) = val;
    if (addr == RTC_CNTL_STORE0_REG) {
      g_lastStore0 = val;
      handleMagicBits(val);
      if (g_role == 1) sendEspNowFrame(PKT_CMD);
    }
    uint32_t rb = *reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(addr));
    char out[12];
    snprintf(out, sizeof(out), "%08X", (unsigned)rb);
    return String(out);
  }
  if (op == "D") {
    int s2 = rest.indexOf(' ');
    uint32_t addr = 0; int cnt = 8;
    if (s2 < 0) {
      if (!parseHexAddr(rest, addr)) return "ERR_ADDR";
    } else {
      if (!parseHexAddr(rest.substring(0, s2), addr)) return "ERR_ADDR";
      cnt = constrain(rest.substring(s2 + 1).toInt(), 1, 64);
    }
    if ((addr & 3) || addr < 0x3FF00000u || addr > 0x3FF80000u) return "ERR_ADDR";
    String out;
    for (int i = 0; i < cnt; ++i) {
      uint32_t v = *reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(addr + i * 4));
      char h[12]; snprintf(h, sizeof(h), "%08X", (unsigned)v);
      if (i > 0) out += ' ';
      out += h;
    }
    return out;
  }
  if (op == "SYNC") {
    uint32_t cmdWord = 0;
    if (!parseHexAddr(rest, cmdWord)) return "ERR_HEX";
    REG_WRITE(RTC_CNTL_STORE0_REG, cmdWord);
    g_lastStore0 = cmdWord;
    handleMagicBits(cmdWord);
    if (g_role == 1) {
      g_syncPending = true;
      digitalWrite(WB_MASTER_RTT_PIN, HIGH);
      sendEspNowFrame(PKT_CMD);
      uint32_t t0 = micros();
      while (g_syncPending && (micros() - t0) < 8000u) {
        delayMicroseconds(100);
      }
      if (g_syncPending) {
        digitalWrite(WB_MASTER_RTT_PIN, LOW);
        g_lossPkts++;
      }
    }
    char buf[96];
    snprintf(buf, sizeof(buf), "%08X %08X %08X %08X RTT_US:%u LOSS:%u",
      (unsigned)REG_READ(RTC_CNTL_STORE1_REG), (unsigned)REG_READ(RTC_CNTL_STORE2_REG),
      (unsigned)REG_READ(RTC_CNTL_STORE3_REG), (unsigned)REG_READ(RTC_CNTL_STORE4_REG),
      (unsigned)g_rttUs, (unsigned)g_lossPkts);
    return String(buf);
  }
  if (op == "TELEM") {
    char buf[120];
    snprintf(buf, sizeof(buf), "%08X %08X %08X %08X %08X RTT_US:%u RX:%u LOSS:%u",
      (unsigned)REG_READ(RTC_CNTL_STORE0_REG), (unsigned)REG_READ(RTC_CNTL_STORE1_REG),
      (unsigned)REG_READ(RTC_CNTL_STORE2_REG), (unsigned)REG_READ(RTC_CNTL_STORE3_REG),
      (unsigned)REG_READ(RTC_CNTL_STORE4_REG),
      (unsigned)g_rttUs, (unsigned)g_rxPkts, (unsigned)g_lossPkts);
    return String(buf);
  }
  if (op == "PIN") {
    int s2 = rest.indexOf(' ');
    int pin = (s2 < 0) ? rest.toInt() : rest.substring(0, s2).toInt();
    String act = (s2 < 0) ? "READ" : rest.substring(s2 + 1);
    act.trim(); act.toUpperCase();
    if (pin < 0 || pin > 39) return "ERR_PIN";
    if (act == "READ" || act == "R") return String(digitalRead(pin));
    pinMode(pin, OUTPUT);
    int val = digitalRead(pin);
    if (act == "HIGH" || act == "1" || act == "ON") val = 1;
    else if (act == "LOW" || act == "0" || act == "OFF") val = 0;
    else val = !val;
    digitalWrite(pin, val);
    return String(val);
  }
  if (op == "ADC") {
    int pin = rest.toInt();
    analogReadResolution(12);
    analogSetPinAttenuation(pin, ADC_11db);
    return String(analogRead(pin));
  }
  if (op == "DAC") {
    int s2 = rest.indexOf(' ');
    if (s2 < 0) return "ERR_ARGS";
    int pin = rest.substring(0, s2).toInt();
    int val = constrain(rest.substring(s2 + 1).toInt(), 0, 255);
    dacWrite(pin, (uint8_t)val);
    return "DAC_OK";
  }
  if (op == "PWM") {
    int s2 = rest.indexOf(' ');
    int s3 = (s2 < 0) ? -1 : rest.indexOf(' ', s2 + 1);
    if (s2 < 0 || s3 < 0) return "ERR_ARGS";
    int pin = rest.substring(0, s2).toInt();
    long rawFreq = rest.substring(s2 + 1, s3).toInt();
    uint32_t freq = (rawFreq <= 0) ? 0u : (uint32_t)rawFreq;
    uint32_t duty = constrain(rest.substring(s3 + 1).toInt(), 0, 1023);
    writeLedc((uint8_t)pin, 14, freq, 10, duty);
    return "PWM_OK";
  }
  if (op == "PULSE") {
    int s2 = rest.indexOf(' ');
    int pin = (s2 < 0) ? rest.toInt() : rest.substring(0, s2).toInt();
    uint32_t tout = (s2 < 0) ? 50000u : (uint32_t)max(1000L, rest.substring(s2 + 1).toInt());
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
    if (ledcReadFreq((uint8_t)pin) == 0) pinMode(pin, INPUT);
    else if (pin >= 0 && pin < SOC_GPIO_PIN_COUNT && GPIO_PIN_MUX_REG[pin]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);
#else
    pinMode(pin, INPUT);
#endif
    unsigned long hi = pulseIn(pin, HIGH, tout);
    unsigned long lo = pulseIn(pin, LOW, tout);
    unsigned long per = hi + lo;
    float freq = (per > 0) ? (1000000.0f / (float)per) : 0.0f;
    float duty = (per > 0) ? (100.0f * (float)hi / (float)per) : 0.0f;
    char buf[72];
    snprintf(buf, sizeof(buf), "FREQ_HZ:%.2f DUTY_PCT:%.2f HI_US:%lu LO_US:%lu", freq, duty, hi, lo);
    return String(buf);
  }
  if (op == "TOUCH") return String(touchRead(rest.toInt()));
  if (op == "I2C") {
    rest.toUpperCase();
    Wire.begin();
    if (rest.startsWith("SCAN")) {
      String found = "";
      for (uint8_t a = 1; a < 127; ++a) {
        Wire.beginTransmission(a);
        if (Wire.endTransmission() == 0) {
          char h[8]; snprintf(h, sizeof(h), "0x%02X", a);
          if (found.length() > 0) found += ',';
          found += h;
        }
      }
      return "I2C_FOUND:" + (found.length() ? found : String("NONE"));
    }
    if (rest.startsWith("READ")) {
      int a, r, n = 1;
      if (sscanf(rest.c_str(), "READ %i %i %i", &a, &r, &n) < 2) return "ERR_ARGS";
      Wire.beginTransmission((uint8_t)a);
      Wire.write((uint8_t)r);
      Wire.endTransmission(false);
      Wire.requestFrom((uint8_t)a, (uint8_t)constrain(n, 1, 16));
      String out;
      while (Wire.available()) {
        char h[6]; snprintf(h, sizeof(h), "%02X ", Wire.read());
        out += h;
      }
      out.trim();
      return out.length() ? out : "ERR_NACK";
    }
    if (rest.startsWith("WRITE")) {
      int a, r, v;
      if (sscanf(rest.c_str(), "WRITE %i %i %i", &a, &r, &v) < 3) return "ERR_ARGS";
      Wire.beginTransmission((uint8_t)a);
      Wire.write((uint8_t)r);
      Wire.write((uint8_t)v);
      return (Wire.endTransmission() == 0) ? "I2C_WR_OK" : "ERR_NACK";
    }
    return "ERR_I2C_SUB";
  }
  if (op == "SPI") {
    int cs = 5; unsigned tx = 0;
    if (sscanf(rest.c_str(), "%d %i", &cs, (int*)&tx) < 2) return "ERR_ARGS";
    pinMode(cs, OUTPUT);
    digitalWrite(cs, HIGH);
    SPI.begin();
    SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
    digitalWrite(cs, LOW);
    uint8_t rx = SPI.transfer((uint8_t)tx);
    digitalWrite(cs, HIGH);
    SPI.endTransaction();
    char h[8]; snprintf(h, sizeof(h), "0x%02X", rx);
    return String(h);
  }
  if (op == "BEEP") {
    int pin = 4, freq = 1200, ms = 150;
    sscanf(rest.c_str(), "%d %d %d", &pin, &freq, &ms);
    writeLedc((uint8_t)pin, 15, (uint32_t)max(50, freq), 10, 512);
    delay(constrain(ms, 10, 2000));
    writeLedc((uint8_t)pin, 15, (uint32_t)max(50, freq), 10, 0);
    return "BEEP_OK";
  }
  if (op == "UI") {
    rest.toUpperCase();
    g_uiId = (rest == "AGV") ? 1 : 0;
    return (g_uiId == 1) ? "AGV_COCKPIT" : "UDE_WORKBENCH";
  }
  if (op == "ROLE") {
    rest.toUpperCase();
    if (rest == "MASTER") {
      g_role = 1;
      pinMode(WB_MASTER_RTT_PIN, OUTPUT);
      digitalWrite(WB_MASTER_RTT_PIN, LOW);
    } else if (rest == "SLAVE") {
      g_role = 2;
    } else {
      g_role = 0;
    }
    return String("ROLE_OK:") + roleName(g_role);
  }
  if (op == "POWER") {
    applyPowerProfile(rest);
    return "POWER_OK:" + String(getCpuFrequencyMhz()) + "MHZ";
  }
  if (op == "ESPNOW") {
    rest.toUpperCase();
    if (rest == "PING") {
      if (g_role == 1) {
        g_pongWait = true;
        g_pingTxUs = micros();
        digitalWrite(WB_MASTER_RTT_PIN, HIGH);
        sendEspNowFrame(PKT_PING, g_pingTxUs);
        uint32_t t0 = millis();
        while (g_pongWait && (millis() - t0) < 25u) { delay(1); }
        if (g_pongWait) {
          digitalWrite(WB_MASTER_RTT_PIN, LOW);
          g_lossPkts++;
        }
      } else {
        sendEspNowFrame(PKT_BEACON);
      }
    }
    char buf[112];
    snprintf(buf, sizeof(buf), "ESPNOW_STAT ROLE:%s PEER:%d TX:%u RX:%u LOSS:%u RTT_US:%u",
      roleName(g_role), g_hasPeer ? 1 : 0, (unsigned)g_txPkts, (unsigned)g_rxPkts,
      (unsigned)g_lossPkts, (unsigned)g_rttUs);
    return String(buf);
  }
  if (op == "OTA_PREP") {
    g_otaArmed = true;
    REG_WRITE(RTC_CNTL_STORE0_REG, 0x10000000u);
    if (g_btUp) { g_bt.end(); g_btUp = false; }
    return "OTA_PREP_OK";
  }
  return "ERR_CMD";
}

static void setupHttpRoutes() {
  g_http.on("/", HTTP_GET, []() {
    g_http.send(200, "text/html; charset=utf-8", (g_uiId == 1) ? HTML_AGV_UI : HTML_UDE_UI);
  });
  g_http.on("/ude", HTTP_GET, []() {
    g_http.send(200, "text/html; charset=utf-8", HTML_UDE_UI);
  });
  g_http.on("/agv", HTTP_GET, []() {
    g_http.send(200, "text/html; charset=utf-8", HTML_AGV_UI);
  });
  g_http.on("/cmd", HTTP_GET, []() {
    if (!g_http.hasArg("q")) { g_http.send(400, "text/plain", "ERR_NO_Q"); return; }
    g_http.send(200, "text/plain", processCommand(g_http.arg("q")));
  });
  g_http.on("/ota", HTTP_POST,
    []() {
      bool ok = !Update.hasError();
      g_http.send(ok ? 200 : 500, "text/plain", ok ? "OTA_OK" : "OTA_FAIL");
      delay(250);
      if (ok) ESP.restart();
    },
    []() {
      HTTPUpload& up = g_http.upload();
      if (up.status == UPLOAD_FILE_START) {
        REG_WRITE(RTC_CNTL_STORE0_REG, 0x10000000u);
        if (g_btUp) { g_bt.end(); g_btUp = false; }
        Update.begin(UPDATE_SIZE_UNKNOWN);
      } else if (up.status == UPLOAD_FILE_WRITE) {
        Update.write(up.buf, up.currentSize);
      } else if (up.status == UPLOAD_FILE_END) {
        Update.end(true);
      }
    });
}

static void core0DaemonTask(void*) {
  uint32_t lastBeaconMs = 0;
  static String serBuf, btBuf;
  for (;;) {
    if (g_httpUp) g_http.handleClient();

    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c == '\n') {
        String out = processCommand(serBuf);
        serBuf = "";
        if (out.length()) Serial.println(out);
      } else if (c != '\r' && serBuf.length() < 256) {
        serBuf += c;
      }
    }
    while (g_btUp && g_bt.available()) {
      char c = (char)g_bt.read();
      if (c == '\n') {
        String out = processCommand(btBuf);
        btBuf = "";
        if (out.length()) g_bt.println(out);
      } else if (c != '\r' && btBuf.length() < 256) {
        btBuf += c;
      }
    }
    if ((g_role == 1 || g_role == 2) && !g_hasPeer && (millis() - lastBeaconMs) > 500u) {
      lastBeaconMs = millis();
      sendEspNowFrame(PKT_BEACON);
    }
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void setup() {
  esp_log_level_set("*", ESP_LOG_NONE);
  Serial.begin(115200);
  Serial.setTimeout(25);
  REG_WRITE(RTC_CNTL_STORE0_REG, 0x10000000u);

  if (WB_NODE_ROLE == 1) {
    pinMode(WB_MASTER_RTT_PIN, OUTPUT);
    digitalWrite(WB_MASTER_RTT_PIN, LOW);
  }

  setupHttpRoutes();

  if (g_role == 2) {
    WiFi.mode(WIFI_STA);
    esp_wifi_set_channel(WB_ESPNOW_CH, WIFI_SECOND_CHAN_NONE);
    esp_wifi_set_ps(WIFI_PS_NONE);
  } else {
    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP(WB_AP_SSID, WB_AP_PASS, WB_ESPNOW_CH);
    g_http.begin();
    g_httpUp = true;
    g_bt.begin(WB_BT_NAME);
    g_btUp = true;
  }

  if (esp_now_init() == ESP_OK) {
    esp_now_register_recv_cb(onEspNowRecv);
    ensurePeerAdded(g_bcastMac);
  }

  user_setup();
  xTaskCreatePinnedToCore(core0DaemonTask, "wb_core0", 8192, nullptr, 2, nullptr, 0);
  Serial.println("ESP32_READY");
}

{{USER_SKETCH_CODE}}