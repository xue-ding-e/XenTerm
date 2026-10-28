"""Control regression: non-ASCII scripts must not use Windows ANSI encoding."""
import runpy
import tempfile
import sys
from pathlib import Path
from unittest.mock import patch

source = Path(__file__).resolve().parents[3]
paths = ['apps/xenterm/macos/Runner/Configs/AppInfo.xcconfig',
         'apps/xenterm/linux/CMakeLists.txt', 'apps/xenterm/windows/runner/Runner.rc',
         'packaging/windows/main.wxs', 'apps/xenterm/tool/package_windows_installer.ps1',
         'apps/xenterm/tool/package_desktop.sh']
original_write = Path.write_text

def windows_write(self, data, encoding=None, errors=None, newline=None):
    return original_write(self, data, encoding=encoding or 'cp1252', errors=errors, newline=newline)

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    for name in paths:
        dest = root / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes((source / name).read_bytes())
    with patch.object(Path, 'write_text', windows_write), patch.object(sys, 'argv', ['flavor', str(root), str(root/'evidence')]):
        runpy.run_path(str(Path(__file__).with_name('flavor.py')), run_name='__main__')
    data = (root/'apps/xenterm/tool/package_desktop.sh').read_bytes()
    assert b'\r\n' not in data
    assert 'XenTerm Flutter Next.app' in data.decode('utf-8')
    assert (root/'evidence/flavor.json').is_file()
print('Windows ANSI-default regression: PASS')
