import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../terminal/core_settings.dart';
import '../distribution.dart';

class ImportedFont {
  final String name;
  final String family;
  final String path;

  const ImportedFont(this.name, this.family, this.path);

  Map<String, String> toJson() => {
    'name': name,
    'family': family,
    'path': path,
  };
}

/// Renderer cache of the shared core's UI/terminal font choices. Imported font
/// bytes and their per-device registration cache stay in application support;
/// choices themselves are read/written through CoreSettingsController.
/// TerminalView reads these values for its cell measurement and painting.
class AppFonts extends ChangeNotifier {
  final Future<Directory> Function() _supportDirectory;
  AppFonts({Future<Directory> Function()? supportDirectory})
      : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  Future<File> _releaseAssetsFile() async => File(
    '${(await _supportDirectory()).path}/xenterm-flutter-next/font-assets.json',
  );

  static const _legacyKey = 'xenterm.fonts.v1';
  static const _assetsKey = 'xenterm.font-assets.v1';
  CoreSettingsController? _settings;
  final List<ImportedFont> imported = [];
  String uiFamily = '';
  String terminalFamily = '';
  double uiSize = 14;
  double terminalSize = 13;
  String? error;
  bool _wasSaving = false;
  bool get saving => _settings?.saving ?? false;

  void bindSettings(CoreSettingsController settings) {
    if (identical(_settings, settings)) return;
    _settings?.removeListener(_fromCore);
    _settings = settings;
    settings.addListener(_fromCore);
    _fromCore();
  }

  void _fromCore() {
    final controller = _settings;
    if (controller == null || !controller.loaded) return;
    final snapshot = controller.settings;
    final changed = uiFamily != snapshot.uiFontFamily ||
        terminalFamily != snapshot.fontFamily || uiSize != snapshot.uiFontSize ||
        terminalSize != snapshot.fontSize;
    uiFamily = snapshot.uiFontFamily;
    terminalFamily = snapshot.fontFamily;
    uiSize = snapshot.uiFontSize;
    terminalSize = snapshot.fontSize;
    final savingChanged = _wasSaving != controller.saving;
    _wasSaving = controller.saving;
    if (changed || savingChanged) notifyListeners();
  }

  void _update(Map<String, dynamic> patch, VoidCallback inMemory) {
    final controller = _settings;
    if (controller == null) {
      // An unbound presenter is useful for isolated renderer tests. Production
      // binds the shared controller before mounting any settings/terminal UI.
      inMemory();
      notifyListeners();
      return;
    }
    controller.update(patch).then((failure) {
      if (_disposed) return;
      error = failure;
      notifyListeners();
    });
  }

  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    _settings?.removeListener(_fromCore);
    super.dispose();
  }

  String labelFor(String family) {
    if (family.isEmpty) return '默认';
    for (final font in imported) {
      if (font.family == family) return font.name;
    }
    return family;
  }

  void setUiFamily(String family) =>
      _update({'ui_font_family': family}, () => uiFamily = family);

  void setTerminalFamily(String family) =>
      _update({'font_family': family}, () => terminalFamily = family);

  void setUiSize(double size) => _update(
    {'ui_font_size': size.isFinite && size == size.roundToDouble() ? size.toInt() : size},
    () => uiSize = size,
  );

  void setTerminalSize(double size) => _update(
    {'font_size': size.isFinite && size == size.roundToDouble() ? size.toInt() : size},
    () => terminalSize = size,
  );

  Future<void> load() async {
    // Independent releases never consult upstream preferences or font paths.
    // The separate JSON file also avoids read/modify/write races in a shared
    // SharedPreferences backing file when both applications run together.
    final String? raw;
    if (isolatedFlutterRelease) {
      final file = await _releaseAssetsFile();
      raw = await file.exists() ? await file.readAsString() : null;
    } else {
      final prefs = await SharedPreferences.getInstance();
      // Keep old preferences intact for the explicit migration preview.
      raw = prefs.getString(_assetsKey) ?? prefs.getString(_legacyKey);
    }
    if (raw == null) return;
    try {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in (saved['imported'] as List<dynamic>? ?? [])) {
        final item = entry as Map<String, dynamic>;
        final font = ImportedFont(
          item['name'] as String,
          item['family'] as String,
          item['path'] as String,
        );
        if (await File(font.path).exists()) {
          try {
            await _register(font.family, await File(font.path).readAsBytes());
            imported.add(font);
          } catch (_) {
            // A removed or corrupt font cannot be selected again.
          }
        }
      }
    } catch (_) {
      error = '字体注册信息读取失败，已保留共享字体设置';
    }
    notifyListeners();
  }

  Future<bool> importFont() async {
    error = null;
    try {
      const type = XTypeGroup(label: '字体', extensions: ['ttf', 'otf']);
      final selected = await openFile(acceptedTypeGroups: [type]);
      if (selected == null) return false;
      final bytes = await selected.readAsBytes();
      if (bytes.length < 12 ||
          bytes.length > 20 * 1024 * 1024 ||
          !_validHeader(bytes)) {
        throw const FormatException('仅支持 20 MB 以下的 TTF/OTF 字体');
      }
      final dir = Directory(
        '${(await _supportDirectory()).path}/${isolatedFlutterRelease ? 'xenterm-flutter-next/fonts' : 'fonts'}',
      );
      await dir.create(recursive: true);
      final family = 'xenterm_${DateTime.now().microsecondsSinceEpoch}';
      final path =
          '${dir.path}/$family.${selected.name.toLowerCase().endsWith('.otf') ? 'otf' : 'ttf'}';
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      try {
        await _register(family, bytes);
      } catch (_) {
        await file.delete();
        rethrow;
      }
      imported.add(ImportedFont(selected.name, family, path));
      await _saveAssets();
      notifyListeners();
      return true;
    } catch (e) {
      error = '导入失败：$e';
      notifyListeners();
      return false;
    }
  }

  static bool _validHeader(Uint8List bytes) {
    final tag = bytes.sublist(0, 4);
    return (tag[0] == 0 && tag[1] == 1 && tag[2] == 0 && tag[3] == 0) ||
        ascii.decode(tag, allowInvalid: true) == 'OTTO';
  }

  static Future<void> _register(String family, Uint8List bytes) async {
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  Future<void> _saveAssets() async {
    final value = jsonEncode({
      'imported': imported.map((font) => font.toJson()).toList(),
    });
    if (isolatedFlutterRelease) {
      final file = await _releaseAssetsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(value, flush: true);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_assetsKey, value);
    }
  }
}
