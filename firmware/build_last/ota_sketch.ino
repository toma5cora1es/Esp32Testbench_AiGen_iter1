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

#define _FW_BUILD_ID       "BLD_ESP32BRIDG_M_143638"
#define _DEFAULT_NODE_ROLE 1   // 0 = STANDALONE, 1 = MASTER_HOST, 2 = SLAVE_AGV
#define _DEFAULT_UI_PAGE   1  // 0 = UDE Workbench (web_ui.html), 1 = AGV Cockpit (web_ui_agv.html)

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
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>ESP32 On-Chip Register & HIL Workbench</title>
  <style>
    body{font-family:Consolas,monospace;background:#14171f;color:#e2e8f0;margin:0;padding:16px}
    .topnav{display:flex;justify-content:space-between;align-items:center;background:#0f172a;border:1px solid #334155;border-radius:8px;padding:8px 14px;margin-bottom:14px}
    .topnav a{color:#38bdf8;text-decoration:none;padding:6px 12px;border-radius:5px;border:1px solid #334155;font-weight:bold;margin-left:6px}
    .topnav a.active{background:#2563eb;color:#fff;border-color:#60a5fa}
    h2{color:#38bdf8;margin-top:0;display:flex;justify-content:space-between;align-items:center}
    .fsmbadge{background:#064e3b;border:1px solid #10b981;color:#4ade80;padding:4px 10px;border-radius:6px;font-size:13px}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:14px}
    .card{background:#1e2330;border:1px solid #334155;border-radius:8px;padding:14px}
    button{background:#2563eb;color:#fff;border:none;padding:8px 12px;border-radius:5px;cursor:pointer;font-family:inherit;margin:3px}
    button.on{background:#16a34a}button.off{background:#dc2626}button.warn{background:#d97706}
    input,select{background:#0f172a;color:#38bdf8;border:1px solid #475569;padding:7px;border-radius:4px;font-family:inherit}
    table{width:100%;border-collapse:collapse;margin-top:8px;font-size:13px}th,td{border:1px solid #334155;padding:6px;text-align:left}
    .bits{display:grid;grid-template-columns:repeat(8,1fr);gap:3px;margin-top:8px}
    .bitbtn{padding:4px;font-size:11px;background:#334155}.bitbtn.high{background:#16a34a;font-weight:bold}
    #log{background:#090b10;color:#4ade80;padding:10px;height:160px;overflow-y:auto;border-radius:6px;white-space:pre-wrap;font-size:12px}
    #pbar{width:100%;background:#0f172a;border:1px solid #475569;border-radius:4px;height:18px;margin-top:6px;display:none}
    #pfill{height:100%;background:#16a34a;width:0%;transition:width 0.2s}
  </style>
</head>
<body>
  <div class="topnav">
    <div>
      <strong style="color:#4ade80">CORE-0 MULTI-PAGE ENGINE</strong>
      <span id="espnowbadge" style="margin-left:12px;font-size:12px;color:#94a3b8">ESP-NOW: Checking...</span>
    </div>
    <div>
      <a href="/ude" class="active">1. UDE SFR Workbench (/ude)</a>
      <a href="/agv">2. Green AGV Arcade Cockpit (/agv)</a>
    </div>
  </div>

  <h2>
    <span>UDE-Lite ESP32 Web Register & HIL Workbench (BLD_ESP32BRIDG_M_143638)</span>
    <span class="fsmbadge" id="fsmstate">FSM: READY_IDLE</span>
  </h2>
  <div class="grid">
    <div class="card">
      <h3>1. Quick Pin, DAC, PWM & ESP-NOW Link</h3>
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
        Node Role & ESP-NOW Bridge:<br>
        <button class="on" onclick="cmd('ROLE MASTER')">Set MASTER</button>
        <button onclick="cmd('ROLE STANDALONE')">Set STANDALONE</button>
        <button class="warn" onclick="checkEspNow()">Ping ESP-NOW RTT</button>
      </div>
    </div>

    <div class="card">
      <h3>2. Direct 32-Bit SFR Register Inspector</h3>
      <select id="preset" onchange="document.getElementById('addr').value=this.value;readReg()">
        <option value="0x3FF44004">GPIO_OUT_REG (0x3FF44004)</option>
        <option value="0x3FF44008">GPIO_OUT_W1TS_REG (0x3FF44008)</option>
        <option value="0x3FF4400C">GPIO_OUT_W1TC_REG (0x3FF4400C)</option>
        <option value="0x3FF44020">GPIO_ENABLE_REG (0x3FF44020)</option>
        <option value="0x3FF4403C">GPIO_IN_REG (0x3FF4403C)</option>
        <option value="0x3FF4804C">RTC_CNTL_STORE0_REG (0x3FF4804C - AGV Cmd)</option>
        <option value="0x3FF48050">RTC_CNTL_STORE1_REG (0x3FF48050 - Encoders)</option>
        <option value="0x3FF48054">RTC_CNTL_STORE2_REG (0x3FF48054 - US & Line)</option>
        <option value="0x3FF48058">RTC_CNTL_STORE3_REG (0x3FF48058 - Pose X/Y)</option>
        <option value="0x3FF4805C">RTC_CNTL_STORE4_REG (0x3FF4805C - Heading/Vel)</option>
      </select><br><br>
      Addr: <input id="addr" value="0x3FF44004" size="11">
      Val: <input id="val" value="0x00000004" size="11"><br><br>
      <button onclick="readReg()">Read Register</button>
      <button class="warn" onclick="writeReg(document.getElementById('addr').value,document.getElementById('val').value)">Write Register</button>
      <div class="bits" id="bitgrid"></div>
    </div>

    <div class="card">
      <h3>3. Backend Command & OTA Firmware Upload</h3>
      Raw CLI: <input id="rawq" value="ESPNOW STATUS" size="18">
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
    <h3>4. Live Peripheral & AGV Mailbox Registers Map</h3>
    <table>
      <thead><tr><th>Register</th><th>Address</th><th>Hex Value</th><th>Binary (31..0)</th></tr></thead>
      <tbody id="regtbl"></tbody>
    </table>
  </div>

  <div class="card" style="margin-top:14px">
    <h3>Backend Execution & FSM Trace Log</h3>
    <div id="log">Ready. Connected to ESP32 Core-0 Daemon (BLD_ESP32BRIDG_M_143638).</div>
  </div>

  <script>
    const REGS=[
      ["GPIO_OUT_REG","0x3FF44004"],
      ["GPIO_IN_REG","0x3FF4403C"],
      ["RTC_CNTL_STORE0_REG (Cmd)","0x3FF4804C"],
      ["RTC_CNTL_STORE1_REG (Enc)","0x3FF48050"],
      ["RTC_CNTL_STORE2_REG (Sen)","0x3FF48054"],
      ["RTC_CNTL_STORE3_REG (Pos)","0x3FF48058"],
      ["RTC_CNTL_STORE4_REG (Vel)","0x3FF4805C"]
    ];
    let curRegVal=0, webFsm="READY_IDLE";
    function setFsm(nextState, reason){
      const prev=webFsm; webFsm=nextState;
      document.getElementById("fsmstate").textContent="FSM: "+webFsm;
      log("[web_ui.html] [FSM: "+prev+" -> "+nextState+"] "+reason);
    }
    function log(m){const el=document.getElementById("log");el.textContent="["+new Date().toLocaleTimeString()+"] "+m+"\n"+el.textContent;}
    async function cmd(q){
      if(webFsm.startsWith("OTA_"))return "";
      const t0=performance.now();
      setFsm("EXECUTING_CMD", "HTTP GET /cmd?q="+q);
      const r=await fetch("/cmd?q="+encodeURIComponent(q));
      const t=(await r.text()).trim();
      const dt=(performance.now()-t0).toFixed(1);
      setFsm("READY_IDLE", "Wire Rx <- \""+t+"\" ("+dt+" ms)");
      return t;
    }
    async function checkEspNow(){
      const s=await cmd("ESPNOW PING");
      document.getElementById("espnowbadge").textContent=s;
    }
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
    async function readReg(){if(webFsm.startsWith("OTA_"))return;const a=document.getElementById("addr").value;const t=await cmd("R "+a.replace(/^0x/i,""));document.getElementById("val").value=t;renderBits(parseInt(t,16));}
    async function writeReg(a,v){if(webFsm.startsWith("OTA_"))return;document.getElementById("addr").value=a;document.getElementById("val").value=v;const t=await cmd("W "+a.replace(/^0x/i,"")+" "+v.replace(/^0x/i,""));renderBits(parseInt(t,16));refreshTable();}
    async function refreshTable(){
      if(webFsm.startsWith("OTA_"))return;let html="";
      for(const [n,a] of REGS){
        if(webFsm.startsWith("OTA_"))return;
        const r=await fetch("/cmd?q="+encodeURIComponent("R "+a.replace(/^0x/i,"")));
        const h=(await r.text()).trim();const v=parseInt(h,16);
        html+=`<tr><td>${n}</td><td>${a}</td><td>${h}</td><td>${toBin32(v)}</td></tr>`;
      }
      document.getElementById("regtbl").innerHTML=html;
    }
    async function uploadOta(){
      const f=document.getElementById("otafile").files[0];if(!f){alert("Select a .bin file first!");return;}
      setFsm("OTA_PREFLIGHT_PREP", "Disabling BT SPP & freeing 2.4GHz radio");
      document.getElementById("pbar").style.display="block";const st=document.getElementById("otastatus");
      st.textContent="Preparing RAM & freeing 2.4GHz radio (OTA_PREP)...";
      try{const prep=await fetch("/cmd?q=OTA_PREP");log("Pre-flight: "+(await prep.text()));}catch(e){}
      await new Promise(r=>setTimeout(r,250));
      setFsm("OTA_STREAMING", "Uploading "+f.name+" ("+f.size+" bytes) to /ota");
      const fd=new FormData();fd.append("image",f);const xhr=new XMLHttpRequest();
      xhr.upload.onprogress=(e)=>{
        if(e.lengthComputable){
          const p=Math.round((e.loaded/e.total)*100);
          document.getElementById("pfill").style.width=p+"%";
          st.textContent="Uploading: "+p+"% ("+Math.round(e.loaded/1024)+" / "+Math.round(e.total/1024)+" KB)";
        }
      };
      xhr.onload=()=>{setFsm("OTA_REBOOT_SETTLE", "OTA_OK received; waiting 4s for ESP32 reboot");st.textContent="OTA Success! Rebooting ESP32 (reloading in 4s)...";setTimeout(()=>{setFsm("READY_IDLE","Reloading UI");location.reload();},4000);};
      xhr.onerror=()=>{setFsm("OTA_REBOOT_SETTLE", "Socket closed during reboot; reloading in 4s");st.textContent="ESP32 rebooting into new firmware (reloading in 4s)...";setTimeout(()=>{setFsm("READY_IDLE","Reloading UI");location.reload();},4000);};
      xhr.open("POST","/ota",true);xhr.send(fd);
    }
    window.onload=async()=>{await readReg();await refreshTable();await checkEspNow();};
  </script>
</body>
</html>
)rawliteral";

static const char _WEB_UI_AGV[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>GREEN AGV — Arcade Cockpit & ESP-NOW Master/Slave Workbench (BLD_ESP32BRIDG_M_143638)</title>
<style>
  :root {
    --bg: #0b0e14; --panel: #131924; --border: #243044;
    --neon: #00f2fe; --green: #00e676; --amber: #ffab00; --red: #ff1744; --text: #e2e8f0;
  }
  * { box-sizing: border-box; user-select: none; -webkit-user-select: none; }
  body {
    margin: 0; padding: 10px; background: var(--bg); color: var(--text);
    font-family: 'Segoe UI', Consolas, monospace; overflow-x: hidden;
  }
  .topnav {
    display: flex; justify-content: space-between; align-items: center;
    background: #0f172a; border: 1px solid var(--border); border-radius: 8px;
    padding: 8px 14px; margin-bottom: 8px;
  }
  .topnav a {
    color: var(--neon); text-decoration: none; padding: 5px 12px; border-radius: 5px;
    border: 1px solid var(--border); font-size: 12px; font-weight: bold; margin-left: 6px;
  }
  .topnav a.active { background: #0284c7; color: #fff; border-color: var(--neon); }
  .header {
    display: flex; justify-content: space-between; align-items: center;
    background: var(--panel); border: 1px solid var(--border); border-radius: 8px;
    padding: 8px 14px; margin-bottom: 10px;
  }
  .badge { padding: 4px 10px; border-radius: 4px; font-weight: bold; font-size: 12px; background: #1e293b; color: var(--neon); }
  .grid { display: grid; grid-template-columns: 1.05fr 1.15fr 1fr; gap: 10px; }
  @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
  .card {
    background: var(--panel); border: 1px solid var(--border); border-radius: 10px;
    padding: 12px; display: flex; flex-direction: column; align-items: center;
  }
  .card h3 { margin: 0 0 8px 0; font-size: 13px; color: var(--neon); text-transform: uppercase; letter-spacing: 1px; width: 100%; border-bottom: 1px solid var(--border); padding-bottom: 5px; }
  .kpi-row { display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; width: 100%; margin-bottom: 8px; }
  .kpi { background: #0d121b; border: 1px solid #1f293a; border-radius: 6px; padding: 8px; text-align: center; }
  .kpi .lbl { font-size: 10px; color: #8b9bb4; }
  .kpi .val { font-size: 18px; font-weight: bold; color: var(--green); margin-top: 2px; }
  .line-leds { display: flex; gap: 8px; margin: 6px 0; flex-wrap: wrap; justify-content: center; }
  .sensor-dot {
    width: 52px; height: 26px; border-radius: 5px; border: 2px solid #334155;
    display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: bold;
    background: #1e293b; color: #94a3b8; transition: 0.1s;
  }
  .sensor-dot.active { background: var(--red); color: #fff; border-color: #ff8a80; box-shadow: 0 0 10px var(--red); }
  .sensor-dot.btn-on { background: var(--green); color: #000; border-color: #69f0ae; box-shadow: 0 0 10px var(--green); }
  .btn-group { display: flex; flex-wrap: wrap; gap: 6px; width: 100%; margin-top: 6px; }
  button {
    flex: 1; padding: 9px 6px; border: 1px solid var(--border); border-radius: 6px;
    background: #1c2536; color: #fff; font-family: inherit; font-weight: bold; font-size: 11px;
    cursor: pointer; transition: 0.15s;
  }
  button.active { background: #0284c7; border-color: var(--neon); box-shadow: 0 0 8px rgba(0,242,254,0.4); }
  button.danger { background: #881337; border-color: var(--red); }
  #joyCanvas, #radarCanvas { background: #070a0e; border: 1px solid #26334d; border-radius: 8px; touch-action: none; }
  .key-hint { font-size: 11px; color: #94a3b8; margin-top: 6px; text-align: center; }
  .cmd-bar { display: flex; gap: 6px; width: 100%; margin-top: 6px; }
  input, select { background: #090d14; color: var(--green); border: 1px solid var(--border); padding: 7px; border-radius: 5px; font-family: Consolas, monospace; }
</style>
</head>
<body>

<div class="topnav">
  <div>
    <strong style="color:var(--green)">GREEN AGV REV 5.2a COCKPIT</strong>
    <span style="font-size:11px;color:#94a3b8;margin-left:10px;">TC78H611 (D4/D2, D13/D12) + ESP-NOW Ch 1</span>
  </div>
  <div>
    <a href="/ude">1. UDE SFR Workbench (/ude)</a>
    <a href="/agv" class="active">2. Green AGV Arcade Cockpit (/agv)</a>
  </div>
</div>

<div class="header">
  <div>
    <strong style="color:var(--green);font-size:16px;">INTERACTIVE TESTBENCH & TELEMETRY HUD</strong>
    <span style="font-size:11px;color:#8b9bb4;margin-left:8px;">FW: BLD_ESP32BRIDG_M_143638</span>
  </div>
  <div id="fsmBadge" class="badge">FSM: MANUAL_ARCADE</div>
</div>

<div class="grid">
  <!-- LEFT PANEL: TELEMETRY HUD & MODE CONTROLS -->
  <div class="card">
    <h3>1. Odometry, Sensors & Actuators (green_agv5.2a)</h3>
    <div class="kpi-row">
      <div class="kpi"><div class="lbl">VELOCITY</div><div id="valVel" class="val">0 mm/s</div></div>
      <div class="kpi"><div class="lbl">ULTRASONIC (D27/26)</div><div id="valUs" class="val">-- mm</div></div>
      <div class="kpi"><div class="lbl">POSE (X, Y)</div><div id="valPose" class="val">0, 0 mm</div></div>
      <div class="kpi"><div class="lbl">HEADING / ENCODERS</div><div id="valEnc" class="val">0° (0|0)</div></div>
    </div>

    <div style="font-size:11px;color:#8b9bb4;">FLOOR SENSORS (D34/32/35) & PUSHBUTTONS (T1=D5, T2=D15)</div>
    <div class="line-leds">
      <div id="dotL" class="sensor-dot">L (34)</div>
      <div id="dotM" class="sensor-dot">M (32)</div>
      <div id="dotR" class="sensor-dot">R (35)</div>
      <div id="dotT1" class="sensor-dot">T1 (D5)</div>
      <div id="dotT2" class="sensor-dot">T2 (15)</div>
    </div>

    <div style="width:100%;margin:4px 0;font-size:12px;">
      Max Speed Limit: <strong id="lblMaxSpd">75%</strong>
      <input type="range" id="rngSpd" min="20" max="100" value="75" style="width:100%;" oninput="document.getElementById('lblMaxSpd').innerText=this.value+'%'">
    </div>

    <div style="width:100%;margin:4px 0;font-size:12px;">
      Servo SV1 (D14): <strong id="lblServo">OFF</strong>
      <input type="range" id="rngServo" min="0" max="15" value="7" style="width:100%;" oninput="updateServo(this.value)">
    </div>

    <div class="btn-group">
      <button id="btnManual" class="active" onclick="setMode(1)">MANUAL ARCADE</button>
      <button id="btnLine" onclick="setMode(2)">LINE FOLLOWER (PID)</button>
      <button id="btnStop" class="danger" onclick="setMode(0)">E-STOP (SPACE)</button>
    </div>

    <div class="btn-group">
      <button id="btnFrontLed" onclick="toggleLight(1)">WHITE LEDs (D25/33)</button>
      <button id="btnRearLed" onclick="toggleLight(2)">RED LEDs (D14/23)</button>
      <button onclick="triggerHorn()">BUZZER (D32)</button>
      <button id="btnServoEn" onclick="toggleServoMode()">SERVO SV1</button>
    </div>

    <div class="btn-group">
      <button onclick="resetOdometry()">ZERO ODOM</button>
      <button onclick="setEcoMode()">80MHz ECO</button>
      <button onclick="wakeSlaveOta()">240MHz + OTA</button>
      <button onclick="sendRaw('I2C SCAN')">I2C / APDS9960</button>
    </div>
  </div>

  <!-- CENTER PANEL: LIVE ULTRASONIC RADAR & ODOMETRY MAP -->
  <div class="card">
    <h3>2. Live Ultrasonic Radar & Trajectory Map</h3>
    <canvas id="radarCanvas" width="320" height="310"></canvas>
    <div class="key-hint">Cyan = AGV Pose & Heading | Red Dots = Ultrasonic Obstacles (HC-SR04)</div>
  </div>

  <!-- RIGHT PANEL: TOUCH JOYSTICK & WASD GAMEPAD -->
  <div class="card">
    <h3>3. Touch Joystick & WASD / Arrow Drive</h3>
    <canvas id="joyCanvas" width="250" height="250"></canvas>
    <div class="key-hint">
      PC: Hold <strong>W / A / S / D</strong> or <strong>Arrow Keys</strong> (Space = E-Stop)<br>
      Mobile: Drag Virtual Analog Stick | Differential Output: <span id="lblPwmOut" style="color:var(--neon);">L:0% R:0%</span>
    </div>
  </div>
</div>

<!-- BOTTOM BAR: DIRECT CORE-0 DAEMON COMMAND & SFR CONSOLE -->
<div class="card" style="margin-top:10px;">
  <h3>4. Core-0 Bare-Metal Register & Wire Protocol Console</h3>
  <div class="cmd-bar">
    <input id="cmdIn" type="text" value="ESPNOW STATUS" style="flex:1;" placeholder="Enter Wire Command (e.g. STATUS, ESPNOW STATUS, I2C SCAN, R 3FF4804C)">
    <button style="flex:0 0 120px;" onclick="sendManualCmd()">SEND WIRE CMD</button>
  </div>
  <pre id="cmdOut" style="width:100%;margin:6px 0 0 0;padding:8px;background:#070a0e;color:var(--green);font-size:11px;border-radius:4px;overflow-x:auto;">Ready.</pre>
</div>

<script>
let agvMode = 1;
let auxMask = 0;
let servoEn = false;
let servoNib = 7;
let joyX = 0, joyY = 0;
let pendingMagic = 0x01;
let keys = {};
let inFlight = false;
let trail = [];
let hits = [];

const joyCv = document.getElementById('joyCanvas');
const joyCtx = joyCv.getContext('2d');
const radCv = document.getElementById('radarCanvas');
const radCtx = radCv.getContext('2d');

function setMode(m) {
  agvMode = m;
  if (m !== 1) { joyX = 0; joyY = 0; drawJoystick(); }
  document.getElementById('btnManual').classList.toggle('active', m === 1);
  document.getElementById('btnLine').classList.toggle('active', m === 2);
  computeControlWordHex(0x01);
}

function toggleLight(bit) {
  auxMask ^= bit;
  document.getElementById('btnFrontLed').classList.toggle('active', (auxMask & 1) !== 0);
  document.getElementById('btnRearLed').classList.toggle('active', (auxMask & 2) !== 0);
  computeControlWordHex(0x01);
}

function triggerHorn() {
  auxMask |= 0x04;
  setTimeout(() => { auxMask &= ~0x04; }, 220);
}

function toggleServoMode() {
  servoEn = !servoEn;
  document.getElementById('btnServoEn').classList.toggle('active', servoEn);
  document.getElementById('lblServo').innerText = servoEn ? `Angle #${servoNib}` : 'OFF';
}

function updateServo(val) {
  servoNib = parseInt(val, 10) & 0x0F;
  if (!servoEn) toggleServoMode();
  else document.getElementById('lblServo').innerText = `Angle #${servoNib}`;
}

function resetOdometry() {
  trail = []; hits = [];
  pendingMagic = 0x0F;
}

function setEcoMode() {
  pendingMagic = 0x0D;
  document.getElementById('cmdOut').innerText = "Queued Magic 0xD: Slave AGV switching to 80 MHz Low-Power Eco Mode.";
}

function wakeSlaveOta() {
  pendingMagic = 0x0E;
  document.getElementById('cmdOut').innerText = "Queued Magic 0xE: Slave AGV boosting to 240 MHz & opening SoftAP 'ESP32_AGV_OTA'.";
}

window.addEventListener('keydown', e => {
  if (document.activeElement.tagName === 'INPUT') return;
  const k = e.key.toLowerCase();
  if (k === ' ') { setMode(0); e.preventDefault(); return; }
  keys[k] = true;
  updateKeyboardVector();
});
window.addEventListener('keyup', e => {
  const k = e.key.toLowerCase();
  delete keys[k];
  updateKeyboardVector();
});

function updateKeyboardVector() {
  let vx = 0, vy = 0;
  if (keys['w'] || keys['arrowup'])    vy += 1;
  if (keys['s'] || keys['arrowdown'])  vy -= 1;
  if (keys['d'] || keys['arrowright']) vx += 1;
  if (keys['a'] || keys['arrowleft'])  vx -= 1;
  joyX = vx; joyY = vy;
  drawJoystick();
  computeControlWordHex(pendingMagic);
}

let dragging = false;
function handleJoyPointer(e) {
  if (!dragging) return;
  const rect = joyCv.getBoundingClientRect();
  const clientX = e.touches ? e.touches[0].clientX : e.clientX;
  const clientY = e.touches ? e.touches[0].clientY : e.clientY;
  const cx = joyCv.width / 2, cy = joyCv.height / 2, maxR = 85;
  let dx = clientX - rect.left - cx;
  let dy = clientY - rect.top - cy;
  const dist = Math.hypot(dx, dy);
  if (dist > maxR) { dx = (dx / dist) * maxR; dy = (dy / dist) * maxR; }
  joyX = dx / maxR;
  joyY = -dy / maxR;
  if (agvMode === 0) setMode(1);
  drawJoystick();
  computeControlWordHex(pendingMagic);
}
joyCv.addEventListener('mousedown', e => { dragging = true; handleJoyPointer(e); });
window.addEventListener('mousemove', handleJoyPointer);
window.addEventListener('mouseup', () => {
  if (dragging) { dragging = false; joyX = 0; joyY = 0; drawJoystick(); computeControlWordHex(pendingMagic); }
});
joyCv.addEventListener('touchstart', e => { dragging = true; handleJoyPointer(e); e.preventDefault(); }, {passive:false});
joyCv.addEventListener('touchmove', e => { handleJoyPointer(e); e.preventDefault(); }, {passive:false});
joyCv.addEventListener('touchend', () => {
  dragging = false; joyX = 0; joyY = 0; drawJoystick(); computeControlWordHex(pendingMagic);
});

function drawJoystick() {
  const cx = joyCv.width / 2, cy = joyCv.height / 2, maxR = 85;
  joyCtx.clearRect(0, 0, joyCv.width, joyCv.height);
  joyCtx.strokeStyle = '#243044'; joyCtx.lineWidth = 2;
  joyCtx.beginPath(); joyCtx.arc(cx, cy, maxR, 0, Math.PI * 2); joyCtx.stroke();
  joyCtx.beginPath(); joyCtx.moveTo(cx - maxR, cy); joyCtx.lineTo(cx + maxR, cy);
  joyCtx.moveTo(cx, cy - maxR); joyCtx.lineTo(cx, cy + maxR); joyCtx.stroke();

  const kx = cx + joyX * maxR, ky = cy - joyY * maxR;
  joyCtx.fillStyle = 'rgba(0, 242, 254, 0.25)';
  joyCtx.strokeStyle = '#00f2fe'; joyCtx.lineWidth = 3;
  joyCtx.beginPath(); joyCtx.arc(kx, ky, 26, 0, Math.PI * 2); joyCtx.fill(); joyCtx.stroke();
}
drawJoystick();

function computeTankSpeeds() {
  const maxSpd = parseInt(document.getElementById('rngSpd').value, 10) || 75;
  let left = (joyY + joyX * 0.75) * maxSpd;
  let right = (joyY - joyX * 0.75) * maxSpd;
  left = Math.max(-100, Math.min(100, Math.round(left)));
  right = Math.max(-100, Math.min(100, Math.round(right)));
  return { left, right };
}

function computeControlWordHex(magicNib) {
  const { left, right } = computeTankSpeeds();
  document.getElementById('lblPwmOut').innerText = `L:${left}% R:${right}%`;
  const uL = left & 0xFF;
  const uR = right & 0xFF;
  const fullAux = (auxMask & 0x07) | (servoEn ? 0x08 : 0x00) | ((servoNib & 0x0F) << 4);
  const word = (((magicNib & 0x0F) << 28) | ((agvMode & 0x0F) << 24) | ((fullAux & 0xFF) << 16) | (uL << 8) | uR) >>> 0;
  return word.toString(16).toUpperCase().padStart(8, '0');
}

// SINGLE NON-OVERLAPPING 200ms SYNC LOOP (Zero TCP Socket Exhaustion!)
setInterval(async () => {
  if (inFlight) return;
  inFlight = true;
  const ctrl = new AbortController();
  const tid = setTimeout(() => ctrl.abort(), 450);
  try {
    const hexWord = computeControlWordHex(pendingMagic);
    pendingMagic = 0x01;
    const resp = await fetch('/cmd?q=' + encodeURIComponent('SYNC ' + hexWord), { signal: ctrl.signal });
    const txt = (await resp.text()).trim();
    const parts = txt.split(/\s+/);
    if (parts.length >= 4) {
      const w1 = parseInt(parts[0], 16) >>> 0;
      const w2 = parseInt(parts[1], 16) >>> 0;
      const w3 = parseInt(parts[2], 16) >>> 0;
      const w4 = parseInt(parts[3], 16) >>> 0;

      const encL = (w1 >> 16) & 0xFFFF; const encLs = (encL & 0x8000) ? encL - 0x10000 : encL;
      const encR = w1 & 0xFFFF;         const encRs = (encR & 0x8000) ? encR - 0x10000 : encR;
      const usMm = (w2 >>> 16) & 0xFFFF;
      const senMask = (w2 >>> 8) & 0xFF;
      const st = w2 & 0xFF;

      const xRaw = (w3 >>> 16) & 0xFFFF; const xMm = (xRaw & 0x8000) ? xRaw - 0x10000 : xRaw;
      const yRaw = w3 & 0xFFFF;          const yMm = (yRaw & 0x8000) ? yRaw - 0x10000 : yRaw;
      const tRaw = (w4 >>> 16) & 0xFFFF; const thRad = ((tRaw & 0x8000) ? tRaw - 0x10000 : tRaw) / 1000.0;
      const vRaw = w4 & 0xFFFF;          const vMms = (vRaw & 0x8000) ? vRaw - 0x10000 : vRaw;

      const stNames = ['IDLE_SAFE', 'MANUAL_ARCADE', 'LINE_FOLLOWER_PID', 'SLAM_STEP', 'FAULT_OBSTACLE_HOLD'];
      document.getElementById('fsmBadge').innerText = 'FSM: ' + (stNames[st] || st);
      document.getElementById('valVel').innerText = `${vMms} mm/s`;
      document.getElementById('valUs').innerText = usMm < 3500 ? `${usMm} mm` : 'CLEAR';
      document.getElementById('valPose').innerText = `${xMm}, ${yMm}`;
      document.getElementById('valEnc').innerText = `${Math.round(thRad * 57.3)}° (${encLs}|${encRs})`;

      document.getElementById('dotL').classList.toggle('active', (senMask & 4) !== 0);
      document.getElementById('dotM').classList.toggle('active', (senMask & 2) !== 0);
      document.getElementById('dotR').classList.toggle('active', (senMask & 1) !== 0);
      document.getElementById('dotT1').classList.toggle('btn-on', (senMask & 8) !== 0);
      document.getElementById('dotT2').classList.toggle('btn-on', (senMask & 16) !== 0);

      updateRadarCanvas(xMm, yMm, thRad, usMm);
    }
  } catch (e) {}
  clearTimeout(tid);
  inFlight = false;
}, 200);

function updateRadarCanvas(xMm, yMm, thRad, usMm) {
  const cx = radCv.width / 2, cy = radCv.height / 2, scale = 0.08;
  if (trail.length === 0 || Math.hypot(xMm - trail[trail.length-1].x, yMm - trail[trail.length-1].y) > 15) {
    trail.push({x: xMm, y: yMm});
    if (trail.length > 250) trail.shift();
  }
  if (usMm > 20 && usMm < 2200) {
    const hx = xMm + (usMm + 95) * Math.cos(thRad);
    const hy = yMm + (usMm + 95) * Math.sin(thRad);
    hits.push({x: hx, y: hy});
    if (hits.length > 400) hits.shift();
  }

  radCtx.clearRect(0, 0, radCv.width, radCv.height);
  radCtx.strokeStyle = '#162030'; radCtx.lineWidth = 1;
  [500, 1000, 1500].forEach(r => {
    radCtx.beginPath(); radCtx.arc(cx, cy, r * scale, 0, Math.PI * 2); radCtx.stroke();
  });

  radCtx.strokeStyle = '#0284c7'; radCtx.lineWidth = 2;
  radCtx.beginPath();
  trail.forEach((p, i) => {
    const px = cx + p.x * scale, py = cy - p.y * scale;
    if (i === 0) radCtx.moveTo(px, py); else radCtx.lineTo(px, py);
  });
  radCtx.stroke();

  radCtx.fillStyle = '#ff1744';
  hits.forEach(h => {
    radCtx.fillRect(cx + h.x * scale - 2, cy - h.y * scale - 2, 4, 4);
  });

  const rx = cx + xMm * scale, ry = cy - yMm * scale;
  radCtx.fillStyle = '#00e676';
  radCtx.beginPath(); radCtx.arc(rx, ry, 5, 0, Math.PI * 2); radCtx.fill();
  radCtx.strokeStyle = '#00f2fe'; radCtx.lineWidth = 2;
  radCtx.beginPath(); radCtx.moveTo(rx, ry);
  radCtx.lineTo(rx + Math.cos(thRad) * 18, ry - Math.sin(thRad) * 18);
  radCtx.stroke();
}

async function sendRaw(cmd) {
  const r = await fetch('/cmd?q=' + encodeURIComponent(cmd));
  document.getElementById('cmdOut').innerText = await r.text();
}
function sendManualCmd() { sendRaw(document.getElementById('cmdIn').value); }
</script>
</body>
</html>
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

void setup() {
  Serial.begin(115200);
  xTaskCreatePinnedToCore(_bgTask, "OTA_Core0", 12288, NULL, 2, NULL, 0);
  user_setup();
}