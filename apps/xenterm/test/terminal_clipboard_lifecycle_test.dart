import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/data/hosts.dart';
import 'package:xenterm_app/screens/terminal/terminal_view.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/theme/app_theme.dart';
import 'package:xenterm_app/widgets/primitives.dart';

class _Session implements TerminalSession {
  final pasteRequests = <({String text, bool confirmed})>[];
  final sent = <List<int>>[];

  @override
  int get version => 1;
  @override
  Map<String, dynamic> snapshot() => {'rows': <dynamic>[]};
  @override
  TerminalPasteResult paste(String text, {bool confirmed = false}) {
    pasteRequests.add((text: text, confirmed: confirmed));
    return confirmed
        ? TerminalPasteResult.sent
        : TerminalPasteResult.needsReview;
  }
  @override
  bool send(List<int> bytes) {
    sent.add(List.of(bytes));
    return true;
  }
  @override
  bool resize(int cols, int rows) => true;
  @override
  bool answerPrompt(int promptId, {required bool accept, String? username,
      String? password, String? text}) => true;
  @override
  void close() {}
}

class _Fixture {
  final fonts = AppFonts();
  final session = _Session();
  bool active = true;
  VoidCallback? duringBuild;

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(ShadcnApp(
    theme: ThemeData(colorScheme: xtDarkScheme()),
    home: Scaffold(child: Column(children: [
      Expanded(child: TerminalView(
        host: const Host(id: 'clipboard-lifecycle', label: 'Synthetic',
            address: 'localhost'),
        fonts: fonts,
        active: active,
        sessionStarter: () => session,
      )),
      Builder(builder: (_) {
        final callback = duringBuild;
        duringBuild = null;
        callback?.call();
        return const SizedBox.shrink();
      }),
    ])),
  ));
}

VoidCallback _action(WidgetTester tester, String key) =>
    tester.widget<XtActionButton>(find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.byType(XtActionButton),
    )).onPressed!;

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return {'text': 'first\nsecond\n'};
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<_Fixture> openReview(WidgetTester tester) async {
    final fixture = _Fixture();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      fixture.fonts.dispose();
    });
    await fixture.pump(tester);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-paste-confirm')), findsOneWidget);
    return fixture;
  }

  void expectUnconfirmed(_Fixture fixture) {
    expect(fixture.session.pasteRequests, [
      (text: 'first\nsecond\n', confirmed: false),
    ]);
    expect(fixture.session.sent, isEmpty);
  }

  testWidgets('deactivating a review during build revokes its old confirmation',
      (tester) async {
    final fixture = await openReview(tester);
    final confirm = _action(tester, 'terminal-paste-confirm');
    fixture.active = false;
    await fixture.pump(tester);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('terminal-paste-review')), findsNothing);
    fixture.active = true;
    await fixture.pump(tester);
    confirm();
    await tester.pump();
    expectUnconfirmed(fixture);
  });

  testWidgets('build-time cancellation is immediate and cannot hide a newer menu',
      (tester) async {
    final fixture = await openReview(tester);
    final cancel = _action(tester, 'terminal-paste-cancel');
    final confirm = _action(tester, 'terminal-paste-confirm');
    final openMenu = tester.widgetList<GestureDetector>(find.descendant(
      of: find.byType(TerminalView),
      matching: find.byType(GestureDetector),
    )).singleWhere((widget) => widget.onSecondaryTapDown != null)
        .onSecondaryTapDown!;
    fixture.duringBuild = () {
      expect(SchedulerBinding.instance.schedulerPhase,
          SchedulerPhase.persistentCallbacks);
      cancel();
      // The pane is still active here. Delaying logical cancellation as well
      // as hide would let this retained callback send the old clipboard text.
      confirm();
      expectUnconfirmed(fixture);
    };
    // Registered before build schedules its hide, so this newer interaction
    // opens a menu earlier in the same post-frame callback queue.
    tester.binding.addPostFrameCallback((_) {
      openMenu(TapDownDetails(globalPosition: const Offset(40, 40)));
    });
    await fixture.pump(tester);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('terminal-paste-review')), findsNothing);
    expect(find.byKey(const ValueKey('terminal-paste')), findsOneWidget);
    expectUnconfirmed(fixture);
  });

  testWidgets('a queued clipboard hide is harmless after the pane is disposed',
      (tester) async {
    final fixture = await openReview(tester);
    final cancel = _action(tester, 'terminal-paste-cancel');
    await tester.pumpWidget(Builder(builder: (_) {
      // The old element is deactivated but not disposed until finalization,
      // which precedes the hide's post-frame callback.
      cancel();
      return const SizedBox.shrink();
    }));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expectUnconfirmed(fixture);
  });
}
