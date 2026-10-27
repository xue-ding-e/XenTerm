import 'package:shadcn_flutter/shadcn_flutter.dart';

/// The saved choice is separate from the currently effective brightness.
/// System mode must remain system when the desktop switches light/dark.
enum AppThemeMode { system, light, dark }

class AppAppearance extends InheritedWidget {
  final AppThemeMode themeMode;
  final ValueChanged<AppThemeMode> onThemeChanged;

  const AppAppearance({
    super.key,
    required this.themeMode,
    required this.onThemeChanged,
    required super.child,
  });

  static AppAppearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppAppearance>();

  @override
  bool updateShouldNotify(AppAppearance oldWidget) =>
      themeMode != oldWidget.themeMode ||
      onThemeChanged != oldWidget.onThemeChanged;
}

/// Scale actual text layout, including explicit per-control font sizes.
/// Scaling Typography alone is cancelled by each copyWith(fontSize: ...).
/// Compose with accessibility scaling instead of replacing the system scaler.
/// Terminal cells use their own TextPainter and terminalSize, not this scope.
class AppTextScaler extends TextScaler {
  final TextScaler system;
  final double factor;

  const AppTextScaler(this.system, this.factor);

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is AppTextScaler && other.system == system && other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}

/// Apply the chosen face to both the library's default sans role and the
/// explicit weight styles used by XenTerm controls. Keep monospace/code roles
/// unchanged: an interface face must not silently change terminal geometry.
Typography appTypography(String uiFamily) {
  const base = Typography.geist();
  if (uiFamily.isEmpty) return base;
  return base.copyWith(
    sans: () => TextStyle(fontFamily: uiFamily),
    normal: () => base.normal.copyWith(fontFamily: uiFamily),
    medium: () => base.medium.copyWith(fontFamily: uiFamily),
    semiBold: () => base.semiBold.copyWith(fontFamily: uiFamily),
    bold: () => base.bold.copyWith(fontFamily: uiFamily),
  );
}
