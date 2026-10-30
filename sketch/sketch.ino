// Thin motor driver for the UNO Q microcontroller.
//
// All the logic (Bluetooth, command parsing) lives in python/main.py on the
// Linux side. This sketch only exposes one function over the Bridge:
//
//   set_motors(left, right)   with left/right in -100..100 (percent power)
//
// The motors are driven by a Modulino Motors board on the Qwiic (I2C)
// connector: channel A = left motor, channel B = right motor.

#include <Arduino_RouterBridge.h>
#include <Arduino_Modulino.h>

// Flip these if a motor turns backwards when it should go forward
// (e.g. because the motors are mounted mirrored on the chassis).
const bool INVERT_LEFT = false;
const bool INVERT_RIGHT = false;

// Stop the motors if no command arrives for this long (lost link, crashed
// Python app, ...). Python sends a keep-alive well within this window.
const unsigned long FAILSAFE_MS = 500;

ModulinoMotors motors;
bool motorsFound = false;

// Written by the Bridge callback, applied in loop() so that only one thread
// ever talks to the I2C bus.
volatile int requestedLeft = 0;
volatile int requestedRight = 0;
volatile unsigned long lastCommandMs = 0;

int appliedLeft = 0;
int appliedRight = 0;

unsigned long lastDetectMs = 0;

void set_motors(int left, int right) {
  requestedLeft = constrain(left, -100, 100);
  requestedRight = constrain(right, -100, 100);
  lastCommandMs = millis();
}

bool motors_found() {
  return motorsFound;
}

bool detectMotors() {
  motorsFound = motors.begin();
  if (motorsFound) {
    motors.setStepperModeEnabled(false);  // DC mode
    motors.setDecay(ModulinoMotors::DecayMode::SLOW);
  }
  // Blue LED on = Modulino Motors not detected on the Qwiic bus.
  digitalWrite(LED4_B, motorsFound ? HIGH : LOW);
  return motorsFound;
}

int16_t toRaw(int percent, bool invert) {
  int32_t raw = (int32_t)percent * ModulinoMotors::MAX_SPEED / 100;
  return (int16_t)(invert ? -raw : raw);
}

void applyMotors(int left, int right) {
  if (motorsFound) {
    motors.setDcSpeedRaw(toRaw(left, INVERT_LEFT), toRaw(right, INVERT_RIGHT));
  }
  appliedLeft = left;
  appliedRight = right;

  // Status LED (LOW = on): green = a motor forward, red = a motor reversed.
  digitalWrite(LED4_G, (left > 0 || right > 0) ? LOW : HIGH);
  digitalWrite(LED4_R, (left < 0 || right < 0) ? LOW : HIGH);
}

void setup() {
  pinMode(LED4_R, OUTPUT);
  pinMode(LED4_G, OUTPUT);
  pinMode(LED4_B, OUTPUT);

  Modulino.begin();
  detectMotors();
  applyMotors(0, 0);

  Bridge.begin();
  Bridge.provide("set_motors", set_motors);
  Bridge.provide("motors_found", motors_found);
}

void loop() {
  // Keep looking for the module if it was not there at startup.
  if (!motorsFound && millis() - lastDetectMs > 2000) {
    lastDetectMs = millis();
    detectMotors();
  }

  int left = requestedLeft;
  int right = requestedRight;
  if (millis() - lastCommandMs > FAILSAFE_MS) {
    left = 0;
    right = 0;
  }
  if (left != appliedLeft || right != appliedRight) {
    applyMotors(left, right);
  }
  delay(10);
}
