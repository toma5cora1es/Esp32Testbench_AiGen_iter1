// ============================================================================
// ESP32 6-Channel Safe ADC Signal Generator (Core 1 Application)
// Outputs 6 distinct signals on left-header pins D25, D26, D27, D14, D12, D13
// to be routed with jumper wires to ADC1 pins VP(36), VN(39), D34, D35, D32, D33.
// ============================================================================
#include <Arduino.h>
#include "soc/rtc_cntl_reg.h"

// 6 Output Pins on the lower-left header (right below D33):
const int PIN_DAC1_WAVE  = 25; // D25 (DAC1): Smooth Analog Triangle Wave (0.25V .. 2.90V)
const int PIN_DAC2_STEPS = 26; // D26 (DAC2): Calibrated Analog Steps (0.5V, 1.0V, 1.65V, 2.5V, 3.0V)
const int PIN_PULSER_1   = 27; // D27       : Slow Digital Square Wave (1.0s period)
const int PIN_PULSER_2   = 14; // D14       : Medium Digital Square Wave (2.0s period)
const int PIN_PULSER_3   = 12; // D12       : Heartbeat Digital Pulse (3.0s period)
const int PIN_PULSER_4   = 13; // D13       : Complementary Digital Wave (1.5s period)
const int PIN_LED        = 2;  // D2        : Built-in Status LED

// Safe 8-bit DAC values (0..255 maps to 0.00V..3.30V)
// 0.50V ~= 39, 1.00V ~= 78, 1.65V ~= 128, 2.50V ~= 194, 3.00V ~= 232
const uint8_t STEP_DAC_VALS[5] = {39, 78, 128, 194, 232};
int stepIndex = 0;
int triVal    = 20;
int triDir    = 5;
uint32_t lastStepMs = 0;

void setup() {
  pinMode(PIN_PULSER_1, OUTPUT);
  pinMode(PIN_PULSER_2, OUTPUT);
  pinMode(PIN_PULSER_3, OUTPUT);
  pinMode(PIN_PULSER_4, OUTPUT);
  pinMode(PIN_LED, OUTPUT);

  // Default tick interval in ms stored in RTC_CNTL_STORE0_REG (0x3FF4804C)
  *(volatile uint32_t*)RTC_CNTL_STORE0_REG = 80;
}

void loop() {
  uint32_t now = millis();

  // 1. Channel 1 (D25 / DAC1): Continuous Analog Triangle Wave (0.25V <-> 2.90V)
  triVal += triDir;
  if (triVal >= 225) { triVal = 225; triDir = -5; }
  if (triVal <= 20)  { triVal = 20;  triDir = +5; }
  dacWrite(PIN_DAC1_WAVE, (uint8_t)triVal);

  // 2. Channel 2 (D26 / DAC2): Exact Analog Voltage Steps (0.5V, 1.0V, 1.65V, 2.5V, 3.0V)
  if (now - lastStepMs >= 2500) {
    lastStepMs = now;
    stepIndex = (stepIndex + 1) % 5;
    dacWrite(PIN_DAC2_STEPS, STEP_DAC_VALS[stepIndex]);
  }

  // 3. Channels 3..6 (D27, D14, D12, D13): Multi-Phase Digital Waves (0.0V / 3.3V)
  digitalWrite(PIN_PULSER_1, (now / 1000) % 2);
  digitalWrite(PIN_PULSER_2, (now / 2000) % 2);
  digitalWrite(PIN_PULSER_3, ((now % 3000) < 600) ? HIGH : LOW);
  digitalWrite(PIN_PULSER_4, !((now / 1500) % 2));
  digitalWrite(PIN_LED,      (now / 500) % 2);

  // Read dynamic speed from RTC_CNTL_STORE0_REG (0x3FF4804C)
  uint32_t tickMs = *(volatile uint32_t*)RTC_CNTL_STORE0_REG;
  if (tickMs < 10 || tickMs > 2000) tickMs = 80;
  delay(tickMs);
}
