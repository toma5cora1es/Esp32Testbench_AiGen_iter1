// ============================================================================
// FILE: firmware/esp32_bridge_ota/green_agv_cockpit.ino
// DESCRIPTION: Official FH Kaernten green_agv5.2a + Sensorboard rev 1.2 Firmware.
//              Exact Schematic Pinout:
//                - TC78H611 H-Bridge : R_FWD=D4, R_REV=D2, L_FWD=D13, L_REV=D12
//                - Wheel Encoders    : OUT_R=D18, OUT_L=D19 (74HC14D Schmitt)
//                - Floor Sensors     : SENS_L=D34, SENS_M=D32, SENS_R=D35 (TLC339D)
//                - Chassis LEDs      : Front=D25,D33 | Rear=D14,D23
//                - Pushbuttons       : T1=D5, T2=D15
//                - Ultrasonic HC-SR04: TRIG=D27, ECHO=D26
//                - I2C Expansion Bus : SDA=D21, SCL=D22 (APDS-9960 @ 0x39)
// ============================================================================

#include <Arduino.h>
#include <Wire.h>
#include "soc/rtc_cntl_reg.h"
#include "soc/gpio_reg.h"

// --- EXACT SCHEMATIC PINOUT (green_agv5.2a Sheet 1/3 & Slide 9) ---
#define PIN_MOT_R_REV   2    // IN1 (TC78H611 Right Motor Backwards)
#define PIN_MOT_R_FWD   4    // IN2 (TC78H611 Right Motor Forward)
#define PIN_MOT_L_REV   12   // IN4 (TC78H611 Left  Motor Backwards)
#define PIN_MOT_L_FWD   13   // IN3 (TC78H611 Left  Motor Forward)

#define PIN_ENC_R       18   // OUT_R (Shutterwheel Right, 20 pulses/rev)
#define PIN_ENC_L       19   // OUT_L (Shutterwheel Left,  20 pulses/rev)

#define PIN_BTN_T1      5    // Pushbutton T1 (Active HIGH)
#define PIN_BTN_T2      15   // Pushbutton T2 (JP5 1-2) or Servo SV2 (JP5 2-3)

#define PIN_LED_FRONT_L 25   // LED4 Front Left
#define PIN_LED_FRONT_R 33   // LED3 Front Right
#define PIN_LED_REAR_L  14   // LED5 Rear Left (JP4 1-2) or Servo SV1 (JP4 2-3)
#define PIN_LED_REAR_R  23   // LED6 Rear Right

#define PIN_US_TRIG     27   // HC-SR04 Trigger (Sensorboard JP2 1-2)
#define PIN_US_ECHO     26   // HC-SR04 Echo    (Sensorboard JP1 1-2)

#define PIN_LINE_L      34   // SENS_L (JP1 1-2)
#define PIN_LINE_M      32   // SENS_M (JP3 1-2) or Buzzer (JP3 2-3 & Sensorboard JP5 1-2)
#define PIN_LINE_R      35   // SENS_R (JP2 1-2)

#define PIN_I2C_SDA     21   // I2C_1..3 SDA
#define PIN_I2C_SCL     22   // I2C_1..3 SCL

// Physical Chassis Constants
static const float WHEEL_DIAM_MM  = 65.0f;
static const float WHEEL_TRACK_MM = 135.0f;
static const float TICKS_PER_REV  = 20.0f;
static const float MM_PER_TICK    = (3.14159265f * WHEEL_DIAM_MM) / TICKS_PER_REV;

// Volatile ISR State
static volatile int32_t  _encTicksL   = 0;
static volatile int32_t  _encTicksR   = 0;
static volatile int8_t   _dirL        = 1;
static volatile int8_t   _dirR        = 1;
static volatile uint32_t _echoStartUs = 0;
static volatile uint16_t _usDistMm    = 2500;

static float    _xMm       = 0.0f;
static float    _yMm       = 0.0f;
static float    _thetaRad  = 0.0f;
static float    _pidInteg  = 0.0f;
static float    _pidPrevE  = 0.0f;
static uint32_t _beepEndMs = 0;
static bool     _servoMode = false;

