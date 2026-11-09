// File: C:\Users\tomas\MATLAB\esp32_workbench_v3\sketches\beep_fast\beep_fast.ino
// Description: Fast Double-Beep Alarm (every 200 ms on GPIO 4 + rapid LED strobe on GPIO 2).
// Period is mirrored in RTC_CNTL_STORE0_REG (0x3FF4804C).

#include <Arduino.h>
#include "soc/gpio_reg.h"
#include "soc/rtc_cntl_reg.h"

#define LED_PIN     2
#define BUZZER_PIN  4
#define FAST_INTERVAL_MS 200

unsigned long lastBeepMs = 0;

void setup() {
  pinMode(LED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  // Store initial 200 ms fast period in ESP32 RTC_CNTL_STORE0_REG (0x3FF4804C)
  *(volatile uint32_t*)RTC_CNTL_STORE0_REG = FAST_INTERVAL_MS;
}

void loop() {
  uint32_t intervalMs = *(volatile uint32_t*)RTC_CNTL_STORE0_REG;
  if (intervalMs < 40 || intervalMs > 60000) {
    intervalMs = FAST_INTERVAL_MS;
  }

  unsigned long now = millis();
  if (now - lastBeepMs >= intervalMs) {
    lastBeepMs = now;

    // Rapid high-pitch pulse (2400 Hz for 45 ms) + atomic GPIO2 LED flash
    *(volatile uint32_t*)GPIO_OUT_W1TS_REG = (1UL << LED_PIN);
    tone(BUZZER_PIN, 2400, 45);
    delay(50);
    *(volatile uint32_t*)GPIO_OUT_W1TC_REG = (1UL << LED_PIN);
  }
  delay(5);
}