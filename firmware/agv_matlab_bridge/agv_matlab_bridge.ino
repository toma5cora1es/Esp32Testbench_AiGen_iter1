/*
 * agv_matlab_bridge.ino  --  ESP32 debug bridge for the MATLAB "UDE-style" workbench (protocol v2)
 *
 * Two independent channels, on purpose:
 *   CONTROL  USB serial @115200  and  TCP :3333   -> read / write / exec / info   (line protocol)
 *   OTA      TCP :3334                            -> stream a new app image into the idle OTA slot
 *
 * Every reply is framed:  @<payload>*<XOR-checksum>\r\n   (see bridge_proto.h)
 *
 * Build-time options (passed by the MATLAB OTA window with arduino-cli --build-property):
 *   -DBOOT_BLINKS=N   how many times the LED on GPIO2 blinks at boot (visible proof of a new image)
 *   -DFW_BUILD=N      a number (unix time) reported by INFO so the host can see the image changed
 */
#include <Arduino.h>
#include <WiFi.h>
#include <Update.h>
#include "esp_heap_caps.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "bridge_proto.h"

#ifndef BOOT_BLINKS
#define BOOT_BLINKS 3
#endif
#ifndef FW_BUILD
#define FW_BUILD 0
#endif

#define FW_VERSION      "2.0.0"
#define LED_PIN         2
#define CTRL_PORT       3333
#define OTA_PORT        3334
#define EXEC_BUF_BYTES  256

// ---- RAM objects the host can look at --------------------------------------
uint32_t *iram_exec_buf = nullptr;            // 256 B of executable IRAM (MALLOC_CAP_EXEC)
volatile uint32_t dram_test_buf[16] = {       // visible in the Memory window; word [3] counts up
  0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0x00000000,
  0xA5A5A5A5, 0x5A5A5A5A, 0xFFFFFFFF, 0x00000002,
  0x11111111, 0x22222222, 0x33333333, 0x44444444,
  0x55555555, 0x66666666, 0x77777777, 0x88888888
};

WiFiServer ctrlServer(CTRL_PORT);
WiFiServer otaServer(OTA_PORT);
WiFiClient ctrlClient;

static char g_pl[1300];   // reply payload
static char g_tx[1400];   // framed reply

// ---- 32-bit-only memory access (IRAM and SFRs require it) -------------------
static inline uint32_t rd32(uint32_t a) {
  uint32_t v;
  asm volatile("l32i %0, %1, 0" : "=r"(v) : "r"(a) : "memory");
  return v;
}
static inline void wr32(uint32_t a, uint32_t v) {
  asm volatile("s32i %0, %1, 0 \n memw \n isync \n" :: "r"(v), "r"(a) : "memory");
}

// ---- reply helper ------------------------------------------------------------
static void sendFrame(Stream &io, const char *payload) {
  size_t n = bridge::frame(g_tx, sizeof(g_tx), payload);
  if (n) io.write((const uint8_t *)g_tx, n);
}

// ---- command handlers ----------------------------------------------------------
typedef uint32_t (*exec_fn_t)(uint32_t, uint32_t);

