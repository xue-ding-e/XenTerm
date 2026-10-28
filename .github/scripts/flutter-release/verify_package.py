"""Check archive bytes and staged bridge identity without opening a profile."""
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import subprocess
import signal
import tempfile
import time
import sys
import tarfile
import zipfile

root, asset, evidence = map(Path, sys.argv[1:4])
platform_name = sys.argv[4]
sha = os.environ['SOURCE_SHA']
assert len(sha) == 40 and all(c in '0123456789abcdef' for c in sha)
if platform_name == 'windows':
    bridge = root / 'apps/xenterm/build/windows/x64/runner/Release/xenterm_bridge.dll'
    executable = bridge.parent / 'xenterm.exe'
    identity_env = dict(os.environ, XT_PACKAGE_EXE=str(executable.resolve()))
    identity = json.loads(subprocess.check_output([
        'powershell', '-NoProfile', '-Command',
        '$v=(Get-Item -LiteralPath $env:XT_PACKAGE_EXE).VersionInfo; '
        '@{CompanyName=$v.CompanyName;ProductName=$v.ProductName}|ConvertTo-Json -Compress',
    ], env=identity_env, timeout=30).decode('utf-8-sig'))
    assert identity == {'CompanyName': 'dev.xuedinge', 'ProductName': 'XenTerm Flutter Next'}, identity
elif platform_name == 'macos':
    bridge = root / 'XenTerm Flutter Next.app/Contents/Frameworks/libxenterm_bridge.dylib'
    executable = bridge.parents[1] / 'MacOS/xenterm_app'
    import plistlib
    info = plistlib.loads((bridge.parents[1] / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'dev.xuedinge.xentermFlutterNext'
else:
    bridge = root / 'apps/xenterm/build/linux/x64/release/bundle/lib/libxenterm_bridge.so'
    executable = bridge.parent.parent / 'xenterm'
    assert b'dev.xuedinge.xenterm_flutter_next' in executable.read_bytes()
lib = ctypes.CDLL(str(bridge.resolve()))
lib.xenterm_isolated_flutter_release.restype = ctypes.c_bool
assert lib.xenterm_isolated_flutter_release() is True, 'release feature is missing'
lib.xenterm_core_version.restype = ctypes.c_void_p
lib.xenterm_string_free.argtypes = [ctypes.c_void_p]
ptr = lib.xenterm_core_version()
assert ptr
version = ctypes.string_at(ptr).decode()
lib.xenterm_string_free(ptr)
assert sha[:7] in version, (sha, version)
bridge_digest = hashlib.sha256(bridge.read_bytes()).hexdigest()
if asset.suffix == '.zip':
    archive = zipfile.ZipFile(asset)
    assert archive.testzip() is None
    names = archive.namelist()
    read = archive.read
else:
    archive = tarfile.open(asset)
    names = archive.getnames()
    read = lambda name: archive.extractfile(name).read()
for name in names:
    path = PurePosixPath(name)
    assert not path.is_absolute() and '..' not in path.parts, name
    assert not any(part in {'sessions.db', 'sessions.json', 'secret.key', '.env'} for part in path.parts), name
bridges = [name for name in names if name.endswith('/' + bridge.name)]
assert len(bridges) == 1
assert hashlib.sha256(read(bridges[0])).hexdigest() == bridge_digest
executables = [name for name in names if name.endswith('/' + executable.name)]
assert len(executables) == 1
assert hashlib.sha256(read(executables[0])).digest() == hashlib.sha256(executable.read_bytes()).digest()
assert any(name.endswith('/LICENSE') for name in names)
assert any(name.endswith('/THIRD_PARTY_NOTICES.md') for name in names)
archive.close()
# A bounded startup smoke, not full interaction or real-session validation.
# Every executable receives a fresh synthetic pinned profile; no host profile
# or real credentials are read, even if the compiled flavor were misconfigured.
with tempfile.TemporaryDirectory(prefix='xt-release-smoke-') as profile_dir:
    env = dict(os.environ, XENTERM_DATA_DIR=profile_dir, XENTERM_LIVE_PORT='', XENTERM_LIVE_DATA='')
    command = [str(executable.resolve())]
    if platform_name == 'linux':
        env['LIBGL_ALWAYS_SOFTWARE'] = '1'
        command = ['xvfb-run', '-a', 'dbus-run-session', '--'] + command
    process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=(os.name != 'nt'))
    try:
        time.sleep(8)
        assert process.poll() is None, 'desktop app exited before startup smoke completed'
    finally:
        def stop(force=False):
            try:
                if os.name == 'nt':
                    process.kill() if force else process.terminate()
                else:
                    os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
            except ProcessLookupError:
                pass
        stop()
        try:
            output = process.communicate(timeout=10)[0]
        except subprocess.TimeoutExpired:
            stop(force=True)
            output = process.communicate(timeout=10)[0]
        (evidence / ('startup-' + platform_name + '.log')).write_bytes(output[-65536:])
digest = hashlib.sha256(asset.read_bytes()).hexdigest()
build = {"source_sha": sha, "control_sha": os.environ['GITHUB_SHA'],
         "run_id": os.environ['GITHUB_RUN_ID'], "platform": platform_name,
         "machine": platform.machine(), "core_version": version,
         "isolated_flutter_release": True, "official_release": False,
         "native_startup_smoke": True, "native_ui_verified": False, "asset": asset.name, "sha256": digest,
         "signing": "ad-hoc, not notarized" if platform_name == 'macos' else "unsigned",
         "flavor": json.loads((evidence / 'flavor.json').read_text(encoding='utf-8'))}
(evidence / ('BUILD-' + platform_name + '-' + platform.machine() + '.json')).write_text(json.dumps(build, indent=2)+'\n', encoding='utf-8', newline='\n')
(evidence / ('SHA256SUMS-' + platform_name + '-' + platform.machine())).write_text(digest + '  ' + asset.name + '\n', encoding='utf-8', newline='\n')
print(json.dumps(build, indent=2))
