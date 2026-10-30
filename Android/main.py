"""Android robot remote: tilt the phone to drive, hold the button to enable."""

import threading

from kivy.app import App
from kivy.clock import Clock
from kivy.core.window import Window
from kivy.lang import Builder
from kivy.utils import platform
from plyer import accelerometer

from bt_link import BluetoothLink
from control import angle_to_power, format_command, mix, tilt_angles

STOP = "L+000R+000"

KV = """
BoxLayout:
    orientation: "vertical"
    padding: "12dp"
    spacing: "10dp"

    BoxLayout:
        size_hint_y: None
        height: "48dp"
        spacing: "8dp"
        Spinner:
            id: devices
            text: "Select robot"
            values: []
        Button:
            text: "Refresh"
            size_hint_x: 0.35
            on_release: app.refresh_devices()

    Button:
        id: connect
        size_hint_y: None
        height: "48dp"
        text: "Connect"
        on_release: app.toggle_connection()

    Label:
        id: status
        size_hint_y: None
        height: "32dp"
        text: "Disconnected"
        text_size: self.width, None
        halign: "center"
        shorten: True

    Label:
        id: angles
        font_size: "20sp"
        text: "Forward 0.0°   Right 0.0°"

    BoxLayout:
        spacing: "12dp"
        BoxLayout:
            orientation: "vertical"
            Label:
                text: "Left"
            Label:
                id: left
                font_size: "40sp"
                text: "0"
        BoxLayout:
            orientation: "vertical"
            Label:
                text: "Right"
            Label:
                id: right
                font_size: "40sp"
                text: "0"

    Label:
        id: command
        font_size: "24sp"
        text: "L+000R+000"

    Button:
        id: drive
        size_hint_y: 0.8
        font_size: "28sp"
        text: "HOLD TO DRIVE"
        background_color: (0.2, 0.7, 0.3, 1) if self.state == "down" else (0.5, 0.5, 0.5, 1)
"""


class RobotRemoteApp(App):
    """
    Application class for controlling a robot via Bluetooth.
    """

    def __init__(self, **kwargs):
        """Initialize the RobotRemoteApp instance."""
        super().__init__(**kwargs)
        self.link = None
        self.addresses = {}
        self.accelerometer_ok = False

    def build(self) -> Widget:
        """Build the root widget for the application."""
        self.link = BluetoothLink(on_disconnect=self._lost_connection)
        self.addresses = {}
        self.accelerometer_ok = False
        return Builder.load_string(KV)

    def on_start(self) -> None:
        """Handle the start of the application."""
        if platform == "android":
            from android.permissions import request_permissions
            request_permissions(
                ["android.permission.BLUETOOTH_CONNECT",
                 "android.permission.BLUETOOTH_SCAN"],
                lambda *_: Clock.schedule_once(lambda dt: self.refresh_devices()))
        else:
            self.refresh_devices()
        try:
            accelerometer.enable()
            self.accelerometer_ok = True
        except RuntimeError:
            self.set_status("Accelerometer not available")
        Window.bind(focus=self._on_focus)
        Clock.schedule_interval(self.update, 1 / 20)

    def on_pause(self) -> bool:
        """Handle the pause of the application."""
        # Never keep driving while the app is in the background.
        self.release_drive()
        self.link.command = STOP
        return True

    def _on_focus(self, window: Window, focused: bool) -> None:
        """Handle the focus change of the application window."""
        if not focused:
            self.release_drive()

    def release_drive(self) -> None:
        """Release the drive button to stop the robot."""
        # A system dialog can swallow the touch-up event, which would leave
        # the button "held" and the robot driving.
        self.root.ids.drive.state = "normal"

    def set_status(self, message: str) -> None:
        """Update the status label with the given message."""
        print(f"status: {message}")
        self.root.ids.status.text = message

    def on_stop(self) -> None:
        """Handle the stop of the application."""
        self.link.disconnect()
        if self.accelerometer_ok:
            accelerometer.disable()

    def refresh_devices(self) -> None:
        """Refresh the list of paired Bluetooth devices."""
        try:
            devices = self.link.paired_devices()
        except OSError as exc:
            self.set_status(f"Bluetooth error: {exc}")
            return
        self.addresses = {f"{name} ({address})": address
                          for name, address in devices}
        self.root.ids.devices.values = list(self.addresses)
        if not devices:
            self.set_status("No paired devices - pair the robot first")
        elif not self.link.connected:
            self.set_status("Select the robot and tap Connect")

    def toggle_connection(self) -> None:
        """Toggle the connection to the selected robot."""
        if self.link.connected:
            self.link.disconnect()
            self._set_connected(False, "Disconnected")
            return
        address = self.addresses.get(self.root.ids.devices.text)
        if address is None:
            self.set_status("Select a robot first")
            return
        self.set_status("Connecting...")
        self.root.ids.connect.disabled = True
        threading.Thread(target=self._connect, args=(address,),
                         daemon=True).start()

    def _connect(self, address: str) -> None:
        """Attempt to connect to the robot at the given address."""
        try:
            self.link.connect(address)
            result = (True, "Connected")
        except OSError as exc:
            result = (False, f"Connection failed: {exc}")
        Clock.schedule_once(lambda dt: self._set_connected(*result))

    def _lost_connection(self) -> None:
        """Handle the loss of connection to the robot."""
        Clock.schedule_once(lambda dt: self._set_connected(False, "Connection lost"))

    def _set_connected(self, connected: bool, message: str) -> None:
        """Update the UI and status based on the connection state."""
        ids = self.root.ids
        ids.connect.disabled = False
        ids.connect.text = "Disconnect" if connected else "Connect"
        self.set_status(message)

    def update(self, _dt: float) -> None:
        """Update the robot's control based on accelerometer readings."""
        ids = self.root.ids
        reading = accelerometer.acceleration if self.accelerometer_ok else None
        if not reading or None in reading:
            self.link.command = STOP
            return

        forward, right = tilt_angles(*reading[:3])
        left_power, right_power = mix(angle_to_power(forward),
                                      angle_to_power(right))
        ids.angles.text = f"Forward {forward:5.1f}°   Right {right:5.1f}°"
        ids.left.text = str(left_power)
        ids.right.text = str(right_power)

        command = format_command(left_power, right_power)
        if ids.drive.state != "down":
            command = STOP
        ids.command.text = command
        self.link.command = command


if __name__ == "__main__":
    RobotRemoteApp().run()
