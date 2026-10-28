import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xenterm_app/distribution.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/theme/legacy_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('independent flavor does not read or rewrite upstream font metadata', () async {
    final root = await Directory.systemTemp.createTemp('xt-font-flavor-');
    addTearDown(() => root.delete(recursive: true));
    final original = jsonEncode({'imported': <dynamic>[], 'uiSize': 17});
    SharedPreferences.setMockInitialValues({
      'xenterm.fonts.v1': original,
      'xenterm.language': 'zh',
    });
    final fonts = AppFonts(supportDirectory: () async => root);
    addTearDown(fonts.dispose);
    await fonts.load();
    final preview = await readLegacyAppearancePreferences();
    if (isolatedFlutterRelease) {
      expect(preview, isEmpty);
      expect(await Directory('${root.path}/xenterm-flutter-next').exists(), isFalse);
    } else {
      expect(preview['language'], 'zh');
      expect(preview['ui_font_size'], 17);
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('xenterm.fonts.v1'), original);
    expect(prefs.getString('xenterm.language'), 'zh');
  });
}
