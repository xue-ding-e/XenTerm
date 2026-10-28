import 'dart:convert';

import '../distribution.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// Read-only migration preview. Raw key presence in an old core settings row
/// cannot prove user intent, so neither defaults nor SharedPreferences silently
/// win. The user selects fields and the normal shared service validates them.
/// Keep every source key intact, including after a successful explicit import.
Future<Map<String, dynamic>> readLegacyAppearancePreferences() async {
  if (isolatedFlutterRelease) return const <String, dynamic>{};
  final prefs = await SharedPreferences.getInstance();
  final values = <String, dynamic>{};
  final language = prefs.getString('xenterm.language');
  if (language != null) values['language'] = language;
  final light = prefs.getBool('xenterm.theme.light');
  if (light != null) values['theme_pref'] = light ? 'light' : 'dark';
  final raw = prefs.getString('xenterm.fonts.v1');
  if (raw != null) {
    try {
      final fonts = jsonDecode(raw) as Map<String, dynamic>;
      for (final (old, key) in [
        ('uiFamily', 'ui_font_family'), ('terminalFamily', 'font_family'),
        ('uiSize', 'ui_font_size'), ('terminalSize', 'font_size'),
      ]) {
        if (!fonts.containsKey(old)) continue;
        final value = fonts[old];
        // JSON may encode a legacy whole-number size as 14.0. Preserve its
        // value as an integer for the typed protocol, without clamping it.
        values[key] = value is num && value.isFinite && value == value.roundToDouble()
            ? value.toInt() : value;
      }
    } on FormatException {
      // Keep an unreadable original untouched rather than inventing defaults.
    } on TypeError {
      // A malformed legacy blob is not a settings write.
    }
  }
  return Map<String, dynamic>.unmodifiable(values);
}
