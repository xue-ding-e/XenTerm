// CI-only native GTK integration target. No injected hosts, sessions, bridge,
// settings controller, clipboard channel or UI callbacks replace production.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/main.dart' as app;
import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/l10n/app_language.dart';
import 'package:xenterm_app/screens/hosts/host_details_panel.dart';
import 'package:xenterm_app/shell/root_shell.dart';
import 'package:xenterm_app/screens/terminal/terminal_view.dart';
import 'package:xenterm_app/widgets/primitives.dart';

import 'native_desktop_steps.dart';

Finder key(String value) => find.byKey(ValueKey(value));

Future<void> waitFor(WidgetTester tester, bool Function() condition, String label) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 20)) {
      fail('Timed out waiting for $label');
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    final error = tester.takeException();
    if (error != null) throw error;
  }
}

Future<CoreSettings> settings(WidgetTester tester) async =>
    (await tester.runAsync(loadSettingsFromCore))!;

Future<Map<String, dynamic>> cliSettings(WidgetTester tester, List<String> arguments) async {
  final result = await tester.runAsync(() => Process.run(
    Platform.environment['XENTERM_UI_TEST_CLI']!,
    ['--data-dir', Platform.environment['XENTERM_DATA_DIR']!, 'cli', 'settings', ...arguments, '--json'],
  ));
  expect(result!.exitCode, 0, reason: 'The same-source console settings operation must succeed');
  return (jsonDecode(result.stdout as String) as Map).cast<String, dynamic>();
}

