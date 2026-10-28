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
# A separate MSI family must never major-upgrade or close the upstream app.
import re
wxs = 'packaging/windows/main.wxs'
replace(wxs, '6E8F2A1B-3C4D-4E5F-9A0B-1C2D3E4F5A6B', '83238181-7F80-480F-9D10-82FF0FCD16F5')
replace(wxs, '7F1C4E7A-2D6B-4A8E-9C33-5B1D0A6F2E81', '59D4AB58-F7CD-482D-A905-A81E6F8F3A21')
replace(wxs, 'B4D7E2C9-8A31-4F6E-9B52-6C0A1E3D8F47', '28966D78-755F-40ED-A06C-DBB415EC006A')
file = root / wxs
text = file.read_bytes().decode('utf-8')
text, removed = re.subn(r'        <util:CloseApplication\b.*?</util:CloseApplication>',
    '<!-- No executable-name-wide close action: other distributions may be running. -->', text, flags=re.S)
assert removed == 1
text = text.replace('Name="XenTerm"', 'Name="XenTerm Flutter Next"')
text = text.replace('Title="XenTerm"', 'Title="XenTerm Flutter Next"')
text = text.replace('Manufacturer="xenterm contributors"', 'Manufacturer="xue-ding-e"')
text = text.replace('Software\\XenTerm', 'Software\\XenTermFlutterNext')
file.write_bytes(text.encode('utf-8'))
changes[wxs]['after_sha256'] = hashlib.sha256(file.read_bytes()).hexdigest()
replace('apps/xenterm/tool/package_windows_installer.ps1',
        '@("README.md", "README.zh.md",', '@("LICENSE", "README.md", "README.zh.md",')
# Rename only the distribution wrapper, not Flutter's generated build output.
p = root / 'apps/xenterm/tool/package_desktop.sh'
before = p.read_bytes()
s = before.decode('utf-8').replace('\r\n', '\n').replace('rm -rf XenTerm.app', 'rm -rf "XenTerm.app"')
s = s.replace('XenTerm.app', 'XenTerm Flutter Next.app')
s = s.replace('  local stage="$1"', '  local stage="$1"\n  cp LICENSE "$stage/"')
s = s.replace('    # Re-sign the whole bundle', '    copy_extras "XenTerm Flutter Next.app/Contents/Resources"\n    # Re-sign the whole bundle')
p.write_bytes(s.encode('utf-8'))
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
}, indent=2) + '\n', encoding='utf-8', newline='\n')