void IRAM_ATTR _isrEncL() { _encTicksL += _dirL; }
void IRAM_ATTR _isrEncR() { _encTicksR += _dirR; }

void IRAM_ATTR _isrUltrasonicEcho() {
  if (digitalRead(PIN_US_ECHO) == HIGH) {
    _echoStartUs = micros();
  } else {
    uint32_t dur = micros() - _echoStartUs;
    if (dur > 100 && dur < 25000) {
      _usDistMm = (uint16_t)((dur * 343UL) / 2000UL);
    } else {
      _usDistMm = 2500;
    }
  }
}

static void _driveMotors(int16_t pctL, int16_t pctR) {
  pctL = constrain(pctL, -100, 100);
  pctR = constrain(pctR, -100, 100);
  _dirL = (pctL >= 0) ? 1 : -1;
  _dirR = (pctR >= 0) ? 1 : -1;

  uint32_t dutyL = (uint32_t)((abs(pctL) * 1023) / 100);
  uint32_t dutyR = (uint32_t)((abs(pctR) * 1023) / 100);

  if (pctL >= 0) { ledcWrite(PIN_MOT_L_FWD, dutyL); ledcWrite(PIN_MOT_L_REV, 0); }
  else           { ledcWrite(PIN_MOT_L_FWD, 0);     ledcWrite(PIN_MOT_L_REV, dutyL); }

  if (pctR >= 0) { ledcWrite(PIN_MOT_R_FWD, dutyR); ledcWrite(PIN_MOT_R_REV, 0); }
  else           { ledcWrite(PIN_MOT_R_FWD, 0);     ledcWrite(PIN_MOT_R_REV, dutyR); }
}

void setup() {
  pinMode(PIN_ENC_L, INPUT);
  pinMode(PIN_ENC_R, INPUT);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_L), _isrEncL, RISING);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_R), _isrEncR, RISING);

  pinMode(PIN_US_TRIG, OUTPUT);
  pinMode(PIN_US_ECHO, INPUT);
  attachInterrupt(digitalPinToInterrupt(PIN_US_ECHO), _isrUltrasonicEcho, CHANGE);

  pinMode(PIN_LINE_L, INPUT);
  pinMode(PIN_LINE_M, INPUT);
  pinMode(PIN_LINE_R, INPUT);
  pinMode(PIN_BTN_T1, INPUT);
  pinMode(PIN_BTN_T2, INPUT);

  pinMode(PIN_LED_FRONT_L, OUTPUT);
  pinMode(PIN_LED_FRONT_R, OUTPUT);
  pinMode(PIN_LED_REAR_L,  OUTPUT);
  pinMode(PIN_LED_REAR_R,  OUTPUT);

  // Attach TC78H611 H-Bridge PWM Channels (2.0 kHz, 10-bit resolution)
  ledcAttach(PIN_MOT_L_FWD, 2000, 10);
  ledcAttach(PIN_MOT_L_REV, 2000, 10);
  ledcAttach(PIN_MOT_R_FWD, 2000, 10);
  ledcAttach(PIN_MOT_R_REV, 2000, 10);
  _driveMotors(0, 0);

  // Initialize RTC_CNTL_STORE0_REG Mailbox (Magic=1, Mode=1 Manual, Lights=0, Speed=0)
  *(volatile uint32_t*)0x3FF4804CUL = 0x11000000UL;
}

