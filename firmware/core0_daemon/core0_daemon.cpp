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

#define WB_BUILD_ID   "{{FW_BUILD_ID}}"
#define WB_NODE_ROLE  {{NODE_ROLE_ID}}
#define WB_RADIO_MODE {{RADIO_MODE_ID}}
#define WB_ENABLE_BT  {{ENABLE_BT}}
#define WB_HAS_APP_UI {{HAS_APP_UI}}
#define WB_AP_SSID    "{{WB_AP_SSID}}"
#define WB_AP_PASS    "{{WB_AP_PASS}}"
#define WB_BT_NAME    "{{WB_BT_NAME}}"
#define WB_ESPNOW_CH  {{WB_ESPNOW_CH}}
#define WB_RTT_PIN    4

void user_setup();

static const char* HTML_UDE_UI = R"WB_UI_UDE({{WEB_UI_UDE_HTML}})WB_UI_UDE";
static const char* HTML_APP_UI = R"WB_UI_APP({{WEB_UI_APP_HTML}})WB_UI_APP";

static WebServer g_http(80);
static BluetoothSerial g_bt;
static portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;

static volatile uint8_t  g_role = WB_NODE_ROLE, g_radio = WB_RADIO_MODE, g_uiId = WB_HAS_APP_UI;
static volatile bool     g_httpUp = false, g_btUp = false, g_hasPeer = false, g_syncPending = false, g_pongWait = false;
static uint8_t           g_peerMac[6] = {0}, g_bcastMac[6] = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
static volatile uint16_t g_seq = 0;
static volatile uint32_t g_txPkts = 0, g_rxPkts = 0, g_lossPkts = 0, g_rttUs = 0;

enum WbMsgType : uint8_t { PKT_BEACON = 1, PKT_CMD = 2, PKT_TLM = 3, PKT_PING = 4, PKT_PONG = 5 };
typedef struct __attribute__((packed)) {
  uint32_t magic; uint8_t type, role; uint16_t seq; uint32_t txUs, s0, s1, s2, s3, s4, crc;
} WbEspNowFrame;

static uint32_t calcCrc(const WbEspNowFrame& f) {
  const uint8_t* p = reinterpret_cast<const uint8_t*>(&f); uint32_t h = 2166136261u;
  for (size_t i = 0; i < sizeof(WbEspNowFrame) - sizeof(uint32_t); ++i) { h ^= p[i]; h *= 16777619u; }
  return h;
}

static inline void writeLedc(uint8_t pin, uint8_t ch, uint32_t freq, uint8_t res, uint32_t duty) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcDetach(pin);
  if (freq == 0 || duty == 0) { pinMode(pin, OUTPUT); digitalWrite(pin, LOW); }
  else { ledcAttach(pin, freq, res); ledcWrite(pin, duty); if (pin < SOC_GPIO_PIN_COUNT && GPIO_PIN_MUX_REG[pin]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]); }
#else
  ledcSetup(ch, freq, res); ledcAttachPin(pin, ch); ledcWrite(ch, duty);
  if (pin < SOC_GPIO_PIN_COUNT && GPIO_PIN_MUX_REG[pin]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[pin]);
#endif
  (void)ch;
}

static const char* roleStr(uint8_t r) { return (r==1)?"MASTER":((r==2)?"SLAVE":"STANDALONE"); }

static void ensurePeer(const uint8_t* mac) {
  if (g_radio == 2 || esp_now_is_peer_exist(mac)) return;
  esp_now_peer_info_t peer = {}; memcpy(peer.peer_addr, mac, 6);
  peer.channel = WB_ESPNOW_CH; peer.ifidx = WIFI_IF_STA; peer.encrypt = false;
  esp_now_add_peer(&peer);
}

static void sendFrame(uint8_t type, uint32_t txOverride = 0) {
  if (g_radio == 2) return;
  WbEspNowFrame f = {}; f.magic = 0x57424E31u; f.type = type; f.role = g_role; f.seq = ++g_seq;
  f.txUs = txOverride ? txOverride : micros();
  f.s0 = REG_READ(RTC_CNTL_STORE0_REG); f.s1 = REG_READ(RTC_CNTL_STORE1_REG);
  f.s2 = REG_READ(RTC_CNTL_STORE2_REG); f.s3 = REG_READ(RTC_CNTL_STORE3_REG); f.s4 = REG_READ(RTC_CNTL_STORE4_REG);
  f.crc = calcCrc(f);
  const uint8_t* dst = (g_hasPeer && type != PKT_BEACON) ? g_peerMac : g_bcastMac;
  if (esp_now_send(dst, reinterpret_cast<const uint8_t*>(&f), sizeof(f)) == ESP_OK) g_txPkts++;
}

