#include <Arduino.h>
#include <esp_arduino_version.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"

static volatile int32_t  g_encTicksL = 0, g_encTicksR = 0;
static volatile uint32_t g_lastIsrL  = 0, g_lastIsrR  = 0;
static volatile int8_t   g_dirL = 1, g_dirR = 1;
static float g_xMm = 0.0f, g_yMm = 0.0f, g_thetaRad = 0.0f;
static int16_t g_velMms = 0; static uint16_t g_usMm = 3000; static uint8_t g_fsm = 0; static int8_t g_locMode = -1;
static float g_lastErr = 0.0f, g_integ = 0.0f; static int8_t g_lastSign = 1;

void IRAM_ATTR isrEncL() { uint32_t t = micros(); if ((t - g_lastIsrL) >= 500u) { g_encTicksL += g_dirL; g_lastIsrL = t; } }
void IRAM_ATTR isrEncR() { uint32_t t = micros(); if ((t - g_lastIsrR) >= 500u) { g_encTicksR += g_dirR; g_lastIsrR = t; } }

static inline void agvPwmAttach(uint8_t pin, uint8_t ch) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(pin, AGV_PWM_FREQ_HZ, AGV_PWM_RES_BITS);
#else
  ledcSetup(ch, AGV_PWM_FREQ_HZ, AGV_PWM_RES_BITS); ledcAttachPin(pin, ch);
#endif
  (void)ch;
}
static inline void agvPwmWrite(uint8_t pin, uint8_t ch, uint32_t d) {
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(pin, d);
#else
  ledcWrite(ch, d);
#endif
  (void)ch;
}
static void drivePair(uint8_t pA, uint8_t cA, uint8_t pB, uint8_t cB, int8_t pct, volatile int8_t& dir) {
  int p = constrain((int)pct, -100, 100); uint32_t mx = (1u << AGV_PWM_RES_BITS) - 1u;
  if (p > 0) { dir = 1; agvPwmWrite(pA, cA, (uint32_t)(p * (int)mx / 100)); agvPwmWrite(pB, cB, 0); }
  else if (p < 0) { dir = -1; agvPwmWrite(pA, cA, 0); agvPwmWrite(pB, cB, (uint32_t)((-p) * (int)mx / 100)); }
  else { agvPwmWrite(pA, cA, 0); agvPwmWrite(pB, cB, 0); }
}
static uint16_t readUsMm() {
  digitalWrite(AGV_PIN_US_TRIG, LOW); delayMicroseconds(2);
  digitalWrite(AGV_PIN_US_TRIG, HIGH); delayMicroseconds(10);
  digitalWrite(AGV_PIN_US_TRIG, LOW);
  unsigned long d = pulseIn(AGV_PIN_US_ECHO, HIGH, 12000u);
  return (d < 100u) ? 3000 : (uint16_t)min(3000UL, (d * 343UL) / 2000UL);
}

void setup() {
  agvPwmAttach(AGV_PIN_MOT_L_A,0); agvPwmAttach(AGV_PIN_MOT_L_B,1);
  agvPwmAttach(AGV_PIN_MOT_R_A,2); agvPwmAttach(AGV_PIN_MOT_R_B,3);
  drivePair(AGV_PIN_MOT_L_A,0,AGV_PIN_MOT_L_B,1,0,g_dirL); drivePair(AGV_PIN_MOT_R_A,2,AGV_PIN_MOT_R_B,3,0,g_dirR);

  pinMode(AGV_PIN_ENC_L, INPUT_PULLUP); pinMode(AGV_PIN_ENC_R, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(AGV_PIN_ENC_L), isrEncL, RISING);
  attachInterrupt(digitalPinToInterrupt(AGV_PIN_ENC_R), isrEncR, RISING);

  pinMode(AGV_PIN_US_TRIG, OUTPUT); digitalWrite(AGV_PIN_US_TRIG, LOW); pinMode(AGV_PIN_US_ECHO, INPUT_PULLDOWN);
  pinMode(AGV_PIN_LINE_L, INPUT); pinMode(AGV_PIN_LINE_M, INPUT); pinMode(AGV_PIN_LINE_R, INPUT);
  pinMode(AGV_PIN_BTN_T1, INPUT_PULLDOWN); pinMode(AGV_PIN_BTN_T2, INPUT_PULLDOWN);
  pinMode(AGV_PIN_LED_FL, OUTPUT); pinMode(AGV_PIN_LED_FR, OUTPUT);
  pinMode(AGV_PIN_LED_RR, OUTPUT); pinMode(AGV_PIN_LED_RL, OUTPUT);
}

