#!/bin/sh
# Installs bt_relay.py as a systemd user service on the UNO Q (no sudo needed).
# Run on the board:  sh ~/ArduinoApps/robot-control/python/host/install.sh
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/robot-bt-relay.service" <<EOF
[Unit]
Description=Bluetooth relay for the Robot Control App Lab app

[Service]
ExecStart=/usr/bin/python3 -u $HERE/bt_relay.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now robot-bt-relay.service
systemctl --user restart robot-bt-relay.service
systemctl --user --no-pager status robot-bt-relay.service | head -5
