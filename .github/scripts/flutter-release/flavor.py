"""Apply only audited independent-distribution metadata, before compilation."""
import hashlib
import json
from pathlib import Path
import sys

root, evidence = map(Path, sys.argv[1:3])
changes = {}
def replace(path, old, new, count=1):
    file = root / path
    before = file.read_bytes()
    text = before.decode()
    if text.count(old) != count:
        raise SystemExit(f"unexpected flavor baseline: {path}: {old!r}")
    after = text.replace(old, new).encode()
    file.write_bytes(after)
    changes[path] = {"before_sha256": changes.get(path, {}).get("before_sha256", hashlib.sha256(before).hexdigest()), "after_sha256": hashlib.sha256(after).hexdigest()}

replace('apps/xenterm/macos/Runner/Configs/AppInfo.xcconfig',
        'PRODUCT_BUNDLE_IDENTIFIER = dev.xenterm.xentermApp',
        'PRODUCT_BUNDLE_IDENTIFIER = dev.xuedinge.xentermFlutterNext')
replace('apps/xenterm/linux/CMakeLists.txt',
        'set(APPLICATION_ID "dev.xenterm.xenterm_app")',
        'set(APPLICATION_ID "dev.xuedinge.xenterm_flutter_next")')
replace('apps/xenterm/windows/runner/Runner.rc',
        'VALUE "CompanyName", "dev.xenterm"', 'VALUE "CompanyName", "dev.xuedinge"')
replace('apps/xenterm/windows/runner/Runner.rc',
        'VALUE "ProductName", "XenTerm"', 'VALUE "ProductName", "XenTerm Flutter Next"')
# Rename only the distribution wrapper, not Flutter's generated build output.
p = root / 'apps/xenterm/tool/package_desktop.sh'
before = p.read_bytes()
s = before.decode().replace('rm -rf XenTerm.app', 'rm -rf "XenTerm.app"')
s = s.replace('XenTerm.app', 'XenTerm Flutter Next.app')
s = s.replace('  local stage="$1"', '  local stage="$1"\n  cp LICENSE "$stage/"')
s = s.replace('    # Re-sign the whole bundle', '    copy_extras "XenTerm Flutter Next.app/Contents/Resources"\n    # Re-sign the whole bundle')
p.write_text(s)
changes['apps/xenterm/tool/package_desktop.sh'] = {
    "before_sha256": hashlib.sha256(before).hexdigest(), "after_sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'flavor.json').write_text(json.dumps({
    "channel": "independent-flutter", "rust_feature": "isolated-flutter-release",
    "dart_define": "XENTERM_FLUTTER_NEXT=true", "changes": changes,
    "macos_bundle_id": "dev.xuedinge.xentermFlutterNext",
    "linux_application_id": "dev.xuedinge.xenterm_flutter_next",
    "windows_company": "dev.xuedinge", "windows_product": "XenTerm Flutter Next",
    "rust_profile_application": "XenTermFlutterNext", "implicit_migration": False,
}, indent=2) + '\n')
