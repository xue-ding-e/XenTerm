// This same test compiles against the pre-fix app API and must fail there by
// the clipboard assertion, not a missing new type or zero selected tests.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/data/hosts.dart';
import 'package:xenterm_app/screens/terminal/terminal_view.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/theme/app_theme.dart';

class _CopySession implements TerminalSession {
  @override
  int get version => 1;
  @override
  Map<String, dynamic> snapshot() => {
    'cols': 8, 'rowCount': 1,
    'rows': [{'text': 'abcdef  ', 'cellOffsets': [0, 1, 2, 3, 4, 5, 6, 7, 8],
      'wrapped': false, 'runs': [{'t': 'abcdef  ', 'c': 8, 's': {}}]}],
  };
  @override
  bool send(List<int> bytes) => true;
  @override
  bool resize(int cols, int rows) => true;
  @override
  bool answerPrompt(int promptId, {required bool accept, String? username, String? password, String? text}) => true;
  @override
  void close() {}
  // The new paste method is deliberately not named/referenced by this copy-only
  // regression; invoking any unimplemented method is a test failure.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected ${invocation.memberName}');
}

void main() {
  testWidgets('dragging terminal cells copies only the selected output', (tester) async {
    var clipboard = 'unchanged';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    final fonts = AppFonts();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      fonts.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(ShadcnApp(
      theme: ThemeData(colorScheme: xtDarkScheme()),
      home: Scaffold(child: TerminalView(
        host: const Host(id: 'copy-regression', label: 'Synthetic', address: 'localhost'),
        fonts: fonts, sessionStarter: () => _CopySession(),
      )),
    ));
    await tester.pump(const Duration(milliseconds: 1));
    final finder = find.byKey(const ValueKey('terminal-canvas'));
    final painter = tester.widget<CustomPaint>(finder).painter! as TerminalPainter;
    await tester.dragFrom(
      tester.getTopLeft(finder) + Offset(painter.cellWidth * 0.5, painter.lineHeight * 0.5),
      Offset(painter.cellWidth * 3, 0),
    );
    await tester.pump();
    expect(clipboard, 'abcd');
  });
}
