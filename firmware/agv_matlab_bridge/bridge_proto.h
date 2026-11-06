// bridge_proto.h -- hardware-independent part of the ESP32 <-> MATLAB protocol (v2).
// No Arduino calls in here on purpose: the same header is unit-tested on a PC
// (see tests/test_bridge_proto.cpp) before it ever touches the chip.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

namespace bridge {

// ---------------------------------------------------------------------------
// 1. Address guard.
//    The ESP32 has NO memory protection: loading from an address that is not
//    mapped raises a LoadProhibited exception, the panic handler prints a
//    "Guru Meditation Error" and the chip reboots (ESP-IDF "Fatal Errors" guide).
//    So the bridge only touches ranges taken from the Technical Reference
//    Manual, chapter 1 "System and Memory" (Embedded Memory + Peripherals).
//    Ranges are [lo, hi).
// ---------------------------------------------------------------------------
struct Region { uint32_t lo; uint32_t hi; bool writable; const char *name; };

static const Region kRegions[] = {
  {0x3FF00000u, 0x3FF10000u, true,  "DPORT"},       // DPORT registers
  {0x3FF40000u, 0x3FF80000u, true,  "PERIPH"},      // PeriBus1/2 peripherals (SFRs)
  {0x3FF80000u, 0x3FF82000u, true,  "RTC_FAST_D"},  // RTC FAST memory, data bus
  {0x3FF90000u, 0x3FFA0000u, false, "ROM1"},        // internal ROM 1 (data bus)
  {0x3FFAE000u, 0x40000000u, true,  "DRAM"},        // SRAM2 + SRAM1, data bus
  {0x40000000u, 0x40060000u, false, "ROM0"},        // internal ROM 0 (boot ROM code)
  {0x40080000u, 0x400C0000u, false, "IRAM"},        // SRAM0/1, instruction bus. READ-ONLY here
  {0x400C0000u, 0x400C2000u, true,  "RTC_FAST_I"},  // RTC FAST memory, instruction bus
  {0x50000000u, 0x50002000u, true,  "RTC_SLOW"},    // RTC SLOW memory
};
static const size_t kNumRegions = sizeof(kRegions) / sizeof(kRegions[0]);

// The only RAM that may be written in the instruction-bus window: the 256-byte
// buffer allocated with MALLOC_CAP_EXEC at boot (set by the sketch).
static uint32_t g_execLo = 0, g_execHi = 0;

inline void setExecWindow(uint32_t lo, uint32_t bytes) { g_execLo = lo; g_execHi = lo + bytes; }
inline bool inExec(uint32_t a, uint32_t bytes) {
  return g_execHi != 0 && a >= g_execLo && (uint64_t)a + bytes <= g_execHi;
}

inline const Region *findRegion(uint32_t a, uint32_t bytes) {
  for (size_t i = 0; i < kNumRegions; i++) {
    const Region &r = kRegions[i];
    if (a >= r.lo && (uint64_t)a + bytes <= r.hi) return &r;
  }
  return nullptr;
}

// Reading these words has a hardware side effect (pops a byte from the UART RX
// FIFO). Reading UART0's FIFO would steal bytes from our own command channel.
inline bool readHasSideEffect(uint32_t a) {
  return a == 0x3FF40000u || a == 0x3FF50000u || a == 0x3FF6E000u;  // UART0/1/2 FIFO
}

inline bool canRead(uint32_t a)  { return (a & 3u) == 0 && (findRegion(a, 4) != nullptr || inExec(a, 4)); }
inline bool canWrite(uint32_t a) {
  if (a & 3u) return false;
  if (inExec(a, 4)) return true;
  const Region *r = findRegion(a, 4);
  return r != nullptr && r->writable;
}

// ---------------------------------------------------------------------------
// 2. Framing.  Every reply is  "@<payload>*<XOR of payload bytes, 2 hex>\r\n".
//    The host ignores any line that does not start with '@' or whose checksum
//    is wrong, so boot-ROM text, log lines and panic dumps cannot be mistaken
//    for data.
// ---------------------------------------------------------------------------
inline uint8_t xorSum(const char *s) { uint8_t c = 0; while (*s) c ^= (uint8_t)*s++; return c; }

inline size_t frame(char *out, size_t cap, const char *payload) {
  size_t n = strlen(payload);
  if (n + 8 > cap) return 0;
  int w = snprintf(out, cap, "@%s*%02X\r\n", payload, xorSum(payload));
  return w > 0 ? (size_t)w : 0;
}

// ---------------------------------------------------------------------------
// 3. Tokenizer + hex parser (no String class, no heap).
// ---------------------------------------------------------------------------
inline int tokenize(char *s, char *tok[], int maxTok) {
  int n = 0;
  char *p = strtok(s, " \t\r\n");
  while (p && n < maxTok) { tok[n++] = p; p = strtok(nullptr, " \t\r\n"); }
  return n;
}
inline uint32_t hex(const char *t) { return (uint32_t)strtoul(t, nullptr, 16); }

}  // namespace bridge
