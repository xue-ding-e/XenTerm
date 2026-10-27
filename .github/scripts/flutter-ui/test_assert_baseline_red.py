"""The RED gate must reject compilation and secondary fixture exceptions."""
import copy
import unittest

from assert_baseline_red import verify


def widget_events():
    return [
        {'type': 'testStart', 'test': {'id': 3, 'name': 'regression'}},
        {'type': 'print', 'testID': 3, 'message':
         'EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK\n'
         'The following TestFailure was thrown running a test:\n'
         "Expected: 'zh'\n  Actual: 'en'\n"},
        {'type': 'error', 'testID': 3,
         'error': 'Test failed. See exception logs above.'},
        {'type': 'testDone', 'testID': 3, 'result': 'error', 'skipped': False},
        {'type': 'done', 'success': False},
    ]


class BaselineGateTests(unittest.TestCase):
    def check(self, events, status=1):
        return verify(events, 'regression', "'zh'", "'en'", status)

    def test_accepts_single_widget_assertion(self):
        self.assertEqual(self.check(widget_events())['executed'], 1)

    def test_accepts_direct_assertion(self):
        events = widget_events()
        del events[1]
        events[1]['error'] = "Expected: 'zh'\n  Actual: 'en'"
        self.assertEqual(self.check(events)['baseline'], 'assertion-red')

    def test_rejects_success(self):
        with self.assertRaises(AssertionError):
            self.check(widget_events(), 0)

    def test_rejects_zero_selected_tests(self):
        events = widget_events()[1:]
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_compilation_error(self):
        events = widget_events()
        events[2]['error'] = 'Compilation failed'
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_secondary_paint_exception(self):
        events = widget_events()
        events.insert(1, {'type': 'print', 'testID': 3, 'message':
                         'EXCEPTION CAUGHT BY RENDERING LIBRARY\n_TypeError'})
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_other_test_error(self):
        events = widget_events()
        events.append({'type': 'error', 'testID': 1, 'error': 'Failed to load'})
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_wrong_test_id_on_print(self):
        events = widget_events()
        events[1]['testID'] = 1
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_another_runtime_exception(self):
        events = widget_events()
        events.append({'type': 'print', 'testID': 3,
                       'message': 'Another exception was thrown: StateError'})
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_multiple_exception_summary(self):
        events = widget_events()
        events[1]['message'] += '\nMultiple exceptions (2) were detected.'
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_other_completed_failure(self):
        events = widget_events()
        events.append({'type': 'testDone', 'testID': 1, 'result': 'error'})
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_repeated_assertion_in_one_print(self):
        events = widget_events()
        events[1]['message'] *= 2
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_wrong_actual_or_expectation(self):
        for old, new in [("Expected: 'zh'", "Expected: 'ja'"),
                         ("Actual: 'en'", "Actual: 'zh'")]:
            events = copy.deepcopy(widget_events())
            events[1]['message'] = events[1]['message'].replace(old, new)
            with self.assertRaises(AssertionError):
                self.check(events)

    def test_rejects_duplicate_execution(self):
        events = widget_events()
        events.append(events[0])
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_rejects_missing_run_completion(self):
        with self.assertRaises(AssertionError):
            self.check(widget_events()[:-1])


if __name__ == '__main__':
    unittest.main()
