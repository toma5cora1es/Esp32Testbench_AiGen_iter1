#include <Arduino.h>
#include <esp_arduino_version.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"

#define AGV_PIN_MOT_L_A   {{PIN_MOT_L_A}}
#define AGV_PIN_MOT_L_B   {{PIN_MOT_L_B}}
#define AGV_PIN_MOT_R_A   {{PIN_MOT_R_A}}
#define AGV_PIN_MOT_R_B   {{PIN_MOT_R_B}}
#define AGV_PIN_ENC_L     {{PIN_ENC_L}}
#define AGV_PIN_ENC_R     {{PIN_ENC_R}}
#define AGV_PIN_US_TRIG   {{PIN_US_TRIG}}
#define AGV_PIN_US_ECHO   {{PIN_US_ECHO}}
#define AGV_PIN_LINE_L    {{PIN_LINE_L}}
#define AGV_PIN_LINE_M    {{PIN_LINE_M}}
#define AGV_PIN_LINE_R    {{PIN_LINE_R}}
#define AGV_PIN_BTN_T1    {{PIN_BTN_T1}}
#define AGV_PIN_BTN_T2    {{PIN_BTN_T2}}
#define AGV_PIN_LED_F     {{PIN_LED_F}}
#define AGV_PIN_LED_R     {{PIN_LED_R}}
#define AGV_PIN_BUZZER    {{PIN_BUZZER}}
#define AGV_PWM_FREQ_HZ   {{PWM_FREQ_HZ}}
#define AGV_PWM_RES_BITS  {{PWM_RES_BITS}}
#define AGV_WHEEL_DIAM_MM {{WHEEL_DIAM_MM}}
#define AGV_WHEEL_BASE_MM {{WHEEL_BASE_MM}}
#define AGV_TICKS_PER_REV {{TICKS_PER_REV}}

static const uint16_t LINE_ADC_THRESH = 1800;
static volatile int32_t g_encTicksL = 0;
static volatile int32_t g_encTicksR = 0;
static volatile int8_t  g_dirSignL  = 1;
static volatile int8_t  g_dirSignR  = 1;

static float    g_xMm       = 0.0f;
static float    g_yMm       = 0.0f;
static float    g_thetaRad  = 0.0f;
static int16_t  g_velMms    = 0;
static uint16_t g_usMm      = 3000;
static uint8_t  g_fsmState  = 0;
static int8_t   g_localMode = -1;

static float    g_pidLastErr = 0.0f;
static float    g_pidInteg   = 0.0f;
static int8_t   g_lastLineSign = 1;

static volatile uint32_t g_lastIsrUsL = 0, g_lastIsrUsR = 0;
void IRAM_ATTR isrEncL() { uint32_t t = micros(); if ((t - g_lastIsrUsL) >= 500u) { g_encTicksL += g_dirSignL; g_lastIsrUsL = t; } }
void IRAM_ATTR isrEncR() { uint32_t t = micros(); if ((t - g_lastIsrUsR) >= 500u) { g_encTicksR += g_dirSignR; g_lastIsrUsR = t; } }

static inline void agvPwmAttach(uint8_t pin, uint8_t ch) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(pin, AGV_PWM_FREQ_HZ, AGV_PWM_RES_BITS);
#else
  ledcSetup(ch, AGV_PWM_FREQ_HZ, AGV_PWM_RES_BITS);
  ledcAttachPin(pin, ch);
#endif
  (void)ch;
}

static inline void agvPwmWrite(uint8_t pin, uint8_t ch, uint32_t duty) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(pin, duty);
#else
  ledcWrite(ch, duty);
#endif
  (void)ch;
}

static void driveMotorPair(uint8_t pinA, uint8_t chA, uint8_t pinB, uint8_t chB, int8_t pct, volatile int8_t& dirSign) {
  int p = constrain((int)pct, -100, 100);
  uint32_t maxDuty = (1u << AGV_PWM_RES_BITS) - 1u;
  if (p > 0) {
    dirSign = 1;
    agvPwmWrite(pinA, chA, (uint32_t)(p * (int)maxDuty / 100));
    agvPwmWrite(pinB, chB, 0);
  } else if (p < 0) {
    dirSign = -1;
    agvPwmWrite(pinA, chA, 0);
    agvPwmWrite(pinB, chB, (uint32_t)((-p) * (int)maxDuty / 100));
  } else {
    agvPwmWrite(pinA, chA, 0);
    agvPwmWrite(pinB, chB, 0);
  }
}

