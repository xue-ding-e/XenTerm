import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/l10n/app_language.dart';
import 'package:xenterm_app/screens/known_hosts/known_hosts_screen.dart';
import 'package:xenterm_app/theme/app_theme.dart';
import 'package:xenterm_app/widgets/primitives.dart';

const _host = KnownHost(
  id: 'example.invalid:2222',
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:synthetic-test-fingerprint',
);

Widget _app(Widget child, {double width = 760, double height = 560}) => ShadcnApp(
  theme: ThemeData(colorScheme: xtDarkScheme()),
  home: Scaffold(
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, height: height, child: child),
    ),
  ),
);

Finder _action(String name, [String id = 'example.invalid:2222']) =>
    find.byKey(ValueKey('known-host-$name-$id'));

Finder _button(Finder action) =>
    find.descendant(of: action, matching: find.byType(XtActionButton));

void main() {
  testWidgets('many remembered keys scroll without a render overflow', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    final hosts = List.generate(
      100,
      (i) => KnownHost(
        id: 'server-$i.example.invalid:22',
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:synthetic-$i',
      ),
    );
    await tester.pumpWidget(
      _app(KnownHostsScreen(loadHosts: () async => hosts)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final list = find.byKey(const ValueKey('known-host-list'));
    expect(list, findsOneWidget);
    // A card's empty center need not participate in hit testing. Prove its
    // real final-row action is visible and usable after scrolling instead.
    final last = _button(_action('copy-address', hosts.last.id));
    await tester.scrollUntilVisible(
      last,
      300,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
      maxScrolls: 100,
    );
    expect(last.hitTestable(), findsOneWidget);
    await tester.tap(last);
    await tester.pump();
    expect(copied, [hosts.last.id]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow cards copy full address and fingerprint, never ellipsis', (
    tester,
  ) async {
    final host = KnownHost(
      id: '${List.filled(20, 'long-label').join('-')}.invalid:2222',
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:${List.filled(12, 'synthetic').join()}',
    );
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      _app(KnownHostsScreen(loadHosts: () async => [host]), width: 320),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(_action('copy-address', host.id));
    await tester.pumpAndSettle();
    await tester.tap(_action('copy-fingerprint', host.id));
    await tester.pumpAndSettle();
    expect(copied, [host.id, host.fingerprint]);
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unreadable fingerprint cannot copy a misleading placeholder', (
    tester,
  ) async {
    const host = KnownHost(id: 'unreadable.invalid:22', keyType: '', fingerprint: '');
    await tester.pumpWidget(
      _app(KnownHostsScreen(loadHosts: () async => const [host])),
    );
    await tester.pumpAndSettle();
    expect(find.text('unreadable key entry'), findsOneWidget);
    expect(
      tester.widget<XtActionButton>(_button(_action('copy-fingerprint', host.id))).onPressed,
      isNull,
    );
  });

  testWidgets('forget requires confirmation and cancel performs no write', (
    tester,
  ) async {
    var deletes = 0;
    await tester.pumpWidget(
      _app(
        KnownHostsScreen(
          loadHosts: () async => const [_host],
          deleteHost: (_) async {
            deletes++;
            return const CoreWriteResult(ok: true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The action is present and usable without first hovering the card.
    expect(_action('remove').hitTestable(), findsOneWidget);
    await tester.tap(_action('remove'));
    await tester.pumpAndSettle();
    expect(deletes, 0);
    expect(_action('confirmation'), findsOneWidget);
    expect(find.textContaining('Verify the server key again'), findsOneWidget);
    await tester.tap(_action('cancel'));
    await tester.pumpAndSettle();
    expect(deletes, 0);
    expect(_action('confirmation'), findsNothing);
    expect(find.text(_host.id), findsOneWidget);
  });

  testWidgets('pending deletion is single-flight and failure keeps the entry', (
    tester,
  ) async {
    final pending = Completer<CoreWriteResult>();
    var deletes = 0;
    var loads = 0;
    await tester.pumpWidget(
      _app(
        KnownHostsScreen(
          loadHosts: () async {
            loads++;
            return const [_host];
          },
          deleteHost: (_) {
            deletes++;
            return pending.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_action('remove'));
    await tester.pumpAndSettle();
    // Invoke twice before rebuilding the disabled button.
    await tester.tap(_action('confirm'));
    await tester.tap(_action('confirm'));
    await tester.pump();
    expect(deletes, 1);
    expect(tester.widget<XtActionButton>(_button(_action('cancel'))).onPressed, isNull);
    expect(
      tester.widget<XtActionButton>(
        _button(find.byKey(const ValueKey('known-host-refresh'))),
      ).onPressed,
      isNull,
    );
    pending.complete(const CoreWriteResult(ok: false, error: 'Synthetic write failure'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.text('Synthetic write failure'), findsOneWidget);
    expect(find.text(_host.id), findsOneWidget);
    expect(tester.widget<XtActionButton>(_button(_action('confirm'))).onPressed, isNotNull);
  });

  testWidgets('delete exceptions preserve confirmation and allow cancellation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        KnownHostsScreen(
          loadHosts: () async => const [_host],
          deleteHost: (_) async => throw StateError('synthetic failure'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_action('remove'));
    await tester.pumpAndSettle();
    await tester.tap(_action('confirm'));
    await tester.pumpAndSettle();
    expect(_action('confirmation'), findsOneWidget);
    expect(find.textContaining('synthetic failure'), findsOneWidget);
    await tester.tap(_action('cancel'));
    await tester.pumpAndSettle();
    expect(find.text(_host.id), findsOneWidget);
  });

  testWidgets('search filters address, algorithm and fingerprint with a count', (
    tester,
  ) async {
    const other = KnownHost(
      id: 'other.invalid:22',
      keyType: 'ssh-rsa',
      fingerprint: 'SHA256:other-fingerprint',
    );
    await tester.pumpWidget(
      _app(KnownHostsScreen(loadHosts: () async => const [_host, other])),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('known-host-search'));
    for (final query in ['EXAMPLE.INVALID', 'ED25519', 'SYNTHETIC-TEST']) {
      await tester.enterText(field, query);
      await tester.pumpAndSettle();
      expect(find.text(_host.id), findsOneWidget);
      expect(find.text(other.id), findsNothing);
      expect(find.text('1 of 2 known hosts'), findsOneWidget);
    }
    await tester.enterText(field, 'no-match');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('0 of 2 known hosts'), findsOneWidget);
  });

  testWidgets('same-frame refresh is single-flight and cannot publish stale responses', (
    tester,
  ) async {
    final pending = Completer<List<KnownHost>>();
    var loads = 0;
    await tester.pumpWidget(
      _app(KnownHostsScreen(loadHosts: () {
        loads++;
        return loads == 1 ? Future.value(const [_host]) : pending.future;
      })),
    );
    await tester.pumpAndSettle();
    final refresh = tester.widget<XtActionButton>(
      _button(find.byKey(const ValueKey('known-host-refresh'))),
    ).onPressed!;
    refresh();
    refresh();
    expect(loads, 2);
    await tester.pump();
    expect(tester.widget<XtActionButton>(
      _button(find.byKey(const ValueKey('known-host-refresh'))),
    ).onPressed, isNull);
    pending.complete(const []);
    await tester.pumpAndSettle();
    expect(find.text(_host.id), findsNothing);
    expect(find.text('No known hosts yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('load errors are retryable and not reported as an empty store', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      _app(
        KnownHostsScreen(loadHosts: () async {
          if (++loads == 1) throw StateError('synthetic load failure');
          return const [_host];
        }),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic load failure'), findsOneWidget);
    expect(find.text('No known hosts yet'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('known-host-refresh')));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.text(_host.id), findsOneWidget);
    expect(find.byKey(const ValueKey('known-host-error')), findsNothing);
  });

  testWidgets('Tab reaches Forget; Enter and Space operate confirmation safely', (
    tester,
  ) async {
    var deletes = 0;
    await tester.pumpWidget(
      _app(
        KnownHostsScreen(
          loadHosts: () async => const [_host],
          deleteHost: (_) async {
            deletes++;
            return const CoreWriteResult(ok: true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = _button(_action('remove'));
    final focus = Focus.of(tester.element(button));
    for (var i = 0; i < 12 && !focus.hasFocus; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_action('confirmation'), findsOneWidget);
    expect(deletes, 0);
    Focus.of(tester.element(_button(_action('cancel')))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_action('confirmation'), findsNothing);
    expect(deletes, 0);
  });

  testWidgets('new known-host actions and warning have Chinese translations', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AppLanguage(
          code: 'zh',
          onChanged: (_) {},
          child: KnownHostsScreen(loadHosts: () async => const [_host]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('复制地址'), findsOneWidget);
    expect(find.text('复制指纹'), findsOneWidget);
    expect(find.text('显示 1 / 1 条已知主机'), findsOneWidget);
    await tester.tap(_action('remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请重新核验服务器密钥'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });
}
