import 'dart:io';

import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xenterm_app/data/hosts.dart';
import 'package:xenterm_app/shell/title_bar.dart';

const _host = Host(id: 'test', label: 'Test session', address: 'example.invalid');
const _windowChannel = MethodChannel('window_manager');

Future<void> _pumpBar(WidgetTester tester, TitleBar bar) async {
  await tester.pumpWidget(
    ShadcnApp(home: Align(alignment: Alignment.topLeft, child: bar)),
  );
  await tester.pumpAndSettle();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  var maximized = false;

  setUp(() {
    calls.clear();
    maximized = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_windowChannel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'isMaximized') return maximized;
      if (call.method == 'isFullScreen') return false;
      if (call.method == 'maximize') maximized = true;
      if (call.method == 'unmaximize') maximized = false;
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_windowChannel, null);
  });

  testWidgets('macOS leaves window controls and gestures to its native bar', (
    tester,
  ) async {
    await _pumpBar(tester, const TitleBar());

    // This assertion also runs against the old TitleBar API: it fails because
    // the old widget draws a second set of controls over a full-size content view.
    expect(find.byIcon(LucideIcons.minus), findsNothing);
    expect(find.byIcon(LucideIcons.square), findsNothing);
    expect(find.byIcon(LucideIcons.x), findsNothing);
    expect(find.byType(DragToMoveArea), findsNothing);

    const blank = Offset(500, 25);
    await tester.tapAt(blank);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(blank);
    await tester.pumpAndSettle();
    await tester.dragFrom(blank, const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.only(foundation.TargetPlatform.macOS));

  for (final platform in [
    foundation.TargetPlatform.macOS,
    foundation.TargetPlatform.windows,
    foundation.TargetPlatform.linux,
  ]) {
    testWidgets('$platform tab actions do not drag or maximize the window', (
      tester,
    ) async {
      final actions = <String>[];
      await _pumpBar(
        tester,
        TitleBar(
          openHosts: const [_host],
          activeHostId: _host.id,
          onToggleSidebar: () => actions.add('sidebar'),
          onToggleSftp: () => actions.add('sftp'),
          onNewTab: () => actions.add('new'),
          onSelectHost: (id) => actions.add('select-$id'),
          onCloseHost: (id) => actions.add('close-$id'),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('toggle-sidebar')));
      // A single click must not wait for a background double-tap recognizer.
      expect(actions, ['sidebar']);
      await tester.tap(find.byKey(const ValueKey('sftp-tab')));
      await tester.tap(find.text(_host.label));
      await tester.tap(find.byKey(const ValueKey('tab-close-test')));
      await tester.tap(find.byIcon(LucideIcons.plus));
      expect(actions, ['sidebar', 'sftp', 'select-test', 'close-test', 'new']);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));
  }

  for (final platform in [foundation.TargetPlatform.windows, foundation.TargetPlatform.linux]) {
    testWidgets('$platform retains its custom window controls', (tester) async {
      await _pumpBar(tester, const TitleBar());
      expect(find.byType(DragToMoveArea), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.minus));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.square));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.x));
      await tester.pumpAndSettle();
      expect(calls, [
        'minimize',
        'isMaximized',
        'maximize',
        'isMaximized',
        'unmaximize',
        'close',
      ]);
    }, variant: TargetPlatformVariant.only(platform));

    testWidgets('$platform blank strip retains dragging and double-click', (
      tester,
    ) async {
      await _pumpBar(tester, const TitleBar());
      const blank = Offset(500, 25);
      await tester.dragFrom(blank, const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(calls, [if (Platform.isWindows) 'isFullScreen', 'startDragging']);
      calls.clear();

      await tester.tapAt(blank);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(blank);
      await tester.pumpAndSettle();
      expect(calls, ['isMaximized', 'maximize']);
    }, variant: TargetPlatformVariant.only(platform));
  }
}