static uint16_t readUltrasonicMm() {
  digitalWrite(AGV_PIN_US_TRIG, LOW);
  delayMicroseconds(2);
  digitalWrite(AGV_PIN_US_TRIG, HIGH);
  delayMicroseconds(10);
  digitalWrite(AGV_PIN_US_TRIG, LOW);
  unsigned long dur = pulseIn(AGV_PIN_US_ECHO, HIGH, 12000u);
  if (dur < 100u) return 3000;
  return (uint16_t)min(3000UL, (dur * 343UL) / 2000UL);
}

void setup() {
  agvPwmAttach(AGV_PIN_MOT_L_A, 0);
  agvPwmAttach(AGV_PIN_MOT_L_B, 1);
  agvPwmAttach(AGV_PIN_MOT_R_A, 2);
  agvPwmAttach(AGV_PIN_MOT_R_B, 3);
  driveMotorPair(AGV_PIN_MOT_L_A, 0, AGV_PIN_MOT_L_B, 1, 0, g_dirSignL);
  driveMotorPair(AGV_PIN_MOT_R_A, 2, AGV_PIN_MOT_R_B, 3, 0, g_dirSignR);

  pinMode(AGV_PIN_ENC_L, INPUT_PULLUP);
  pinMode(AGV_PIN_ENC_R, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(AGV_PIN_ENC_L), isrEncL, RISING);
  attachInterrupt(digitalPinToInterrupt(AGV_PIN_ENC_R), isrEncR, RISING);

  pinMode(AGV_PIN_US_TRIG, OUTPUT);
  digitalWrite(AGV_PIN_US_TRIG, LOW);
  pinMode(AGV_PIN_US_ECHO, INPUT_PULLDOWN);

  pinMode(AGV_PIN_LINE_L, INPUT);
  pinMode(AGV_PIN_LINE_M, INPUT);
  pinMode(AGV_PIN_LINE_R, INPUT);
  pinMode(AGV_PIN_BTN_T1, INPUT_PULLUP);
  pinMode(AGV_PIN_BTN_T2, INPUT_PULLUP);

  pinMode(AGV_PIN_LED_F, OUTPUT);
  pinMode(AGV_PIN_LED_R, OUTPUT);
  agvPwmAttach(AGV_PIN_BUZZER, 4);
  agvPwmWrite(AGV_PIN_BUZZER, 4, 0);
  analogReadResolution(12);
}

