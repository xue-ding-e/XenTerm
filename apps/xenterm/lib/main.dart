import 'package:flutter/foundation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'data/hosts.dart';
import 'l10n/app_language.dart';
import 'shell/root_shell.dart';
import 'terminal/core_settings.dart';
import 'theme/app_theme.dart';
import 'theme/app_appearance.dart';
import 'theme/legacy_preferences.dart';
import 'theme/app_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fonts = AppFonts();
  await fonts.load();
  await windowManager.ensureInitialized();

  await windowManager.waitUntilReadyToShow(desktopWindowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(XenTermApp(fonts: fonts));
}

// AppKit owns the macOS titlebar and its traffic-light hit targets. Keeping
// Flutter out of the full-size content view lets the native window reserve the
// correct area, including after resize/full-screen transitions. Other desktop
// platforms keep the shell's custom frame, drag region and resize borders.
WindowOptions get desktopWindowOptions => WindowOptions(
  title: 'XenTerm',
  titleBarStyle: defaultTargetPlatform == TargetPlatform.macOS
      ? TitleBarStyle.normal
      : TitleBarStyle.hidden,
  windowButtonVisibility: true,
  minimumSize: const Size(940, 600),
  backgroundColor: Colors.transparent,
);

class XenTermApp extends StatefulWidget {
  final AppFonts? fonts;
  /// Overrides the hosts loader (widget tests use the sample fixture; the app
  /// loads the real sessions from the Rust core).
  final Future<List<Host>> Function()? hostsLoader;
  final CoreSettingsController? settings;
  const XenTermApp({
    super.key,
    this.fonts,
    this.hostsLoader,
    this.settings,
  });

  @override
  State<XenTermApp> createState() => _XenTermAppState();
}

class _XenTermAppState extends State<XenTermApp> with WidgetsBindingObserver {
  late final AppFonts _fonts = widget.fonts ?? AppFonts();
  late final CoreSettingsController _settings =
      widget.settings ?? CoreSettingsController();

  AppThemeMode get _themeMode => switch (_settings.settings.themePref) {
    'light' => AppThemeMode.light,
    'dark' => AppThemeMode.dark,
    _ => AppThemeMode.system,
  };
  bool get _lightTheme => switch (_themeMode) {
    AppThemeMode.light => true,
    AppThemeMode.dark => false,
    AppThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.light,
  };
  // Resolution is a platform adapter. Persist only the shared choice, never
  // today's resolved system locale/brightness.
  String get _language => AppLanguage.supported.containsKey(_settings.settings.language)
      ? _settings.settings.language
      : AppLanguage.resolveSystemLanguage(
          WidgetsBinding.instance.platformDispatcher.locales,
        );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fonts.bindSettings(_settings);
    _fonts.addListener(_changed);
    _settings.addListener(_changed);
    if (!_settings.loaded) _initialize();
  }

  Future<void> _initialize() async {
    await _settings.load();
    if (!mounted) return;
    // A preview is not an import. Do not overwrite either source, even when a
    // legacy preference differs from a core default of uncertain provenance.
    try {
      _settings.legacyPreferencePreview = await readLegacyAppearancePreferences();
      if (mounted) setState(() {});
    } catch (_) {
      // Optional old preference storage being unavailable does not invalidate
      // a successfully loaded shared-core snapshot.
    }
  }

  void _setLanguage(String code) => _settings.update({'language': code});
  void _setTheme(bool light) =>
      _setThemeMode(light ? AppThemeMode.light : AppThemeMode.dark);
  void _setThemeMode(AppThemeMode mode) =>
      _settings.update({'theme_pref': mode.name});

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (_settings.settings.language == 'system') setState(() {});
  }

  @override
  void didChangePlatformBrightness() {
    if (_themeMode == AppThemeMode.system) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.settings == null) {
      // The FFI wrapper runs in Isolate.run; a full profile refresh is not a
      // per-frame/per-second poll. It may involve disk/keyring work.
      _settings.load(clearError: false);
    }
  }

  void _changed() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fonts.removeListener(_changed);
    _settings.removeListener(_changed);
    if (widget.fonts == null) _fonts.dispose();
    if (widget.settings == null) _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadcnApp(
      title: 'XenTerm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: _lightTheme ? xtLightScheme() : xtDarkScheme(),
        typography: appTypography(_fonts.uiFamily),
        // The app's own radii (8/10/15) are applied at the call sites via
        // XtRadius; the multiplier only styles library internals.
        radius: 0.5,
      ),
      // Wrap the navigator too: popup menus and dialogs use the same scale.
      // Fixed per-control fontSize values are scaled at text layout time.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: AppTextScaler(
            MediaQuery.textScalerOf(context),
            _fonts.uiSize / 14,
          ),
        ),
        child: child!,
      ),
      home: !_settings.loaded
          ? Scaffold(child: Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_settings.error == null) const CircularProgressIndicator()
                else ...[
                  Text(AppLanguage.translate(_language, 'Could not load shared settings')),
                  const SizedBox(height: 12),
                  Text(_settings.error!),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    onPressed: _initialize,
                    child: Text(AppLanguage.translate(_language, 'Retry')),
                  ),
                ],
              ],
            )))
          : AppAppearance(
              themeMode: _themeMode,
              onThemeChanged: _setThemeMode,
              child: AppLanguage(
        code: _language,
        onChanged: _setLanguage,
        child: DefaultTextEditingShortcuts(
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontFamily: _fonts.uiFamily.isEmpty ? null : _fonts.uiFamily,
              // Applied once by AppTextScaler, not twice through inheritance.
              fontSize: 14,
            ),
            child: RootShell(
              lightTheme: _lightTheme,
              onThemeChanged: _setTheme,
              fonts: _fonts,
              settings: _settings,
              hostsLoader: widget.hostsLoader,
            ),
          ),
        ),
              ),
            ),
    );
  }
}
