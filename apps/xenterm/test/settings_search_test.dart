import 'package:flutter_test/flutter_test.dart';
import 'package:xenterm_app/screens/settings/settings_search.dart';
import 'package:xenterm_app/theme/app_appearance.dart';
import 'package:flutter/widgets.dart';

void main() {
  test('search indexes both locales, mixed tokens and stable unique IDs', () {
    expect(settingsSearchEntries.map((entry) => entry.id).toSet().length,
        settingsSearchEntries.length);
    for (final locale in ['en', 'zh']) {
      for (final query in ['language', ' LANGUAGE ', '语言', '界面语言']) {
        expect(searchSettings(query, locale).map((entry) => entry.id), ['language']);
      }
      expect(searchSettings('font size', locale).map((entry) => entry.id),
          containsAll(['terminal-size', 'interface-size']));
      expect(searchSettings('跟随系统', locale).map((entry) => entry.id), ['theme']);
      expect(searchSettings('does-not-exist', locale), isEmpty);
      expect(searchSettings(' ', locale), isEmpty);
    }
  });

  test('UI face is applied to actual label styles without changing mono', () {
    final selected = appTypography('fixture-ui-family');
    expect(selected.sans.fontFamily, 'fixture-ui-family');
    expect(selected.normal.fontFamily, 'fixture-ui-family');
    expect(selected.medium.fontFamily, 'fixture-ui-family');
    expect(selected.bold.fontFamily, 'fixture-ui-family');
    expect(selected.mono, appTypography('').mono);
  });

  test('UI font factor composes with accessibility scaling exactly once', () {
    const scaler = AppTextScaler(TextScaler.linear(1.5), 20 / 14);
    expect(scaler.scale(14), closeTo(30, 0.001));
    expect(scaler, const AppTextScaler(TextScaler.linear(1.5), 20 / 14));
  });
}