void loop() {
  static uint32_t lastCtrlUs = 0;
  static uint32_t lastUsMs   = 0;
  static int32_t  prevL      = 0;
  static int32_t  prevR      = 0;
  static bool     prevT1     = false;
  static bool     prevT2     = false;
  static float    velAccDs   = 0.0f;
  static float    velAccDt   = 0.0f;

  uint32_t nowUs = micros();
  if ((nowUs - lastCtrlUs) < 2000u) {
    delayMicroseconds(200);
    return;
  }
  float dt = (float)(nowUs - lastCtrlUs) * 1e-6f;
  lastCtrlUs = nowUs;
  if (dt <= 0.0f || dt > 0.1f) dt = 0.002f;

  uint32_t nowMs = millis();
  if ((nowMs - lastUsMs) >= 60u) {
    lastUsMs = nowMs;
    g_usMm = readUltrasonicMm();
  }

  uint32_t s0    = REG_READ(RTC_CNTL_STORE0_REG);
  uint8_t  magic = (s0 >> 28) & 0x0F;
  uint8_t  mode  = (s0 >> 24) & 0x0F;
  uint8_t  aux   = (s0 >> 16) & 0xFF;
  int8_t   cmdL  = (int8_t)((s0 >> 8) & 0xFF);
  int8_t   cmdR  = (int8_t)(s0 & 0xFF);

  if (magic == 0xF) {
    noInterrupts();
    g_encTicksL = 0; g_encTicksR = 0;
    interrupts();
    prevL = 0; prevR = 0;
    g_xMm = 0.0f; g_yMm = 0.0f; g_thetaRad = 0.0f;
    REG_WRITE(RTC_CNTL_STORE0_REG, (s0 & 0x0FFFFFFFu) | 0x10000000u);
  }

  bool lHit = analogRead(AGV_PIN_LINE_L) > LINE_ADC_THRESH;
  bool mHit = analogRead(AGV_PIN_LINE_M) > LINE_ADC_THRESH;
  bool rHit = analogRead(AGV_PIN_LINE_R) > LINE_ADC_THRESH;
  bool t1   = (digitalRead(AGV_PIN_BTN_T1) == LOW);
  bool t2   = (digitalRead(AGV_PIN_BTN_T2) == LOW);

  if (t1 && !prevT1) g_localMode = (g_localMode == 2) ? -1 : 2;
  if (t2 && !prevT2) g_localMode = 0;
  prevT1 = t1; prevT2 = t2;
  if (g_localMode >= 0 && mode != 0) mode = (uint8_t)g_localMode;
  if (mode == 0) g_localMode = -1;

  digitalWrite(AGV_PIN_LED_F, (aux & 0x01) ? HIGH : LOW);
  digitalWrite(AGV_PIN_LED_R, (aux & 0x02) ? HIGH : LOW);
  agvPwmWrite(AGV_PIN_BUZZER, 4, (aux & 0x04) ? (1u << (AGV_PWM_RES_BITS - 1)) : 0u);

  int8_t outL = 0, outR = 0;
  if (mode == 0) {
    g_fsmState = 0;
    g_pidInteg = 0.0f;
  } else if (mode == 1) {
    g_fsmState = 1;
    outL = cmdL;
    outR = cmdR;
  } else if (mode == 2) {
    if (g_usMm < 120) {
      g_fsmState = 4;
      outL = 0; outR = 0;
    } else {
      g_fsmState = 2;
      float err = 0.0f;
      int cnt = (lHit ? 1 : 0) + (mHit ? 1 : 0) + (rHit ? 1 : 0);
      if (cnt > 0) {
        err = ((rHit ? 1.0f : 0.0f) - (lHit ? 1.0f : 0.0f)) / (float)cnt;
        if (err != 0.0f) g_lastLineSign = (err > 0.0f) ? 1 : -1;
      } else {
        err = 1.2f * (float)g_lastLineSign;
      }
      g_pidInteg = constrain(g_pidInteg + err * dt, -1.5f, 1.5f);
      float deriv = (err - g_pidLastErr) / dt;
      g_pidLastErr = err;
      float corr = 38.0f * err + 0.5f * g_pidInteg + 0.45f * deriv;
      int basePct = 55;
      outL = (int8_t)constrain((int)(basePct + corr), -100, 100);
      outR = (int8_t)constrain((int)(basePct - corr), -100, 100);
    }
  }

  driveMotorPair(AGV_PIN_MOT_L_A, 0, AGV_PIN_MOT_L_B, 1, outL, g_dirSignL);
  driveMotorPair(AGV_PIN_MOT_R_A, 2, AGV_PIN_MOT_R_B, 3, outR, g_dirSignR);

  int32_t curL, curR;
  noInterrupts();
  curL = g_encTicksL; curR = g_encTicksR;
  interrupts();

  int32_t dTicksL = curL - prevL;
  int32_t dTicksR = curR - prevR;
  prevL = curL; prevR = curR;

  float mmPerTick = (3.1415926f * AGV_WHEEL_DIAM_MM) / (float)AGV_TICKS_PER_REV;
  float dL = (float)dTicksL * mmPerTick;
  float dR = (float)dTicksR * mmPerTick;
  float dS = 0.5f * (dL + dR);
  float dTh = (dR - dL) / AGV_WHEEL_BASE_MM;

  g_thetaRad += dTh;
  g_xMm += dS * cosf(g_thetaRad);
  g_yMm += dS * sinf(g_thetaRad);

  velAccDs += dS;
  velAccDt += dt;
  if (velAccDt >= 0.040f) {
    g_velMms = (int16_t)constrain((int)(velAccDs / velAccDt), -32767, 32767);
    velAccDs = 0.0f;
    velAccDt = 0.0f;
  }

  uint8_t senMask = (rHit ? 1 : 0) | (mHit ? 2 : 0) | (lHit ? 4 : 0) | (t1 ? 8 : 0) | (t2 ? 16 : 0);
  uint32_t s1 = ((uint32_t)((uint16_t)(int16_t)curL) << 16) | (uint16_t)(int16_t)curR;
  uint32_t s2 = ((uint32_t)g_usMm << 16) | ((uint32_t)senMask << 8) | (uint32_t)g_fsmState;
  uint32_t s3 = ((uint32_t)((uint16_t)(int16_t)g_xMm) << 16) | (uint16_t)(int16_t)g_yMm;
  int16_t thMrad = (int16_t)constrain((int)(g_thetaRad * 1000.0f), -32767, 32767);
  uint32_t s4 = ((uint32_t)((uint16_t)thMrad) << 16) | (uint16_t)g_velMms;

  REG_WRITE(RTC_CNTL_STORE1_REG, s1);
  REG_WRITE(RTC_CNTL_STORE2_REG, s2);
  REG_WRITE(RTC_CNTL_STORE3_REG, s3);
  REG_WRITE(RTC_CNTL_STORE4_REG, s4);
}