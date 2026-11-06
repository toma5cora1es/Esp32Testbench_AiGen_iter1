#include <Arduino.h>
#include <WiFi.h>
#include <Update.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>
#include "esp_heap_caps.h"
#include "mbedtls/ccm.h"

// =============================================================================
// 1. Memory Buffers (IRAM Code Injection + DRAM UDE Live Inspection)
// =============================================================================
uint32_t *iram_exec_buf = nullptr;

// DRAM Buffer (0x3FFBxxxx):
// Words 0..7   : General UDE test patterns & heartbeat counter (Word 3)
// Words 8..12  : Decrypted Xiaomi S400 Telemetry (Status, Weight*100, HR, Imp50*10, Imp250*10)
// Words 13..18 : Raw 24-byte 0xFE95 MiBeacon BLE packet captured from air
volatile uint32_t dram_test_buf[32] = {
    0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0x00000000,
    0xA5A5A5A5, 0x5A5A5A5A, 0xFFFFFFFF, 0x00000002,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x99999999, 0xAAAAAAAA, 0xBBBBBBBB, 0xCCCCCCCC,
    0xDDDDDDDD, 0xEEEEEEEE, 0xFFFFFFFF, 0x01234567,
    0x89ABCDEF, 0x76543210, 0xFEDCBA98, 0x00003BD5
};

WiFiServer tcpServer(3333);
WiFiClient tcpClient;

// =============================================================================
// 2. Xiaomi S400 (0x3BD5 / MJTZC01YM) BLE State & AES-CCM Bindkey
// =============================================================================
BLEScan *pBLEScan = nullptr;
bool bleScanning = true;
uint32_t lastBleScanTrigger = 0;

// Default 16-byte bindkey (can be updated live from MATLAB via BLE_KEY command)
uint8_t s400_bindkey[16] = {
    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
};

struct ScaleTelemetry {
    char macStr[20];
    int rssi;
    uint16_t productId;
    uint8_t frameCounter;
    uint32_t rxCount;
    bool decryptedOk;
    uint8_t profileId;
    float weightKg;
    uint16_t heartRateBpm;
    float impedanceLowOhm;   // 50 kHz extracellular
    float impedanceHighOhm;  // 250 kHz intracellular + extracellular
    uint32_t packedRaw;
    uint32_t scaleTimestamp;
    uint8_t rawFrame[24];
    uint8_t rawFrameLen;
} scaleData = {"00:00:00:00:00:00", -99, 0x3BD5, 0, 0, false, 1, 0.0f, 0, 0.0f, 0.0f, 0, 0, {0}, 0};

// =============================================================================
// 3. Safe 32-Bit Aligned Memory Read/Write Primitives
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

void writeXtensaReturnStub(uint32_t baseAddr, uint32_t imm12) {
    imm12 &= 0x7FFU;
    uint32_t movi_b0 = 0x22U;
    uint32_t movi_b1 = 0xA0U | ((imm12 >> 8) & 0x0FU);
    uint32_t movi_b2 = imm12 & 0xFFU;

    uint32_t word0 = 0x00004136U | (movi_b0 << 24);
    uint32_t word1 = movi_b1 | (movi_b2 << 8) | 0xF01D0000U;

    safeWrite32(baseAddr,     word0);
    safeWrite32(baseAddr + 4, word1);
}

// =============================================================================
// 4. Xiaomi S400 MiBeacon v5 AES-CCM Decryption & Parser
// =============================================================================
void syncScaleToDram() {
    // Mirror parsed scale telemetry into dram_test_buf[8..18] for UDE Memory Viewer
    dram_test_buf[8]  = (scaleData.rxCount << 16) | (scaleData.decryptedOk ? 0x0001 : 0x0000);
    dram_test_buf[9]  = (uint32_t)(scaleData.weightKg * 100.0f);
    dram_test_buf[10] = (uint32_t)scaleData.heartRateBpm;
    dram_test_buf[11] = (uint32_t)(scaleData.impedanceLowOhm * 10.0f);
    dram_test_buf[12] = (uint32_t)(scaleData.impedanceHighOhm * 10.0f);

    // Copy 24-byte raw BLE frame into dram_test_buf[13..18]
    const uint32_t *rawWords = (const uint32_t *)scaleData.rawFrame;
    for (int i = 0; i < 6; i++) {
        dram_test_buf[13 + i] = rawWords[i];
    }
}

