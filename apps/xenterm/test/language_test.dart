import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xenterm_app/l10n/app_language.dart';
import 'package:xenterm_app/main.dart';
import 'support/shared_settings_fixture.dart';
import 'package:xenterm_app/theme/app_fonts.dart';

const _languageKey = 'xenterm.language';
late SettingsFixture fixture;

Future<void> _pumpApp(WidgetTester tester) async {
  final fonts = AppFonts();
  final settings = fixture.controller();
  addTearDown(fonts.dispose);
  addTearDown(settings.dispose);
  await tester.pumpWidget(
    XenTermApp(
      fonts: fonts,
      settings: settings,
      hostsLoader: () async => [],
    ),
  );
  await tester.pumpAndSettle();
}

AppLanguage _language(WidgetTester tester) =>
    tester.widget<AppLanguage>(find.byType(AppLanguage));

void _setLocales(WidgetTester tester, List<Locale> locales) {
  tester.platformDispatcher.localesTestValue = locales;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fixture = SettingsFixture();
  });

  // Locale resolution remains a Flutter adapter; explicit choices and restart
  // state now come from the shared-service snapshot, not private preferences.
  const systemCases = <String, (List<Locale>, String)>{
    'zh-CN': ([Locale('zh', 'CN')], 'zh'),
    'zh-Hans': (
      [Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')],
      'zh',
    ),
    'English': ([Locale('en', 'US')], 'en'),
    'unsupported language': ([Locale('fr', 'FR')], 'en'),
    'empty locale list': ([], 'en'),
    'first supported preference': ([Locale('fr'), Locale('zh', 'CN')], 'zh'),
    'English preferred before Chinese': ([Locale('en'), Locale('zh')], 'en'),
  };
  for (final entry in systemCases.entries) {
    testWidgets('without a saved choice follows ${entry.key}', (tester) async {
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      _setLocales(tester, entry.value.$1);
      await _pumpApp(tester);

      expect(_language(tester).code, entry.value.$2);
      expect(
        find.text(entry.value.$2 == 'zh' ? '首页' : 'Home'),
        findsWidgets,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(_languageKey), isFalse);
    });
  }

  for (final code in ['en', 'zh']) {
    testWidgets('saved $code takes priority over the system', (tester) async {
      fixture.values['language'] = code;
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      _setLocales(tester, [Locale(code == 'en' ? 'zh' : 'en')]);
      await _pumpApp(tester);
      expect(_language(tester).code, code);

      _setLocales(tester, [const Locale('fr')]);
      await tester.pumpAndSettle();
      expect(_language(tester).code, code);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(_languageKey), isFalse);
      expect(fixture.values['language'], code);
    });
  }

  testWidgets('an unsupported saved value still follows the system', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({_languageKey: 'obsolete'});
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    _setLocales(tester, [const Locale('zh', 'CN')]);
    await _pumpApp(tester);
    expect(_language(tester).code, 'zh');

    _setLocales(tester, [const Locale('en')]);
    await tester.pumpAndSettle();
    expect(_language(tester).code, 'en');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_languageKey), 'obsolete');
  });

  testWidgets('automatic language tracks system changes without saving them', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    _setLocales(tester, [const Locale('en')]);
    await _pumpApp(tester);
    expect(_language(tester).code, 'en');

    _setLocales(tester, [
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    ]);
    await tester.pumpAndSettle();
    expect(_language(tester).code, 'zh');
    expect(find.text('首页'), findsWidgets);

    _setLocales(tester, [const Locale('fr')]);
    await tester.pumpAndSettle();
    expect(_language(tester).code, 'en');
    expect(find.text('Home'), findsWidgets);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(_languageKey), isFalse);
  });

  testWidgets('a manual choice survives system changes and app restart', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    _setLocales(tester, [const Locale('zh', 'CN')]);
    await _pumpApp(tester);
    expect(_language(tester).code, 'zh');

    _language(tester).onChanged('en');
    await tester.pumpAndSettle();
    expect(_language(tester).code, 'en');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(_languageKey), isFalse);
    expect(fixture.values['language'], 'en');

    _setLocales(tester, [const Locale('zh')]);
    await tester.pumpAndSettle();
    expect(_language(tester).code, 'en');
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpApp(tester);
    expect(_language(tester).code, 'en');
  });

  testWidgets('choosing the current automatic language makes it explicit', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    _setLocales(tester, [const Locale('en')]);
    await _pumpApp(tester);
    _language(tester).onChanged('en');
    await tester.pumpAndSettle();

    _setLocales(tester, [const Locale('zh')]);
    await tester.pumpAndSettle();
    expect(_language(tester).code, 'en');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(_languageKey), isFalse);
    expect(fixture.values['language'], 'en');
  });

  testWidgets('an unsupported manual value does not disable automatic mode', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    _setLocales(tester, [const Locale('en')]);
    await _pumpApp(tester);
    fixture.rejectNext = 'invalid language';
    _language(tester).onChanged('invalid');
    await tester.pumpAndSettle();

    _setLocales(tester, [const Locale('zh')]);
    await tester.pumpAndSettle();
    expect(_language(tester).code, 'zh');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(_languageKey), isFalse);
  });

  testWidgets('unmounting removes the system locale observer', (tester) async {
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    _setLocales(tester, [const Locale('en')]);
    await _pumpApp(tester);
    await tester.pumpWidget(const SizedBox.shrink());

    _setLocales(tester, [const Locale('zh')]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
