"""Launch the uninstrumented release bundle; real OCR-guided X11 interaction."""
import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time
from native_desktop_driver import Driver, command


def words(image):
    result = command('tesseract', str(image), 'stdout', '-l', 'eng', 'tsv').decode()
    return [row for row in csv.DictReader(io.StringIO(result), delimiter='\t')
            if row.get('text', '').strip() and float(row['conf']) >= 30]


def main():
    p = argparse.ArgumentParser(); p.add_argument('--bundle', type=Path, required=True); p.add_argument('--runtime', type=Path, required=True); p.add_argument('--source-sha', required=True); a = p.parse_args()
    bundle = a.bundle.resolve(strict=True); runtime = a.runtime.resolve()
    assert re.fullmatch('[0-9a-f]{40}', a.source_sha) and not runtime.exists()
    runtime.mkdir(mode=0o700)
    for name in ['home', 'config', 'data', 'cache', 'profile', 'artifacts']: (runtime / name).mkdir(mode=0o700)
    executable = bundle / 'xenterm'; bridge = bundle / 'lib/libxenterm_bridge.so'
    assert executable.is_file() and bridge.is_file()
    env = {**os.environ, 'HOME': str(runtime / 'home'), 'XDG_CONFIG_HOME': str(runtime / 'config'),
           'XDG_DATA_HOME': str(runtime / 'data'), 'XDG_CACHE_HOME': str(runtime / 'cache'),
           'XENTERM_DATA_DIR': str(runtime / 'profile'), 'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8'}
    env.pop('XENTERM_BRIDGE_PATH', None)
    log = (runtime / 'private-app.log').open('w')
    app = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=subprocess.STDOUT)
    driver = Driver(runtime, bundle, a.source_sha)
    step = {'pid': app.pid, 'source_sha': a.source_sha}
    image = runtime / 'artifacts/release-startup.png'
    deadline = time.monotonic() + 45
    try:
        entries = None
        while time.monotonic() < deadline:
            assert app.poll() is None, 'release app exited before startup gate'
            try:
                window, _, _ = driver.window(step)
                command('import', '-window', window, str(image))
                entries = words(image)
                text = {r['text'].strip() for r in entries}
                if {'Home', 'Settings'} <= text: break
            except (RuntimeError, ValueError):
                pass
            time.sleep(.3)
        else: raise TimeoutError('release Home/Settings were not rendered')
        maps = Path(f'/proc/{app.pid}/maps').read_text()
        assert str(bridge) in maps, 'release did not map its default bundle/lib bridge'
        assert (runtime / 'profile/sessions.db').is_file(), 'core did not initialize isolated profile'
        target = next(r for r in entries if r['text'].strip() == 'Settings')
        point = [int(target['left']) + int(target['width']) / 2,
                 int(target['top']) + int(target['height']) / 2]
        driver.perform({**step, 'operation': 'click', 'point': point, 'device_pixel_ratio': 1}, 'release-settings')
        time.sleep(.5)
        driver.perform({**step, 'operation': 'key', 'key': 'ctrl+f'}, 'release-search-focus')
        driver.set_clipboard('language')
        driver.perform({**step, 'operation': 'key', 'key': 'ctrl+v'}, 'release-search-paste')
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            result_image = runtime / 'artifacts/release-settings-search.png'
            command('import', '-window', window, str(result_image))
            visible = ' '.join(r['text'] for r in words(result_image))
            if 'Interface language' in visible: break
            time.sleep(.3)
        else: raise TimeoutError('release settings search did not show the language result')
        (runtime / 'artifacts/release-smoke.json').write_text(json.dumps({
            'source_sha': a.source_sha, 'kind': 'uninstrumented-linux-release',
            'default_bridge_mapped': True, 'isolated_profile_created': True,
            'ocr_home_settings': True, 'physical_settings_click_search_paste': True,
            'bridge_sha256': hashlib.sha256(bridge.read_bytes()).hexdigest(),
        }, indent=2) + '\n')
    finally:
        driver.clear_clipboard_owner()
        if app.poll() is None:
            app.terminate()
            try: app.wait(timeout=8)
            except subprocess.TimeoutExpired: app.kill(); app.wait(timeout=3)
        log.close()


if __name__ == '__main__': main()