bool decryptAndParseS400(const uint8_t *frame, size_t len, const uint8_t macBytes[6], int rssi) {
    if (len < 11) return false;
    uint16_t frameCtrl = frame[0] | (frame[1] << 8);
    uint16_t productId = frame[2] | (frame[3] << 8);

    // Filter for Xiaomi S400 / S200 family Product IDs (0x3BD5 = S400 White, 0x30D9 = S400, 0x48CF = S400 Blue, 0x4B05 = S400 Pro)
    bool isS400 = (productId == 0x3BD5 || productId == 0x30D9 || productId == 0x48CF || productId == 0x4B05);
    if (!isS400) return false;

    snprintf(scaleData.macStr, sizeof(scaleData.macStr), "%02X:%02X:%02X:%02X:%02X:%02X",
             macBytes[0], macBytes[1], macBytes[2], macBytes[3], macBytes[4], macBytes[5]);
    scaleData.rssi = rssi;
    scaleData.productId = productId;
    scaleData.frameCounter = frame[4];
    scaleData.rxCount++;

    memset(scaleData.rawFrame, 0, sizeof(scaleData.rawFrame));
    scaleData.rawFrameLen = (len > 24) ? 24 : len;
    memcpy(scaleData.rawFrame, frame, scaleData.rawFrameLen);

    // Encrypted weigh-in frame has Frame Control 0x5948 (0x48 0x59) and length == 24 bytes
    if ((frameCtrl & 0x0048) == 0x0048 && len == 24) {
        // Construct 12-byte MiBeacon v5 Nonce:
        // MAC reversed (6B) + Product ID LE (2B) + Frame Counter (1B) + Ext Counter (3B)
        uint8_t nonce[12];
        for (int i = 0; i < 6; i++) nonce[i] = macBytes[5 - i];
        nonce[6]  = frame[2];
        nonce[7]  = frame[3];
        nonce[8]  = frame[4];
        nonce[9]  = frame[17];
        nonce[10] = frame[18];
        nonce[11] = frame[19];

        uint8_t aad = 0x11;
        uint8_t decrypted[12] = {0};

        mbedtls_ccm_context ctx;
        mbedtls_ccm_init(&ctx);
        int ret = mbedtls_ccm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, s400_bindkey, 128);
        if (ret == 0) {
            ret = mbedtls_ccm_auth_decrypt(&ctx, 12,
                                           nonce, sizeof(nonce),
                                           &aad, 1,
                                           &frame[5], decrypted,
                                           &frame[20], 4);
        }
        mbedtls_ccm_free(&ctx);

        if (ret == 0) {
            scaleData.decryptedOk = true;
            uint16_t objId = decrypted[0] | (decrypted[1] << 8);
            uint8_t objLen = decrypted[2];
            if (objId == 0x6E16 && objLen == 0x09) {
                scaleData.profileId = decrypted[3];
                uint32_t packed = (uint32_t)decrypted[4] |
                                  ((uint32_t)decrypted[5] << 8) |
                                  ((uint32_t)decrypted[6] << 16) |
                                  ((uint32_t)decrypted[7] << 24);
                uint32_t ts = (uint32_t)decrypted[8] |
                              ((uint32_t)decrypted[9] << 8) |
                              ((uint32_t)decrypted[10] << 16) |
                              ((uint32_t)decrypted[11] << 24);

                scaleData.packedRaw = packed;
                scaleData.scaleTimestamp = ts;

                uint16_t rawMass = packed & 0x7FFU;
                uint8_t  rawHr   = (packed >> 11) & 0x7FU;
                uint16_t rawImp  = (packed >> 18) & 0x3FFFU;

                if (rawMass > 0) {
                    // Packet 1: Weight + Heart Rate + 50 kHz Low-Frequency Impedance
                    scaleData.weightKg = rawMass * 0.1f;
                    if (rawHr > 0 && rawHr < 127) {
                        scaleData.heartRateBpm = rawHr + 50;
                    }
                    if (rawImp > 0) {
                        scaleData.impedanceLowOhm = rawImp * 0.1f;
                    }
                } else if (rawMass == 0 && rawHr == 0 && rawImp > 0) {
                    // Packet 2: 250 kHz High-Frequency Impedance
                    scaleData.impedanceHighOhm = rawImp * 0.1f;
                }
            }
        } else {
            scaleData.decryptedOk = false;
        }
    }

    syncScaleToDram();
    return true;
}

