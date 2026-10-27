"""Copy production source byte-for-byte; add only SDK test instrumentation."""
import argparse
from pathlib import Path
import shutil
p = argparse.ArgumentParser(); p.add_argument('product', type=Path); p.add_argument('host', type=Path); p.add_argument('control', type=Path); a = p.parse_args()
assert not a.host.exists()
shutil.copytree(a.product, a.host, ignore=shutil.ignore_patterns('build', '.dart_tool', '.plugin_symlinks', 'ephemeral'))
pubspec = a.host / 'pubspec.yaml'
s = pubspec.read_text(); assert s.count('dev_dependencies:\n') == 1 and '  integration_test:' not in s
pubspec.write_text(s.replace('dev_dependencies:\n', 'dev_dependencies:\n  integration_test:\n    sdk: flutter\n'))
target = a.host / 'integration_test'; target.mkdir(exist_ok=False)
for name in ['native_desktop_test.dart', 'native_desktop_steps.dart']:
    shutil.copyfile(a.control / name, target / name)
print('Created isolated integration host; production source and lock unchanged')