void loop() {
  static uint32_t lastUs = 0, lastPing = 0; static int32_t pL = 0, pR = 0;
  static bool prevT1 = false, prevT2 = false; static float vDs = 0.0f, vDt = 0.0f;
  uint32_t now = micros(); if ((now - lastUs) < 2000u) { delayMicroseconds(200); return; }
  float dt = (float)(now - lastUs) * 1e-6f; lastUs = now; if (dt <= 0.0f || dt > 0.1f) dt = 0.002f;
  if ((millis() - lastPing) >= 60u) { lastPing = millis(); g_usMm = readUsMm(); }

  uint32_t s0 = REG_READ(RTC_CNTL_STORE0_REG);
  uint8_t magic = (s0>>28)&15, mode = (s0>>24)&15, aux = (s0>>16)&255;
  int8_t cmdL = (int8_t)((s0>>8)&255), cmdR = (int8_t)(s0&255);
  if (magic == 0xF) {
    noInterrupts(); g_encTicksL=0; g_encTicksR=0; interrupts();
    pL=0; pR=0; g_xMm=0; g_yMm=0; g_thetaRad=0;
    REG_WRITE(RTC_CNTL_STORE0_REG, (s0 & 0x0FFFFFFFu) | 0x10000000u);
  }

  bool lH=(digitalRead(AGV_PIN_LINE_L)==HIGH), mH=(digitalRead(AGV_PIN_LINE_M)==HIGH), rH=(digitalRead(AGV_PIN_LINE_R)==HIGH);
  bool t1=(digitalRead(AGV_PIN_BTN_T1)==AGV_BTN_ACT_LVL), t2=(digitalRead(AGV_PIN_BTN_T2)==AGV_BTN_ACT_LVL);
  if (t1 && !prevT1) g_locMode = (g_locMode == 2) ? -1 : 2;
  if (t2 && !prevT2) g_locMode = 0;
  prevT1 = t1; prevT2 = t2;
  if (g_locMode >= 0 && mode != 0) mode = (uint8_t)g_locMode;
  if (mode == 0) g_locMode = -1;

  digitalWrite(AGV_PIN_LED_FL, (aux&1)?HIGH:LOW); digitalWrite(AGV_PIN_LED_FR, (aux&1)?HIGH:LOW);
  digitalWrite(AGV_PIN_LED_RR, (aux&2)?HIGH:LOW); digitalWrite(AGV_PIN_LED_RL, (aux&2)?HIGH:LOW);

  int8_t oL = 0, oR = 0;
  if (mode == 0) { g_fsm = 0; g_integ = 0; }
  else if (mode == 1) { g_fsm = 1; oL = cmdL; oR = cmdR; }
  else if (mode == 2) {
    if (g_usMm < 120) { g_fsm = 4; }
    else {
      g_fsm = 2; int cnt = (lH?1:0)+(mH?1:0)+(rH?1:0);
      float err = cnt ? (((rH?1.0f:0.0f)-(lH?1.0f:0.0f))/(float)cnt) : (1.2f*(float)g_lastSign);
      if (cnt && err != 0.0f) g_lastSign = (err > 0.0f) ? 1 : -1;
      g_integ = constrain(g_integ + err*dt, -1.5f, 1.5f);
      float deriv = (err - g_lastErr) / dt; g_lastErr = err;
      float corr = 38.0f*err + 0.5f*g_integ + 0.45f*deriv;
      oL = (int8_t)constrain((int)(55 + corr), -100, 100);
      oR = (int8_t)constrain((int)(55 - corr), -100, 100);
    }
  }
  drivePair(AGV_PIN_MOT_L_A,0,AGV_PIN_MOT_L_B,1,oL,g_dirL); drivePair(AGV_PIN_MOT_R_A,2,AGV_PIN_MOT_R_B,3,oR,g_dirR);

  int32_t cL, cR; noInterrupts(); cL=g_encTicksL; cR=g_encTicksR; interrupts();
  int32_t dTL=cL-pL, dTR=cR-pR; pL=cL; pR=cR;
  float mmPt = (3.1415926f * AGV_WHEEL_DIAM_MM) / (float)AGV_TICKS_PER_REV;
  float dL=dTL*mmPt, dR=dTR*mmPt, dS=0.5f*(dL+dR), dTh=(dR-dL)/AGV_WHEEL_BASE_MM;
  g_thetaRad += dTh; g_xMm += dS*cosf(g_thetaRad); g_yMm += dS*sinf(g_thetaRad);
  vDs += dS; vDt += dt;
  if (vDt >= 0.040f) { g_velMms = (int16_t)constrain((int)(vDs/vDt), -32767, 32767); vDs=0; vDt=0; }

  uint8_t msk = (rH?1:0)|(mH?2:0)|(lH?4:0)|(t1?8:0)|(t2?16:0);
  REG_WRITE(RTC_CNTL_STORE1_REG, ((uint32_t)(uint16_t)(int16_t)cL<<16)|(uint16_t)(int16_t)cR);
  REG_WRITE(RTC_CNTL_STORE2_REG, ((uint32_t)g_usMm<<16)|((uint32_t)msk<<8)|g_fsm);
  REG_WRITE(RTC_CNTL_STORE3_REG, ((uint32_t)(uint16_t)(int16_t)g_xMm<<16)|(uint16_t)(int16_t)g_yMm);
  REG_WRITE(RTC_CNTL_STORE4_REG, ((uint32_t)(uint16_t)(int16_t)constrain((int)(g_thetaRad*1000.0f),-32767,32767)<<16)|(uint16_t)g_velMms);
}