// Injects a real AES-CCM encrypted Xiaomi S400 frame into decryptAndParseS400() for instant testing
void simulateS400WeighIn(float simWeightKg, uint16_t simHrBpm, float simImp50, float simImp250) {
    uint8_t testMac[6] = {0xA4, 0xC1, 0x38, 0x57, 0x3C, 0x99};
    uint8_t nonce[12]  = {0x99, 0x3C, 0x57, 0x38, 0xC1, 0xA4, 0xD5, 0x3B, 0x42, 0x01, 0x00, 0x00};
    uint8_t aad = 0x11;

    // Packet 1: Weight + HR + 50 kHz Impedance
    uint32_t wRaw   = (uint32_t)(simWeightKg * 10.0f) & 0x7FFU;
    uint32_t hrRaw  = ((simHrBpm > 50) ? (simHrBpm - 50) : 22) & 0x7FU;
    uint32_t impRaw = (uint32_t)(simImp50 * 10.0f) & 0x3FFFU;
    uint32_t packed1 = wRaw | (hrRaw << 11) | (impRaw << 18);

    uint8_t plain1[12] = {
        0x16, 0x6E, 0x09, 0x01,
        (uint8_t)(packed1 & 0xFF), (uint8_t)((packed1 >> 8) & 0xFF),
        (uint8_t)((packed1 >> 16) & 0xFF), (uint8_t)((packed1 >> 24) & 0xFF),
        0x78, 0x56, 0x34, 0x12
    };

    uint8_t frame1[24] = {0x48, 0x59, 0xD5, 0x3B, 0x42};
    frame1[17] = 0x01; frame1[18] = 0x00; frame1[19] = 0x00;

    mbedtls_ccm_context ctx;
    mbedtls_ccm_init(&ctx);
    mbedtls_ccm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, s400_bindkey, 128);
    mbedtls_ccm_encrypt_and_tag(&ctx, 12, nonce, 12, &aad, 1, plain1, &frame1[5], &frame1[20], 4);
    mbedtls_ccm_free(&ctx);

    decryptAndParseS400(frame1, 24, testMac, -58);

    // Packet 2: 250 kHz High-Frequency Impedance
    uint32_t impHighRaw = (uint32_t)(simImp250 * 10.0f) & 0x3FFFU;
    uint32_t packed2 = (impHighRaw << 18);
    uint8_t plain2[12] = {
        0x16, 0x6E, 0x09, 0x01,
        (uint8_t)(packed2 & 0xFF), (uint8_t)((packed2 >> 8) & 0xFF),
        (uint8_t)((packed2 >> 16) & 0xFF), (uint8_t)((packed2 >> 24) & 0xFF),
        0x79, 0x56, 0x34, 0x12
    };
    nonce[8] = 0x43;
    uint8_t frame2[24] = {0x48, 0x59, 0xD5, 0x3B, 0x43};
    frame2[17] = 0x01; frame2[18] = 0x00; frame2[19] = 0x00;

    mbedtls_ccm_init(&ctx);
    mbedtls_ccm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, s400_bindkey, 128);
    mbedtls_ccm_encrypt_and_tag(&ctx, 12, nonce, 12, &aad, 1, plain2, &frame2[5], &frame2[20], 4);
    mbedtls_ccm_free(&ctx);

    decryptAndParseS400(frame2, 24, testMac, -58);
    // Keep packedRaw showing Packet 1 for educational bitfield visualization
    scaleData.packedRaw = packed1;
    memcpy(scaleData.rawFrame, frame1, 24);
    syncScaleToDram();
}

// =============================================================================
// 5. Passive BLE Advertisement Callback
// =============================================================================
class XiaomiAdvertisedDeviceCallbacks : public BLEAdvertisedDeviceCallbacks {
    void onResult(BLEAdvertisedDevice advertisedDevice) override {
        int serviceCount = advertisedDevice.getServiceDataCount();
        for (int i = 0; i < serviceCount; i++) {
            BLEUUID uuid = advertisedDevice.getServiceDataUUID(i);
            // Check for Xiaomi MiBeacon Service Data (0xFE95)
            if (uuid.equals(BLEUUID((uint16_t)0xFE95))) {
                String payloadStr = advertisedDevice.getServiceData(i);
                const uint8_t *payload = (const uint8_t *)payloadStr.c_str();
                size_t len = payloadStr.length();
                const uint8_t *mac = (const uint8_t *)advertisedDevice.getAddress().getNative();
                decryptAndParseS400(payload, len, mac, advertisedDevice.getRSSI());
            }
        }
    }
};