#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
static void onEspNowRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
  const uint8_t* mac = info ? info->src_addr : nullptr;
#else
static void onEspNowRecv(const uint8_t* mac, const uint8_t* data, int len) {
#endif
  if (!mac || len != (int)sizeof(WbEspNowFrame)) return;
  WbEspNowFrame f; memcpy(&f, data, sizeof(f));
  if (f.magic != 0x57424E31u || f.crc != calcCrc(f)) return;
  portENTER_CRITICAL_ISR(&g_mux);
  if (!g_hasPeer && f.role != g_role && f.role != 0) { memcpy(g_peerMac, mac, 6); g_hasPeer = true; }
  g_rxPkts++;
  portEXIT_CRITICAL_ISR(&g_mux);
  ensurePeer(mac);

  if (g_role == 2) {
    if (f.type == PKT_CMD) { REG_WRITE(RTC_CNTL_STORE0_REG, f.s0); sendFrame(PKT_TLM, f.txUs); }
    else if (f.type == PKT_PING) sendFrame(PKT_PONG, f.txUs);
  } else if (g_role == 1 && (f.type == PKT_TLM || f.type == PKT_PONG)) {
    uint32_t now = micros(); digitalWrite(WB_RTT_PIN, LOW); g_rttUs = now - f.txUs;
    if (f.type == PKT_TLM) {
      REG_WRITE(RTC_CNTL_STORE1_REG, f.s1); REG_WRITE(RTC_CNTL_STORE2_REG, f.s2);
      REG_WRITE(RTC_CNTL_STORE3_REG, f.s3); REG_WRITE(RTC_CNTL_STORE4_REG, f.s4);
      g_syncPending = false;
    }
    g_pongWait = false;
  }
}

static bool parseHex(const String& tok, uint32_t& out) {
  String s = tok; s.trim(); if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2);
  if (!s.length()) return false; char* e = nullptr; out = strtoul(s.c_str(), &e, 16); return (e != s.c_str());
}