List<int> received(Directory runtime) {
  final file = File('${runtime.path}/fixture/received.jsonl');
  if (!file.existsSync()) return [];
  final output = <int>[];
  for (final line in file.readAsLinesSync()) {
    final hex = (jsonDecode(line) as Map)['hex'] as String;
    for (var i = 0; i < hex.length; i += 2) {
      output.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
  }
  return output;
}

Future<void> reveal(WidgetTester tester, NativeDesktopSteps steps,
    Finder target, Finder scrollArea, String label) async {
  for (var i = 0; i < 12 && target.hitTestable().evaluate().isEmpty; i++) {
    await steps.scroll(tester, '$label-wheel-$i', scrollArea, 3);
  }
  expect(target.hitTestable(), findsOneWidget, reason: label);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.shouldPropagateDevicePointerEvents = true;
  testWidgets('native isolated desktop flows with real OS input and Rust services', (tester) async {
    final steps = NativeDesktopSteps();
    final runtime = steps.runtime;
    final profile = Platform.environment['XENTERM_DATA_DIR']!;
    final home = Platform.environment['HOME']!;
    expect(profile, startsWith('${runtime.path}/'));
    expect(home, startsWith('${runtime.path}/'));
    expect(Directory(profile).existsSync(), isTrue);
    await app.main();
    await waitFor(tester, () => key('host-search').evaluate().isNotEmpty, 'real hosts loaded');
    final language = Platform.environment['XENTERM_UI_EXPECT_LANGUAGE']!;
    expect(binding.platformDispatcher.locales.first.languageCode, language);
    expect(AppLanguage.of(tester.element(key('host-search'))).code, language);
    expect((await settings(tester)).language, 'system');
    await steps.resize(tester, 'initial-viewport', const Size(1500, 1000));
    await steps.screenshot(tester, 'system-$language-boot');
    if (language == 'zh') {
      // Independent real zh_CN process, not a mocked PlatformDispatcher.
      await steps.click(tester, 'chinese-settings', find.text('设置').last);
      await waitFor(tester, () => key('settings-search').evaluate().isNotEmpty, 'Chinese settings');
      await steps.enterText(tester, 'english-alias-in-chinese', key('settings-search'), 'language');
      expect(find.text('界面语言').hitTestable(), findsWidgets);
      await steps.screenshot(tester, 'chinese-language-search');
      await steps.complete();
      return;
    }

    // Each navigation screen loads real empty-profile data, not a loader fake.
    const emptyPages = {
      'Keychain': 'No SSH keys yet', 'Tunnels': 'No forwarding rules',
      'Snippets': 'No snippets yet', 'Known Hosts': 'No known hosts yet',
      'Logs': 'No session logs yet',
    };
    for (final page in emptyPages.entries) {
      final checkpoint = page.key.toLowerCase().replaceAll(' ', '-');
      await steps.click(tester, 'nav-$checkpoint', find.text(page.key).first);
      await waitFor(tester, () => find.text(page.value).hitTestable().evaluate().isNotEmpty,
          'real ${page.key} data loaded');
      expect(find.textContaining('Could not load'), findsNothing);
      await steps.screenshot(tester, 'page-$checkpoint');
    }
    await steps.click(tester, 'settings-open', find.text('Settings').last);
    await waitFor(tester, () => key('settings-search').evaluate().isNotEmpty, 'settings loaded');
    for (final query in ['language', '语言']) {
      await steps.enterText(tester, query == 'language' ? 'search-en' : 'search-zh', key('settings-search'), query);
      expect(find.text('Interface language').hitTestable(), findsWidgets);
    }
    await steps.key(tester, 'search-keyboard-first', 'Down');
    await steps.key(tester, 'search-keyboard-select', 'Return');
    await waitFor(tester, () => key('setting-language').hitTestable().evaluate().isNotEmpty, 'search result focused control');
    await steps.click(tester, 'language-open', find.descendant(of: key('setting-language'), matching: find.text('Follow system')));
    await steps.click(tester, 'language-chinese', find.text('简体中文').last);
    await waitFor(tester, () => AppLanguage.of(tester.element(key('settings-search'))).code == 'zh', 'manual Chinese');
    expect((await settings(tester)).language, 'zh');
    await steps.screenshot(tester, 'manual-chinese');
    await steps.click(tester, 'language-open-again', find.descendant(of: key('setting-language'), matching: find.text('简体中文')));
    await steps.click(tester, 'language-english', find.text('English').last);
    await waitFor(tester, () => AppLanguage.of(tester.element(key('settings-search'))).code == 'en', 'manual English');

    Future<void> searchTarget(String query, String title, String checkpoint) async {
      await steps.enterText(tester, '$checkpoint-search', key('settings-search'), query);
      await steps.click(tester, '$checkpoint-result', find.text(title).hitTestable().first);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await searchTarget('terminal text size', 'Terminal text size', 'terminal-font');
    final beforeSize = (await settings(tester)).fontSize;
    await steps.click(tester, 'terminal-size-plus', key('terminal-plus'));
    await waitFor(tester, () => tester.widget<XtIconButton>(key('terminal-plus')).onPressed != null, 'font save completed');
    expect((await settings(tester)).fontSize, beforeSize + 1);
    await searchTarget('interface text size', 'Interface text size', 'interface-font');
    await steps.click(tester, 'interface-size-plus', key('interface-plus'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect((await settings(tester)).uiFontSize, 15);
    await steps.screenshot(tester, 'font-scopes');
    // An independent real CLI process updates exactly the same service/profile.
    // Refresh is explicit; this is not advertised as a file watcher.
    for (final size in [8, 32, 14]) {
      final before = await cliSettings(tester, ['get']);
      await cliSettings(tester, ['set', jsonEncode({'ui_font_size': size}),
        '--expected-revision', before['revision'] as String]);
      await steps.click(tester, 'shared-cli-refresh-$size', key('settings-refresh'));
      await waitFor(tester, () => tester.widget<RootShell>(find.byType(RootShell))
          .settings.settings.uiFontSize == size, 'CLI size observed after explicit refresh');
      await steps.screenshot(tester, 'shared-ui-size-$size');
    }
    await searchTarget('theme', 'Theme', 'theme');
    await steps.click(tester, 'theme-open', find.text('Follow system').last);
    await steps.click(tester, 'theme-dark', find.text('Dark').last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect((await settings(tester)).themePref, 'dark');
    await steps.click(tester, 'theme-open-system', find.text('Dark').last);
    await steps.click(tester, 'theme-system', find.text('Follow system').last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect((await settings(tester)).themePref, 'system');
    await searchTarget('credits', 'Developer & credits', 'credits');
    await steps.screenshot(tester, 'credits-links');
    // Do not open external websites in the native acceptance process; actual
    // verified link URLs and launch failures have dedicated widget tests.

    await steps.click(tester, 'home-open', find.text('Home').first);
    await waitFor(tester, () => key('host-search').evaluate().isNotEmpty, 'home');
    await steps.click(tester, 'new-host', find.text('New host').first);
    final drawer = find.byType(HostDetailsPanel);
    await waitFor(tester, () => drawer.evaluate().isNotEmpty, 'host editor');
    final connection = jsonDecode(File('${runtime.path}/fixture/connection.json').readAsStringSync()) as Map;
    expect(connection['host'], '127.0.0.1');
    await steps.enterText(tester, 'host-address', key('host-address'), '127.0.0.1');
    await steps.enterText(tester, 'host-label', key('label-field'), 'Native fixture');
    final port = find.byWidgetPredicate((widget) => widget is EditableText && widget.controller.text == '22');
    await steps.enterText(tester, 'host-port', port, '${connection['port']}');
    await reveal(tester, steps, key('host-username'), drawer, 'username');
    await steps.enterText(tester, 'host-user', key('host-username'), 'fixture');
    await reveal(tester, steps, key('host-password'), drawer, 'password');
    await steps.enterText(tester, 'host-password', key('host-password'), connection['password'] as String);
    final save = find.descendant(of: drawer, matching: find.byWidgetPredicate(
      (widget) => widget is XtIconButton && widget.icon == LucideIcons.check));
    await steps.click(tester, 'host-save', save);
    await waitFor(tester, () => drawer.evaluate().isEmpty && find.text('Native fixture').evaluate().isNotEmpty, 'persisted host');
    final hosts = (await tester.runAsync(loadHostsFromCore))!;
    expect(hosts.where((host) => host.label == 'Native fixture').length, 1);
    await steps.click(tester, 'host-connect', find.text('Native fixture').first);
    await waitFor(tester, () => find.text('Trust').hitTestable().evaluate().isNotEmpty, 'real loopback host-key prompt');
    await steps.screenshot(tester, 'host-key-review');
    await steps.click(tester, 'trust-loopback-key', find.text('Trust').last);
    final canvas = key('terminal-canvas');
    TerminalPainter painter() => tester.widget<CustomPaint>(canvas).painter! as TerminalPainter;
    await waitFor(tester, () => canvas.evaluate().isNotEmpty &&
      (painter().screen?['rows'] as List? ?? []).any((row) => '${row['text']}'.contains('ASCII 中')), 'real UTF-8 PTY output');
    expect(painter().fontSize, beforeSize + 1);
    await steps.screenshot(tester, 'terminal-real-unicode');
    final rows = painter().screen!['rows'] as List;
    final row = rows.indexWhere((row) => '${row['text']}'.contains('ASCII 中'));
    final cols = painter().screen!['cols'] as int;
    final origin = tester.getTopLeft(canvas);
    final cell = painter().cellWidth;
    final line = painter().lineHeight;
    await steps.drag(tester, 'unicode-cell-selection', origin + Offset(cell * .5, line * (row + .5)),
      origin + Offset(cell * (cols - .5), line * (row + .5)));
    expect(painter().selection?.text(painter().screen), 'ASCII 中🙂 e\u0301 selection');
    await steps.key(tester, 'selection-copy-ctrl-c', 'ctrl+c');
    await steps.expectClipboard(tester, 'selection-os-clipboard', 'ASCII 中🙂 e\u0301 selection');
    expect(received(runtime), isEmpty, reason: 'selection Ctrl+C must not send interrupt');
    await steps.click(tester, 'clear-selection-focus', canvas);
    await steps.key(tester, 'no-selection-interrupt', 'ctrl+c');
    await waitFor(tester, () => received(runtime).isNotEmpty, 'interrupt byte');
    expect(received(runtime), [3]);

    final beforePaste = received(runtime);
    await steps.setClipboard(tester, 'multiline-clipboard', 'line-one\nline-two');
    await steps.key(tester, 'multiline-paste', 'ctrl+v');
    await waitFor(tester, () => key('terminal-paste-review').evaluate().isNotEmpty, 'safe paste review');
    await steps.click(tester, 'paste-cancel', key('terminal-paste-cancel'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect(received(runtime), beforePaste);
    await steps.key(tester, 'multiline-review-again', 'ctrl+shift+v');
    await waitFor(tester, () => key('terminal-paste-confirm').evaluate().isNotEmpty, 'second paste review');
    await steps.click(tester, 'paste-confirm', key('terminal-paste-confirm'));
    final expected = [...beforePaste, ...utf8.encode('\x1b[200~line-one\rline-two\x1b[201~')];
    await waitFor(tester, () => received(runtime).length >= expected.length, 'bracketed paste bytes');
    expect(received(runtime), expected);
    final searchEditor = find.descendant(of: key('terminal-search'), matching: find.byType(EditableText));
    final oldQuery = tester.widget<EditableText>(searchEditor).controller.text;
    await steps.click(tester, 'search-field-focus', key('terminal-search'));
    await steps.setClipboard(tester, 'search-field-clipboard', 'query-only');
    await steps.key(tester, 'search-field-paste', 'ctrl+v');
    expect(tester.widget<EditableText>(searchEditor).controller.text, 'query-only');
    await steps.key(tester, 'search-field-undo', 'ctrl+z');
    expect(tester.widget<EditableText>(searchEditor).controller.text, oldQuery);
    expect(received(runtime), expected, reason: 'text fields must not send terminal bytes');
    await steps.resize(tester, 'narrow-native', const Size(940, 600));
    await steps.resize(tester, 'wide-native', const Size(1500, 1000));
    await tester.pump(const Duration(milliseconds: 200));
    await steps.screenshot(tester, 'resized-terminal');

    await steps.click(tester, 'sftp-open', key('sftp-tab'));
    await waitFor(tester, () => key('sftp-/fixture.txt').evaluate().isNotEmpty, 'real SFTP directory');
    await steps.screenshot(tester, 'sftp-real-list');
    final newFolder = find.byWidgetPredicate((widget) => widget is XtIconButton && widget.tooltip == 'New folder');
    await steps.click(tester, 'sftp-new-folder', newFolder);
    await steps.enterText(tester, 'sftp-folder-name', key('sftp-new-folder-name'), 'ui-folder');
    await steps.click(tester, 'sftp-create-cancel', find.text('Cancel').last);
    expect(Directory('${runtime.path}/fixture/remote-files/ui-folder').existsSync(), isFalse);
    await steps.click(tester, 'sftp-new-folder-again', newFolder);
    await steps.enterText(tester, 'sftp-folder-name-again', key('sftp-new-folder-name'), 'ui-folder');
    await steps.click(tester, 'sftp-create-confirm', find.text('Create').last);
    await waitFor(tester, () => key('sftp-/ui-folder').evaluate().isNotEmpty, 'new SFTP directory listed');
    expect(Directory('${runtime.path}/fixture/remote-files/ui-folder').existsSync(), isTrue);
    await steps.click(tester, 'sftp-select-folder', key('sftp-/ui-folder'));
    final deleteFolder = find.byWidgetPredicate((widget) => widget is XtIconButton && widget.tooltip == 'Delete ui-folder');
    await steps.click(tester, 'sftp-delete-review', deleteFolder);
    await steps.click(tester, 'sftp-delete-cancel', find.text('Cancel').last);
    expect(Directory('${runtime.path}/fixture/remote-files/ui-folder').existsSync(), isTrue);
    await steps.click(tester, 'sftp-delete-review-again', deleteFolder);
    await steps.click(tester, 'sftp-delete-confirm', find.text('Delete').last);
    await waitFor(tester, () => !Directory('${runtime.path}/fixture/remote-files/ui-folder').existsSync(), 'synthetic directory deleted');
    await steps.screenshot(tester, 'sftp-after-confirmed-delete');

    await steps.click(tester, 'show-sidebar', key('toggle-sidebar'));
    await steps.click(tester, 'known-hosts-after-trust', find.text('Known Hosts').first);
    final identity = '127.0.0.1:${connection['port']}';
    await waitFor(tester, () => key('known-host-$identity').evaluate().isNotEmpty, 'remembered real loopback key');
    await steps.click(tester, 'known-host-copy', key('known-host-copy-address-$identity'));
    await steps.expectClipboard(tester, 'known-host-address-clipboard', identity);
    await steps.click(tester, 'known-host-forget-review', key('known-host-remove-$identity'));
    await steps.click(tester, 'known-host-forget-cancel', key('known-host-cancel-$identity'));
    expect((await tester.runAsync(loadKnownHostsFromCore))!.any((host) => host.id == identity), isTrue);
    await steps.screenshot(tester, 'known-hosts-real-layout');
    expect(tester.takeException(), isNull);
    await steps.complete();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
