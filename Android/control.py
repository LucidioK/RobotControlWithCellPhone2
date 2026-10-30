"""Tilt -> motor power math. Pure Python, no Android dependencies."""

import math

# Tilt angle (degrees) that gives 100% power. 0 degrees gives 0%.
MAX_ANGLE = 45.0


def tilt_angles(ax: float, ay: float, az: float) -> tuple[float, float]:
    """Return (forward, right) tilt in degrees from accelerometer readings.

    Phone held flat, screen up, top edge pointing at the robot's front:
      forward > 0  when the top edge is tilted down (rotation about X)
      right   > 0  when the right edge is tilted down (rotation about Y)
    """
    forward = math.degrees(math.atan2(-ay, math.hypot(ax, az)))
    right = math.degrees(math.atan2(-ax, math.hypot(ay, az)))
    return forward, right


def angle_to_power(angle: float) -> float:
    """Map -MAX_ANGLE..MAX_ANGLE degrees linearly to -100..100 percent."""
    return _clamp(angle / MAX_ANGLE * 100.0)


def mix(throttle: float, steering: float) -> tuple[int, int]:
    """Differential-drive mix: returns (left, right) integer powers."""
    left = _clamp(throttle + steering)
    right = _clamp(throttle - steering)
    return int(round(left)), int(round(right))


def format_command(left: int, right: int) -> str:
    """Format powers as the wire protocol, e.g. (100, -80) -> 'L+100R-080'."""
    return f"L{left:+04d}R{right:+04d}"


def tilt_to_command(ax: float, ay: float, az: float) -> str:
    """Convert accelerometer readings to a robot command string."""
    forward, right = tilt_angles(ax, ay, az)
    left_power, right_power = mix(angle_to_power(forward), angle_to_power(right))
    return format_command(left_power, right_power)


def _clamp(value: float, limit: float = 100.0) -> float:
    """Clamp the value to the range [-limit, limit]."""
    return max(-limit, min(limit, value))
