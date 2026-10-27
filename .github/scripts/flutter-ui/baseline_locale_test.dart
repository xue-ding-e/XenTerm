// Identical public API on the original baseline: failure must be the zh/en
// assertion, not a new symbol, compiler error, or zero selected tests.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xenterm_app/main.dart';
import 'package:xenterm_app/l10n/app_language.dart';
import 'package:xenterm_app/terminal/core_settings.dart';
import 'package:xenterm_app/theme/app_fonts.dart';

void main() {
  testWidgets('unconfigured Chinese system selects Chinese', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.localesTestValue = [const Locale('zh', 'CN')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final fonts = AppFonts();
    final settings = CoreSettingsController()..loaded = true;
    addTearDown(fonts.dispose);
    addTearDown(settings.dispose);
    await tester.pumpWidget(XenTermApp(fonts: fonts, settings: settings, hostsLoader: () async => []));
    await tester.pumpAndSettle();
    expect(tester.widget<AppLanguage>(find.byType(AppLanguage)).code, 'zh');
  });
}
