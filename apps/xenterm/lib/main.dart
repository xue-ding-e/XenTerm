import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import 'data/hosts.dart';
import 'l10n/app_language.dart';
import 'shell/root_shell.dart';
import 'shell/window_activity.dart';
import 'terminal/core_settings.dart';
import 'theme/app_theme.dart';
import 'theme/app_appearance.dart';
import 'theme/legacy_preferences.dart';
import 'theme/app_fonts.dart';

/// Opt-in frame-timing probe for smoothness work. Build with
/// --dart-define=XENTERM_FRAME_STATS=true --profile; every 60 frames a
/// FRAMESTATS ... line goes to stdout and frames over 32ms are logged
/// individually, so a scripted UI run can be diffed before/after a change.
const bool _frameStatsEnabled = bool.fromEnvironment('XENTERM_FRAME_STATS');

void _installFrameStats() {
  final started = DateTime.now();
  final pending = <FrameTiming>[];
  String pct(List<double> sorted, double q) {
    if (sorted.isEmpty) return '0.0';
    final index = ((sorted.length - 1) * q).round();
    return sorted[index].toStringAsFixed(1);
  }

  void flush() {
    if (pending.isEmpty) return;
    final builds = [
      for (final frame in pending) frame.buildDuration.inMicroseconds / 1000.0,
    ]..sort();
    final rasters = [
      for (final frame in pending) frame.rasterDuration.inMicroseconds / 1000.0,
    ]..sort();
    final totals = <double>[
      for (var i = 0; i < pending.length; i++) builds[i] + rasters[i],
    ];
    final dropped = totals.where((total) => total > 16.7).length;
    final slow = totals.where((total) => total > 32).length;
    // ignore: avoid_print
    print(
      'FRAMESTATS t=${DateTime.now().difference(started).inMilliseconds} '
      'n=${pending.length} build_p50=${pct(builds, 0.5)} '
      'build_p90=${pct(builds, 0.9)} build_max=${builds.last.toStringAsFixed(1)} '
      'raster_p50=${pct(rasters, 0.5)} raster_p90=${pct(rasters, 0.9)} '
      'raster_max=${rasters.last.toStringAsFixed(1)} '
      'over16=$dropped over32=$slow',
    );
    pending.clear();
  }

  SchedulerBinding.instance.addTimingsCallback((batch) {
    for (final frame in batch) {
      final total = frame.buildDuration + frame.rasterDuration;
      if (total > const Duration(milliseconds: 32)) {
        // ignore: avoid_print
        print(
          'FRAMESTATS_SLOW t=${DateTime.now().difference(started).inMilliseconds} '
          'build=${(frame.buildDuration.inMicroseconds / 1000.0).toStringAsFixed(1)} '
          'raster=${(frame.rasterDuration.inMicroseconds / 1000.0).toStringAsFixed(1)}',
        );
      }
    }
    pending.addAll(batch);
    if (pending.length >= 60) flush();
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_frameStatsEnabled) _installFrameStats();
  final fonts = AppFonts();
  await fonts.load();
  await windowManager.ensureInitialized();

  // Pick the opaque window colour before the first frame: a translucent window
  // is what makes live resize / zoom / minimize cost extra compositor work on
  // macOS and Windows.
  // Shared-core settings load asynchronously; never let legacy preferences
  // overwrite them. Use system brightness only for the initial opaque frame.
  final restoreLight = WidgetsBinding.instance.platformDispatcher.platformBrightness
      == Brightness.light;
  final windowBackground =
      restoreLight ? XtPalette.paperBase : XtPalette.black900;

  await windowManager.waitUntilReadyToShow(
    desktopWindowOptionsFor(windowBackground), () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // Some platforms (macOS with a hidden titlebar) force the window translucent
  // when the titlebar style is applied; restore opacity after that.
  await configureWindowSurface(windowBackground);
  WindowActivityObserver.install(windowActivity);

  runApp(XenTermApp(fonts: fonts));
}

/// Applies the opaque window colour natively where window_manager cannot:
/// macOS marks windows with a hidden titlebar as non-opaque, and that flag is
/// what makes the compositor blend every frame.
Future<void> configureWindowSurface(Color color) async {
  try {
    await windowManager.setBackgroundColor(color);
  } catch (_) {
    // Not supported on this host; the Flutter surface still covers the window.
  }
  if (!Platform.isMacOS) return;
  try {
    await const MethodChannel('xenterm/window').invokeMethod<void>(
      'setOpaque',
      <String, int>{
        'r': (color.r * 255.0).round(),
        'g': (color.g * 255.0).round(),
        'b': (color.b * 255.0).round(),
      },
    );
  } catch (_) {
    // Older builds without the channel keep the platform default.
  }
}

// AppKit owns the macOS titlebar and its traffic-light hit targets. Keeping
// Flutter out of the full-size content view lets the native window reserve the
// correct area, including after resize/full-screen transitions. Other desktop
// platforms keep the shell's custom frame, drag region and resize borders.
WindowOptions get desktopWindowOptions =>
    desktopWindowOptionsFor(XtPalette.black900);

WindowOptions desktopWindowOptionsFor(Color background) => WindowOptions(
  title: 'XenTerm',
  titleBarStyle: defaultTargetPlatform == TargetPlatform.macOS
      ? TitleBarStyle.normal
      : TitleBarStyle.hidden,
  windowButtonVisibility: true,
  minimumSize: const Size(940, 600),
  backgroundColor: background,
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
    _syncWindowSurface();
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
    if (_themeMode == AppThemeMode.system) _changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.settings == null) {
      // The FFI wrapper runs in Isolate.run; a full profile refresh is not a
      // per-frame/per-second poll. It may involve disk/keyring work.
      _settings.load(clearError: false);
    }
  }

  Color? _windowSurface;

  void _syncWindowSurface() {
    final color = _lightTheme ? XtPalette.paperBase : XtPalette.black900;
    if (_windowSurface == color) return;
    _windowSurface = color;
    configureWindowSurface(color);
  }

  void _changed() {
    if (!mounted) return;
    _syncWindowSurface();
    setState(() {});
  }

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
