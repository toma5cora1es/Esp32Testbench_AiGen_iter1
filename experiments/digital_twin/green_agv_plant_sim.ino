#include <Arduino.h>
#include "driver/gpio.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"

struct PwmCap { uint8_t pin; volatile uint32_t lastRiseUs, highUs, periodUs, lastEdgeUs; volatile uint16_t edgeCount; };
static portMUX_TYPE g_simMux = portMUX_INITIALIZER_UNLOCKED;
static PwmCap g_cap[4] = {
  {SIM_MOT_LA_IN,0,0,0,0,0}, {SIM_MOT_LB_IN,0,0,0,0,0},
  {SIM_MOT_RA_IN,0,0,0,0,0}, {SIM_MOT_RB_IN,0,0,0,0,0}
};

static inline void IRAM_ATTR handlePwmEdge(int idx) {
  uint32_t now = (uint32_t)esp_timer_get_time();
  portENTER_CRITICAL_ISR(&g_simMux);
  g_cap[idx].lastEdgeUs = now; g_cap[idx].edgeCount++;
  if (gpio_get_level((gpio_num_t)g_cap[idx].pin) == 1) {
    uint32_t per = now - g_cap[idx].lastRiseUs;
    if (per >= 100u && per <= 50000u) g_cap[idx].periodUs = per;
    g_cap[idx].lastRiseUs = now;
  } else {
    uint32_t hi = now - g_cap[idx].lastRiseUs;
    if (hi <= 50000u) g_cap[idx].highUs = hi;
  }
  portEXIT_CRITICAL_ISR(&g_simMux);
}
void IRAM_ATTR isrPwm0() { handlePwmEdge(0); } void IRAM_ATTR isrPwm1() { handlePwmEdge(1); }
void IRAM_ATTR isrPwm2() { handlePwmEdge(2); } void IRAM_ATTR isrPwm3() { handlePwmEdge(3); }

static volatile bool g_trigSeen = false; static volatile uint32_t g_trigUs = 0; static volatile uint16_t g_trigCount = 0;
void IRAM_ATTR isrUsTrig() {
  portENTER_CRITICAL_ISR(&g_simMux);
  g_trigUs = (uint32_t)esp_timer_get_time(); g_trigSeen = true; g_trigCount++;
  portEXIT_CRITICAL_ISR(&g_simMux);
}

static void readCap(int i, float* dutyPct, uint16_t* freqHz) {
  uint32_t now = (uint32_t)esp_timer_get_time();
  portENTER_CRITICAL(&g_simMux);
  uint32_t age = now - g_cap[i].lastEdgeUs, hi = g_cap[i].highUs, per = g_cap[i].periodUs; uint16_t ec = g_cap[i].edgeCount;
  if (age > 6000u) g_cap[i].edgeCount = 0;
  portEXIT_CRITICAL(&g_simMux);
  if (age > 6000u || per == 0 || ec < 3) { *dutyPct = (digitalRead(g_cap[i].pin)==HIGH)?100.0f:0.0f; *freqHz = 0; }
  else { *dutyPct = constrain(100.0f*(float)hi/(float)per, 0.0f, 100.0f); *freqHz = (uint16_t)min(65535UL, (unsigned long)(1000000UL/per)); }
}

void setup() {
  for (int i=0;i<4;++i) pinMode(g_cap[i].pin, INPUT_PULLDOWN);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_LA_IN), isrPwm0, CHANGE);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_LB_IN), isrPwm1, CHANGE);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_RA_IN), isrPwm2, CHANGE);
  attachInterrupt(digitalPinToInterrupt(SIM_MOT_RB_IN), isrPwm3, CHANGE);
  pinMode(SIM_US_TRIG_IN, INPUT_PULLDOWN); attachInterrupt(digitalPinToInterrupt(SIM_US_TRIG_IN), isrUsTrig, FALLING);

  pinMode(SIM_US_ECHO_OUT,OUTPUT); digitalWrite(SIM_US_ECHO_OUT,LOW);
  pinMode(SIM_LINE_L_OUT,OUTPUT); digitalWrite(SIM_LINE_L_OUT,LOW);
  pinMode(SIM_LINE_M_OUT,OUTPUT); digitalWrite(SIM_LINE_M_OUT,HIGH);
  pinMode(SIM_LINE_R_OUT,OUTPUT); digitalWrite(SIM_LINE_R_OUT,LOW);
  pinMode(SIM_BTN_T1_OUT,OUTPUT); digitalWrite(SIM_BTN_T1_OUT,LOW);
  pinMode(SIM_BTN_T2_OUT,OUTPUT); digitalWrite(SIM_BTN_T2_OUT,LOW);
  pinMode(SIM_ENC_L_OUT,OUTPUT); digitalWrite(SIM_ENC_L_OUT,LOW);
  pinMode(SIM_ENC_R_OUT,OUTPUT); digitalWrite(SIM_ENC_R_OUT,LOW);
  pinMode(SIM_LED_FL_IN,INPUT_PULLDOWN); pinMode(SIM_LED_FR_IN,INPUT_PULLDOWN);
  pinMode(SIM_LED_RR_IN,INPUT_PULLDOWN); pinMode(SIM_LED_RL_IN,INPUT_PULLDOWN);
  REG_WRITE(RTC_CNTL_STORE0_REG, 0x10020258u);
}