void loop() {
  static uint32_t lastOdomMs = millis();
  static uint32_t lastUsMs   = millis();
  static int32_t  prevTicksL = 0;
  static int32_t  prevTicksR = 0;

  uint32_t now = millis();

  // 1. Non-Blocking Ultrasonic Trigger (Every 60 ms)
  if (now - lastUsMs >= 60) {
    lastUsMs = now;
    digitalWrite(PIN_US_TRIG, LOW);
    delayMicroseconds(2);
    digitalWrite(PIN_US_TRIG, HIGH);
    delayMicroseconds(10);
    digitalWrite(PIN_US_TRIG, LOW);
  }

  // Stop non-blocking buzzer tone when duration expires
  if (_beepEndMs > 0 && now >= _beepEndMs) {
    _beepEndMs = 0;
    ledcDetach(PIN_LINE_M);
    pinMode(PIN_LINE_M, INPUT);
  }

  // 2. 50 Hz (20 ms) Real-Time Control, Odometry & Sensor Mailbox Loop
  if (now - lastOdomMs >= 20) {
    float dt = (now - lastOdomMs) / 1000.0f;
    lastOdomMs = now;

    // Unpack RTC_CNTL_STORE0_REG (0x3FF4804C):
    // [31:28] Magic | [27:24] Mode | [23:16] AuxMask | [15:8] CmdL | [7:0] CmdR
    // AuxMask bits: Bit0=FrontLEDs(D25/D33), Bit1=RearLEDs(D14/D23), Bit2=Buzzer(D32), Bit3=ServoMode(D14)
    uint32_t cmdWord = *(volatile uint32_t*)0x3FF4804CUL;
    uint8_t  magic   = (cmdWord >> 28) & 0x0F;
    uint8_t  mode    = (cmdWord >> 24) & 0x0F;
    uint8_t  auxMask = (cmdWord >> 16) & 0xFF;
    int8_t   cmdL    = (int8_t)((cmdWord >> 8) & 0xFF);
    int8_t   cmdR    = (int8_t)(cmdWord & 0xFF);

    if (magic == 0x0F) {
      // Zero Odometry Reset
      _encTicksL = 0; _encTicksR = 0;
      prevTicksL = 0; prevTicksR = 0;
      _xMm = 0.0f; _yMm = 0.0f; _thetaRad = 0.0f;
      *(volatile uint32_t*)0x3FF4804CUL = (cmdWord & 0x0FFFFFFFUL) | 0x10000000UL;
    }

    // Headlights (D25, D33) & Rear LEDs (D14, D23)
    digitalWrite(PIN_LED_FRONT_L, (auxMask & 0x01) ? HIGH : LOW);
    digitalWrite(PIN_LED_FRONT_R, (auxMask & 0x01) ? HIGH : LOW);
    digitalWrite(PIN_LED_REAR_R,  (auxMask & 0x02) ? HIGH : LOW);

    // Optional Servo SV1 on D14 (Bit 3 of AuxMask) vs Rear LED5 on D14
    if (auxMask & 0x08) {
      if (!_servoMode) { ledcAttach(PIN_LED_REAR_L, 50, 10); _servoMode = true; }
      // Map AuxMask[7:4] (0..15) to 50Hz Servo Pulse (500..2400 us -> duty 26..123 of 1023)
      uint8_t srvNib = (auxMask >> 4) & 0x0F;
      uint32_t srvDuty = 26 + (srvNib * 97) / 15;
      ledcWrite(PIN_LED_REAR_L, srvDuty);
    } else {
      if (_servoMode) { ledcDetach(PIN_LED_REAR_L); pinMode(PIN_LED_REAR_L, OUTPUT); _servoMode = false; }
      digitalWrite(PIN_LED_REAR_L, (auxMask & 0x02) ? HIGH : LOW);
    }

    // Optional Buzzer Horn on D32 (Bit 2 of AuxMask; requires JP3 2-3 & Sensorboard JP5 1-2)
    if ((auxMask & 0x04) && _beepEndMs == 0) {
      ledcAttach(PIN_LINE_M, 2000, 10);
      ledcWrite(PIN_LINE_M, 400); // 40% duty cycle per Slide 42
      _beepEndMs = now + 120;
      // Clear buzzer trigger bit so it doesn't loop forever
      *(volatile uint32_t*)0x3FF4804CUL = cmdWord & ~(0x04UL << 16);
    }

    // Read Floor Sensors (D34=L, D32=M, D35=R) & Pushbuttons (T1=D5, T2=D15)
    uint8_t bL  = digitalRead(PIN_LINE_L) ? 1 : 0;
    uint8_t bM  = (_beepEndMs == 0 && digitalRead(PIN_LINE_M)) ? 1 : 0;
    uint8_t bR  = digitalRead(PIN_LINE_R) ? 1 : 0;
    uint8_t t1  = digitalRead(PIN_BTN_T1) ? 1 : 0;
    uint8_t t2  = digitalRead(PIN_BTN_T2) ? 1 : 0;
    // Pack sensor byte: [4]T2 | [3]T1 | [2]Line_L | [1]Line_M | [0]Line_R
    uint8_t senMask = (t2 << 4) | (t1 << 3) | (bL << 2) | (bM << 1) | bR;
    uint8_t lineOnly = senMask & 0x07;

    // Differential Wheel Odometry
    int32_t curL = _encTicksL;
    int32_t curR = _encTicksR;
    float dL = (curL - prevTicksL) * MM_PER_TICK;
    float dR = (curR - prevTicksR) * MM_PER_TICK;
    prevTicksL = curL;
    prevTicksR = curR;

    float dCenter = 0.5f * (dL + dR);
    float dTheta  = (dR - dL) / WHEEL_TRACK_MM;
    _thetaRad += dTheta;
    if (_thetaRad >  3.14159f) _thetaRad -= 6.28318f;
    if (_thetaRad < -3.14159f) _thetaRad += 6.28318f;

    _xMm += dCenter * cosf(_thetaRad);
    _yMm += dCenter * sinf(_thetaRad);
    int16_t velMms = (dt > 0.001f) ? (int16_t)(dCenter / dt) : 0;

    // Motion Control FSM
    uint8_t fsmState = mode;
    if (_usDistMm < 150 && (mode == 2 || (cmdL > 0 && cmdR > 0))) {
      fsmState = 4; // FAULT_OBSTACLE_HOLD
      _driveMotors(0, 0);
    } else if (mode == 0) {
      _driveMotors(0, 0);
    } else if (mode == 1) {
      _driveMotors(cmdL, cmdR);
    } else if (mode == 2) {
      float err = 0.0f;
      if      (lineOnly == 0b100) err = -2.0f;
      else if (lineOnly == 0b110) err = -1.0f;
      else if (lineOnly == 0b010) err =  0.0f;
      else if (lineOnly == 0b011) err = +1.0f;
      else if (lineOnly == 0b001) err = +2.0f;
      else                        err = _pidPrevE;

      _pidInteg = constrain(_pidInteg + err * dt, -5.0f, 5.0f);
      float deriv = (err - _pidPrevE) / dt;
      _pidPrevE = err;

      float turn = 22.0f * err + 1.5f * _pidInteg + 2.5f * deriv;
      int16_t baseSpd = 55;
      _driveMotors((int16_t)(baseSpd - turn), (int16_t)(baseSpd + turn));
    }

    // Write Telemetry Mailbox (RTC_CNTL_STORE1..4_REG: 0x3FF48050..0x3FF4805C)
    uint16_t uEncL = (uint16_t)((int16_t)curL);
    uint16_t uEncR = (uint16_t)((int16_t)curR);
    uint16_t uX    = (uint16_t)((int16_t)_xMm);
    uint16_t uY    = (uint16_t)((int16_t)_yMm);
    uint16_t uTh   = (uint16_t)((int16_t)(_thetaRad * 1000.0f));
    uint16_t uVel  = (uint16_t)velMms;

    *(volatile uint32_t*)0x3FF48050UL = ((uint32_t)uEncL << 16) | uEncR;
    *(volatile uint32_t*)0x3FF48054UL = ((uint32_t)_usDistMm << 16) | ((uint32_t)senMask << 8) | fsmState;
    *(volatile uint32_t*)0x3FF48058UL = ((uint32_t)uX << 16) | uY;
    *(volatile uint32_t*)0x3FF4805CUL = ((uint32_t)uTh << 16) | uVel;
  }
  delay(2);
}