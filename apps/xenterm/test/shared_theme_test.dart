import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xenterm_app/main.dart';
import 'package:xenterm_app/theme/app_appearance.dart';
import 'package:xenterm_app/theme/app_fonts.dart';

import 'support/shared_settings_fixture.dart';

Future<void> _mount(WidgetTester tester, SettingsFixture fixture) async {
  final fonts = AppFonts();
  final controller = fixture.controller();
  addTearDown(fonts.dispose);
  addTearDown(controller.dispose);
  await tester.pumpWidget(XenTermApp(
    fonts: fonts, settings: controller, hostsLoader: () async => [],
  ));
  await tester.pumpAndSettle();
}

Brightness _brightness(WidgetTester tester) =>
    tester.widget<ShadcnApp>(find.byType(ShadcnApp)).theme.colorScheme.brightness;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shared system theme tracks the desktop without persisting brightness', (tester) async {
    final fixture = SettingsFixture();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await _mount(tester, fixture);
    expect(_brightness(tester), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.dark);
    expect(fixture.values['theme_pref'], 'system');
    expect(fixture.calls, isEmpty);
  });

  testWidgets('manual theme wins, survives restart and can return to system', (tester) async {
    final fixture = SettingsFixture();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await _mount(tester, fixture);
    tester.widget<AppAppearance>(find.byType(AppAppearance)).onThemeChanged(AppThemeMode.dark);
    await tester.pumpAndSettle();
    expect(fixture.values['theme_pref'], 'dark');
    expect(_brightness(tester), Brightness.dark);
    await tester.pumpWidget(const SizedBox.shrink());
    await _mount(tester, fixture);
    expect(_brightness(tester), Brightness.dark);
    tester.widget<AppAppearance>(find.byType(AppAppearance)).onThemeChanged(AppThemeMode.system);
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('xenterm.theme.light'), isFalse);
    expect(prefs.containsKey('xenterm.theme.mode'), isFalse);
  });
}