// =============================================================================
// 6. Command Dispatcher (UDE Memory + IRAM Exec + OTA + Xiaomi S400 BLE)
// =============================================================================
void processCommand(String line, Stream &io) {
    line.trim();
    if (line.length() == 0) return;

    char cmd[20] = {0};
    uint32_t arg1 = 0, arg2 = 0;
    int n = sscanf(line.c_str(), "%19s %x %x", cmd, &arg1, &arg2);

    if (strcmp(cmd, "PING") == 0) {
        io.println("PONG_ESP32_UDE");
    }
    else if (strcmp(cmd, "R") == 0 && n >= 2) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%08X", safeRead32(arg1));
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
    else if (strcmp(cmd, "BLE_KEY") == 0) {
        String keyHex = line.substring(7);
        keyHex.trim();
        if (keyHex.length() == 32) {
            for (int i = 0; i < 16; i++) {
                char byteStr[3] = {keyHex[i * 2], keyHex[i * 2 + 1], 0};
                s400_bindkey[i] = (uint8_t)strtoul(byteStr, nullptr, 16);
            }
            io.println("OK_KEY_SET");
        } else {
            io.println("ERR_KEY_LEN");
        }
    }
    else if (strcmp(cmd, "BLE_SIM") == 0) {
        float w = 74.6f + (random(-15, 15) * 0.1f);
        uint16_t hr = 68 + random(-5, 8);
        float imp50 = 548.2f + (random(-30, 30) * 0.1f);
        float imp250 = 489.5f + (random(-25, 25) * 0.1f);
        simulateS400WeighIn(w, hr, imp50, imp250);
        io.println("OK_SIM");
    }
    else if (strcmp(cmd, "BLE_STATUS") == 0) {
        char rawHex[52] = {0};
        for (int i = 0; i < 24; i++) {
            snprintf(&rawHex[i * 2], 3, "%02X", scaleData.rawFrame[i]);
        }
        char buf[320];
        snprintf(buf, sizeof(buf),
                 "MAC=%s RSSI=%d PID=0x%04X CNT=%u RX=%u DEC=%d PROF=%u W=%.2f HR=%u IMP50=%.1f IMP250=%.1f PACKED=0x%08X RAW=%s",
                 scaleData.macStr, scaleData.rssi, scaleData.productId,
                 scaleData.frameCounter, scaleData.rxCount, scaleData.decryptedOk ? 1 : 0,
                 scaleData.profileId, scaleData.weightKg, scaleData.heartRateBpm,
                 scaleData.impedanceLowOhm, scaleData.impedanceHighOhm,
                 scaleData.packedRaw, rawHex);
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

    iram_exec_buf = (uint32_t *)heap_caps_malloc(256, MALLOC_CAP_EXEC | MALLOC_CAP_32BIT);
    for (uint32_t i = 0; i < 64; i++) {
        safeWrite32((uint32_t)&iram_exec_buf[i], 0);
    }
    writeXtensaReturnStub((uint32_t)iram_exec_buf, 42);

    WiFi.mode(WIFI_AP);
    WiFi.softAP("ESP32_UDE_BRIDGE", "12345678");
    tcpServer.begin();

    // Initialize Passive BLE Scanner for Xiaomi Scale S400 (0xFE95)
    BLEDevice::init("ESP32_S400_SNIFFER");
    pBLEScan = BLEDevice::getScan();
    pBLEScan->setAdvertisedDeviceCallbacks(new XiaomiAdvertisedDeviceCallbacks(), true);
    pBLEScan->setActiveScan(false); // Passive scan preserves scale battery life
    pBLEScan->setInterval(100);
    pBLEScan->setWindow(99);
}

void loop() {
    static uint32_t lastTick = 0;
    if (millis() - lastTick > 200) {
        lastTick = millis();
        dram_test_buf[3]++;
    }

    // Non-blocking 1-second BLE scan slices every 3 seconds so Serial/TCP stay ultra-fast
    if (bleScanning && (millis() - lastBleScanTrigger > 3000)) {
        lastBleScanTrigger = millis();
        pBLEScan->start(1, false);
        pBLEScan->clearResults();
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