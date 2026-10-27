import 'dart:async';

import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/data/hosts.dart';
import 'package:xenterm_app/screens/terminal/terminal_view.dart';
import 'package:xenterm_app/screens/terminal/terminal_tools_panel.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/theme/app_theme.dart';
import 'package:xenterm_app/widgets/primitives.dart';

class _Session implements TerminalSession {
  final sent = <List<int>>[];
  final pasted = <String>[];
  final pasteRequests = <({String text, bool confirmed})>[];
  bool review = false;
  bool reject = false;
  int currentVersion = 1;
  Map<String, dynamic> frame = {
    'rows': [
      {'text': 'abcdef  ', 'cellOffsets': [0, 1, 2, 3, 4, 5, 6, 7, 8],
       'wrapped': false, 'runs': [{'t': 'abcdef  ', 'c': 8, 's': <String, dynamic>{}}]},
    ],
    'cols': 8,
    'rowCount': 1,
    'cursor': [0, 0],
  };

  @override
  int get version => currentVersion;
  @override
  Map<String, dynamic>? snapshot() => frame;
  @override
  bool send(List<int> bytes) { sent.add(List.of(bytes)); return true; }
  @override
  TerminalPasteResult paste(String text, {bool confirmed = false}) {
    pasteRequests.add((text: text, confirmed: confirmed));
    if (reject) return TerminalPasteResult.rejected;
    if (review && !confirmed) return TerminalPasteResult.needsReview;
    pasted.add(text);
    return TerminalPasteResult.sent;
  }
  @override
  bool resize(int cols, int rows) => true;
  @override
  bool answerPrompt(int promptId, {required bool accept, String? username, String? password, String? text}) => true;
  @override
  void close() {}
}

Future<void> _keys(WidgetTester tester, LogicalKeyboardKey key, {bool control = false, bool shift = false, bool meta = false, bool alt = false}) async {
  final modifiers = [
    if (control) LogicalKeyboardKey.controlLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
    if (meta) LogicalKeyboardKey.metaLeft,
    if (alt) LogicalKeyboardKey.altLeft,
  ];
  for (final modifier in modifiers) { await tester.sendKeyDownEvent(modifier); }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) { await tester.sendKeyUpEvent(modifier); }
  await tester.pump();
}

Future<void> _mount(WidgetTester tester, _Session session, {bool active = true, TerminalSession Function()? sessionStarter}) async {
  final fonts = AppFonts();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    fonts.dispose();
  });
  await tester.pumpWidget(ShadcnApp(
    theme: ThemeData(colorScheme: xtDarkScheme()),
    home: Scaffold(child: TerminalView(
      host: const Host(id: 'clipboard-fixture', label: 'Synthetic', address: 'localhost'),
      fonts: fonts,
      active: active,
      sessionStarter: sessionStarter ?? () => session,
    )),
  ));
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

Future<void> _select(WidgetTester tester) async {
  final finder = find.byKey(const ValueKey('terminal-canvas'));
  final painter = tester.widget<CustomPaint>(finder).painter! as TerminalPainter;
  final origin = tester.getTopLeft(finder);
  await tester.dragFrom(
    origin + Offset(painter.cellWidth * 0.5, painter.lineHeight * 0.5),
    Offset(painter.cellWidth * 3, 0),
  );
  await tester.pump();
}

