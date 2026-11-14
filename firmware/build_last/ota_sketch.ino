// ============================================================================
// FILE: firmware/core0_daemon/core0_daemon.cpp
// DESCRIPTION: Modular Core-0 Hardware-in-the-Loop (HIL), Register, Web Portal,
//              Wi-Fi SoftAP OTA, USB Serial & Bluetooth Classic SPP Daemon.
//              Concatenated automatically with web_ui.html and <sketch>.ino
//              by esp32_flash.m during compilation.
// ============================================================================

#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Update.h>
#include <Wire.h>
#include <SPI.h>
#include "BluetoothSerial.h"
#include "esp_bt.h"
#include "soc/gpio_reg.h"
#include "soc/rtc_cntl_reg.h"
#include "esp_ota_ops.h"

#define _FW_BUILD_ID "BLD_ESP32BRIDGEO_210154"

void user_setup();
static WebServer _bgServer(80);
static BluetoothSerial _bgSerialBT;
static volatile bool _otaInProgress = false;
static volatile bool _btActive = true;
static size_t _otaWritten = 0;

// Direct IO_MUX FUN_IE (Bit 9) Input Buffer Enabler (Compatible with ESP-IDF 5.x / Core 3.3.12)
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

// Bare-Metal Register Pulse-Width, Frequency & Duty-Cycle Analyzer
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

