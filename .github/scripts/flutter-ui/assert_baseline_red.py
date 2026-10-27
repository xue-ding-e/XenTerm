"""Require execution of named regression and its intended assertion failure."""
import argparse
import json
import re
from pathlib import Path


def verify(events, name, expected, actual, exit_code):
    assert exit_code != 0, 'baseline unexpectedly passed'
    starts = [e['test'] for e in events
              if e.get('type') == 'testStart' and e['test']['name'] == name]
    assert len(starts) == 1, 'named regression did not execute exactly once'
    test_id = starts[0]['id']
    done = [e for e in events
            if e.get('type') == 'testDone' and e.get('testID') == test_id]
    assert len(done) == 1 and done[0]['result'] in ('failure', 'error')
    assert not done[0].get('skipped', False)
    failed = [e for e in events if e.get('type') == 'testDone'
              and e.get('result') in ('failure', 'error')]
    assert failed == done, 'another test or loading stage also failed'
    errors = [e for e in events if e.get('type') == 'error']
    assert len(errors) == 1 and errors[0].get('testID') == test_id, (
        'unexpected compilation, fixture, or multiple failures')
    error = errors[0]['error']
    prints = [e for e in events if e.get('type') == 'print']
    assert not any(word in e.get('message', '') for e in prints for word in (
        'Another exception', 'Multiple exceptions', '_TypeError'))
    exceptions = [e for e in prints
                  if 'EXCEPTION CAUGHT' in e.get('message', '')]
    assert all(e.get('testID') == test_id for e in exceptions), (
        'framework exception belongs to another test')
    # Flutter widget tests put the assertion in a print event and only emit a
    # summary error. Never accept an unrelated paint/fixture exception as RED.
    if 'Expected:' in error and 'Actual:' in error:
        assert not exceptions, 'unexpected extra framework exception'
        detail = error
    else:
        assert error.startswith('Test failed. See exception logs above.')
        assert len(exceptions) == 1, 'expected one framework assertion only'
        detail = exceptions[0]['message']
        assert detail.count('The following TestFailure was thrown running a test:') == 1
    expected_line = re.search(r'^Expected:\s*(.+)$', detail, re.MULTILINE)
    actual_line = re.search(r'^\s*Actual:\s*(.+)$', detail, re.MULTILINE)
    assert expected_line and actual_line, detail
    assert expected in expected_line[1] and actual in actual_line[1], detail
    assert not any(word in detail for word in (
        'Compilation failed', 'Failed to load', 'No tests ran',
        'Multiple exceptions', 'Another exception', '_TypeError'))
    final = [e for e in events if e.get('type') == 'done']
    assert len(final) == 1 and final[0]['success'] is False
    return {'test': name, 'baseline': 'assertion-red', 'executed': 1}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('events', type=Path)
    parser.add_argument('name')
    parser.add_argument('expected')
    parser.add_argument('actual')
    parser.add_argument('exit_code', type=int)
    args = parser.parse_args()
    events = []
    for line in args.events.read_text().splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    print(json.dumps(verify(events, args.name, args.expected, args.actual,
                            args.exit_code)))


if __name__ == '__main__':
    main()
