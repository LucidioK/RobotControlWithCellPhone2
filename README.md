# Robot Control With Cell Phone

Drive a two-motor robot built on an **Arduino UNO Q** by tilting an Android phone.

```
Android phone (Kivy app, Python)
   │  Bluetooth Classic RFCOMM, 20 Hz, "L+100R-080\n"
   ▼
UNO Q Debian — python/host/bt_relay.py (RFCOMM channel 1 → Unix socket)
   │  <app>/.cache/phone.sock
   ▼
UNO Q App Lab container — python/main.py (parses, validates, keep-alive)
   │  Bridge.call("set_motors", left, right)
   ▼
UNO Q MCU — sketch/sketch.ino          (Modulino Motors over I2C, 500 ms failsafe)
```

See a robot with this code here: https://www.youtube.com/shorts/3nrknw-yI7w

## Deploying (PowerShell 7.3+)

```powershell
.\deploy_to_arduino.ps1               # USB if plugged in, else SSH over Wi-Fi
.\deploy_to_arduino.ps1 -Pair 120     # ...then open a 2-minute Bluetooth pairing window
.\deploy_to_android.ps1               # build the APK in WSL, install and start it
.\deploy_to_android.ps1 -SkipBuild    # install the last APK without rebuilding
```

Both scripts give USB devices back from usbipd/WSL (asking for administrator
rights only for forced bindings) and explain what to fix when something is in
the way. `Get-Help .\deploy_to_android.ps1 -Detailed` lists all options.

* **Arduino:** finds the board with `arduino-cli`, offers to set up SSH key
  access on first use, backs up the board's current app to
  `~/.robot-control-backups`, deploys with LF line endings, restarts the app
  (compiling and flashing the sketch) and the relay service, then reports
  whether the Modulino Motors was detected and which phones are paired.
* **Android:** creates the Buildozer environment in WSL on first use, repairs
  a corrupted Gradle cache, and detects: no phone/charge-only cable, USB
  debugging off, missing USB driver, computer not yet authorized, wrong CPU or
  Android version, and failed or blocked installs.

If scripts are blocked, run them with
`pwsh -ExecutionPolicy Bypass -File .\deploy_to_arduino.ps1`.

## Protocol

`L<sign><3 digits>R<sign><3 digits>` + newline, power in percent (0–100).
`L+100R-080` = left motor 100 % forward, right motor 80 % backward.

## Tilt mapping

Hold the phone flat, screen up, top edge pointing at the robot's front.

* Rotation about X (tilt top edge down/up) → throttle
* Rotation about Y (tilt right/left edge down) → steering
* 0° = 0 %, 45° = 100 % (linear, clamped beyond 45°)
* Differential mix: `left = throttle + steering`, `right = throttle − steering`, clamped to ±100

Change `MAX_ANGLE` in `Android/control.py` to adjust sensitivity.

## Safety

* The robot only moves while **HOLD TO DRIVE** is pressed; otherwise the phone sends `L+000R+000`.
* The app sends a stop when backgrounded or disconnected.
* `python/main.py` stops the motors if the phone is silent for 1 s or disconnects.
* The sketch stops the motors if no command reaches it for 500 ms.
* The sketch stops the robot when the Modulino Distance sees something closer
  than 10 cm (clear again above 12 cm). While blocked it still lets the robot
  back straight away; set `ALLOW_REVERSE_WHEN_BLOCKED = false` in
  `sketch/sketch.ino` to refuse every movement instead. The App Lab log shows
  `Obstacle at … cm` / `Way is clear again`.

## Arduino part (`app.yaml`, `python/`, `sketch/`)

The repository root is an Arduino App Lab app. Almost everything is Python;
the sketch is only a small motor driver, because the GPIO/PWM pins belong
to the microcontroller, not the Linux side.

App Lab runs `python/main.py` in a Docker container on its own network
namespace, and Linux only allows Bluetooth sockets in the host namespace
(`Errno 97`). So `python/host/bt_relay.py` (stdlib only) runs on the board's
Debian as a systemd user service and just copies the phone's bytes into a
Unix socket in the app folder, which the container also sees.

### Wiring (Modulino Motors + Modulino Distance)

Chain a **Modulino Motors** and a **Modulino Distance** to the UNO Q's Qwiic
connector with I2C cables. Left motor on channel **A**, right motor on channel
**B**, and the motor battery on the Modulino's motor power input. Mount the
distance sensor facing forward.

If a motor turns the wrong way, set `INVERT_LEFT` / `INVERT_RIGHT` in
`sketch/sketch.ino` (or swap that motor's two wires).

Status LED4 on the UNO Q: **green** = a motor is driven forward, **red** = a
motor is driven in reverse, **blue** = a Modulino is missing on the Qwiic bus
(the sketch keeps looking for it every 2 s).

### Install

1. Copy `app.yaml`, `python/` and `sketch/` to `~/ArduinoApps/robot-control/`
   on the board (e.g. `adb push`).
2. Start it from App Lab, or `arduino-app-cli app start user:robot-control`.
   The log should show `Waiting for phone via /app/.cache/phone.sock`.
3. Once, on the board: `sh ~/ArduinoApps/robot-control/python/host/install.sh`
   (installs and starts the relay service; check it with
   `journalctl --user -u robot-bt-relay -f`).

### One-time Bluetooth pairing on the board

Open a 10-minute pairing window from a shell on the UNO Q (`adb shell` or SSH):

```sh
( echo "agent NoInputNoOutput"; echo "default-agent"; echo "discoverable-timeout 600"; echo "discoverable on"; echo "pairable on"; for i in $(seq 300); do sleep 2; echo yes; done ) | bluetoothctl
```

Then pair the phone with the board from Android's Bluetooth settings. The
phone may also offer to use the board for calls/media audio; turn those off in
the paired device's settings — the robot link doesn't need them.

## Android part (`Android/`)

Written in Python with [Kivy](https://kivy.org), [plyer](https://github.com/kivy/plyer)
(accelerometer) and [pyjnius](https://github.com/kivy/pyjnius) (Android Bluetooth API).
Packaged with [Buildozer](https://buildozer.readthedocs.io), which runs on
Linux — on Windows use WSL2.

```sh
python3 -m venv ~/venvs/buildozer && . ~/venvs/buildozer/bin/activate
pip install buildozer cython
cd Android
buildozer android debug            # APK ends up in Android/bin/
adb install -r bin/*.apk
```

Build notes:
* Build only one architecture (`android.archs = arm64-v8a`). With two,
  python-for-android (2026.05) re-creates its venv over the first one and
  breaks pip (`cannot import name 'BuildDependencyInstallError'`).
* `Unexpected lock protocol found in lock file. Expected 3, found 0` from
  Gradle means `~/.gradle/caches` was corrupted (e.g. WSL shut down
  mid-build); move that folder away and rebuild.

Usage: pair the robot in Android settings → open the app → pick the robot →
**Connect** → hold **HOLD TO DRIVE** and tilt.

Tests for the tilt math (run anywhere): `python -m unittest discover -s Android/tests`

## Troubleshooting

* **Relay log says `Robot app not running`**: start the App Lab app; the
  relay drops phone connections while `phone.sock` doesn't exist.
* **Relay log says `Address already in use`**: another process holds RFCOMM
  channel 1. Change `RFCOMM_CHANNEL` in **both** `python/host/bt_relay.py`
  and `Android/bt_link.py`.
* **Connection failed** on the phone: the board doesn't advertise an SPP SDP
  record, so the app falls back to connecting straight to RFCOMM channel 1.