static void handleCommand(char *line, Stream &io) {
  char *tok[5];
  int n = bridge::tokenize(line, tok, 5);
  if (n == 0) return;
  const char *c = tok[0];
  g_pl[0] = 0;

  if (!strcmp(c, "PING")) {
    snprintf(g_pl, sizeof(g_pl), "PONG");
  }
  else if (!strcmp(c, "INFO")) {
    String ip = WiFi.softAPIP().toString();
    const esp_partition_t *run = esp_ota_get_running_partition();
    const esp_partition_t *nxt = esp_ota_get_next_update_partition(NULL);
    snprintf(g_pl, sizeof(g_pl),
      "FW=%s BUILD=%lu BLINKS=%d IRAM=0x%08lX EXECLEN=%d DRAM=0x%08lX IP=%s RUN=%s NEXT=%s "
      "CHIP=%s REV=%d CPU=%d FLASH=%lu HEAP=%lu UP=%lu",
      FW_VERSION, (unsigned long)FW_BUILD, (int)BOOT_BLINKS,
      (unsigned long)(uintptr_t)iram_exec_buf, EXEC_BUF_BYTES,
      (unsigned long)(uintptr_t)dram_test_buf, ip.c_str(),
      run ? run->label : "none", nxt ? nxt->label : "none",
      ESP.getChipModel(), (int)ESP.getChipRevision(), (int)ESP.getCpuFreqMHz(),
      (unsigned long)ESP.getFlashChipSize(), (unsigned long)ESP.getFreeHeap(),
      (unsigned long)(millis() / 1000));
  }
  else if (!strcmp(c, "MAP")) {            // the host draws the very table the guard enforces
    size_t k = 0;
    for (size_t i = 0; i < bridge::kNumRegions && k + 48 < sizeof(g_pl); i++) {
      const bridge::Region &r = bridge::kRegions[i];
      k += snprintf(g_pl + k, sizeof(g_pl) - k, "%s:%08lX:%08lX:%d;", r.name,
                    (unsigned long)r.lo, (unsigned long)r.hi, r.writable ? 1 : 0);
    }
    if (iram_exec_buf)
      snprintf(g_pl + k, sizeof(g_pl) - k, "EXEC_BUF:%08lX:%08lX:1;",
               (unsigned long)(uintptr_t)iram_exec_buf,
               (unsigned long)((uintptr_t)iram_exec_buf + EXEC_BUF_BYTES));
  }
  else if (!strcmp(c, "PART")) {           // flash partition table: label:type:subtype:offset:size;
    size_t k = 0;
    esp_partition_iterator_t it = esp_partition_find(ESP_PARTITION_TYPE_ANY, ESP_PARTITION_SUBTYPE_ANY, NULL);
    while (it && k + 64 < sizeof(g_pl)) {
      const esp_partition_t *p = esp_partition_get(it);
      k += snprintf(g_pl + k, sizeof(g_pl) - k, "%s:%02X:%02X:%lX:%lX;", p->label,
                    (unsigned)p->type, (unsigned)p->subtype,
                    (unsigned long)p->address, (unsigned long)p->size);
      it = esp_partition_next(it);
    }
    if (it) esp_partition_iterator_release(it);
  }
  else if (!strcmp(c, "R") && n >= 2) {
    uint32_t a = bridge::hex(tok[1]);
    if (a & 3u)                            snprintf(g_pl, sizeof(g_pl), "ERR ALIGN %08lX", (unsigned long)a);
    else if (!bridge::canRead(a))          snprintf(g_pl, sizeof(g_pl), "ERR RANGE %08lX", (unsigned long)a);
    else if (bridge::readHasSideEffect(a)) snprintf(g_pl, sizeof(g_pl), "ERR SIDEFX %08lX", (unsigned long)a);
    else                                   snprintf(g_pl, sizeof(g_pl), "%08lX", (unsigned long)rd32(a));
  }
  else if (!strcmp(c, "RB") && n >= 3) {   // block read; unreadable words come back as "--------"
    uint32_t a = bridge::hex(tok[1]);
    uint32_t cnt = bridge::hex(tok[2]);
    if (cnt > 128) cnt = 128;
    if (a & 3u) { snprintf(g_pl, sizeof(g_pl), "ERR ALIGN %08lX", (unsigned long)a); }
    else {
      size_t k = 0;
      for (uint32_t i = 0; i < cnt; i++) {
        uint32_t w = a + i * 4;
        if (i) g_pl[k++] = ' ';
        if (!bridge::canRead(w))               k += snprintf(g_pl + k, sizeof(g_pl) - k, "--------");
        else if (bridge::readHasSideEffect(w)) k += snprintf(g_pl + k, sizeof(g_pl) - k, "~~~~~~~~");
        else                                   k += snprintf(g_pl + k, sizeof(g_pl) - k, "%08lX", (unsigned long)rd32(w));
      }
      g_pl[k] = 0;
    }
  }
  else if (!strcmp(c, "W") && n >= 3) {
    uint32_t a = bridge::hex(tok[1]);
    uint32_t v = bridge::hex(tok[2]);
    if (a & 3u)                     snprintf(g_pl, sizeof(g_pl), "ERR ALIGN %08lX", (unsigned long)a);
    else if (!bridge::canWrite(a))  snprintf(g_pl, sizeof(g_pl), "ERR RO %08lX", (unsigned long)a);
    else { wr32(a, v);              snprintf(g_pl, sizeof(g_pl), "OK"); }
  }
  else if (!strcmp(c, "EXEC") && n >= 2) { // EXEC addr [a2] [a3]  -> calls addr(a2, a3), windowed ABI
    uint32_t a  = bridge::hex(tok[1]);
    uint32_t a2 = (n >= 3) ? bridge::hex(tok[2]) : 0;
    uint32_t a3 = (n >= 4) ? bridge::hex(tok[3]) : 0;
    if (!bridge::inExec(a, 4)) snprintf(g_pl, sizeof(g_pl), "ERR EXECRANGE %08lX", (unsigned long)a);
    else {
      asm volatile("memw \n isync \n" ::: "memory");
      uint32_t ret = ((exec_fn_t)(uintptr_t)a)(a2, a3);
      snprintf(g_pl, sizeof(g_pl), "EXEC_RET=0x%08lX", (unsigned long)ret);
    }
  }
  else if (!strcmp(c, "REBOOT")) {
    snprintf(g_pl, sizeof(g_pl), "REBOOTING");
    sendFrame(io, g_pl);
    io.flush();
    delay(200);
    ESP.restart();
    return;
  }
  else {
    snprintf(g_pl, sizeof(g_pl), "ERR UNKNOWN %s", c);
  }
  sendFrame(io, g_pl);
}

