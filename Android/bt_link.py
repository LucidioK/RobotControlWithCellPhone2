"""Classic Bluetooth (RFCOMM / SPP) client using the Android Java API via pyjnius."""

import threading
import time

try:
    from jnius import JavaException, autoclass, cast
except ImportError:
    ON_ANDROID = False
else:
    try:
        BluetoothAdapter = autoclass("android.bluetooth.BluetoothAdapter")
        UUID = autoclass("java.util.UUID")
        Integer = autoclass("java.lang.Integer")
        ON_ANDROID = True
    except JavaException:
        ON_ANDROID = False

SPP_UUID = "00001101-0000-1000-8000-00805F9B34FB"

# Must match RFCOMM_CHANNEL in python/main.py on the robot.
RFCOMM_CHANNEL = 1

SEND_INTERVAL_S = 0.05  # 20 commands per second


class BluetoothLink:
    """Connects to the robot and streams the latest command at a fixed rate."""

    def __init__(self, on_disconnect: callable | None):
        """
        Initialize the Bluetooth link.

        Args:
            on_disconnect (callable | None): A function to call when the connection is lost.
                Defaults to None.
        """
        self.on_disconnect = on_disconnect
        self.command = "L+000R+000"
        self._socket = None
        self._stream = None
        self._running = False

    @property
    def connected(self) -> bool:
        """
        Check if the link is connected.
        Returns:
            bool: True if connected, False otherwise.
        """
        return self._running

    def paired_devices(self) -> list[tuple[str, str]]:
        """Return a list of (name, address) for bonded devices."""
        if not ON_ANDROID:
            return []
        adapter = BluetoothAdapter.getDefaultAdapter()
        if adapter is None or not adapter.isEnabled():
            return []
        return [
            (d.getName() or d.getAddress(), d.getAddress())
            for d in adapter.getBondedDevices().toArray()
        ]

    def connect(self, bluetooth_address: str) -> None:
        """
        Blocking connect; raises on failure. Call from a worker thread.
        Args:
            bluetooth_address (str): The Bluetooth address of the device to connect to.
        """
        if not ON_ANDROID:
            raise RuntimeError("Bluetooth is only available on Android")
        adapter = BluetoothAdapter.getDefaultAdapter()
        adapter.cancelDiscovery()
        device = adapter.getRemoteDevice(bluetooth_address)

        try:
            sock = device.createRfcommSocketToServiceRecord(UUID.fromString(SPP_UUID))
            sock.connect()
        except JavaException as exc:
            print(
                f"bt_link: SPP service lookup failed ({exc}); "
                f"trying RFCOMM channel {RFCOMM_CHANNEL}"
            )
            # The robot does not publish an SDP record, so connect straight
            # to the RFCOMM channel (hidden but widely used API).
            sock = _channel_socket(device)
            sock.connect()

        self._socket = sock
        self._stream = sock.getOutputStream()
        self._running = True
        threading.Thread(target=self._send_loop, daemon=True).start()

    def disconnect(self) -> None:
        """Disconnect from the robot and stop the send loop."""
        if self._running:
            self._running = False
            try:
                self._write("L+000R+000")
            except (JavaException, OSError):
                pass
        self._close()

    def _write(self, text: str) -> None:
        """Write a command string to the robot."""
        self._stream.write((text + "\n").encode("ascii"))
        self._stream.flush()

    def _send_loop(self) -> None:
        """Send the latest command at a fixed rate until disconnected."""
        while self._running:
            try:
                self._write(self.command)
            except (JavaException, OSError):
                if self._running:
                    self._running = False
                    self._close()
                    if self.on_disconnect:
                        self.on_disconnect()
                return
            time.sleep(SEND_INTERVAL_S)

    def _close(self) -> None:
        """Close the Bluetooth socket and clear references."""
        if self._socket is not None:
            try:
                self._socket.close()
            except Exception:
                pass
        self._socket = None
        self._stream = None


def _channel_socket(
    device: "android.bluetooth.BluetoothDevice",
) -> "android.bluetooth.BluetoothSocket":
    """Create a BluetoothSocket for RFCOMM_CHANNEL without an SDP lookup.

    Args:
        device: The remote Bluetooth device.

    Returns:
        A connected BluetoothSocket.

    Raises:
        RuntimeError: If all attempts to create the socket fail.
    """
    attempts = [
        ("direct call", lambda: device.createRfcommSocket(RFCOMM_CHANNEL)),
        ("reflection", lambda: _reflect_create(device)),
    ]
    errors = []
    for name, attempt in attempts:
        try:
            return cast("android.bluetooth.BluetoothSocket", attempt())
        except (JavaException, RuntimeError, TypeError) as exc:
            print(f"bt_link: createRfcommSocket via {name} failed: {exc}")
            errors.append(f"{name}: {exc}")
    raise RuntimeError("; ".join(errors))


def _reflect_create(
    device: "android.bluetooth.BluetoothDevice",
) -> "android.bluetooth.BluetoothSocket":
    """
    Create a BluetoothSocket using reflection for RFCOMM_CHANNEL.

    Args:
        device: The remote Bluetooth device.

    Returns:
        A connected BluetoothSocket.

    Raises:
        RuntimeError: If the method is not found or if the invocation fails.
    """
    for method in device.getClass().getMethods():
        if (
            method.getName() == "createRfcommSocket"
            and len(method.getParameterTypes()) == 1
        ):
            break
    else:
        raise RuntimeError("createRfcommSocket(int) not found")
    channel = Integer(RFCOMM_CHANNEL)
    try:
        return method.invoke(device, channel)
    # pylint: disable=broad-except
    except (JavaException, TypeError):
        return method.invoke(device, [channel])
    # pylint: enable=broad-except
