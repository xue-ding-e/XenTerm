/// Cell-based selection over the exact rows rendered by the native terminal.
/// Offsets are UTF-16 boundaries supplied by the core, not guessed character
/// widths: a wide glyph's two cells share a start, and combining marks remain
/// attached to their base. Unknown/older snapshots cannot produce a selection.
library;

typedef TerminalCellPosition = ({int row, int column});
typedef TerminalSelectionRange = ({int row, int start, int end});

class TerminalSelection {
  final TerminalCellPosition anchor;
  final TerminalCellPosition extent;

  const TerminalSelection(this.anchor, this.extent);

  List<TerminalSelectionRange> ranges(Map<String, dynamic>? screen) {
    final rows = screen?['rows'];
    final columns = screen?['cols'];
    if (rows is! List || rows.isEmpty || columns is! int || columns < 1) {
      return const [];
    }
    final rowCount = screen?['rowCount'];
    if (rowCount != null && rowCount != rows.length) return const [];
    final forward = anchor.row < extent.row ||
        (anchor.row == extent.row && anchor.column <= extent.column);
    final first = forward ? anchor : extent;
    final last = forward ? extent : anchor;
    if (first.row < 0 || last.row >= rows.length) return const [];
    final result = <TerminalSelectionRange>[];
    for (var row = first.row; row <= last.row; row++) {
      final data = rows[row];
      if (data is! Map) return const [];
      final text = data['text'];
      final offsets = data['cellOffsets'];
      if (text is! String || offsets is! List || offsets.length != columns + 1) {
        return const [];
      }
      var previous = 0;
      for (final offset in offsets) {
        if (offset is! int || offset < previous || offset > text.length) {
          return const [];
        }
        // Never split a UTF-16 surrogate pair, even in a malformed snapshot.
        if (offset > 0 && offset < text.length &&
            text.codeUnitAt(offset) >= 0xdc00 &&
            text.codeUnitAt(offset) <= 0xdfff) {
          return const [];
        }
        previous = offset;
      }
      if (offsets.first != 0 || offsets.last != text.length) return const [];
      var start = row == first.row ? first.column : 0;
      var end = row == last.row ? last.column + 1 : columns;
      if (start < 0 || start >= columns || end <= 0 || end > columns) {
        return const [];
      }
      // Selecting either half of a wide cell selects the complete glyph.
      while (start > 0 && offsets[start - 1] == offsets[start]) {
        start--;
      }
      while (end < columns && offsets[end] == offsets[end - 1]) {
        end++;
      }
      result.add((row: row, start: start, end: end));
    }
    return result;
  }

  String text(Map<String, dynamic>? screen) {
    final selected = ranges(screen);
    if (selected.isEmpty) return '';
    final rows = screen!['rows'] as List;
    final result = StringBuffer();
    for (var index = 0; index < selected.length; index++) {
      final range = selected[index];
      final row = rows[range.row] as Map;
      final offsets = row['cellOffsets'] as List;
      final text = row['text'] as String;
      var part = text.substring(offsets[range.start], offsets[range.end]);
      final reachesEnd = range.end == offsets.length - 1;
      final wrapped = row['wrapped'] == true;
      if (reachesEnd && !wrapped) part = part.replaceFirst(RegExp(r' +$'), '');
      result.write(part);
      if (index < selected.length - 1 && !(reachesEnd && wrapped)) {
        result.write('\n');
      }
    }
    return result.toString();
  }
}

/// Selection must not silently move to different output after a screen update
/// or scroll. Cursor/status-only updates may retain it.
bool sameTerminalSelectionContent(
  Map<String, dynamic>? before,
  Map<String, dynamic>? after,
) {
  final left = before?['rows'];
  final right = after?['rows'];
  if (left is! List || right is! List || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a is! Map || b is! Map || a['text'] != b['text'] ||
        a['wrapped'] != b['wrapped']) {
      return false;
    }
    final aOffsets = a['cellOffsets'];
    final bOffsets = b['cellOffsets'];
    if (aOffsets is! List || bOffsets is! List ||
        aOffsets.length != bOffsets.length) {
      return false;
    }
    for (var cell = 0; cell < aOffsets.length; cell++) {
      if (aOffsets[cell] != bOffsets[cell]) return false;
    }
  }
  return true;
}
