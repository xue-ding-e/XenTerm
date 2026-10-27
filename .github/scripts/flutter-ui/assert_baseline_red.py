"""Require execution of named regression and its intended assertion failure."""
import argparse
import json
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('events', type=Path)
p.add_argument('name')
p.add_argument('expected')
p.add_argument('actual')
p.add_argument('exit_code', type=int)
a = p.parse_args()
assert a.exit_code != 0, 'baseline unexpectedly passed'
events = []
for line in a.events.read_text().splitlines():
    try: events.append(json.loads(line))
    except json.JSONDecodeError: continue
starts = [e['test'] for e in events if e.get('type') == 'testStart' and e['test']['name'] == a.name]
assert len(starts) == 1, 'named regression did not execute exactly once'
id = starts[0]['id']
done = [e for e in events if e.get('type') == 'testDone' and e.get('testID') == id]
assert len(done) == 1 and done[0]['result'] in ('failure', 'error') and not done[0].get('skipped', False)
errors = [e['error'] for e in events if e.get('type') == 'error' and e.get('testID') == id]
assert len(errors) == 1, 'unexpected compilation, fixture, or multiple failures'
error = errors[0]
assert 'Expected:' in error and 'Actual:' in error and a.expected in error and a.actual in error, error
assert not any(word in error for word in ('Compilation failed', 'Failed to load', 'No tests ran'))
print(json.dumps({'test': a.name, 'baseline': 'assertion-red', 'executed': 1}))
