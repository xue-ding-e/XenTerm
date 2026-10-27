"""Drive the isolated native X11 app from live Flutter geometry checkpoints.

The integration target runs production app.main and real plugins/FFI. It writes
semantic finder geometry; this peer supplies real OS mouse, keys and clipboard.
No application state, bridge result or clipboard channel is mocked here.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time

ALLOWED_KEYS = {
    'Tab', 'shift+Tab', 'Return', 'space', 'Escape', 'BackSpace', 'Delete',
    'Home', 'End', 'Up', 'Down', 'Left', 'Right', 'Page_Up', 'Page_Down',
    'ctrl+a', 'ctrl+c', 'ctrl+v', 'ctrl+x', 'ctrl+z', 'ctrl+shift+z',
    'ctrl+shift+c', 'ctrl+shift+v', 'ctrl+shift+f',
}


def command(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True, timeout=8)
    if result.returncode:
        # Do not put clipboard contents or command arguments in public failures.
        raise RuntimeError(f'{Path(args[0]).name} failed ({result.returncode})')
    return result.stdout


class Driver:
    def __init__(self, runtime: Path, binary_root: Path, source_sha: str):
        self.runtime = runtime
        self.binary_root = binary_root
        self.source_sha = source_sha
        self.clipboard_owner = None

    def window(self, step):
        if step.get('source_sha') != self.source_sha:
            raise ValueError('checkpoint source does not match the validated product')
        pid = step['pid']
        if not isinstance(pid, int) or pid <= 1:
            raise ValueError('invalid native app PID')
        exe = Path(f'/proc/{pid}/exe').resolve(strict=True)
        if not exe.is_relative_to(self.binary_root):
            raise ValueError('checkpoint PID is not a binary under the product build')
        windows = command('xdotool', 'search', '--onlyvisible', '--pid', str(pid)).decode().split()
        matches = [window for window in windows
                   if command('xdotool', 'getwindowname', window).decode().strip() == 'XenTerm']
        if len(matches) != 1:
            raise ValueError('expected one visible native XenTerm window')
        window = matches[0]
        command('xdotool', 'windowactivate', '--sync', window)
        geometry = command('xdotool', 'getwindowgeometry', '--shell', window).decode()
        values = dict(line.split('=', 1) for line in geometry.splitlines() if '=' in line)
        return window, int(values['WIDTH']), int(values['HEIGHT'])

    def set_clipboard(self, text):
        raw = text.encode('utf-8')
        if len(raw) > 1024 * 1024:
            raise ValueError('synthetic clipboard exceeds driver budget')
        self.clear_clipboard_owner()
        # -quiet stays in the foreground and owns the X11 selection until it is
        # replaced. Track this exact child; never kill another clipboard process.
        self.clipboard_owner = subprocess.Popen(
            ['xclip', '-selection', 'clipboard', '-in', '-quiet'],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.clipboard_owner.stdin.write(raw)
        self.clipboard_owner.stdin.close()
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                if command('xclip', '-selection', 'clipboard', '-out') == raw:
                    return
            except RuntimeError:
                if self.clipboard_owner.poll() is not None:
                    raise RuntimeError('fixture clipboard owner exited')
            time.sleep(0.05)
        raise TimeoutError('fixture clipboard ownership was not established')

    def clear_clipboard_owner(self):
        process = self.clipboard_owner
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        self.clipboard_owner = None

    @staticmethod
    def point(step, name, width, height):
        ratio = step['device_pixel_ratio']
        x, y = step[name]
        if not all(isinstance(value, (int, float)) and not isinstance(value, bool)
                   and math.isfinite(value) for value in (ratio, x, y)) or not 0.5 <= ratio <= 4:
            raise ValueError('invalid rendered geometry')
        x, y = round(x * ratio), round(y * ratio)
        if not (0 <= x < width and 0 <= y < height):
            raise ValueError('semantic target lies outside native window')
        return x, y

    def perform(self, step, identifier):
        window, width, height = self.window(step)
        operation = step['operation']
        if operation == 'click':
            x, y = self.point(step, 'point', width, height)
            button = step.get('button', 1)
            if button not in (1, 3):
                raise ValueError('unsupported pointer button')
            command('xdotool', 'mousemove', '--sync', '--window', window, str(x), str(y))
            command('xdotool', 'click', str(button))
        elif operation == 'drag':
            start = self.point(step, 'start', width, height)
            end = self.point(step, 'end', width, height)
            command('xdotool', 'mousemove', '--sync', '--window', window, *map(str, start))
            command('xdotool', 'mousedown', '1')
            try:
                # Several physical updates cross Flutter's drag slop before
                # extending selection. One jump can merely start the gesture.
                for index in range(1, 9):
                    x = round(start[0] + (end[0] - start[0]) * index / 8)
                    y = round(start[1] + (end[1] - start[1]) * index / 8)
                    command('xdotool', 'mousemove', '--sync', '--window', window, str(x), str(y))
                    time.sleep(0.025)
            finally:
                command('xdotool', 'mouseup', '1')
        elif operation == 'scroll':
            x, y = self.point(step, 'point', width, height)
            ticks = step['ticks']
            if not isinstance(ticks, int) or isinstance(ticks, bool) or not 1 <= abs(ticks) <= 12:
                raise ValueError('invalid bounded wheel step')
            command('xdotool', 'mousemove', '--sync', '--window', window, str(x), str(y))
            command('xdotool', 'click', '--repeat', str(abs(ticks)), '--delay', '60', '5' if ticks > 0 else '4')
        elif operation == 'key':
            key = step['key']
            if key not in ALLOWED_KEYS:
                raise ValueError('keyboard operation is not allowlisted')
            command('xdotool', 'key', '--clearmodifiers', key)
        elif operation == 'set_clipboard':
            self.set_clipboard(step['text'])
        elif operation == 'assert_clipboard':
            expected = step['text'].encode('utf-8')
            actual = command('xclip', '-selection', 'clipboard', '-out')
            if actual != expected:
                raise AssertionError('native clipboard differs from expected synthetic text')
            return {'clipboard_sha256': hashlib.sha256(actual).hexdigest()}
        elif operation == 'screenshot':
            artifacts = self.runtime / 'artifacts'
            artifacts.mkdir(exist_ok=True)
            command('import', '-window', window, str(artifacts / f'{identifier}.png'))
        elif operation == 'resize':
            requested_width, requested_height = step['size']
            if (not isinstance(requested_width, int) or not isinstance(requested_height, int)
                    or not 940 <= requested_width <= 1920 or not 600 <= requested_height <= 1200):
                raise ValueError('resize exceeds acceptance viewport bounds')
            command('xdotool', 'windowsize', '--sync', window,
                    str(requested_width), str(requested_height))
        else:
            raise ValueError('unsupported desktop operation')
        return {}

    def run(self, timeout):
        steps = self.runtime / 'steps'
        acknowledgements = self.runtime / 'acks'
        steps.mkdir(exist_ok=True)
        acknowledgements.mkdir(exist_ok=True)
        completed = set()
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                complete = self.runtime / 'test-complete.json'
                if complete.exists():
                    result = json.loads(complete.read_text())
                    if (result.get('ok') is not True or result.get('source_sha') != self.source_sha
                            or result.get('steps') != len(completed) or not completed):
                        raise ValueError('native acceptance did not complete the declared physical steps')
                    return
                for path in sorted(steps.glob('*.json')):
                    identifier = path.stem
                    if identifier in completed:
                        continue
                    if not re.fullmatch(r'[0-9]{3}-[a-z0-9-]+', identifier):
                        raise ValueError('invalid checkpoint filename')
                    if len(completed) >= 500 or path.stat().st_size > 2 * 1024 * 1024:
                        raise ValueError('checkpoint exceeds driver budget')
                    try:
                        result = {'ok': True, **self.perform(json.loads(path.read_text()), identifier)}
                    except Exception as error:
                        result = {'ok': False, 'error_type': type(error).__name__, 'error': str(error)}
                    temporary = acknowledgements / f'{identifier}.pending'
                    temporary.write_text(json.dumps(result))
                    temporary.replace(acknowledgements / f'{identifier}.json')
                    if not result['ok']:
                        raise RuntimeError(f'desktop checkpoint {identifier} failed')
                    completed.add(identifier)
                time.sleep(0.05)
            raise TimeoutError('native desktop acceptance deadline expired')
        finally:
            self.clear_clipboard_owner()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--binary-root', required=True, type=Path)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if not re.fullmatch('[0-9a-f]{40}', args.source_sha) or not 30 <= args.timeout <= 900:
        parser.error('an exact source SHA and bounded timeout are required')
    if not os.environ.get('DISPLAY'):
        parser.error('a real isolated X11 display is required; no mock fallback')
    Driver(args.runtime.resolve(strict=True), args.binary_root.resolve(strict=True),
           args.source_sha).run(args.timeout)


if __name__ == '__main__':
    main()