void main() {
  String clipboard = '';
  Completer<Object?>? delayedRead;
  Completer<Object?>? delayedWrite;
  setUp(() {
    clipboard = 'synthetic-paste';
    delayedRead = null;
    delayedWrite = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          if (delayedRead != null) return delayedRead!.future;
          return {'text': clipboard};
        case 'Clipboard.setData':
          if (delayedWrite != null) return delayedWrite!.future;
          clipboard = (call.arguments as Map)['text'] as String;
          return null;
        case 'Clipboard.hasStrings':
          return {'value': clipboard.isNotEmpty};
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('Ctrl+C copies a nonempty selection without interrupting', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await _select(tester);
    expect(clipboard, 'abcd');
    clipboard = 'replace-on-explicit-copy';
    await _keys(tester, LogicalKeyboardKey.keyC, control: true);
    expect(clipboard, 'abcd');
    expect(session.sent, isEmpty);
  });

  testWidgets('Ctrl+C without a selection keeps the interrupt byte', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyC, control: true);
    expect(session.sent, [[3]]);
    expect(clipboard, 'synthetic-paste');
  });

  for (final platform in [foundation.TargetPlatform.linux, foundation.TargetPlatform.windows, foundation.TargetPlatform.macOS]) {
    testWidgets('$platform platform clipboard chords never become PTY key bytes', (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final mac = platform == foundation.TargetPlatform.macOS;
      await _keys(tester, LogicalKeyboardKey.keyC, control: !mac, shift: !mac, meta: mac);
      expect(session.sent, isEmpty);
      await _keys(tester, LogicalKeyboardKey.keyV, control: !mac, shift: !mac, meta: mac);
      expect(session.pasted, ['synthetic-paste']);
      expect(session.sent, isEmpty);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('Ctrl+V uses paste rather than raw input', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    expect(session.pasted, ['synthetic-paste']);
    expect(session.sent, isEmpty);
  });

  testWidgets('mixed Alt shortcuts retain the existing key encoding', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true, alt: true);
    expect(session.sent, [[22]]);
    expect(session.pasteRequests, isEmpty);
  });

  testWidgets('review cancellation sends no terminal input and keeps selection', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    await _select(tester);
    clipboard = 'first\nsecond\n';
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    expect(find.byKey(const ValueKey('terminal-paste-review')), findsOneWidget);
    expect(session.pasted, isEmpty);
    await tester.tap(find.byKey(const ValueKey('terminal-paste-cancel')));
    await tester.pump();
    expect(session.sent, isEmpty);
    expect(session.pasted, isEmpty);
    await _keys(tester, LogicalKeyboardKey.keyC, control: true);
    expect(clipboard, 'abcd');
  });

  testWidgets('review defaults keyboard activation to cancel, not sending', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-paste-confirm')), findsNothing);
    expect(session.pasted, isEmpty);
    expect(session.sent, isEmpty);
  });

  testWidgets('review confirms the original immutable text exactly once', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    clipboard = 'first\nsecond\n';
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    clipboard = 'changed-during-review';
    await tester.tap(find.byKey(const ValueKey('terminal-paste-confirm')));
    await tester.pump();
    expect(session.pasteRequests, [
      (text: 'first\nsecond\n', confirmed: false),
      (text: 'first\nsecond\n', confirmed: true),
    ]);
    expect(session.pasted, ['first\nsecond\n']);
    expect(session.sent, isEmpty);
  });

  testWidgets('one review can only be confirmed once before rebuild', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    final confirm = tester.widget<XtActionButton>(find.descendant(
      of: find.byKey(const ValueKey('terminal-paste-confirm')),
      matching: find.byType(XtActionButton),
    )).onPressed!;
    confirm();
    confirm();
    await tester.pump();
    expect(session.pasted, ['synthetic-paste']);
    expect(session.pasteRequests.where((request) => request.confirmed).length, 1);
  });

  testWidgets('cancel invalidates a previously captured confirmation callback', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    final confirm = tester.widget<XtActionButton>(find.descendant(
      of: find.byKey(const ValueKey('terminal-paste-confirm')),
      matching: find.byType(XtActionButton),
    )).onPressed!;
    final cancel = tester.widget<XtActionButton>(find.descendant(
      of: find.byKey(const ValueKey('terminal-paste-cancel')),
      matching: find.byType(XtActionButton),
    )).onPressed!;
    cancel();
    confirm();
    await tester.pump();
    expect(session.pasted, isEmpty);
    expect(session.pasteRequests.where((request) => request.confirmed), isEmpty);
    expect(session.sent, isEmpty);
  });

  testWidgets('copy failure after deactivation cannot reopen an old overlay', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await _select(tester);
    delayedWrite = Completer<Object?>();
    await _keys(tester, LogicalKeyboardKey.keyC, control: true);
    await _mount(tester, session, active: false);
    delayedWrite!.completeError(PlatformException(code: 'synthetic-copy-failure'));
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-paste-review')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closed session cancels pending review without sending', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    session.frame = {...session.frame, 'closed': 'synthetic close'};
    session.currentVersion++;
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const ValueKey('terminal-paste-confirm')), findsNothing);
    expect(session.pasted, isEmpty);
  });

  testWidgets('right click menu has disabled copy without a selection', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await tester.tap(find.byKey(const ValueKey('terminal-canvas')), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-copy-selection')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-copy-selection')), warnIfMissed: false);
    await tester.pump();
    expect(clipboard, 'synthetic-paste');
    expect(session.sent, isEmpty);
    await tester.tap(find.byKey(const ValueKey('terminal-paste')));
    await tester.pump();
    expect(session.pasted, ['synthetic-paste']);
  });

  testWidgets('search field keeps clipboard and undo input out of the terminal', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await tester.tap(find.byKey(const ValueKey('terminal-search')));
    await tester.pump();
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    await _keys(tester, LogicalKeyboardKey.keyZ, control: true);
    expect(session.sent, isEmpty);
    expect(session.pasteRequests, isEmpty);
  });

  testWidgets('losing focus while reading clipboard prevents a late paste', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    delayedRead = Completer<Object?>();
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    await tester.tap(find.byKey(const ValueKey('terminal-search')));
    await tester.pump();
    delayedRead!.complete({'text': 'late-text'});
    await tester.pump();
    expect(session.pasteRequests, isEmpty);
    expect(session.sent, isEmpty);
  });

  testWidgets('focus regain cannot revive a clipboard read canceled by focus loss', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    delayedRead = Completer<Object?>();
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    await tester.tap(find.byKey(const ValueKey('terminal-search')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-canvas')));
    await tester.pump();
    delayedRead!.complete({'text': 'late-text'});
    await tester.pump();
    expect(session.pasteRequests, isEmpty);
    expect(session.sent, isEmpty);
  });

  testWidgets('a late clipboard read cannot cross a reconnect to a new session', (tester) async {
    final oldSession = _Session();
    final newSession = _Session();
    var starts = 0;
    await _mount(tester, oldSession, sessionStarter: () => starts++ == 0 ? oldSession : newSession);
    delayedRead = Completer<Object?>();
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    tester.widget<TerminalToolsPanel>(find.byType(TerminalToolsPanel)).onReconnect();
    await tester.pump();
    delayedRead!.complete({'text': 'belongs-to-old-session'});
    await tester.pump();
    expect(starts, 2);
    expect(oldSession.pasteRequests, isEmpty);
    expect(newSession.pasteRequests, isEmpty);
    expect(oldSession.sent, isEmpty);
    expect(newSession.sent, isEmpty);
  });

  testWidgets('ending an old selection drag does not invalidate a pending review', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    final canvas = find.byKey(const ValueKey('terminal-canvas'));
    final painter = tester.widget<CustomPaint>(canvas).painter! as TerminalPainter;
    final drag = await tester.startGesture(tester.getTopLeft(canvas) +
        Offset(painter.cellWidth * 0.5, painter.lineHeight * 0.5));
    await drag.moveBy(Offset(painter.cellWidth * 3, 0));
    await drag.moveBy(Offset(painter.cellWidth, 0));
    await tester.pump();
    final selected = tester.widget<CustomPaint>(canvas).painter! as TerminalPainter;
    expect(selected.selection?.text(selected.screen), isNotEmpty);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    await drag.up();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-paste-confirm')));
    await tester.pump();
    expect(session.pasted, ['synthetic-paste']);
    expect(session.sent, isEmpty);
  });

  testWidgets('review keyboard activators do not accept key repeats', (tester) async {
    final session = _Session()..review = true;
    await _mount(tester, session);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    for (final key in ['terminal-paste-cancel', 'terminal-paste-confirm']) {
      final detector = tester.widget<FocusableActionDetector>(find.descendant(
        of: find.byKey(ValueKey(key)), matching: find.byType(FocusableActionDetector),
      ));
      final activators = detector.shortcuts!.keys.whereType<SingleActivator>();
      expect(activators, hasLength(2));
      expect(activators.every((activator) => !activator.includeRepeats), isTrue);
    }
  });

  testWidgets('inactive terminal never reads or sends clipboard text', (tester) async {
    final session = _Session();
    await _mount(tester, session, active: false);
    await _keys(tester, LogicalKeyboardKey.keyV, control: true);
    expect(session.pasteRequests, isEmpty);
    expect(session.sent, isEmpty);
  });

  testWidgets('screen content changes clear stale selection before Ctrl+C', (tester) async {
    final session = _Session();
    await _mount(tester, session);
    await _select(tester);
    session.frame = {...session.frame, 'rows': [
      {'text': 'changed ', 'cellOffsets': [0, 1, 2, 3, 4, 5, 6, 7, 8],
       'wrapped': false, 'runs': [{'t': 'changed ', 'c': 8, 's': <String, dynamic>{}}]},
    ]};
    session.currentVersion++;
    await tester.pump(const Duration(milliseconds: 250));
    await _keys(tester, LogicalKeyboardKey.keyC, control: true);
    expect(session.sent, [[3]]);
  });
}
