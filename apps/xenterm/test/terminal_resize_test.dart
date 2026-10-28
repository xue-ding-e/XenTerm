import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:flutter/scheduler.dart';
import 'package:xenterm_app/shell/window_activity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/data/hosts.dart';
import 'package:xenterm_app/screens/terminal/terminal_tools_panel.dart';
import 'package:xenterm_app/screens/terminal/terminal_view.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/theme/app_theme.dart';

class _RecordingSession implements TerminalSession {
  final sizes = <(int, int)>[];
  final phases = <SchedulerPhase>[];
  int closes = 0;
  int versionValue = 1;
  int versionReads = 0;
  bool disconnected = false;
  bool acceptsResize = true;

  @override
  int get version { versionReads++; return versionValue; }

  @override
  Map<String, dynamic> snapshot() => {
    'rows': <dynamic>[],
    if (disconnected) 'closed': 'test disconnect',
  };

  @override
  bool resize(int cols, int rows) {
    sizes.add((cols, rows));
    phases.add(SchedulerBinding.instance.schedulerPhase);
    return acceptsResize;
  }

  @override
  bool send(List<int> bytes) => true;

  @override
  TerminalPasteResult paste(String text, {bool confirmed = false}) => TerminalPasteResult.sent;

  @override
  bool answerPrompt(
    int promptId, {
    required bool accept,
    String? username,
    String? password,
    String? text,
  }) => true;

  @override
  void close() => closes++;
}

class _Fixture {
  final fonts = AppFonts();
  final _RecordingSession Function() start;
  double width = 1000;
  bool active = true;

  _Fixture(this.start);

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    ShadcnApp(
      theme: ThemeData(colorScheme: xtDarkScheme()),
      home: Scaffold(
        child: Center(
          child: SizedBox(
            width: width,
            height: 600,
            child: TerminalView(
              host: const Host(
                id: 'resize-test',
                label: 'Resize',
                address: 'localhost',
              ),
              fonts: fonts,
              active: active,
              sessionStarter: start,
            ),
          ),
        ),
      ),
    ),
  );

  (int, int) expectedSize(WidgetTester tester) {
    final finder = find.byKey(const ValueKey('terminal-canvas'));
    final size = tester.getSize(finder);
    final painter = tester.widget<CustomPaint>(finder).painter! as TerminalPainter;
    return (
      (size.width / painter.cellWidth).floor().clamp(2, 1000),
      (size.height / painter.lineHeight).floor().clamp(2, 1000),
    );
  }
}

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage(state.toString()),
    (_) {},
  );
}

