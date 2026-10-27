import 'package:flutter_test/flutter_test.dart';
import 'package:xenterm_app/terminal/terminal_selection.dart';

Map<String, dynamic> _screen(List<Map<String, dynamic>> rows) => {
  'rows': rows,
  'cols': (rows.first['cellOffsets'] as List).length - 1,
  'rowCount': rows.length,
};

Map<String, dynamic> _row(String text, List<int> offsets, {bool wrapped = false}) => {
  'text': text,
  'cellOffsets': offsets,
  'wrapped': wrapped,
};

void main() {
  test('selection copies only the chosen cells in either direction', () {
    final screen = _screen([_row('hello ', [0, 1, 2, 3, 4, 5, 6])]);
    for (final selection in [
      const TerminalSelection((row: 0, column: 1), (row: 0, column: 3)),
      const TerminalSelection((row: 0, column: 3), (row: 0, column: 1)),
    ]) {
      expect(selection.text(screen), 'ell');
    }
  });

  test('either half of a wide character copies the whole character', () {
    final screen = _screen([_row('A中B ', [0, 1, 1, 2, 3, 4])]);
    for (final column in [1, 2]) {
      final selection = TerminalSelection(
        (row: 0, column: column), (row: 0, column: column),
      );
      expect(selection.text(screen), '中');
      expect(selection.ranges(screen), [(row: 0, start: 1, end: 3)]);
    }
  });

  test('emoji surrogate pairs and combining marks remain whole', () {
    final screen = _screen([_row('🙂e\u0301 ', [0, 0, 2, 4, 5])]);
    expect(const TerminalSelection((row: 0, column: 0), (row: 0, column: 1)).text(screen), '🙂');
    expect(const TerminalSelection((row: 0, column: 2), (row: 0, column: 2)).text(screen), 'e\u0301');
  });

  test('soft wrapped rows join without inserting a newline', () {
    final screen = _screen([
      _row('abcd', [0, 1, 2, 3, 4], wrapped: true),
      _row('ef  ', [0, 1, 2, 3, 4]),
    ]);
    expect(const TerminalSelection((row: 0, column: 1), (row: 1, column: 1)).text(screen), 'bcdef');
  });

  test('hard wrapped rows retain a newline and trim end-of-row padding', () {
    final screen = _screen([
      _row('ab  ', [0, 1, 2, 3, 4]),
      _row('cd  ', [0, 1, 2, 3, 4]),
    ]);
    expect(const TerminalSelection((row: 0, column: 0), (row: 1, column: 3)).text(screen), 'ab\ncd');
  });

  test('a leading wide-character wrap spacer has no copied text', () {
    final screen = _screen([_row('abc', [0, 1, 2, 3, 3], wrapped: true)]);
    expect(const TerminalSelection((row: 0, column: 3), (row: 0, column: 3)).text(screen), '');
  });

  test('old snapshots without cell metadata cannot be selected', () {
    const selection = TerminalSelection((row: 0, column: 0), (row: 0, column: 0));
    expect(selection.text({'cols': 2, 'rows': [{'text': 'ab'}]}), '');
  });

  test('malformed or mismatched UTF16 boundaries are rejected', () {
    const selection = TerminalSelection((row: 0, column: 0), (row: 0, column: 1));
    for (final offsets in [
      [0, 1, 2], // Middle offset splits the emoji surrogate pair.
      [0, 2, 1], // Non-monotonic.
      [0, 2, 3], // Beyond the text.
      [1, 1, 2], // Missing the start.
      [0, 0, 1], // Missing the end.
    ]) {
      expect(selection.text(_screen([_row('🙂', offsets)])), '');
    }
    final wrongColumns = _screen([_row('ab', [0, 1, 2])])..['cols'] = 3;
    expect(selection.text(wrongColumns), '');
  });

  test('scroll or text changes invalidate selection but cursor changes do not', () {
    final before = _screen([_row('ab', [0, 1, 2])]);
    final same = _screen([_row('ab', [0, 1, 2])])..['cursor'] = [0, 1];
    expect(sameTerminalSelectionContent(before, same), isTrue);
    expect(sameTerminalSelectionContent(before, _screen([_row('cd', [0, 1, 2])])), isFalse);
    expect(sameTerminalSelectionContent(before, _screen([_row('ab', [0, 1, 2], wrapped: true)])), isFalse);
  });
}