// Injected HTML/JS Payload from firmware/core0_daemon/web_ui.html
static const char _WEB_UI[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>ESP32 On-Chip Register & HIL Workbench</title>
  <style>
    body{font-family:Consolas,monospace;background:#14171f;color:#e2e8f0;margin:0;padding:16px}
    h2{color:#38bdf8;margin-top:0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:14px}
    .card{background:#1e2330;border:1px solid #334155;border-radius:8px;padding:14px}
    button{background:#2563eb;color:#fff;border:none;padding:8px 12px;border-radius:5px;cursor:pointer;font-family:inherit;margin:3px}
    button.on{background:#16a34a}button.off{background:#dc2626}button.warn{background:#d97706}
    input,select{background:#0f172a;color:#38bdf8;border:1px solid #475569;padding:7px;border-radius:4px;font-family:inherit}
    table{width:100%;border-collapse:collapse;margin-top:8px;font-size:13px}th,td{border:1px solid #334155;padding:6px;text-align:left}
    .bits{display:grid;grid-template-columns:repeat(8,1fr);gap:3px;margin-top:8px}
    .bitbtn{padding:4px;font-size:11px;background:#334155}.bitbtn.high{background:#16a34a;font-weight:bold}
    #log{background:#090b10;color:#4ade80;padding:10px;height:140px;overflow-y:auto;border-radius:6px;white-space:pre-wrap;font-size:12px}
    #pbar{width:100%;background:#0f172a;border:1px solid #475569;border-radius:4px;height:18px;margin-top:6px;display:none}
    #pfill{height:100%;background:#16a34a;width:0%;transition:width 0.2s}
  </style>
</head>
<body>
  <h2>UDE-Lite ESP32 Web Register & HIL Workbench (BLD_ESP32BRIDGEO_210154)</h2>
  <div class="grid">
    <div class="card">
      <h3>1. Quick Pin, DAC, PWM & Bus Control</h3>
      <div>
        GPIO 2 (LED):
        <button class="on" onclick="cmd('PIN 2 HIGH')">HIGH</button>
        <button class="off" onclick="cmd('PIN 2 LOW')">LOW</button>
        <button onclick="cmd('PIN 2 TOGGLE')">TOGGLE</button>
      </div>
      <div style="margin-top:6px">
        DAC D25 (0..255):
        <button onclick="cmd('DAC 25 0')">0V</button>
        <button onclick="cmd('DAC 25 128')">1.65V</button>
        <button onclick="cmd('DAC 25 255')">3.3V</button>
        <button class="warn" onclick="cmd('I2C SCAN')">I2C Scan (D21/D22)</button>
      </div>
      <div style="margin-top:6px">
        Dynamic Beep Interval (RTC_CNTL_STORE0_REG 0x3FF4804C):<br>
        <button onclick="writeReg('0x3FF4804C','0x00000096')">Fast (150 ms)</button>
        <button onclick="writeReg('0x3FF4804C','0x000003E8')">Medium (1000 ms)</button>
        <button onclick="writeReg('0x3FF4804C','0x00000BB8')">Slow (3000 ms)</button>
      </div>
    </div>

    <div class="card">
      <h3>2. Direct 32-Bit SFR Register Inspector</h3>
      <select id="preset" onchange="document.getElementById('addr').value=this.value;readReg()">
        <option value="0x3FF44004">GPIO_OUT_REG (0x3FF44004)</option>
        <option value="0x3FF44008">GPIO_OUT_W1TS_REG (0x3FF44008)</option>
        <option value="0x3FF4400C">GPIO_OUT_W1TC_REG (0x3FF4400C)</option>
        <option value="0x3FF44020">GPIO_ENABLE_REG (0x3FF44020)</option>
        <option value="0x3FF44024">GPIO_ENABLE_W1TS_REG (0x3FF44024)</option>
        <option value="0x3FF4403C">GPIO_IN_REG (0x3FF4403C)</option>
        <option value="0x3FF49040">IO_MUX_GPIO2_REG (0x3FF49040)</option>
        <option value="0x3FF4804C">RTC_CNTL_STORE0_REG (0x3FF4804C)</option>
      </select><br><br>
      Addr: <input id="addr" value="0x3FF44004" size="11">
      Val: <input id="val" value="0x00000004" size="11"><br><br>
      <button onclick="readReg()">Read Register</button>
      <button class="warn" onclick="writeReg(document.getElementById('addr').value,document.getElementById('val').value)">Write Register</button>
      <div class="bits" id="bitgrid"></div>
    </div>

    <div class="card">
      <h3>3. Backend Command & OTA Firmware Upload</h3>
      Raw CLI: <input id="rawq" value="INFO" size="18">
      <button onclick="cmd(document.getElementById('rawq').value)">Send</button>
      <button onclick="refreshTable()">Refresh SFR Table</button>
      <hr style="border-color:#334155">
      <input type="file" id="otafile" accept=".bin">
      <button class="warn" onclick="uploadOta()">Flash .bin (OTA)</button>
      <div id="pbar"><div id="pfill"></div></div>
      <div id="otastatus" style="font-size:12px;margin-top:4px;color:#38bdf8"></div>
    </div>
  </div>

  <div class="card" style="margin-top:14px">
    <h3>4. Live Peripheral Registers Map</h3>
    <table>
      <thead><tr><th>Register</th><th>Address</th><th>Hex Value</th><th>Binary (31..0)</th></tr></thead>
      <tbody id="regtbl"></tbody>
    </table>
  </div>

  <div class="card" style="margin-top:14px">
    <h3>Backend Execution Log</h3>
    <div id="log">Ready. Connected to ESP32 Backend (BLD_ESP32BRIDGEO_210154).</div>
  </div>

  <script>
    const REGS=[
      ["GPIO_OUT_REG","0x3FF44004"],
      ["GPIO_ENABLE_REG","0x3FF44020"],
      ["GPIO_IN_REG","0x3FF4403C"],
      ["IO_MUX_GPIO2_REG","0x3FF49040"],
      ["RTC_CNTL_STORE0_REG","0x3FF4804C"]
    ];
    let curRegVal=0, otaBusy=false;
    function log(m){const el=document.getElementById("log");el.textContent="["+new Date().toLocaleTimeString()+"] "+m+"\n"+el.textContent;}
    async function cmd(q){if(otaBusy)return "";const r=await fetch("/cmd?q="+encodeURIComponent(q));const t=await r.text();log("CMD \""+q+"\" -> "+t.trim());return t.trim();}
    function toBin32(v){return (v>>>0).toString(2).padStart(32,"0").replace(/(.{4})/g,"$1_").slice(0,-1);}
    function renderBits(v){
      curRegVal=v>>>0;const g=document.getElementById("bitgrid");g.innerHTML="";
      for(let b=31;b>=0;b--){
        const bit=(curRegVal>>>b)&1;const btn=document.createElement("button");
        btn.className="bitbtn "+(bit?"high":"");btn.textContent="B"+b+":"+bit;
        btn.onclick=()=>{const next=(curRegVal^(1<<b))>>>0;writeReg(document.getElementById("addr").value,"0x"+next.toString(16).toUpperCase().padStart(8,"0"));};
        g.appendChild(btn);
      }
    }
    async function readReg(){if(otaBusy)return;const a=document.getElementById("addr").value;const t=await cmd("R "+a.replace(/^0x/i,""));document.getElementById("val").value=t;renderBits(parseInt(t,16));}
    async function writeReg(a,v){if(otaBusy)return;document.getElementById("addr").value=a;document.getElementById("val").value=v;const t=await cmd("W "+a.replace(/^0x/i,"")+" "+v.replace(/^0x/i,""));renderBits(parseInt(t,16));refreshTable();}
    async function refreshTable(){
      if(otaBusy)return;let html="";
      for(const [n,a] of REGS){
        if(otaBusy)return;
        const r=await fetch("/cmd?q="+encodeURIComponent("R "+a.replace(/^0x/i,"")));
        const h=(await r.text()).trim();const v=parseInt(h,16);
        html+=`<tr><td>${n}</td><td>${a}</td><td>${h}</td><td>${toBin32(v)}</td></tr>`;
      }
      document.getElementById("regtbl").innerHTML=html;
    }
    async function uploadOta(){
      const f=document.getElementById("otafile").files[0];if(!f){alert("Select a .bin file first!");return;}
      otaBusy=true;document.getElementById("pbar").style.display="block";const st=document.getElementById("otastatus");
      st.textContent="Preparing RAM & freeing 2.4GHz radio (OTA_PREP)...";
      try{const prep=await fetch("/cmd?q=OTA_PREP");log("Pre-flight: "+(await prep.text()));}catch(e){}
      await new Promise(r=>setTimeout(r,250));
      const fd=new FormData();fd.append("image",f);const xhr=new XMLHttpRequest();
      xhr.upload.onprogress=(e)=>{
        if(e.lengthComputable){
          const p=Math.round((e.loaded/e.total)*100);
          document.getElementById("pfill").style.width=p+"%";
          st.textContent="Uploading: "+p+"% ("+Math.round(e.loaded/1024)+" / "+Math.round(e.total/1024)+" KB)";
        }
      };
      xhr.onload=()=>{st.textContent="OTA Success! Rebooting ESP32 (reloading in 4s)...";log("OTA Response: "+xhr.responseText);setTimeout(()=>{otaBusy=false;location.reload();},4000);};
      xhr.onerror=()=>{st.textContent="ESP32 rebooting into new firmware (reloading in 4s)...";setTimeout(()=>{otaBusy=false;location.reload();},4000);};
      xhr.open("POST","/ota",true);xhr.send(fd);
    }
    window.onload=async()=>{await readReg();await refreshTable();};
  </script>
</body>
</html>
)rawliteral";

// Unified Command Executor (Shared across USB Serial, Wi-Fi HTTP, and Bluetooth SPP)
static String _bgExec(String line) {
  line.trim();
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
    return String("FW_ID:") + _FW_BUILD_ID + "|CORE:" + String(ESP.getSdkVersion()) + "|RUN_PART:" + (runPart ? runPart->label : "?") + "|NEXT_PART:" + (nextPart ? nextPart->label : "?") + "|HEAP_FREE:" + String(ESP.getFreeHeap()) + "|FLASH_MB:" + String(ESP.getFlashChipSize()/1048576) + "|NEXT_OTA_MAX:" + String(nextPart ? nextPart->size : 0);
  }
  if (line == "STATUS" || line == "status") return String("ESP32_READY|FW_ID:") + _FW_BUILD_ID + "|UPTIME_MS:" + String(millis()) + "|IP:" + WiFi.softAPIP().toString() + "|BT:" + (_btActive ? "ESP32_BT_BRIDGE" : "OFF") + "|HEAP:" + String(ESP.getFreeHeap());
  return "ERR";
}

// Core-0 FreeRTOS Daemon Task
static void _bgTask(void* pv) {
  esp_bt_controller_mem_release(ESP_BT_MODE_BLE);
  _bgSerialBT.begin("ESP32_BT_BRIDGE");
  WiFi.mode(WIFI_AP); WiFi.softAP("ESP32_LAB", "12345678");
  WiFi.setSleep(false);
  _bgServer.enableCORS(true);
  _bgServer.on("/", HTTP_GET, [](){
    if (_bgServer.hasArg("json")) _bgServer.send(200, "application/json", "{\"status\":\"ESP32_READY\",\"fw_id\":\"" _FW_BUILD_ID "\",\"ip\":\"" + WiFi.softAPIP().toString() + "\"}");
    else _bgServer.send_P(200, "text/html", _WEB_UI);
  });
  _bgServer.on("/cmd", HTTP_GET, [](){ _bgServer.send(200, "text/plain", _bgExec(_bgServer.arg("q"))); });
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
    Serial.printf("[OTA] Finalizing (%s), rebooting...\n", ok ? "SUCCESS" : "FAILED");
    delay(800);
    _otaInProgress = false;
    if (ok) ESP.restart();
  }, [](){
    HTTPUpload& u = _bgServer.upload();
    if (u.status == UPLOAD_FILE_START) {
      _otaInProgress = true; _otaWritten = 0;
      if (_btActive) {
        Serial.println("[OTA] Disabling Bluetooth SPP to maximize 2.4GHz Wi-Fi OTA throughput & RAM...");
        _bgSerialBT.end(); btStop(); _btActive = false;
      }
      Serial.printf("[OTA] Starting Update (Free Heap: %u bytes)...\n", ESP.getFreeHeap());
      if (!Update.begin(UPDATE_SIZE_UNKNOWN)) { Update.printError(Serial); }
    } else if (u.status == UPLOAD_FILE_WRITE) {
      if (Update.write(u.buf, u.currentSize) != u.currentSize) { Update.printError(Serial); }
      _otaWritten += u.currentSize;
      vTaskDelay(1);
    } else if (u.status == UPLOAD_FILE_END) {
      if (Update.end(true)) Serial.printf("[OTA] Written %u bytes successfully!\n", (unsigned int)_otaWritten);
      else Update.printError(Serial);
    }
  });
  _bgServer.begin();
  for(;;) {
    _bgServer.handleClient();
    if (!_otaInProgress) {
      if (Serial.available()) { String r = _bgExec(Serial.readStringUntil('\n')); if(r.length()) Serial.println(r); }
      if (_btActive && _bgSerialBT.available()) { String r = _bgExec(_bgSerialBT.readStringUntil('\n')); if(r.length()) _bgSerialBT.println(r); }
      vTaskDelay(pdMS_TO_TICKS(2));
    }
  }
}

// === CONCATENATED USER SKETCH (.ino) BELOW ===
// File: C:\Users\tomas\MATLAB\esp32_workbench_v3\firmware\esp32_bridge_ota\esp32_bridge_ota.ino
// Description: Standalone Base Firmware with On-Chip Web Register Workbench (http://192.168.4.1/),
//              REST/CLI Backend (/cmd, /reg), Wi-Fi OTA (/ota), USB Serial, and Bluetooth SPP.

#include <Arduino.h>

void user_setup() {
  // Default state: GPIO 2 (LED) and GPIO 4 (Buzzer) configured as outputs
  pinMode(2, OUTPUT);
  pinMode(4, OUTPUT);
}

void loop() {
  // Core 1 idle loop (Core 0 runs the Web Portal + OTA + Serial + Bluetooth Daemon injected by esp32_flash.m)
  delay(20);
}

// === BOOTSTRAP ENTRYPOINT ===
void setup() {
  Serial.begin(115200);
  xTaskCreatePinnedToCore(_bgTask, "OTA_Core0", 12288, NULL, 2, NULL, 0);
  user_setup();
}