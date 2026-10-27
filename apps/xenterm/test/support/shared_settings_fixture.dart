import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/terminal/core_settings.dart';

/// In-memory protocol fixture, not evidence of core validation or persistence.
/// Rust's isolated SQLite tests and native cross-process tests cover those.
class SettingsFixture {
  final values = <String, dynamic>{
    'session_logs': false, 'cursor_style': 'block', 'line_spacing': 1.0,
    'padding': true, 'bold': false, 'sftp_follow_cd': true, 'download_dir': '',
    'language': 'system', 'theme_pref': 'system', 'font_family': '',
    'font_size': 13, 'ui_font_family': '', 'ui_font_size': 14,
  };
  int revision = 0;
  String? rejectNext;
  final calls = <(Map<String, dynamic>, String)>[];
  final explicit = <String>{};

  CoreSettings get snapshot => CoreSettings.fromCoreJson({
    ...values,
    'revision': 'r$revision',
    'explicit_fields': explicit.toList(),
    'invalid_legacy_fields': <String>[],
  });

  Future<CoreSettings> read() async => snapshot;

  Future<CoreSettingsWriteResult> write(Map<String, dynamic> patch, String expected) async {
    calls.add((Map.of(patch), expected));
    final rejection = rejectNext;
    rejectNext = null;
    if (rejection != null || expected != 'r$revision') {
      return CoreSettingsWriteResult(error: rejection ?? 'revision conflict', code: 'settings_update_failed');
    }
    values.addAll(patch);
    explicit.addAll(patch.keys);
    revision++;
    return CoreSettingsWriteResult(settings: snapshot);
  }

  CoreSettingsController controller() => CoreSettingsController(reader: read, writer: write)
    ..settings = snapshot
    ..loaded = true;
}
