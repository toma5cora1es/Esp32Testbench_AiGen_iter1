#include <Arduino.h>
#include "soc/rtc_cntl_reg.h"

const int PIN_LED    = 2;
const int PIN_BUZZER = 4;

void setup() {
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);
  // Store default 200 ms fast interval in RTC_CNTL_STORE0_REG (0x3FF4804C)
  *(volatile uint32_t*)RTC_CNTL_STORE0_REG = 200;
}

void loop() {
  digitalWrite(PIN_LED, HIGH);
  tone(PIN_BUZZER, 2400, 80);
  delay(80);
  digitalWrite(PIN_LED, LOW);

  uint32_t intervalMs = *(volatile uint32_t*)RTC_CNTL_STORE0_REG;
  if (intervalMs < 40 || intervalMs > 60000) intervalMs = 200;
  delay(intervalMs);
}
