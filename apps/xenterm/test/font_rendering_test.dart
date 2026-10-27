import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/data/hosts.dart';
import 'package:xenterm_app/main.dart';
import 'package:xenterm_app/screens/terminal/terminal_view.dart';
import 'support/shared_settings_fixture.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/theme/app_theme.dart';

class _Session implements TerminalSession {
  int cols = 0;
  int rows = 0;
  @override
  int get version => 1;
  @override
  Map<String, dynamic> snapshot() => {
    'rows': [{'runs': [{'c': 0, 't': '字号 Font', 's': <String, dynamic>{}}], 'text': '字号 Font'}],
    'cursor': [0, 0],
  };
  @override
  bool resize(int columns, int lines) { cols = columns; rows = lines; return true; }
  @override
  bool send(List<int> bytes) => true;

  @override
  TerminalPasteResult paste(String text, {bool confirmed = false}) => TerminalPasteResult.sent;
  @override
  bool answerPrompt(int promptId, {required bool accept, String? username,
      String? password, String? text}) => true;
  @override
  void close() {}
  // Additional clipboard operations are not exercised by a rendering test.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Both regressions use only pre-existing APIs so they fail by assertion on
  // the original source. They measure real Flutter layout/painter input, not
  // merely that the preference number changed; native screenshots remain a
  // separate acceptance gate.
  testWidgets('UI size changes rendered labels, not terminal size', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fonts = AppFonts();
    final settings = SettingsFixture().controller();
    addTearDown(fonts.dispose);
    addTearDown(settings.dispose);
    await tester.pumpWidget(XenTermApp(
      fonts: fonts, settings: settings, hostsLoader: () async => [],
    ));
    await tester.pumpAndSettle();
    final label = find.descendant(of: find.text('Home').first, matching: find.byType(RichText));
    final before = tester.renderObject<RenderParagraph>(label).size.height;
    fonts.setUiSize(20);
    await tester.pumpAndSettle();
    final after = tester.renderObject<RenderParagraph>(label).size.height;
    expect(after, greaterThan(before));
    expect(fonts.terminalSize, 13);
    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal font change updates painter and PTY grid without parent rebuild', (tester) async {
    final fonts = AppFonts();
    final session = _Session();
    addTearDown(fonts.dispose);
    await tester.pumpWidget(ShadcnApp(
      theme: ThemeData(colorScheme: xtDarkScheme()),
      home: Scaffold(child: TerminalView(
        host: const Host(id: 'font-test', label: 'Font', address: 'localhost'),
        fonts: fonts,
        sessionStarter: () => session,
      )),
    ));
    await tester.pump(const Duration(milliseconds: 40));
    final beforeCols = session.cols;
    final beforeRows = session.rows;
    fonts.setTerminalSize(24);
    await tester.pump();
    final canvas = tester.widget<CustomPaint>(find.byKey(const ValueKey('terminal-canvas')));
    final painter = canvas.painter! as TerminalPainter;
    expect(painter.fontSize, 24);
    expect(session.cols, lessThan(beforeCols));
    expect(session.rows, lessThan(beforeRows));
    expect(fonts.uiSize, 14);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
