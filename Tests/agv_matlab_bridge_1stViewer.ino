#include <Arduino.h>
#include <WiFi.h>
#include <Update.h>
#include "esp_heap_caps.h"

// Executable RAM buffer allocated in 32-bit IRAM (0x4008xxxx / 0x4009xxxx)
uint32_t *iram_exec_buf = nullptr;

// Test data buffer in DRAM (0x3FFBxxxx) for live inspection in UDE Memory Viewer
volatile uint32_t dram_test_buf[16] = {
    0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0x00000000,
    0xA5A5A5A5, 0x5A5A5A5A, 0xFFFFFFFF, 0x00000002,
    0x11111111, 0x22222222, 0x33333333, 0x44444444,
    0x55555555, 0x66666666, 0x77777777, 0x88888888
};

WiFiServer tcpServer(3333);
WiFiClient tcpClient;

// Safe 32-bit aligned read/write for ESP32 IRAM (prevents LoadStoreError)
static inline uint32_t iramRead32(uint32_t addr) {
    uint32_t val;
    asm volatile("l32i %0, %1, 0" : "=r"(val) : "r"(addr & ~3U));
    return val;
}

static inline void iramWrite32(uint32_t addr, uint32_t val) {
    asm volatile(
        "s32i %0, %1, 0 \n"
        "memw           \n"
        "isync          \n"
        :
        : "r"(val), "r"(addr & ~3U)
        : "memory"
    );
}

// Writes a valid 8-byte Xtensa LX6 function into IRAM that returns imm12 (0..2047)
// Instructions (Little-Endian):
//   entry a1, 16   -> 36 41 00
//   movi  a2, imm  -> 22 ((imm & 0xF) << 4 | 0xA0) ((imm >> 4) & 0xFF)
//   retw.n         -> 1D F0
void writeXtensaStub(uint32_t baseAddr, uint32_t imm12) {
    imm12 &= 0x7FFU;
    uint32_t b3 = 0x22U | ((imm12 >> 8) & 0x0FU) << 4; // Wait: Xtensa movi is: op2=1010(A), r=2(a2), s=imm[11:8], t=0010(2), imm8=imm[7:0]
    // In Xtensa LX6 RRI8 format for MOVI (t=2, s=imm[11:8], r=0xA, op0=2):
    // Byte 0 of movi = (s << 4) | 0x02  ? No: byte0 = (t << 4) | op0 = 0x22
    // Byte 1 of movi = (r << 4) | s    = 0xA0 | ((imm12 >> 8) & 0x0F)
    // Byte 2 of movi = imm12 & 0xFF
    uint32_t movi_b0 = 0x22U;
    uint32_t movi_b1 = 0xA0U | ((imm12 >> 8) & 0x0FU);
    uint32_t movi_b2 = imm12 & 0xFFU;

    uint32_t word0 = 0x00004136U | (movi_b0 << 24);
    uint32_t word1 = movi_b1 | (movi_b2 << 8) | 0xF01D0000U;

    iramWrite32(baseAddr,     word0);
    iramWrite32(baseAddr + 4, word1);
}

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
        uint32_t val = iramRead32(arg1);
        char buf[16];
        snprintf(buf, sizeof(buf), "%08X", val);
        io.println(buf);
    }
    else if (strcmp(cmd, "RB") == 0 && n >= 3) {
        uint32_t base = arg1 & ~3U;
        uint32_t count = (arg2 > 128) ? 128 : arg2;
        String out = "";
        out.reserve(count * 9);
        char buf[12];
        for (uint32_t i = 0; i < count; i++) {
            snprintf(buf, sizeof(buf), "%08X", iramRead32(base + i * 4));
            if (i > 0) out += " ";
            out += buf;
        }
        io.println(out);
    }
    else if (strcmp(cmd, "W") == 0 && n >= 3) {
        iramWrite32(arg1, arg2);
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
            delay(300);
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
    Serial.begin(115200);

    // Allocate 256 bytes in 32-bit executable IRAM
    iram_exec_buf = (uint32_t *)heap_caps_malloc(256, MALLOC_CAP_EXEC | MALLOC_CAP_32BIT);
    for (uint32_t i = 0; i < 64; i++) {
        iramWrite32((uint32_t)&iram_exec_buf[i], 0);
    }
    writeXtensaStub((uint32_t)iram_exec_buf, 42);

    WiFi.mode(WIFI_AP);
    WiFi.softAP("ESP32_UDE_BRIDGE", "12345678");
    tcpServer.begin();
}

void loop() {
    static uint32_t lastTick = 0;
    if (millis() - lastTick > 250) {
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