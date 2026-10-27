import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/l10n/app_language.dart';
import 'package:xenterm_app/screens/settings/settings_screen.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/terminal/core_settings.dart';
import 'package:xenterm_app/theme/app_theme.dart';

Future<AppFonts> _mount(WidgetTester tester, {String locale = 'en'}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(940, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fonts = AppFonts();
  final settings = CoreSettingsController()
    ..settings = const CoreSettings()
    ..loaded = true;
  addTearDown(fonts.dispose);
  addTearDown(settings.dispose);
  await tester.pumpWidget(ShadcnApp(
    theme: ThemeData(colorScheme: xtDarkScheme()),
    home: AppLanguage(
      code: locale,
      onChanged: (_) {},
      child: Scaffold(child: SettingsScreen(
        lightTheme: false,
        onThemeChanged: (_) {},
        fonts: fonts,
        settings: settings,
      )),
    ),
  ));
  await tester.pumpAndSettle();
  return fonts;
}

void main() {
  // This regression uses the old public SettingsScreen API. On the base it
  // fails because there is no search widget, not because a new import is absent.
  for (final locale in ['en', 'zh']) {
    for (final query in ['language', '语言', 'LANGUAGE']) {
      testWidgets('$locale search "$query" locates the language control', (tester) async {
        await _mount(tester, locale: locale);
        final search = find.byKey(const ValueKey('settings-search'));
        expect(search, findsOneWidget);
        await tester.enterText(search, query);
        await tester.pumpAndSettle();
        final label = AppLanguage.translate(locale, 'Interface language');
        expect(find.text(label), findsOneWidget);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        final control = find.byKey(const ValueKey('setting-language'));
        expect(control.hitTestable(), findsOneWidget);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'setting-language');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('clear, Escape and no-match state keep settings usable', (tester) async {
    await _mount(tester);
    final search = find.byKey(const ValueKey('settings-search'));
    await tester.enterText(search, 'no-such-setting-92881');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsNothing);
    expect(find.byKey(const ValueKey('setting-language')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'settings-search');
    await tester.enterText(search, 'font');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Search results'), findsNothing);
  });

  testWidgets('keyboard search opens an offscreen control and scrolls to it', (tester) async {
    await _mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'settings-search');
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'interface text size');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final plus = find.byKey(const ValueKey('interface-plus'));
    expect(plus.hitTestable(), findsOneWidget);
    expect(tester.getRect(plus).bottom, lessThanOrEqualTo(600));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'setting-interface-size');
  });

  testWidgets('standalone Settings refreshes its font value immediately', (tester) async {
    final fonts = await _mount(tester);
    final plus = find.byKey(const ValueKey('terminal-plus'));
    await tester.ensureVisible(plus);
    await tester.pumpAndSettle();
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(fonts.terminalSize, 16);
    expect(fonts.uiSize, 14);
    expect(find.text('16'), findsOneWidget);
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(fonts.terminalSize, 17, reason: 'the callback must not retain the old value');
    expect(find.text('17'), findsOneWidget);
  });
}
