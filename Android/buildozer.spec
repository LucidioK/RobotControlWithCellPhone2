[app]
title = Robot Remote
package.name = robotremote
package.domain = org.example
source.dir = .
source.include_exts = py
source.exclude_dirs = tests, bin, .buildozer
version = 1.0

requirements = python3,kivy,plyer,pyjnius

# Tilting the phone must not rotate the UI.
orientation = portrait
fullscreen = 0

android.permissions = BLUETOOTH, BLUETOOTH_ADMIN, BLUETOOTH_CONNECT, BLUETOOTH_SCAN
android.api = 34
android.minapi = 24
android.archs = arm64-v8a
android.accept_sdk_license = True

# Keep the screen on while driving.
android.wakelock = True

[buildozer]
log_level = 2
warn_on_root = 1