void loop() {
  static uint32_t lastPhys = (uint32_t)esp_timer_get_time(), eStart = 0, eEnd = 0; static uint8_t ePh = 0;
  static float phL = 0.0f, phR = 0.0f; static int16_t encL = 0, encR = 0;
  uint32_t s0 = REG_READ(RTC_CNTL_STORE0_REG);
  uint8_t autoTrk=(s0>>24)&15, btns=(s0>>20)&15, lineMsk=(s0>>16)&15; uint16_t distMm=(uint16_t)(s0&0xFFFFu);
  if (distMm < 30) distMm = 3000;

  uint32_t now = (uint32_t)esp_timer_get_time(); bool trigNow=false; uint32_t t0=0;
  portENTER_CRITICAL(&g_simMux);
  if (g_trigSeen) { g_trigSeen=false; t0=g_trigUs; trigNow=true; }
  uint16_t trigSnap = g_trigCount;
  portEXIT_CRITICAL(&g_simMux);

  if (trigNow) { eStart = t0 + 420u; eEnd = eStart + (uint32_t)(distMm * 5.831f); ePh = 1; }
  if (ePh == 1 && (int32_t)(now - eStart) >= 0) { digitalWrite(SIM_US_ECHO_OUT, HIGH); ePh = 2; }
  else if (ePh == 2 && (int32_t)(now - eEnd) >= 0) { digitalWrite(SIM_US_ECHO_OUT, LOW); ePh = 0; }

  if (autoTrk) { static const uint8_t seq[6]={2,6,4,2,3,1}; lineMsk=seq[(millis()/1200u)%6u]; }
  digitalWrite(SIM_LINE_L_OUT,(lineMsk&4)?HIGH:LOW); digitalWrite(SIM_LINE_M_OUT,(lineMsk&2)?HIGH:LOW); digitalWrite(SIM_LINE_R_OUT,(lineMsk&1)?HIGH:LOW);
  digitalWrite(SIM_BTN_T1_OUT,(btns&1)?HIGH:LOW); digitalWrite(SIM_BTN_T2_OUT,(btns&2)?HIGH:LOW);

  float dt = (float)(now - lastPhys) * 1e-6f;
  if (dt >= 0.001f) {
    lastPhys = now; float dLA,dLB,dRA,dRB; uint16_t fLA,fLB,fRA,fRB;
    readCap(0,&dLA,&fLA); readCap(1,&dLB,&fLB); readCap(2,&dRA,&fRA); readCap(3,&dRB,&fRB);
    int16_t netL=(int16_t)roundf(dLA-dLB), netR=(int16_t)roundf(dRA-dRB);
    uint16_t fL=(dLA>=dLB)?fLA:fLB, fR=(dRA>=dRB)?fRA:fRB;

    phL += fabsf((float)netL)*0.45f*dt; phR += fabsf((float)netR)*0.45f*dt;
    if (phL>=1.0f){phL-=1.0f; encL+=(netL>=0)?1:-1;} if (phR>=1.0f){phR-=1.0f; encR+=(netR>=0)?1:-1;}
    digitalWrite(SIM_ENC_L_OUT, (phL<0.5f && netL!=0)?HIGH:LOW);
    digitalWrite(SIM_ENC_R_OUT, (phR<0.5f && netR!=0)?HIGH:LOW);

    uint8_t leds=(digitalRead(SIM_LED_FL_IN)?1:0)|(digitalRead(SIM_LED_FR_IN)?2:0)|(digitalRead(SIM_LED_RR_IN)?4:0)|(digitalRead(SIM_LED_RL_IN)?8:0);
    REG_WRITE(RTC_CNTL_STORE1_REG, ((uint32_t)(uint16_t)netL<<16)|(uint16_t)netR);
    REG_WRITE(RTC_CNTL_STORE2_REG, ((uint32_t)fL<<16)|(uint32_t)fR);
    REG_WRITE(RTC_CNTL_STORE3_REG, ((uint32_t)leds<<16)|(uint32_t)trigSnap);
    REG_WRITE(RTC_CNTL_STORE4_REG, ((uint32_t)(uint16_t)encL<<16)|(uint16_t)encR);
  }
  delayMicroseconds(20);
}