static String processCommand(const String& rawIn) {
  String cmd = rawIn; cmd.trim(); if (!cmd.length()) return "";
  int sp = cmd.indexOf(' '); String op = (sp<0)?cmd:cmd.substring(0,sp); String rest = (sp<0)?"":cmd.substring(sp+1);
  op.toUpperCase(); rest.trim();

  if (op == "STATUS") {
    char b[192]; snprintf(b, sizeof(b), "ESP32_READY|ROLE:%s|RADIO:%s|ID:%s|IP:%s|MHZ:%u|PEER:%d",
      roleStr(g_role), (g_radio==2?"USB_ONLY":(g_radio==1?"STA_NOW":"AP_NOW")), WB_BUILD_ID,
      (g_radio==2?"0.0.0.0":WiFi.softAPIP().toString().c_str()), (unsigned)getCpuFrequencyMhz(), g_hasPeer?1:0);
    return String(b);
  }
  if (op == "INFO") {
    char b[200]; snprintf(b, sizeof(b), "ID:%s ROLE:%s HEAP_FREE:%u FLASH_MB:%u SKETCH_KB:%u OTA_FREE_KB:%u MHZ:%u",
      WB_BUILD_ID, roleStr(g_role), (unsigned)ESP.getFreeHeap(), (unsigned)(ESP.getFlashChipSize()/1048576u),
      (unsigned)(ESP.getSketchSize()/1024u), (unsigned)(ESP.getFreeSketchSpace()/1024u), (unsigned)getCpuFrequencyMhz());
    return String(b);
  }
  if (op == "R" || op == "REG") {
    uint32_t a=0; if (!parseHex(rest,a)||(a&3)||a<0x3FF00000u||a>0x3FF80000u) return "ERR_ADDR";
    char o[12]; snprintf(o,sizeof(o),"%08X",(unsigned)*reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a))); return String(o);
  }
  if (op == "W") {
    int s2 = rest.indexOf(' '); if (s2<0) return "ERR_ARGS"; uint32_t a=0, v=0;
    if (!parseHex(rest.substring(0,s2),a)||!parseHex(rest.substring(s2+1),v)) return "ERR_HEX";
    if ((a&3)||a<0x3FF00000u||a>0x3FF80000u) return "ERR_ADDR";
    *reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a)) = v;
    if (a == RTC_CNTL_STORE0_REG && g_role == 1) sendFrame(PKT_CMD);
    char o[12]; snprintf(o,sizeof(o),"%08X",(unsigned)*reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a))); return String(o);
  }
  if (op == "D") {
    int s2 = rest.indexOf(' '); uint32_t a=0; int cnt=8;
    if (s2<0) { if (!parseHex(rest,a)) return "ERR_ADDR"; } else { if (!parseHex(rest.substring(0,s2),a)) return "ERR_ADDR"; cnt=constrain(rest.substring(s2+1).toInt(),1,64); }
    if ((a&3)||a<0x3FF00000u||a>0x3FF80000u) return "ERR_ADDR";
    String out; for (int i=0;i<cnt;++i){ char h[12]; snprintf(h,sizeof(h),"%08X",(unsigned)*reinterpret_cast<volatile uint32_t*>(static_cast<uintptr_t>(a+i*4))); if(i>0)out+=' '; out+=h; } return out;
  }
  if (op == "SYNC") {
    uint32_t cw=0; if (!parseHex(rest,cw)) return "ERR_HEX";
    REG_WRITE(RTC_CNTL_STORE0_REG, cw);
    if (g_role == 1) {
      g_syncPending = true; digitalWrite(WB_RTT_PIN, HIGH); sendFrame(PKT_CMD);
      uint32_t t0 = micros(); while (g_syncPending && (micros()-t0) < 8000u) delayMicroseconds(100);
      if (g_syncPending) { digitalWrite(WB_RTT_PIN, LOW); g_lossPkts++; }
    }
    char b[96]; snprintf(b,sizeof(b),"%08X %08X %08X %08X RTT_US:%u LOSS:%u",
      (unsigned)REG_READ(RTC_CNTL_STORE1_REG),(unsigned)REG_READ(RTC_CNTL_STORE2_REG),
      (unsigned)REG_READ(RTC_CNTL_STORE3_REG),(unsigned)REG_READ(RTC_CNTL_STORE4_REG),(unsigned)g_rttUs,(unsigned)g_lossPkts);
    return String(b);
  }
  if (op == "TELEM") {
    char b[120]; snprintf(b,sizeof(b),"%08X %08X %08X %08X %08X RTT_US:%u RX:%u LOSS:%u",
      (unsigned)REG_READ(RTC_CNTL_STORE0_REG),(unsigned)REG_READ(RTC_CNTL_STORE1_REG),(unsigned)REG_READ(RTC_CNTL_STORE2_REG),
      (unsigned)REG_READ(RTC_CNTL_STORE3_REG),(unsigned)REG_READ(RTC_CNTL_STORE4_REG),(unsigned)g_rttUs,(unsigned)g_rxPkts,(unsigned)g_lossPkts);
    return String(b);
  }
  if (op == "PIN") {
    int s2=rest.indexOf(' '), pin=(s2<0)?rest.toInt():rest.substring(0,s2).toInt();
    String act=(s2<0)?"READ":rest.substring(s2+1); act.trim(); act.toUpperCase();
    if (pin<0||pin>39) return "ERR_PIN"; if (act=="READ"||act=="R") return String(digitalRead(pin));
    pinMode(pin,OUTPUT); int v=digitalRead(pin); if(act=="HIGH"||act=="1"||act=="ON")v=1; else if(act=="LOW"||act=="0"||act=="OFF")v=0; else v=!v;
    digitalWrite(pin,v); return String(v);
  }
  if (op == "ADC") { int p=rest.toInt(); analogReadResolution(12); analogSetPinAttenuation(p,ADC_11db); return String(analogRead(p)); }
  if (op == "DAC") { int s2=rest.indexOf(' '); if(s2<0)return"ERR"; dacWrite(rest.substring(0,s2).toInt(),(uint8_t)constrain(rest.substring(s2+1).toInt(),0,255)); return "DAC_OK"; }
  if (op == "PWM") {
    int s2=rest.indexOf(' '), s3=(s2<0)?-1:rest.indexOf(' ',s2+1); if(s2<0||s3<0)return"ERR";
    int p=rest.substring(0,s2).toInt(); long rf=rest.substring(s2+1,s3).toInt();
    writeLedc((uint8_t)p, 14, rf<=0?0u:(uint32_t)rf, 10, constrain(rest.substring(s3+1).toInt(),0,1023)); return "PWM_OK";
  }
  if (op == "PULSE") {
    int s2=rest.indexOf(' '), p=(s2<0)?rest.toInt():rest.substring(0,s2).toInt();
    uint32_t tout=(s2<0)?50000u:(uint32_t)max(1000L,rest.substring(s2+1).toInt());
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
    if (ledcReadFreq((uint8_t)p)==0) pinMode(p,INPUT); else if(p>=0&&p<SOC_GPIO_PIN_COUNT&&GPIO_PIN_MUX_REG[p]) PIN_INPUT_ENABLE(GPIO_PIN_MUX_REG[p]);
#else
    pinMode(p,INPUT);
#endif
    unsigned long hi=pulseIn(p,HIGH,tout), lo=pulseIn(p,LOW,tout), per=hi+lo;
    char b[72]; snprintf(b,sizeof(b),"FREQ_HZ:%.2f DUTY_PCT:%.2f HI_US:%lu LO_US:%lu", per?(1e6f/per):0.0f, per?(100.0f*hi/per):0.0f, hi, lo); return String(b);
  }
  if (op == "TOUCH") return String(touchRead(rest.toInt()));
  if (op == "I2C") {
    Wire.begin(); rest.toUpperCase();
    if (rest.startsWith("SCAN")) {
      String f=""; for(uint8_t a=1;a<127;++a){ Wire.beginTransmission(a); if(Wire.endTransmission()==0){ char h[8]; snprintf(h,sizeof(h),"0x%02X",a); if(f.length())f+=','; f+=h; } }
      return "I2C_FOUND:" + (f.length()?f:String("NONE"));
    }
    return "ERR_I2C";
  }
  if (op == "SPI") {
    int cs=5; unsigned tx=0; if(sscanf(rest.c_str(),"%d %i",&cs,(int*)&tx)<2)return"ERR";
    pinMode(cs,OUTPUT); digitalWrite(cs,HIGH); SPI.begin(); SPI.beginTransaction(SPISettings(1000000,MSBFIRST,SPI_MODE0));
    digitalWrite(cs,LOW); uint8_t rx=SPI.transfer((uint8_t)tx); digitalWrite(cs,HIGH); SPI.endTransaction();
    char h[8]; snprintf(h,sizeof(h),"0x%02X",rx); return String(h);
  }
  if (op == "POWER") {
    rest.toUpperCase();
    if (rest=="ECO") { setCpuFrequencyMhz(80); if(g_radio!=2) esp_wifi_set_ps(WIFI_PS_MIN_MODEM); if(g_btUp){g_bt.end();g_btUp=false;} }
    else if (rest=="BALANCED") { setCpuFrequencyMhz(160); if(g_radio!=2) esp_wifi_set_ps(WIFI_PS_NONE); if(g_btUp){g_bt.end();g_btUp=false;} }
    else { setCpuFrequencyMhz(240); if(g_radio!=2) esp_wifi_set_ps(WIFI_PS_NONE); }
    return "POWER_OK:" + String(getCpuFrequencyMhz()) + "MHZ";
  }
  if (op == "UI") { rest.toUpperCase(); g_uiId = (rest=="APP"||rest=="AGV")?1:0; return g_uiId?"APP_UI":"UDE_WORKBENCH"; }
  if (op == "ROLE") {
    rest.toUpperCase();
    if(rest=="MASTER"){g_role=1;pinMode(WB_RTT_PIN,OUTPUT);digitalWrite(WB_RTT_PIN,LOW);} else if(rest=="SLAVE")g_role=2; else g_role=0;
    return String("ROLE_OK:") + roleStr(g_role);
  }
  if (op == "ESPNOW") {
    rest.toUpperCase();
    if (rest=="PING" && g_role==1) {
      g_pongWait=true; uint32_t tx=micros(); digitalWrite(WB_RTT_PIN,HIGH); sendFrame(PKT_PING, tx);
      uint32_t t0=millis(); while(g_pongWait && (millis()-t0)<25u) delay(1);
      if(g_pongWait){ digitalWrite(WB_RTT_PIN,LOW); g_lossPkts++; }
    } else if (rest=="PING" && g_role==2) sendFrame(PKT_BEACON);
    char b[112]; snprintf(b,sizeof(b),"ESPNOW_STAT ROLE:%s PEER:%d TX:%u RX:%u LOSS:%u RTT_US:%u",
      roleStr(g_role), g_hasPeer?1:0, (unsigned)g_txPkts, (unsigned)g_rxPkts, (unsigned)g_lossPkts, (unsigned)g_rttUs);
    return String(b);
  }
  if (op == "OTA_PREP") { REG_WRITE(RTC_CNTL_STORE0_REG, 0x10000000u); if(g_btUp){g_bt.end();g_btUp=false;} return "OTA_PREP_OK"; }
  return "ERR_CMD";
}

