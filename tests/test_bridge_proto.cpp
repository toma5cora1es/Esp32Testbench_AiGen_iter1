// Host-side unit test of bridge_proto.h
//   g++ -std=c++17 tests/test_bridge_proto.cpp -I firmware/agv_matlab_bridge -o test_proto && ./test_proto
#include <cassert>
#include <cstdio>
#include "bridge_proto.h"
using namespace bridge;

int main() {
  // --- address guard: addresses the chip really has -----------------------
  assert(canRead(0x3FF44004));        // GPIO_OUT_REG
  assert(canRead(0x3FFBDB60));        // DRAM (dram_test_buf in the log)
  assert(canRead(0x40094CE4));        // IRAM region (exec buffer lives here)
  assert(canRead(0x40000000));        // boot ROM
  assert(canRead(0x50000000));        // RTC SLOW
  // --- addresses that used to take the chip down --------------------------
  assert(!canRead(0xC0000000));       // the AURIX address from the UDE manual screenshot
  assert(!canRead(0x00000000));       // NULL
  assert(!canRead(0x3FF20000));       // hole between DPORT and PeriBus1
  assert(!canRead(0x3FFA0000));       // hole between ROM1 and SRAM2
  assert(!canRead(0x3FF44002));       // unaligned
  assert(canRead(0x3FFFFFFC));        // last word of DRAM is fine
  assert(canRead(0x40000000));        // first word of ROM0 is fine
  assert(!canRead(0x40060000));       // first word after ROM0: hole
  // --- write policy ----------------------------------------------------------
  assert(canWrite(0x3FF44008));       // GPIO_OUT_W1TS
  assert(!canWrite(0x3FF90000));      // ROM1
  assert(!canWrite(0x40094CE4));      // IRAM is read-only ...
  setExecWindow(0x40094CE4, 256);
  assert(canWrite(0x40094CE4));       // ... except the exec buffer
  assert(canWrite(0x40094CE4 + 252));
  assert(!canWrite(0x40094CE4 + 256));
  // --- read side effects ----------------------------------------------------
  assert(readHasSideEffect(0x3FF40000));
  assert(!readHasSideEffect(0x3FF40004));
  // --- framing ------------------------------------------------------------------
  char out[64];
  assert(frame(out, sizeof out, "PONG") > 0);
  assert(strcmp(out, "@PONG*16\r\n") == 0);   // 'P'^'O'^'N'^'G' = 0x50^0x4F^0x4E^0x47 = 0x16
  // --- tokenizer + hex --------------------------------------------------------
  char line[] = "RB 3FFBDB60 20\r\n";
  char *t[4];
  assert(tokenize(line, t, 4) == 3 && strcmp(t[0], "RB") == 0);
  assert(hex(t[1]) == 0x3FFBDB60u && hex(t[2]) == 0x20u);
  puts("bridge_proto: all tests passed");
  return 0;
}
