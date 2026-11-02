// Thin motor driver for the UNO Q microcontroller.
//
// All the logic (Bluetooth, command parsing) lives in python/main.py on the
// Linux side. This sketch exposes over the Bridge:
//
//   set_motors(left, right)   left/right in -100..100 (percent power);
//                             returns the obstacle distance in mm while the
//                             robot is blocked, or -1 when the way is clear
//   motors_found()            whether the Modulino Motors was detected
//   distance_found()          whether the Modulino Distance was detected
//
// Modulinos on the Qwiic (I2C) connector:
//   Modulino Motors   channel A = left motor, channel B = right motor
//   Modulino Distance facing forward; the robot stops when something is
//                     closer than STOP_DISTANCE_MM

#include <Arduino_RouterBridge.h>
#include <Arduino_Modulino.h>

// Flip these if a motor turns backwards when it should go forward
// (e.g. because the motors are mounted mirrored on the chassis).
const bool INVERT_LEFT = false;
const bool INVERT_RIGHT = false;

// Stop the motors if no command arrives for this long (lost link, crashed
// Python app, ...). Python sends a keep-alive well within this window.
const unsigned long FAILSAFE_MS = 500;

// Obstacle stop: blocked below STOP_DISTANCE_MM, clear again only above
// CLEAR_DISTANCE_MM so the robot does not stutter at the threshold.
const float STOP_DISTANCE_MM = 100;
const float CLEAR_DISTANCE_MM = 120;
// While blocked, still allow backing straight away from the obstacle
// (both motors reversing). Set to false to refuse every movement.
const bool ALLOW_REVERSE_WHEN_BLOCKED = true;

ModulinoMotors motors;
ModulinoDistance distance;
bool motorsFound = false;
bool distanceFound = false;

// Written by the Bridge callback, applied in loop() so that only one thread
// ever talks to the I2C bus.
volatile int requestedLeft = 0;
volatile int requestedRight = 0;
volatile unsigned long lastCommandMs = 0;

// Updated in loop(), read by the Bridge callback.
volatile bool obstacle = false;
volatile int obstacleMm = -1;

int appliedLeft = 0;
int appliedRight = 0;

unsigned long lastDetectMs = 0;

int set_motors(int left, int right) {
  requestedLeft = constrain(left, -100, 100);
  requestedRight = constrain(right, -100, 100);
  lastCommandMs = millis();
  return obstacle ? obstacleMm : -1;
}

bool motors_found() {
  return motorsFound;
}

bool distance_found() {
  return distanceFound;
}

// Looks for modules that were not found yet.
void detectModules() {
  if (!motorsFound) {
    motorsFound = motors.begin();
    if (motorsFound) {
      motors.setStepperModeEnabled(false);  // DC mode
      motors.setDecay(ModulinoMotors::DecayMode::SLOW);
    }
  }
  if (!distanceFound) {
    distanceFound = distance.begin();
  }
  // Blue LED on = a Modulino is missing on the Qwiic bus.
  digitalWrite(LED4_B, (motorsFound && distanceFound) ? HIGH : LOW);
}

void updateObstacle() {
  if (!distanceFound) {
    return;
  }
  // available() is false when nothing is in range: the way is clear.
  if (!distance.available()) {
    obstacle = false;
    obstacleMm = -1;
    return;
  }
  float mm = distance.get();
  if (mm < STOP_DISTANCE_MM) {
    obstacle = true;
  } else if (mm > CLEAR_DISTANCE_MM) {
    obstacle = false;
  }
  obstacleMm = (int)mm;
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
  detectModules();
  applyMotors(0, 0);

  Bridge.begin();
  Bridge.provide("set_motors", set_motors);
  Bridge.provide("motors_found", motors_found);
  Bridge.provide("distance_found", distance_found);
}

void loop() {
  // Keep looking for modules that were not there at startup.
  if ((!motorsFound || !distanceFound) && millis() - lastDetectMs > 2000) {
    lastDetectMs = millis();
    detectModules();
  }

  updateObstacle();

  int left = requestedLeft;
  int right = requestedRight;
  if (millis() - lastCommandMs > FAILSAFE_MS) {
    left = 0;
    right = 0;
  }
  bool backingAway = ALLOW_REVERSE_WHEN_BLOCKED && left <= 0 && right <= 0;
  if (obstacle && !backingAway) {
    left = 0;
    right = 0;
  }
  if (left != appliedLeft || right != appliedRight) {
    applyMotors(left, right);
  }
  delay(10);
}