static void sendHtml(const char* html) { g_http.sendHeader("Connection","close"); g_http.send(200, "text/html; charset=utf-8", html); }

static void setupHttp() {
  g_http.on("/", HTTP_GET, []() { sendHtml(g_uiId ? HTML_APP_UI : HTML_UDE_UI); });
  g_http.on("/ude", HTTP_GET, []() { sendHtml(HTML_UDE_UI); });
  g_http.on("/app", HTTP_GET, []() { sendHtml(HTML_APP_UI); });
  g_http.on("/agv", HTTP_GET, []() { sendHtml(HTML_APP_UI); });
  g_http.on("/cmd", HTTP_GET, []() {
    g_http.sendHeader("Connection", "close");
    if (!g_http.hasArg("q")) { g_http.send(400, "text/plain", "ERR_NO_Q"); return; }
    g_http.send(200, "text/plain", processCommand(g_http.arg("q")));
  });
  g_http.on("/ota", HTTP_POST,
    []() { g_http.sendHeader("Connection","close"); bool ok=!Update.hasError(); g_http.send(ok?200:500,"text/plain",ok?"OTA_OK":"OTA_FAIL"); delay(250); if(ok)ESP.restart(); },
    []() {
      HTTPUpload& up = g_http.upload();
      if (up.status==UPLOAD_FILE_START) { REG_WRITE(RTC_CNTL_STORE0_REG,0x10000000u); if(g_btUp){g_bt.end();g_btUp=false;} Update.begin(UPDATE_SIZE_UNKNOWN); }
      else if (up.status==UPLOAD_FILE_WRITE) Update.write(up.buf, up.currentSize);
      else if (up.status==UPLOAD_FILE_END) Update.end(true);
    });
}

