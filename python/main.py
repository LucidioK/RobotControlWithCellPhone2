"""Phone -> motor bridge for the Arduino UNO Q (Linux side, App Lab app).

The Android app streams newline-terminated commands such as:

    L+100R-080      left motor 100% forward, right motor 80% backward

App Lab runs this file in a container, which cannot open Bluetooth sockets.
So host/bt_relay.py (running on the board's Debian) accepts the phone's
Bluetooth connection and passes the bytes to the Unix socket served here.

Each valid command is forwarded to the microcontroller sketch through the
Bridge as set_motors(left, right).
"""

import os
import re
import socket
import threading
import time
from pathlib import Path

from arduino.app_utils import App, Bridge

# Inside the container the app folder is /app; on the host it is
# ~/ArduinoApps/<app>. Both sides see this socket at <app>/.cache/phone.sock.
PHONE_SOCKET = Path(__file__).resolve().parent.parent / ".cache" / "phone.sock"

# Startup status, also written here for deploy_to_arduino.ps1 to read (the
# container log is not always readable from the host).
STATUS_FILE = PHONE_SOCKET.with_name("status.txt")

# Resend the current command at least this often so the sketch failsafe
# (500 ms) does not stop the motors while the phone holds a steady tilt.
KEEPALIVE_S = 0.2

# Drop the connection (and stop) if the phone goes silent this long.
CLIENT_TIMEOUT_S = 1.0

MAX_LINE = 64

LOG_INTERVAL_S = 1.0

COMMAND_RE = re.compile(r"^L([+-])(\d{3})R([+-])(\d{3})$")


def report(message):
    """Print a startup status line and record it in STATUS_FILE."""
    print(message)
    try:
        with open(STATUS_FILE, "a", encoding="utf-8") as status:
            status.write(message + "\n")
    except OSError:
        pass


def parse_command(line):
    """Return (left, right) in -100..100, or None if the line is invalid."""
    match = COMMAND_RE.match(line.strip())
    if not match:
        return None
    left = int(match.group(2)) * (-1 if match.group(1) == "-" else 1)
    right = int(match.group(4)) * (-1 if match.group(3) == "-" else 1)
    if abs(left) > 100 or abs(right) > 100:
        return None
    return left, right


class MotorOutput:
    """Forwards commands to the MCU, skipping redundant calls."""

    def __init__(self):
        self._last = None
        self._last_sent_at = 0.0
        self._last_logged_at = 0.0

    def set(self, left, right, force=False):
        now = time.monotonic()
        if now - self._last_logged_at >= LOG_INTERVAL_S or force:
            print(f"Motors: left {left:+4d}  right {right:+4d}")
            self._last_logged_at = now
        if (not force and (left, right) == self._last
                and now - self._last_sent_at < KEEPALIVE_S):
            return
        try:
            Bridge.call("set_motors", left, right)
            self._last = (left, right)
            self._last_sent_at = now
        except Exception as exc:
            print(f"Bridge call failed: {exc}")

    def stop(self):
        self.set(0, 0, force=True)


motors = MotorOutput()


def handle_client(client, address):
    print(f"Phone connected: {address}")
    client.settimeout(CLIENT_TIMEOUT_S)
    buffer = b""
    try:
        while True:
            try:
                data = client.recv(256)
            except socket.timeout:
                print("Phone went silent, stopping")
                break
            if not data:
                break
            buffer += data
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                command = parse_command(raw.decode("ascii", errors="ignore"))
                if command is None:
                    print(f"Ignoring invalid command: {raw!r}")
                    continue
                motors.set(*command)
            if len(buffer) > MAX_LINE:
                buffer = b""
    except OSError as exc:
        print(f"Connection error: {exc}")
    finally:
        motors.stop()
        client.close()
        print(f"Phone disconnected: {address}")


def phone_server():
    while True:
        server = None
        try:
            PHONE_SOCKET.parent.mkdir(parents=True, exist_ok=True)
            if PHONE_SOCKET.exists():
                PHONE_SOCKET.unlink()
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(PHONE_SOCKET))
            os.chmod(PHONE_SOCKET, 0o660)
            server.listen(1)
            report(f"Waiting for phone via {PHONE_SOCKET}")
            while True:
                client, _ = server.accept()
                handle_client(client, "Bluetooth relay")
        except OSError as exc:
            print(f"Phone server error: {exc}; retrying in 5 s")
            motors.stop()
            time.sleep(5)
        finally:
            if server is not None:
                server.close()


STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
STATUS_FILE.write_text("", encoding="utf-8")
try:
    report(f"Modulino Motors detected: {Bridge.call('motors_found')}")
except Exception as exc:
    report(f"Could not query the sketch: {exc}")

threading.Thread(target=phone_server, daemon=True).start()

App.run()
