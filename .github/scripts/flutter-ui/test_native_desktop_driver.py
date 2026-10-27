import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import native_desktop_driver as native


class DriverControls(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.driver = native.Driver(root, root, 'a' * 40)
        self.driver.window = lambda step: ('17', 1200, 900)

    def test_geometry_multiplies_dpr_and_rejects_outside_nonfinite_boolean(self):
        self.assertEqual(native.Driver.point({'point': [10, 20], 'device_pixel_ratio': 2}, 'point', 1200, 900), (20, 40))
        for point, ratio in [([1200, 1], 1), ([0, -1], 1), ([0, 0], float('nan')), ([True, 1], 1), ([1, 1], 5)]:
            with self.assertRaises(ValueError):
                native.Driver.point({'point': point, 'device_pixel_ratio': ratio}, 'point', 1200, 900)

    def test_drag_has_multiple_physical_updates_and_balanced_release(self):
        calls = []
        with patch.object(native, 'command', lambda *args: calls.append(args)), patch.object(native.time, 'sleep'):
            self.driver.perform({'operation': 'drag', 'start': [10, 10], 'end': [100, 10], 'device_pixel_ratio': 1}, '001-drag')
        self.assertEqual(sum(call[1] == 'mousemove' for call in calls), 9)
        self.assertEqual(calls[-1], ('xdotool', 'mouseup', '1'))

    def test_drag_failure_still_releases_its_button(self):
        calls = []
        def command(*args):
            calls.append(args)
            if len(calls) == 3:
                raise RuntimeError('synthetic move failure')
        with patch.object(native, 'command', command), self.assertRaises(RuntimeError):
            self.driver.perform({'operation': 'drag', 'start': [10, 10], 'end': [100, 10], 'device_pixel_ratio': 1}, '001-drag')
        self.assertEqual(calls[-1], ('xdotool', 'mouseup', '1'))

    def test_wheel_keyboard_and_resize_are_bounded(self):
        for operation in [
            {'operation': 'scroll', 'ticks': 13, 'point': [10, 10], 'device_pixel_ratio': 1},
            {'operation': 'key', 'key': 'super+F4'},
            {'operation': 'resize', 'size': [8000, 8000]},
        ]:
            with self.assertRaises(ValueError), patch.object(native, 'command') as command:
                self.driver.perform(operation, '001-invalid')
                command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
