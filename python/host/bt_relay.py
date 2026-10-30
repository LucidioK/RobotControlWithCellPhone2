#!/usr/bin/env python3
"""Bluetooth relay for the UNO Q host (Debian), standard library only.

App Lab runs python/main.py in a container that cannot open Bluetooth
sockets, so this script runs directly on the board. It listens for the phone
on an RFCOMM (Bluetooth serial) channel and copies everything the phone sends
to the app's Unix socket. It has no robot logic of its own.

Installed as a systemd user service by install.sh in this folder.
"""

import select
import socket
import sys
import time
from pathlib import Path

# Must match RFCOMM_CHANNEL in Android/bt_link.py.
RFCOMM_CHANNEL = 1

APP_SOCKET = Path(__file__).resolve().parent.parent.parent / ".cache" / "phone.sock"


def log(message):
    print(message, flush=True)


def connect_app():
    app = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        app.connect(str(APP_SOCKET))
    except OSError:
        app.close()
        raise
    return app


def relay(phone, app):
    """Copy phone -> app until either side closes."""
    sockets = [phone, app]
    while True:
        readable, _, _ = select.select(sockets, [], [])
        for sock in readable:
            data = sock.recv(1024)
            if not data:
                return
            if sock is phone:
                app.sendall(data)


def serve():
    server = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM,
                           socket.BTPROTO_RFCOMM)
    server.bind(("00:00:00:00:00:00", RFCOMM_CHANNEL))
    server.listen(1)
    log(f"Listening on RFCOMM channel {RFCOMM_CHANNEL}, relaying to {APP_SOCKET}")
    try:
        while True:
            phone, address = server.accept()
            log(f"Phone connected: {address[0]}")
            try:
                app = connect_app()
            except OSError as exc:
                log(f"Robot app not running ({exc}); dropping phone")
                phone.close()
                continue
            try:
                relay(phone, app)
            except OSError as exc:
                log(f"Relay error: {exc}")
            finally:
                app.close()
                phone.close()
                log("Phone disconnected")
    finally:
        server.close()


def main():
    while True:
        try:
            serve()
        except OSError as exc:
            log(f"Bluetooth error: {exc}; retrying in 5 s")
            time.sleep(5)


if __name__ == "__main__":
    sys.exit(main())
