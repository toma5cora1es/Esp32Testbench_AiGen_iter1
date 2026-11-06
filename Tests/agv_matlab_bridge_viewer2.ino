#include <Arduino.h>
#include <WiFi.h>
#include <Update.h>
#include "esp_heap_caps.h"

// =============================================================================
// Memory Allocations
// =============================================================================
// Executable RAM buffer placed directly in 32-bit IRAM (0x4008xxxx / 0x4009xxxx)
uint32_t *iram_exec_buf = nullptr;

// DRAM Inspection buffer (0x3FFBxxxx) mapped for UDE Memory Viewer demonstration
volatile uint32_t dram_test_buf[32] = {
    0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0x00000000,
    0xA5A5A5A5, 0x5A5A5A5A, 0xFFFFFFFF, 0x00000002,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x11111111, 0x22222222, 0x33333333, 0x44444444,
    0x55555555, 0x66666666, 0x77777777, 0x88888888,
    0x99999999, 0xAAAAAAAA, 0xBBBBBBBB, 0xCCCCCCCC,
    0xDDDDDDDD, 0xEEEEEEEE, 0xFFFFFFFF, 0x01234567,
    0x89ABCDEF, 0x76543210, 0xFEDCBA98, 0x1337BEEF
};

WiFiServer tcpServer(3333);
WiFiClient tcpClient;

// =============================================================================
// Low-Level Safe 32-Bit Memory Access Primitives
// =============================================================================
static inline uint32_t safeRead32(uint32_t addr) {
    uint32_t val;
    asm volatile("l32i %0, %1, 0" : "=r"(val) : "r"(addr & ~3U));
    return val;
}

static inline void safeWrite32(uint32_t addr, uint32_t val) {
    asm volatile(
        "s32i %0, %1, 0 \n"
        "memw           \n"
        "isync          \n"
        :
        : "r"(val), "r"(addr & ~3U)
        : "memory"
    );
}

// Writes an executable 8-byte Xtensa LX6 function returning imm12 (0..2047)
void writeXtensaReturnStub(uint32_t baseAddr, uint32_t imm12) {
    imm12 &= 0x7FFU;
    uint32_t movi_b0 = 0x22U;
    uint32_t movi_b1 = 0xA0U | ((imm12 >> 8) & 0x0FU);
    uint32_t movi_b2 = imm12 & 0xFFU;

    uint32_t word0 = 0x00004136U | (movi_b0 << 24); // entry a1, 16 + movi byte 0
    uint32_t word1 = movi_b1 | (movi_b2 << 8) | 0xF01D0000U; // movi remainder + retw.n

    safeWrite32(baseAddr,     word0);
    safeWrite32(baseAddr + 4, word1);
}

// =============================================================================
// Serial / TCP Command Dispatcher
// =============================================================================
void processCommand(String line, Stream &io) {
    line.trim();
    if (line.length() == 0) return;

    char cmd[16] = {0};
    uint32_t arg1 = 0, arg2 = 0;
    int n = sscanf(line.c_str(), "%15s %x %x", cmd, &arg1, &arg2);

    if (strcmp(cmd, "PING") == 0) {
        io.println("PONG_ESP32_UDE");
    }
    else if (strcmp(cmd, "R") == 0 && n >= 2) {
        uint32_t val = safeRead32(arg1);
        char buf[16];
        snprintf(buf, sizeof(buf), "%08X", val);
        io.println(buf);
    }
    else if (strcmp(cmd, "RB") == 0 && n >= 3) {
        uint32_t base = arg1 & ~3U;
        uint32_t count = (arg2 > 64) ? 64 : arg2;
        String out = "";
        out.reserve(count * 9);
        char buf[12];
        for (uint32_t i = 0; i < count; i++) {
            snprintf(buf, sizeof(buf), "%08X", safeRead32(base + i * 4));
            if (i > 0) out += " ";
            out += buf;
        }
        io.println(out);
    }
    else if (strcmp(cmd, "W") == 0 && n >= 3) {
        safeWrite32(arg1, arg2);
        io.println("OK");
    }
    else if (strcmp(cmd, "INFO") == 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "IRAM=0x%08X DRAM=0x%08X IP=%s",
                 (uint32_t)iram_exec_buf, (uint32_t)dram_test_buf,
                 WiFi.softAPIP().toString().c_str());
        io.println(buf);
    }
    else if (strcmp(cmd, "EXEC") == 0 && n >= 2) {
        asm volatile("memw; isync");
        typedef uint32_t (*iram_fn_t)(void);
        iram_fn_t fn = (iram_fn_t)arg1;
        uint32_t ret = fn();
        char buf[32];
        snprintf(buf, sizeof(buf), "EXEC_RET=0x%08X", ret);
        io.println(buf);
    }
    else if (strcmp(cmd, "OTA") == 0 && n >= 2) {
        uint32_t fwSize = arg1;
        if (!Update.begin(fwSize)) {
            io.println("ERR_OTA_BEGIN");
            return;
        }
        io.println("READY_FOR_BIN");
        uint8_t buff[512];
        uint32_t written = 0;
        uint32_t t0 = millis();
        while (written < fwSize && (millis() - t0 < 15000)) {
            if (io.available()) {
                int len = io.readBytes(buff, min((uint32_t)sizeof(buff), fwSize - written));
                Update.write(buff, len);
                written += len;
                t0 = millis();
            }
        }
        if (Update.end(true)) {
            io.println("OTA_OK_REBOOTING");
            delay(200);
            ESP.restart();
        } else {
            io.println("ERR_OTA_END");
        }
    }
    else {
        io.println("OK");
    }
}

void setup() {
    pinMode(2, OUTPUT);
    digitalWrite(2, LOW);
    Serial.begin(115200);

    // Allocate 256 bytes inside executable IRAM
    iram_exec_buf = (uint32_t *)heap_caps_malloc(256, MALLOC_CAP_EXEC | MALLOC_CAP_32BIT);
    for (uint32_t i = 0; i < 64; i++) {
        safeWrite32((uint32_t)&iram_exec_buf[i], 0);
    }
    writeXtensaReturnStub((uint32_t)iram_exec_buf, 42);

    WiFi.mode(WIFI_AP);
    WiFi.softAP("ESP32_UDE_BRIDGE", "12345678");
    tcpServer.begin();
}

void loop() {
    // Dynamic background counter to demonstrate live polling in the memory viewer
    static uint32_t lastTick = 0;
    if (millis() - lastTick > 200) {
        lastTick = millis();
        dram_test_buf[3]++;
    }

    if (Serial.available()) {
        String line = Serial.readStringUntil('\n');
        processCommand(line, Serial);
    }

    if (tcpServer.hasClient()) {
        if (!tcpClient || !tcpClient.connected()) {
            tcpClient = tcpServer.available();
        } else {
            tcpServer.available().stop();
        }
    }
    if (tcpClient && tcpClient.connected() && tcpClient.available()) {
        String line = tcpClient.readStringUntil('\n');
        processCommand(line, tcpClient);
    }
}