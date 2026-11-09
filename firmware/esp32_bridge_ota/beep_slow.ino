#include <Arduino.h>
#include "soc/rtc_cntl_reg.h"

const int PIN_LED    = 2;
const int PIN_BUZZER = 4;

void setup() {
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);
  // Store default 3000 ms interval in RTC_CNTL_STORE0_REG (0x3FF4804C)
  *(volatile uint32_t*)RTC_CNTL_STORE0_REG = 3000;
}

void loop() {
  digitalWrite(PIN_LED, HIGH);
  tone(PIN_BUZZER, 1000, 120);
  delay(120);
  digitalWrite(PIN_LED, LOW);

  uint32_t intervalMs = *(volatile uint32_t*)RTC_CNTL_STORE0_REG;
  if (intervalMs < 50 || intervalMs > 60000) intervalMs = 3000;
  delay(intervalMs);
}