static void core0Task(void*) {
  uint32_t lastBcn = 0; static String serBuf, btBuf;
  for (;;) {
    if (g_httpUp) g_http.handleClient();
    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c=='\n') { String o = processCommand(serBuf); serBuf=""; if(o.length()) Serial.println(o); }
      else if (c!='\r' && serBuf.length()<256) serBuf += c;
    }
    while (g_btUp && g_bt.available()) {
      char c = (char)g_bt.read();
      if (c=='\n') { String o = processCommand(btBuf); btBuf=""; if(o.length()) g_bt.println(o); }
      else if (c!='\r' && btBuf.length()<256) btBuf += c;
    }
    if (g_radio != 2 && (g_role == 1 || g_role == 2) && !g_hasPeer && (millis()-lastBcn) > 500u) {
      lastBcn = millis(); sendFrame(PKT_BEACON);
    }
    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void setup() {
  esp_log_level_set("*", ESP_LOG_NONE);
  Serial.begin(115200); Serial.setTimeout(25);
  REG_WRITE(RTC_CNTL_STORE0_REG, 0x10000000u);
  if (WB_NODE_ROLE == 1) { pinMode(WB_RTT_PIN, OUTPUT); digitalWrite(WB_RTT_PIN, LOW); }

  if (g_radio != 2) {
    setupHttp();
    if (g_radio == 1) {
      WiFi.mode(WIFI_STA); esp_wifi_set_channel(WB_ESPNOW_CH, WIFI_SECOND_CHAN_NONE); esp_wifi_set_ps(WIFI_PS_NONE);
    } else {
      WiFi.mode(WIFI_AP_STA); WiFi.softAP(WB_AP_SSID, WB_AP_PASS, WB_ESPNOW_CH);
      g_http.begin(); g_httpUp = true;
      if (WB_ENABLE_BT) { g_bt.begin(WB_BT_NAME); g_btUp = true; }
    }
    if (esp_now_init() == ESP_OK) { esp_now_register_recv_cb(onEspNowRecv); ensurePeer(g_bcastMac); }
  }

  user_setup();
  xTaskCreatePinnedToCore(core0Task, "wb_core0", 8192, nullptr, 2, nullptr, 0);
  Serial.println("ESP32_READY");
}

{{USER_SKETCH_CODE}}