// ---- non-blocking line assembler (so a half-received line never stalls loop()) ----
struct LineReader {
  char buf[96];
  size_t n = 0;
  char *poll(Stream &s) {
    while (s.available()) {
      int ch = s.read();
      if (ch == '\n' || ch == '\r') {
        if (n) { buf[n] = 0; n = 0; return buf; }
      } else if (n < sizeof(buf) - 1) {
        buf[n++] = (char)ch;
      }
    }
    return nullptr;
  }
};
static LineReader serialLine, tcpLine;

// ---- OTA session: header line, raw image, MD5 check, switch boot slot, reboot ------
//   host -> "OTA <size-dec> <md5-hex32>\n" then <size> raw bytes
//   dev  -> "@READY" | "@ERR ..." ... then "@OTA_OK" and reboot
static void otaSession(WiFiClient c) {
  c.setNoDelay(true);
  uint32_t t0 = millis();
  while (!c.available() && c.connected() && millis() - t0 < 3000) delay(5);
  String hdr = c.readStringUntil('\n');
  char hb[128];
  hdr.toCharArray(hb, sizeof(hb));
  char *tok[4];
  int n = bridge::tokenize(hb, tok, 4);
  if (n < 3 || strcmp(tok[0], "OTA") != 0) { sendFrame(c, "ERR BAD_HEADER"); c.stop(); return; }
  uint32_t size = strtoul(tok[1], nullptr, 10);
  if (size < 1024) { sendFrame(c, "ERR BAD_SIZE"); c.stop(); return; }

  if (!Update.begin(size)) {               // erases the idle OTA slot (app0 <-> app1)
    snprintf(g_pl, sizeof(g_pl), "ERR BEGIN %s", Update.errorString());
    sendFrame(c, g_pl); c.stop(); return;
  }
  Update.setMD5(tok[2]);
  sendFrame(c, "READY");

  static uint8_t buf[1024];
  uint32_t written = 0;
  t0 = millis();
  while (written < size && c.connected() && millis() - t0 < 15000) {
    int avail = c.available();
    if (avail <= 0) { delay(1); continue; }
    size_t want = min((size_t)avail, min(sizeof(buf), (size_t)(size - written)));
    size_t got = c.readBytes(buf, want);
    if (Update.write(buf, got) != got) {
      snprintf(g_pl, sizeof(g_pl), "ERR WRITE %s", Update.errorString());
      Update.abort(); sendFrame(c, g_pl); c.stop(); return;
    }
    written += got;
    t0 = millis();
  }
  if (written != size) { Update.abort(); sendFrame(c, "ERR TIMEOUT"); c.stop(); return; }

  if (Update.end()) {                      // checks MD5, then updates otadata -> next boot uses new slot
    sendFrame(c, "OTA_OK");
    c.flush();
    delay(500);
    ESP.restart();
  } else {
    snprintf(g_pl, sizeof(g_pl), "ERR END %s", Update.errorString());
    sendFrame(c, g_pl);
    c.stop();
  }
}

// ---- Arduino entry points ----------------------------------------------------------
void setup() {
  pinMode(LED_PIN, OUTPUT);
  Serial.begin(115200);

  // 256 bytes of executable RAM: the only place the host may write machine code.
  iram_exec_buf = (uint32_t *)heap_caps_malloc(EXEC_BUF_BYTES, MALLOC_CAP_EXEC | MALLOC_CAP_32BIT);
  if (iram_exec_buf) {
    for (uint32_t i = 0; i < EXEC_BUF_BYTES / 4; i++) wr32((uint32_t)(uintptr_t)&iram_exec_buf[i], 0);
    // default stub:  entry a1,32 ; movi a2,42 ; retw.n   (returns 42)
    wr32((uint32_t)(uintptr_t)&iram_exec_buf[0], 0x22004136u);
    wr32((uint32_t)(uintptr_t)&iram_exec_buf[1], 0xF01D2AA0u);
    bridge::setExecWindow((uint32_t)(uintptr_t)iram_exec_buf, EXEC_BUF_BYTES);
  }

  WiFi.mode(WIFI_AP);
  WiFi.softAP("ESP32_UDE_BRIDGE", "12345678");
  ctrlServer.begin();
  otaServer.begin();

  for (int i = 0; i < BOOT_BLINKS; i++) {  // visible proof of which image is running
    digitalWrite(LED_PIN, HIGH); delay(90);
    digitalWrite(LED_PIN, LOW);  delay(90);
  }
}

void loop() {
  static uint32_t lastTick = 0;
  if (millis() - lastTick > 250) {         // a counter you can watch live in the Memory window
    lastTick = millis();
    dram_test_buf[3]++;
  }

  if (char *l = serialLine.poll(Serial)) handleCommand(l, Serial);

  if (ctrlServer.hasClient()) {
    if (!ctrlClient || !ctrlClient.connected()) { ctrlClient = ctrlServer.available(); ctrlClient.setNoDelay(true); }
    else ctrlServer.available().stop();
  }
  if (ctrlClient && ctrlClient.connected()) {
    if (char *l = tcpLine.poll(ctrlClient)) handleCommand(l, ctrlClient);
  }

  if (otaServer.hasClient()) {
    WiFiClient oc = otaServer.available();
    if (oc) otaSession(oc);
  }
}
