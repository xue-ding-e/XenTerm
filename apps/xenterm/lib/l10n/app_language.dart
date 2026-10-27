import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'zh_common.dart';
import 'zh_hosts.dart';
import 'zh_screens.dart';
import 'zh_terminal.dart';

/// UI language lives above the shell so every page can read the same choice.
///
/// The shared Rust settings service persists `system`, `en` or `zh`; the
/// app root resolves `system` through the platform locale list. Legacy Flutter
/// preferences remain available only as an explicit import preview. Translations are literal maps
/// split by area (one file per screen group) so screens can be translated
/// independently; the English source string is the key and also the fallback.
///
/// Strings with runtime values use `{placeholders}`: pass the values in the
/// optional [args] map of [tr] and keep the same placeholders in the
/// translation. Plurals are modelled by choosing a different source string
/// (`'1 match'` vs `'{count} matches'`) at the call site.
class AppLanguage extends InheritedWidget {
  static const supported = <String, String>{'en': 'English', 'zh': '简体中文'};

  /// Picks the first supported language in the system's preference order.
  /// Regional/script variants share our existing language catalogue (for
  /// example, `zh-CN` and `zh-Hans` both use Simplified Chinese).
  static String resolveSystemLanguage(Iterable<Locale> locales) {
    for (final locale in locales) {
      final code = locale.languageCode;
      if (supported.containsKey(code)) return code;
    }
    return 'en';
  }

  final String code;
  final ValueChanged<String> onChanged;

  const AppLanguage({
    super.key,
    required this.code,
    required this.onChanged,
    required super.child,
  });

  static AppLanguage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLanguage>();

  static AppLanguage of(BuildContext context) => maybeOf(context)!;

  /// Translates [english] for the language above [context] and substitutes
  /// `{name}` placeholders from [args]. Falls back to the English source when no
  /// [AppLanguage] is mounted (unit tests that pump a single panel) or the key
  /// has no translation yet.
  static String tr(
    BuildContext context,
    String english, [
    Map<String, Object?>? args,
  ]) {
    final translated = maybeOf(context)?.text(english) ?? english;
    return _interpolate(translated, args);
  }

  /// Translation without a [BuildContext] (startup code, tests).
  static String translate(
    String code,
    String english, [
    Map<String, Object?>? args,
  ]) {
    final translated = _translations[code]?[english] ?? english;
    return _interpolate(translated, args);
  }

  static String _interpolate(String text, Map<String, Object?>? args) {
    if (args == null || args.isEmpty) return text;
    var result = text;
    args.forEach((key, value) {
      result = result.replaceAll('{$key}', '${value ?? ''}');
    });
    return result;
  }

  /// Display name for a supported code (`en` → `English`).
  static String? nameOf(String code) => supported[code];

  String text(String english) => _translations[code]?[english] ?? english;

  @override
  bool updateShouldNotify(AppLanguage oldWidget) =>
      code != oldWidget.code || onChanged != oldWidget.onChanged;
}

const _translations = <String, Map<String, String>>{
  'zh': <String, String>{
    ...zhCommon,
    ...zhHosts,
    ...zhScreens,
    ...zhTerminal,
  },
};
