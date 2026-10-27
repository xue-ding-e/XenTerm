"""Record SDK instrumentation closure; forbid existing dependency/source drift."""
import argparse
import hashlib
import json
from pathlib import Path
import yaml
p = argparse.ArgumentParser(); p.add_argument('product', type=Path); p.add_argument('host', type=Path); p.add_argument('deps', type=Path); p.add_argument('output', type=Path); a = p.parse_args()
original = yaml.safe_load((a.product / 'pubspec.lock').read_text())['packages']
actual = yaml.safe_load((a.host / 'pubspec.lock').read_text())['packages']
for name, expected in original.items():
    assert name in actual
    assert {k: v for k, v in expected.items() if k != 'dependency'} == {k: v for k, v in actual[name].items() if k != 'dependency'}, f'Existing dependency drift: {name}'
packages = {p['name']: p for p in json.loads(a.deps.read_text())['packages']}
closure = set(); pending = ['integration_test']
while pending:
    name = pending.pop()
    if name in closure: continue
    closure.add(name); pending.extend(packages[name].get('dependencies', []))
added = set(actual) - set(original)
assert 'integration_test' in added and added <= closure
assert actual['integration_test']['source'] == 'sdk'
hashes = {}
for directory in ['lib', 'assets', 'linux']:
    original_files = {p.relative_to(a.product) for p in (a.product / directory).rglob('*') if p.is_file() and 'ephemeral' not in p.parts and '.plugin_symlinks' not in p.parts}
    actual_files = {p.relative_to(a.host) for p in (a.host / directory).rglob('*') if p.is_file() and 'ephemeral' not in p.parts and '.plugin_symlinks' not in p.parts}
    assert original_files == actual_files, f'Production file set changed: {directory}'
    for relative in original_files:
        original_bytes = (a.product / relative).read_bytes()
        assert original_bytes == (a.host / relative).read_bytes(), f'Production bytes changed: {relative}'
        hashes[str(relative)] = hashlib.sha256(original_bytes).hexdigest()
a.output.write_text(json.dumps({'instrumentation': 'Flutter SDK integration_test', 'added_dependency_closure': {n: actual[n] for n in sorted(added)}, 'unchanged_product_files_sha256': hashes}, indent=2) + '\n')
print(f'Existing {len(original)} dependencies unchanged; {len(added)} additions in SDK test closure; {len(hashes)} product files byte-identical')