void main() {
  Future<void> prepare(WidgetTester tester, _Fixture fixture) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1800, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(fixture.fonts.dispose);
    await _lifecycle(tester, AppLifecycleState.resumed);
    await fixture.pump(tester);
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('initial size is prompt and native reflow is outside layout', (
    tester,
  ) async {
    final session = _RecordingSession();
    final fixture = _Fixture(() => session);
    await prepare(tester, fixture);
    expect(session.sizes, [fixture.expectedSize(tester)]);
    expect(session.phases, everyElement(SchedulerPhase.idle));
    await fixture.pump(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(session.sizes, hasLength(1), reason: 'same grid is not resized');
    await finish(tester);
  });

  testWidgets('continuous dragging is throttled and flushes the final grid', (
    tester,
  ) async {
    final session = _RecordingSession();
    final fixture = _Fixture(() => session);
    await prepare(tester, fixture);
    for (var step = 1; step <= 20; step++) {
      fixture.width = 1000 + step * 20;
      await fixture.pump(tester);
      await tester.pump(const Duration(milliseconds: 10));
    }
    // Updates continue during the drag; a reset-on-every-event debounce would
    // still have sent only the initial grid. Inline resize sends 21 instead.
    expect(session.sizes.length, inInclusiveRange(3, 5));
    await tester.pump(const Duration(milliseconds: 61));
    expect(session.sizes.last, fixture.expectedSize(tester));
    expect(session.phases, everyElement(SchedulerPhase.idle));
    await finish(tester);
  });

  testWidgets('window animation pauses polling without starving final PTY size', (tester) async {
    windowActivity.wake();
    addTearDown(windowActivity.wake);
    final session = _RecordingSession();
    final fixture = _Fixture(() => session);
    await prepare(tester, fixture);
    windowActivity.resize();
    final reads = session.versionReads;
    for (final width in [1100.0, 1200.0, 1400.0]) {
      fixture.width = width;
      await fixture.pump(tester);
      await tester.pump(const Duration(milliseconds: 65));
      windowActivity.resize();
    }
    expect(session.versionReads, reads, reason: 'polling stays paused during animation');
    expect(session.sizes.last, fixture.expectedSize(tester));
    await tester.pump(WindowActivity.settleDelay + const Duration(milliseconds: 1));
    await tester.pump();
    expect(session.versionReads, greaterThan(reads), reason: 'settling resumes polling');
    expect(session.phases, everyElement(SchedulerPhase.idle));
    await finish(tester);
  });

  testWidgets('hidden tabs retain only the latest size and flush on activation', (
    tester,
  ) async {
    final session = _RecordingSession();
    final fixture = _Fixture(() => session)..active = false;
    await prepare(tester, fixture);
    for (final width in [1100.0, 1200.0, 1400.0]) {
      fixture.width = width;
      await fixture.pump(tester);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(session.sizes, isEmpty);
    fixture.active = true;
    await fixture.pump(tester);
    await tester.pump(const Duration(milliseconds: 1));
    expect(session.sizes, [fixture.expectedSize(tester)]);
    await finish(tester);
  });

  testWidgets('reconnect at identical bounds resizes the new default 80x24 PTY', (
    tester,
  ) async {
    final old = _RecordingSession();
    final next = _RecordingSession();
    var starts = 0;
    final fixture = _Fixture(() => starts++ == 0 ? old : next);
    await prepare(tester, fixture);
    final expected = fixture.expectedSize(tester);
    tester.widget<TerminalToolsPanel>(find.byType(TerminalToolsPanel))
        .onReconnect();
    await tester.pump(const Duration(milliseconds: 1));
    expect(old.closes, 1);
    expect(next.sizes, [expected]);
    await finish(tester);
  });

  testWidgets('pending resize cannot leak into a closed session generation', (
    tester,
  ) async {
    final old = _RecordingSession();
    final next = _RecordingSession();
    var starts = 0;
    final fixture = _Fixture(() => starts++ == 0 ? old : next);
    await prepare(tester, fixture);
    fixture.width = 1400;
    await fixture.pump(tester);
    tester.widget<TerminalToolsPanel>(find.byType(TerminalToolsPanel))
        .onReconnect();
    await tester.pump(const Duration(milliseconds: 1));
    expect(old.sizes, hasLength(1));
    expect(next.sizes, [fixture.expectedSize(tester)]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(old.sizes, hasLength(1));
    expect(next.sizes, hasLength(1));
    await finish(tester);
  });

  testWidgets('backgrounding cancels queued reflow and resume flushes latest', (
    tester,
  ) async {
    final session = _RecordingSession();
    final fixture = _Fixture(() => session);
    await prepare(tester, fixture);
    fixture.width = 1400;
    await fixture.pump(tester);
    await _lifecycle(tester, AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 100));
    expect(session.sizes, hasLength(1));
    await _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    expect(session.sizes, hasLength(2));
    expect(session.sizes.last, fixture.expectedSize(tester));
    await finish(tester);
  });

  testWidgets('disposing during a drag cancels the queued native resize', (
    tester,
  ) async {
    final session = _RecordingSession();
    final fixture = _Fixture(() => session);
    await prepare(tester, fixture);
    fixture.width = 1400;
    await fixture.pump(tester);
    await finish(tester);
    expect(session.closes, 1);
    expect(session.sizes, hasLength(1));
  });

  testWidgets('a disconnect snapshot cancels queued resize before it can fire', (
    tester,
  ) async {
    final session = _RecordingSession();
    final fixture = _Fixture(() => session);
    await prepare(tester, fixture);
    fixture.width = 1400;
    await fixture.pump(tester);
    session.disconnected = true;
    session.versionValue++;
    // The existing poll runs before the pending trailing resize. Once it
    // reports closure, no further reflow should be sent to that session.
    await tester.pump(const Duration(milliseconds: 61));
    expect(session.sizes, hasLength(1));
    await finish(tester);
  });

  testWidgets('missing native handle is visible, does not spin, and can retry', (
    tester,
  ) async {
    final old = _RecordingSession()..acceptsResize = false;
    final next = _RecordingSession();
    var starts = 0;
    final fixture = _Fixture(() => starts++ == 0 ? old : next);
    await prepare(tester, fixture);
    expect(
      find.text('xenterm_session_resize: unknown session handle'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(old.sizes, hasLength(1), reason: 'invalid handles are not retried');
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(old.closes, 1);
    expect(next.sizes, [fixture.expectedSize(tester)]);
    expect(
      find.text('xenterm_session_resize: unknown session handle'),
      findsNothing,
    );
    await finish(tester);
  });
}
