import math
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from control import (angle_to_power, format_command, mix, tilt_angles,
                     tilt_to_command)

G = 9.81


def reading(forward_deg, right_deg=0.0):
    """Accelerometer vector for a phone tilted forward or right (one axis)."""
    if right_deg:
        r = math.radians(right_deg)
        return -G * math.sin(r), 0.0, G * math.cos(r)
    f = math.radians(forward_deg)
    return 0.0, -G * math.sin(f), G * math.cos(f)


class ControlTest(unittest.TestCase):
    def test_flat_is_stop(self):
        self.assertEqual(tilt_to_command(0, 0, G), "L+000R+000")

    def test_angles(self):
        forward, right = tilt_angles(*reading(30))
        self.assertAlmostEqual(forward, 30, places=6)
        self.assertAlmostEqual(right, 0, places=6)
        forward, right = tilt_angles(*reading(0, 20))
        self.assertAlmostEqual(right, 20, places=6)

    def test_angle_to_power(self):
        self.assertEqual(angle_to_power(0), 0)
        self.assertEqual(angle_to_power(45), 100)
        self.assertEqual(angle_to_power(-22.5), -50)
        self.assertEqual(angle_to_power(80), 100)

    def test_full_forward_and_back(self):
        self.assertEqual(tilt_to_command(*reading(45)), "L+100R+100")
        self.assertEqual(tilt_to_command(*reading(-60)), "L-100R-100")

    def test_spin_right(self):
        self.assertEqual(tilt_to_command(*reading(0, 45)), "L+100R-100")

    def test_mix_clamps(self):
        self.assertEqual(mix(100, 100), (100, 0))
        self.assertEqual(mix(50, -20), (30, 70))

    def test_format(self):
        self.assertEqual(format_command(100, -80), "L+100R-080")
        self.assertEqual(format_command(0, 5), "L+000R+005")


if __name__ == "__main__":
    unittest.main()
