import '../../l10n/app_language.dart';

/// Stable control IDs, not translated titles, own navigation and focus.
/// Search both supported languages even when the interface uses the other one.
class SettingsSearchEntry {
  final String id;
  final int tab;
  final String label;
  final String section;
  final String aliases;

  const SettingsSearchEntry(
    this.id,
    this.tab,
    this.label,
    this.section, [
    this.aliases = '',
  ]);

  bool matches(String query, String locale) {
    final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
    final haystack = [
      label,
      section,
      aliases,
      for (final code in {...AppLanguage.supported.keys, locale}) ...[
        AppLanguage.translate(code, label),
        AppLanguage.translate(code, section),
      ],
    ].join(' ').toLowerCase();
    return terms.every(haystack.contains);
  }
}

const settingsSearchEntries = <SettingsSearchEntry>[
  SettingsSearchEntry('language', 0, 'Interface language', 'Language',
      'language locale 语言 语种 English 简体中文'),
  SettingsSearchEntry('cursor', 0, 'Cursor style', 'Terminal settings'),
  SettingsSearchEntry('line-spacing', 0, 'Line spacing', 'Terminal settings'),
  SettingsSearchEntry('padding', 0, 'Inset terminal text', 'Terminal settings'),
  SettingsSearchEntry('bold', 0, 'Use a bold face for terminal text', 'Terminal settings'),
  SettingsSearchEntry('terminal-font', 0, 'Terminal font', 'Terminal settings'),
  SettingsSearchEntry('terminal-size', 0, 'Terminal text size', 'Terminal settings',
      'font size 字号 字体大小'),
  SettingsSearchEntry('theme', 0, 'Theme', 'Appearance',
      'system follow light dark 跟随系统 浅色 深色'),
  SettingsSearchEntry('interface-font', 0, 'Interface font', 'Interface'),
  SettingsSearchEntry('interface-size', 0, 'Interface text size', 'Interface',
      'font size 字号 字体大小'),
  SettingsSearchEntry('import-font', 0, 'Import font (TTF/OTF)', 'Interface'),
  SettingsSearchEntry('sftp-follow', 1, 'Follow the terminal directory', 'SFTP settings'),
  SettingsSearchEntry('download-folder', 1, 'Download folder', 'SFTP settings'),
  SettingsSearchEntry('session-logs', 2, 'Save session logs', 'Session logs'),
  SettingsSearchEntry('profile-export', 2, 'Export sessions (JSON)', 'Profile data'),
  SettingsSearchEntry('profile-import', 2, 'Import sessions (JSON)', 'Profile data'),
  SettingsSearchEntry('shortcuts', 3, 'Keyboard shortcuts', 'Shortcuts'),
  SettingsSearchEntry('credits', 4, 'Developer & credits', 'About',
      'author contributors dependencies github 作者 贡献者 依赖 鸣谢'),
  SettingsSearchEntry('links', 4, 'Links', 'About',
      'source issue release license github 源码 反馈 发布 许可证'),
];

List<SettingsSearchEntry> searchSettings(String query, String locale) =>
    query.trim().isEmpty
        ? const []
        : settingsSearchEntries
            .where((entry) => entry.matches(query, locale))
            .toList();
