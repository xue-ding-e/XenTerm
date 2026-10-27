/// Settings — the desktop settings window. Every control here changes a real
/// value: terminal rendering reads the core settings live, font choices are
/// persisted by [AppFonts], the SFTP download folder is used by the file
/// browser, and "Save session logs" controls the core transcript writer.
///
/// Header 80px, a 220px tab sidebar and the tab content, all painted from the
/// shared theme tokens. Every control is the shared primitive (XtSwitchRow,
/// XtSelectRow, XtStepper, XtCard) rather than a screen-local copy.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../bridge/native_bridge.dart'
    show CoreSettings, coreVersionSync, exportProfileFromCore, importProfileToCore;
import '../../l10n/app_language.dart';
import '../../terminal/core_settings.dart';
import '../../theme/app_fonts.dart';
import '../../theme/app_field.dart';
import 'settings_search.dart';
import 'settings_links.dart';
import '../../theme/app_theme.dart';
import '../../widgets/primitives.dart';

class SettingsScreen extends StatefulWidget {
  final bool lightTheme;
  final ValueChanged<bool> onThemeChanged;
  final AppFonts fonts;
  final CoreSettingsController settings;

  /// Test/alternate persistence hook; defaults to the shared controller.
  final Future<String?> Function(Map<String, dynamic> values)? saveSettings;

  /// Tests intercept link launches; no browser or platform process is started.
  final Future<bool> Function(String url)? openLink;

  const SettingsScreen({
    super.key,
    required this.lightTheme,
    required this.onThemeChanged,
    required this.fonts,
    required this.settings,
    this.saveSettings,
    this.openLink,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _dataBusy = false;
  bool _dataError = false;
  String? _dataStatus;

  Future<void> _exportProfile() async {
    setState(() {
      _dataBusy = true;
      _dataStatus = null;
      _dataError = false;
    });
    try {
      final export = await exportProfileFromCore();
      final location = await getSaveLocation(
        suggestedName: 'xenterm-profile.json',
      );
      if (location == null) {
        if (mounted) setState(() => _dataBusy = false);
        return;
      }
      await File(location.path).writeAsString(export.json, flush: true);
      if (!mounted) return;
      setState(() {
        _dataBusy = false;
        final file = location.path.split(Platform.pathSeparator).last;
        _dataStatus = export.count == 1
            ? AppLanguage.tr(context, 'Exported 1 session to {file}', {
                'file': file,
              })
            : AppLanguage.tr(context, 'Exported {count} sessions to {file}', {
                'count': export.count,
                'file': file,
              });
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _dataBusy = false;
        _dataError = true;
        _dataStatus = '$error';
      });
    }
  }

  Future<void> _importProfile() async {
    setState(() {
      _dataBusy = true;
      _dataStatus = null;
      _dataError = false;
    });
    try {
      final file = await openFile();
      if (file == null) {
        if (mounted) setState(() => _dataBusy = false);
        return;
      }
      final raw = await File(file.path).readAsString();
      // Validate first, then commit — the core is append-only either way.
      final preview = await importProfileToCore(raw, dryRun: true);
      final applied = await importProfileToCore(raw);
      if (!mounted) return;
      setState(() {
        _dataBusy = false;
        _dataStatus = applied.added == 1
            ? AppLanguage.tr(
                context,
                'Imported 1 session ({skipped} already present, skipped)',
                {'skipped': preview.skipped},
              )
            : AppLanguage.tr(
                context,
                'Imported {count} sessions ({skipped} already present, skipped)',
                {'count': applied.added, 'skipped': preview.skipped},
              );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _dataBusy = false;
        _dataError = true;
        _dataStatus = '$error';
      });
    }
  }

  static const _tabs = ['Terminal', 'SFTP', 'Logs', 'Shortcuts', 'About'];

  int _tab = 0;
  String? _saveError;
  bool _saving = false;
  String? _copiedLink;
  String? _failedLink;
  Timer? _copyReset;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'settings-search');
  final _scroll = ScrollController();
  final _targetKeys = <String, GlobalKey>{};
  final _targetFocus = <String, FocusNode>{};
  String _query = '';
  String? _locatedId;
  int _resultIndex = 0;
  bool _legacyPreviewOpen = false;
  final _legacyFields = <String>{};

  List<SettingsSearchEntry> get _results => searchSettings(
    _query,
    AppLanguage.maybeOf(context)?.code ?? 'en',
  );

  Widget _target(String id, Widget child) => Focus(
    key: _targetKeys.putIfAbsent(id, () => GlobalKey()),
    focusNode: _targetFocus.putIfAbsent(
      id, () => FocusNode(debugLabel: 'setting-$id'),
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(XtRadius.field),
        border: Border.all(
          color: _locatedId == id
              ? XtColors.accent(context)
              : Colors.transparent,
        ),
      ),
      child: child,
    ),
  );

  void _searchChanged(String value) => setState(() {
    _query = value;
    _resultIndex = 0;
    _locatedId = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  void _clearSearch() {
    _search.clear();
    _searchChanged('');
    _searchFocus.requestFocus();
  }

  void _openResult(SettingsSearchEntry entry) {
    _search.clear();
    setState(() {
      _query = '';
      _tab = entry.tab;
      _locatedId = entry.id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _targetKeys[entry.id]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.2);
        _targetFocus[entry.id]?.requestFocus();
      }
    });
  }

  KeyEventResult _searchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (command && !keyboard.isAltPressed && !keyboard.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
      return KeyEventResult.handled;
    }
    // Let the platform IME finish/cancel Chinese composition first.
    if (_searchFocus.hasFocus && _search.value.composing.isValid &&
        !_search.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _query.isNotEmpty) {
      _clearSearch();
      return KeyEventResult.handled;
    }
    if (!_searchFocus.hasFocus || _query.isEmpty) return KeyEventResult.ignored;
    final results = _results;
    if (results.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _resultIndex = (_resultIndex +
          (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1)) % results.length);
      final resultContext = _targetKeys['result-${results[_resultIndex].id}']?.currentContext;
      if (resultContext != null) Scrollable.ensureVisible(resultContext);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _openResult(results[(_resultIndex < results.length ? _resultIndex : 0)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<Widget> _searchResults() {
    final results = _results;
    return [
      _SectionCard(
        title: results.isEmpty ? 'No matches' : 'Search results',
        children: [
          if (results.isEmpty)
            const _SettingsText('Try a different search.'),
          for (var i = 0; i < results.length; i++)
            Focus(
              key: _targetKeys.putIfAbsent('result-${results[i].id}', () => GlobalKey()),
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    (event.logicalKey == LogicalKeyboardKey.enter ||
                     event.logicalKey == LogicalKeyboardKey.space)) {
                  _openResult(results[i]);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              onFocusChange: (focused) {
                if (focused) setState(() => _resultIndex = i);
              },
              child: Semantics(
                button: true,
                selected: i == _resultIndex,
                child: XtHoverRow(
                  selected: i == _resultIndex,
                  padding: const EdgeInsets.all(12),
                  onTap: () => _openResult(results[i]),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppLanguage.tr(context, results[i].label)),
                      Text(
                        '${AppLanguage.tr(context, _tabs[results[i].tab])} › '
                        '${AppLanguage.tr(context, results[i].section)}',
                        style: Theme.of(context).typography.normal.copyWith(
                          fontSize: 12,
                          color: XtColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_changed);
    widget.fonts.addListener(_changed);
    if (!widget.settings.loaded) widget.settings.load();
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fonts != widget.fonts) {
      oldWidget.fonts.removeListener(_changed);
      widget.fonts.addListener(_changed);
    }
    if (oldWidget.settings != widget.settings) {
      oldWidget.settings.removeListener(_changed);
      widget.settings.addListener(_changed);
      if (!widget.settings.loaded) widget.settings.load();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    for (final focus in _targetFocus.values) { focus.dispose(); }
    widget.fonts.removeListener(_changed);
    _copyReset?.cancel();
    widget.settings.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  CoreSettings get _core => widget.settings.settings;

  Future<void> _save(Map<String, dynamic> values) async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final error =
        await (widget.saveSettings?.call(values) ??
            widget.settings.update(values));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saveError = error;
    });
  }

  Future<void> _chooseDownloadFolder() async {
    final directory = await getDirectoryPath();
    if (directory == null || directory.isEmpty) return;
    await _save({'download_dir': directory});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Focus(
      autofocus: true,
      onKeyEvent: _searchKey,
      child: Container(
      color: XtColors.chrome(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: scale > 1 ? 80 * scale : 80,
            padding: const EdgeInsets.fromLTRB(20, 25, 20, 0),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: XtColors.hairline(context)),
              ),
            ),
            alignment: Alignment.topLeft,
            child: Row(
              children: [
                Text(
                  AppLanguage.tr(context, 'Settings'),
                  style: theme.typography.bold.copyWith(
                    fontSize: 24,
                    height: 45 / 24,
                    color: XtColors.textPrimary(context),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 360,
                      child: XtField(
                        key: const ValueKey('settings-search'),
                        placeholder: AppLanguage.tr(context, 'Search settings'),
                        controller: _search,
                        focusNode: _searchFocus,
                        onChanged: _searchChanged,
                        onSubmitted: (_) {
                          if (_search.value.composing.isValid &&
                              !_search.value.composing.isCollapsed) {
                            return;
                          }
                          final results = _results;
                          if (results.isNotEmpty) {
                            _openResult(results[(_resultIndex < results.length ? _resultIndex : 0)]);
                          }
                        },
                        leading: const Icon(LucideIcons.search, size: 16),
                        trailing: _query.isEmpty ? null : XtIconButton(
                          key: const ValueKey('settings-search-clear'),
                          icon: LucideIcons.x,
                          tooltip: AppLanguage.tr(context, 'Clear search'),
                          onPressed: _clearSearch,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                XtIconButton(
                  key: const ValueKey('settings-refresh'),
                  icon: LucideIcons.refreshCw,
                  tooltip: AppLanguage.tr(context, 'Refresh shared settings'),
                  onPressed: widget.settings.saving ? null : () {
                    setState(() => _saveError = null);
                    widget.settings.load();
                  },
                ),
                if (_saving || widget.settings.saving)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The tab rail shrinks a step on small windows so the 700px
                // card column keeps its breathing room at the 940px minimum.
                final sidebarWidth = constraints.maxWidth < 1000 ? 176.0 : 220.0;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TabSidebar(
                      width: sidebarWidth,
                      tabs: _tabs,
                      active: _tab,
                      onSelect: (i) {
                        _search.clear();
                        setState(() { _tab = i; _query = ''; _locatedId = null; });
                        if (_scroll.hasClients) _scroll.jumpTo(0);
                      },
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: XtColors.page(context),
                        // The content column is capped at 700 and centred; the
                        // surrounding scroll view keeps every anchor mounted and never
                        // clips the last card, and the horizontal padding keeps
                        // the card off the window edge at narrow widths.
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 60),
                          child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_saveError != null || widget.settings.error != null)
                              _SectionCard(
                                children: [
                                  _SettingsText(
                                    _saveError ?? widget.settings.error!,
                                    color: XtColors.danger(context),
                                  ),
                                ],
                              ),
                            ...(_query.trim().isEmpty ? _contentFor(_tab) : _searchResults()),
                          ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      ),
    );
  }


  /// About tab: real application/build identity, project links and credits.
  /// A normal click opens the documented destination; the separate copy action
  /// remains available when a desktop has no browser association.
  Future<void> _openLink(String url) async {
    var opened = false;
    try {
      opened = await (widget.openLink?.call(url) ?? openSettingsLink(url));
    } catch (_) {
      // A failed platform handler is visible and must not break Settings.
    }
    if (mounted) setState(() => _failedLink = opened ? null : url);
  }

  void _copyLink(String label, String url) {
    Clipboard.setData(ClipboardData(text: url));
    _copyReset?.cancel();
    setState(() => _copiedLink = label);
    _copyReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedLink = null);
    });
  }

  List<Widget> _aboutTab() {
    final theme = Theme.of(context);
    final version = coreVersionSync();
    final features = <(IconData, String, String)>[
      (LucideIcons.server, 'SSH / SFTP', 'File browsing and transfers'),
      (
        LucideIcons.cable,
        'Telnet / Serial',
        'Network devices and serial consoles',
      ),
      (LucideIcons.arrowLeftRight, 'Port forwarding', 'Tunnels and jump hosts'),
      (LucideIcons.braces, 'MCP / CLI', 'Automation without a JVM'),
    ];
    return [
      if (_failedLink != null)
        _SectionCard(children: [
          const _SettingsText('Could not open the browser. Use Copy link instead.'),
          _SettingsText(_failedLink!),
        ]),
      _SectionCard(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/app_icon.png',
                  width: 64,
                  height: 64,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'XenTerm',
                      style: theme.typography.bold.copyWith(
                        fontSize: 20,
                        height: 1.2,
                        color: XtColors.textPrimary(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // The canonical build identity, verbatim from the core
                    // (`xt-vX.Y.Z` or `xt-<channel>-<hash>-T<timestamp>`).
                    // Never localised: users paste it into bug reports and MCP
                    // clients see the same string.
                    Text(
                      version ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.mono.copyWith(
                        fontSize: 12,
                        color: XtColors.textSecondary(context),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        XtBadge(label: 'Rust'),
                        XtBadge(label: 'Flutter'),
                        XtBadge(label: 'MCP'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            AppLanguage.tr(
              context,
              'A lightweight SSH / SFTP / Telnet / serial terminal with a Rust '
              'core and a Flutter desktop UI.',
            ),
            style: theme.typography.normal.copyWith(
              fontSize: 13,
              height: 1.6,
              color: XtColors.textSecondary(context),
            ),
          ),
        ],
      ),
      _SectionCard(
        title: 'Features',
        children: [
          const SizedBox(height: 2),
          for (var row = 0; row < features.length; row += 2)
            Padding(
              padding: EdgeInsets.only(top: row == 0 ? 10 : 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _AboutFeature(
                      icon: features[row].$1,
                      title: features[row].$2,
                      detail: features[row].$3,
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: row + 1 < features.length
                        ? _AboutFeature(
                            icon: features[row + 1].$1,
                            title: features[row + 1].$2,
                            detail: features[row + 1].$3,
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
        ],
      ),
      _target('credits', _SectionCard(
        title: 'Developer & credits',
        children: [
          _SettingsText('Maintained by 小白 and the XenTerm contributors.'),
          _SettingsText(
            'Thanks to xue-ding-e and noerror6 for their contributions, and to '
            'the open-source projects this app is built on: Flutter, '
            'shadcn_flutter, Rust, russh, rio-vt, Lucide, Simple Icons and '
            'Twemoji.',
          ),
          for (final link in creditLinks)
            _LinkRow(
              label: link.label,
              url: link.url,
              icon: LucideIcons.github,
              copied: _copiedLink == link.url,
              onTap: () => _openLink(link.url),
              onCopy: () => _copyLink(link.url, link.url),
            ),
        ],
      )),
      _target('links', _SectionCard(
        title: 'Links',
        children: [
          Padding(
            // Aligned with the link labels below.
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Text(
              AppLanguage.tr(context, 'Open links in your browser, or use the copy button.'),
              style: theme.typography.normal.copyWith(
                fontSize: 12,
                color: XtColors.textTertiary(context),
              ),
            ),
          ),
          for (final link in projectLinks)
            _LinkRow(
              label: link.label,
              url: link.url,
              icon: LucideIcons.externalLink,
              copied: _copiedLink == link.url,
              onTap: () => _openLink(link.url),
              onCopy: () => _copyLink(link.url, link.url),
            ),
        ],
      )),
    ];
  }

  List<Widget> _contentFor(int tab) => switch (tab) {
    0 => _terminalTab(),
    1 => _sftpTab(),
    2 => _logsTab(),
    3 => _shortcutsTab(),
    _ => _aboutTab(),
  };

  List<Widget> _terminalTab() {
    final fonts = widget.fonts;
    final core = _core;

    return [
      if (widget.settings.legacyPreferencePreview.isNotEmpty) _legacyCard(),
      // Language is global, so it sits first: switching it rebuilds the whole
      // shell while every value below stays untouched.
      _SectionCard(
        title: 'Language',
        children: [
          _target('language', XtSelectRow<String>(
            key: const ValueKey('setting-language'),
            label: 'Interface language',
            value: core.language,
            options: const {'system': 'Follow system', 'en': 'English', 'zh': '简体中文'},
            onChanged: (code) => _save({'language': code}),
          )),
        ],
      ),
      _SectionCard(
        title: 'Terminal settings',
        children: [
          _target('cursor', XtSelectRow<String>(
            label: 'Cursor style',
            value: switch (core.cursorStyle) {
              'bar' => 'Bar',
              'underline' => 'Underline',
              _ => 'Block',
            },
            options: const {'Block': 'Block', 'Bar': 'Bar', 'Underline': 'Underline'},
            onChanged: (value) => _save({
              'cursor_style': switch (value) {
                'Bar' => 'bar',
                'Underline' => 'underline',
                _ => 'block',
              },
            }),
          )),
          _target('line-spacing', XtSelectRow<String>(
            label: 'Line spacing',
            value: switch (core.lineSpacing) {
              <= 0.92 => 'Compact',
              >= 1.08 => 'Relaxed',
              _ => 'Normal',
            },
            options: const {
              'Compact': 'Compact',
              'Normal': 'Normal',
              'Relaxed': 'Relaxed',
            },
            onChanged: (value) => _save({
              'line_spacing': switch (value) {
                'Compact' => 0.85,
                'Relaxed' => 1.15,
                _ => 1.0,
              },
            }),
          )),
          _target('padding', XtSwitchRow(
            key: const ValueKey('setting-padding'),
            label: 'Inset terminal text',
            description: 'Keep a small margin around the character grid',
            value: core.padding,
            onChanged: (value) => _save({'padding': value}),
          )),
          _target('bold', XtSwitchRow(
            key: const ValueKey('setting-bold'),
            label: 'Use a bold face for terminal text',
            value: core.bold,
            onChanged: (value) => _save({'bold': value}),
          )),
        ],
      ),
      _SectionCard(
        children: [
          _target('terminal-font', XtSelectRow<String>(
            label: 'Terminal font',
            value: fonts.terminalFamily.isEmpty
                ? 'Default'
                : _familyLabel(fonts.terminalFamily),
            options: _fontChoice(fonts),
            onChanged: (value) => setState(() {
              fonts.setTerminalFamily(
                value == 'Default' ? '' : _familyValue(value),
              );
            }),
          )),
          const _SettingsText('Changes terminal characters and the grid, not interface labels.'),
          _target('terminal-size', _StepperRow(
            label: 'Terminal text size',
            keyPrefix: 'terminal',
            enabled: !fonts.saving,
            value: fonts.terminalSize,
            onChanged: fonts.setTerminalSize,
            min: 8,
            max: 32,
          )),
        ],
      ),
      _SectionCard(
        title: 'Appearance',
        children: [
          _target('theme', XtSelectRow<String>(
            label: 'Theme',
            value: core.themePref,
            options: const {'system': 'Follow system', 'dark': 'Dark', 'light': 'Light'},
            onChanged: (value) => _save({'theme_pref': value}),
          )),
        ],
      ),
      _SectionCard(
        title: 'Interface',
        children: [
          _target('interface-font', XtSelectRow<String>(
            label: 'Interface font',
            value: fonts.uiFamily.isEmpty
                ? 'Default'
                : _familyLabel(fonts.uiFamily),
            options: _fontChoice(fonts),
            onChanged: (value) => setState(() {
              fonts.setUiFamily(value == 'Default' ? '' : _familyValue(value));
            }),
          )),
          const _SettingsText('Changes menus and interface labels, not terminal characters.'),
          _target('interface-size', _StepperRow(
            label: 'Interface text size',
            keyPrefix: 'interface',
            enabled: !fonts.saving,
            value: fonts.uiSize,
            onChanged: fonts.setUiSize,
            min: 8,
            max: 32,
          )),
          _target('import-font', _DestinationRow(
            label: 'Import font (TTF/OTF)',
            onTap: () async {
              await fonts.importFont();
              if (mounted) setState(() {});
            },
          )),
          if (fonts.error != null)
            _SettingsText(
              fonts.error!,
              color: XtColors.danger(context),
            )
          else
            const _SettingsText(
              'Imported fonts are stored in this device\'s app data.',
            ),
        ],
      ),
    ];
  }

  Widget _legacyCard() {
    final previous = widget.settings.legacyPreferencePreview;
    final current = <String, dynamic>{
      'language': _core.language, 'theme_pref': _core.themePref,
      'font_family': _core.fontFamily, 'font_size': _core.fontSize,
      'ui_font_family': _core.uiFontFamily, 'ui_font_size': _core.uiFontSize,
    };
    const labels = {
      'language': 'Interface language', 'theme_pref': 'Theme',
      'font_family': 'Terminal font', 'font_size': 'Terminal text size',
      'ui_font_family': 'Interface font', 'ui_font_size': 'Interface text size',
    };
    return _SectionCard(
      title: 'Previous interface preferences',
      children: [
        const _SettingsText('Old preferences are preserved. Nothing is imported automatically.'),
        _DestinationRow(
          key: const ValueKey('settings-legacy-preview'),
          label: _legacyPreviewOpen ? 'Hide previous preferences' : 'Review previous preferences',
          onTap: () => setState(() => _legacyPreviewOpen = !_legacyPreviewOpen),
        ),
        if (_legacyPreviewOpen) ...[
          for (final entry in previous.entries)
            XtSwitchRow(
              key: ValueKey('settings-legacy-${entry.key}'),
              label: labels[entry.key] ?? entry.key,
              description: AppLanguage.tr(context, 'Previous: {previous} · Shared: {current}', {
                'previous': entry.value, 'current': current[entry.key],
              }),
              value: _legacyFields.contains(entry.key),
              onChanged: (selected) => setState(() {
                if (selected) { _legacyFields.add(entry.key); }
                else { _legacyFields.remove(entry.key); }
              }),
            ),
          const SizedBox(height: 16),
          XtActionButton(
            key: const ValueKey('settings-legacy-apply'),
            label: AppLanguage.tr(context, 'Apply selected preferences'),
            onPressed: _legacyFields.isEmpty || _saving || widget.settings.saving
                ? null : () => _save({
                    for (final key in _legacyFields) key: previous[key],
                  }),
          ),
        ],
      ],
    );
  }

  List<Widget> _sftpTab() => [
    _SectionCard(
      title: 'SFTP settings',
      children: [
        _target('sftp-follow', XtSwitchRow(
          key: const ValueKey('setting-sftp-follow'),
          label: 'Follow the terminal directory',
          description:
              'Open the file browser at the shell\'s current folder when supported',
          value: _core.sftpFollowCd,
          onChanged: (value) => _save({'sftp_follow_cd': value}),
        )),
        _target('download-folder', _PathRow(
          label: 'Download folder',
          value: _core.downloadDir.isEmpty
              ? 'Ask for a folder each time'
              : _core.downloadDir,
          onChoose: _chooseDownloadFolder,
        )),
        if (_core.downloadDir.isNotEmpty)
          _DestinationRow(
            label: 'Clear download folder',
            onTap: () => _save({'download_dir': ''}),
          ),
        const _SettingsText(
          'Downloaded files are written to this folder; the picker appears when '
          'no folder is set.',
        ),
      ],
    ),
  ];

  List<Widget> _logsTab() => [
    _SectionCard(
      title: 'Session logs',
      children: [
        _target('session-logs', XtSwitchRow(
          key: const ValueKey('setting-session-logs'),
          label: 'Save session logs',
          description:
              'Record new terminal sessions as text transcripts. Existing '
              'sessions are not recorded retroactively.',
          value: _core.sessionLogs,
          onChanged: (value) => _save({'session_logs': value}),
        )),
        const _SettingsText(
          'Transcripts are stored in the app data folder and appear in Logs, '
          'where they can be opened or deleted. Nothing is uploaded.',
        ),
      ],
    ),
    _SectionCard(
      title: 'Profile data',
      children: [
        _target('profile-export', _DestinationRow(
          key: const ValueKey('settings-export'),
          label: 'Export sessions (JSON)',
          onTap: _dataBusy ? null : _exportProfile,
        )),
        _target('profile-import', _DestinationRow(
          key: const ValueKey('settings-import'),
          label: 'Import sessions (JSON)',
          onTap: _dataBusy ? null : _importProfile,
        )),
        if (_dataStatus != null)
          _SettingsText(
            _dataStatus!,
            color: _dataError == true ? XtColors.danger(context) : null,
          )
        else
          const _SettingsText(
            'Exports carry every saved host; secrets are written in the '
            'portable encrypted form. Importing never overwrites existing '
            'sessions — new ones are appended.',
          ),
      ],
    ),
  ];

  List<Widget> _shortcutsTab() => [
    _target('shortcuts', _SectionCard(
      title: 'Keyboard shortcuts',
      children: [
        _ShortcutRow(
          keys: 'Ctrl+Shift+F',
          action: 'Search the terminal buffer',
        ),
        _ShortcutRow(
          keys: 'Ctrl+L',
          action: 'Clear the screen (sent to the shell)',
        ),
        _ShortcutRow(keys: 'Ctrl+C', action: 'Copy selected text; otherwise interrupt the running command'),
        _ShortcutRow(keys: 'Ctrl+V', action: 'Paste clipboard text with safety review'),
        _ShortcutRow(keys: 'Cmd+C / Cmd+V', action: 'Copy / paste on macOS'),
        _ShortcutRow(keys: 'Ctrl+Shift+C / Ctrl+Shift+V', action: 'Copy / paste on Windows and Linux'),
        _ShortcutRow(keys: 'Ctrl+F / Cmd+F', action: 'Search settings (while in Settings)'),
        _ShortcutRow(keys: 'Shift+Tab', action: 'Backtab'),
        _ShortcutRow(
          keys: 'Home / End / PgUp / PgDn',
          action: 'Move through the terminal buffer',
        ),
        _ShortcutRow(keys: 'Enter', action: 'Run the command'),
      ],
    )),
  ];

  // Font families are stored as family identifiers; show their display names.
  Map<String, String> _fontChoice(AppFonts fonts) => {
    for (final label in _fontOptions(fonts)) label: label,
  };

  List<String> _fontOptions(AppFonts fonts) => [
    'Default',
    ...{
      if (fonts.terminalFamily.isNotEmpty) _familyLabel(fonts.terminalFamily),
      if (fonts.uiFamily.isNotEmpty) _familyLabel(fonts.uiFamily),
      for (final f in fonts.imported) f.name,
    },
  ];

  String _familyLabel(String family) {
    for (final f in widget.fonts.imported) {
      if (f.family == family) return f.name;
    }
    return family;
  }

  String _familyValue(String label) {
    for (final f in widget.fonts.imported) {
      if (f.name == label) return f.family;
    }
    return label;
  }
}

// ── The 220px tab sidebar ───────────────────────────────────────────────
class _TabSidebar extends StatelessWidget {
  final double width;
  final List<String> tabs;
  final int active;
  final ValueChanged<int> onSelect;

  const _TabSidebar({
    required this.width,
    required this.tabs,
    required this.active,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: XtColors.chrome(context),
        border: Border(right: BorderSide(color: XtColors.hairline(context))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SingleChildScrollView(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tabs.length; i++)
            _TabItem(
              label: AppLanguage.tr(context, tabs[i]),
              selected: i == active,
              onTap: () => onSelect(i),
            ),
        ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: XtHoverRow(
        selected: selected,
        onTap: onTap,
        radius: XtRadius.field,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: theme.typography.normal.copyWith(
              fontSize: 13,
              color: selected
                  ? XtColors.textPrimary(context)
                  : XtColors.textSecondary(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// A read-only path with a real folder picker.
class _PathRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onChoose;

  const _PathRow({
    required this.label,
    required this.value,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLanguage.tr(context, label),
                  style: theme.typography.medium.copyWith(
                    fontSize: 13,
                    color: XtColors.textPrimary(context),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  AppLanguage.tr(context, value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.normal.copyWith(
                    fontSize: 13,
                    color: XtColors.textTertiary(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          XtActionButton(
            label: AppLanguage.tr(context, 'Choose…'),
            variant: XtActionVariant.secondary,
            onPressed: onChoose,
          ),
        ],
      ),
    );
  }
}

/// One accurate shortcut entry (no fake alternative key bindings).
class _ShortcutRow extends StatelessWidget {
  final String keys;
  final String action;

  const _ShortcutRow({required this.keys, required this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          XtKeyChip(label: keys),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              AppLanguage.tr(context, action),
              style: theme.typography.normal.copyWith(
                fontSize: 13,
                color: XtColors.textSecondary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section card: max-width 700, 20 padding, surface fill, radius 10 ────
class _SectionCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const _SectionCard({this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: XtCard(
          margin: const EdgeInsets.only(top: 30),
          padding: const EdgeInsets.all(20),
          radius: XtRadius.field,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Text(
                  AppLanguage.tr(context, title!),
                  style: theme.typography.normal.copyWith(
                    fontSize: 16,
                    height: 1.75,
                    color: XtColors.textPrimary(context),
                  ),
                ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// "Text Size" with a minus/plus pair and a centred numeric field.
class _StepperRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final String keyPrefix;
  final bool enabled;

  const _StepperRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
    required this.keyPrefix,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppLanguage.tr(context, label),
              style: theme.typography.medium.copyWith(
                fontSize: 13,
                color: XtColors.textPrimary(context),
              ),
            ),
          ),
          // The two step buttons are the shared XtIconButton, so settings and
          // the terminal tools panel cannot drift apart. Their ValueKeys stay
          // because the widget tests drive them.
          XtIconButton(
            key: ValueKey('$keyPrefix-minus'),
            icon: LucideIcons.minus,
            size: 34,
            iconSize: 14,
            onPressed: enabled && value > min ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 51,
            child: Text(
              '${value.round()}',
              textAlign: TextAlign.center,
              style: theme.typography.normal.copyWith(
                fontSize: 13,
                color: XtColors.textPrimary(context),
              ),
            ),
          ),
          XtIconButton(
            key: ValueKey('$keyPrefix-plus'),
            icon: LucideIcons.plus,
            size: 34,
            iconSize: 14,
            onPressed: enabled && value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

/// A destination row: label left, chevron right.
class _DestinationRow extends StatelessWidget {
  final String label;

  /// Null disables the row (shown muted, not tappable) while a long export or
  /// import runs.
  final VoidCallback? onTap;

  const _DestinationRow({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  AppLanguage.tr(context, label),
                  style: theme.typography.medium.copyWith(
                    fontSize: 13,
                    color: onTap == null
                        ? XtColors.textDisabled(context)
                        : XtColors.textPrimary(context),
                  ),
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 15,
                color: XtColors.textTertiary(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// One feature summary on the About page: a real icon, a title and a short
/// detail line. Two of these form a row in the 700px settings column.
class _AboutFeature extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;

  const _AboutFeature({
    required this.icon,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: XtColors.selected(context),
            borderRadius: BorderRadius.circular(XtRadius.menu),
          ),
          child: Icon(icon, size: 15, color: XtColors.textSecondary(context)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLanguage.tr(context, title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.medium.copyWith(
                  fontSize: 13,
                  color: XtColors.textPrimary(context),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                AppLanguage.tr(context, detail),
                style: theme.typography.normal.copyWith(
                  fontSize: 12,
                  height: 1.35,
                  color: XtColors.textTertiary(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One About link row: open on click/Enter, with a separate copy affordance.
/// The full destination is available as a tooltip and in the clipboard, rather
/// than wrapping long URLs into every settings card.
class _LinkRow extends StatelessWidget {
  final String label;
  final String url;
  final IconData icon;
  final bool copied;
  final VoidCallback onTap;
  final VoidCallback onCopy;

  const _LinkRow({
    required this.label,
    required this.url,
    required this.icon,
    required this.copied,
    required this.onTap,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
             event.logicalKey == LogicalKeyboardKey.space)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        link: true,
        child: Tooltip(
          tooltip: (_) => Text(url),
          child: XtHoverRow(
      key: ValueKey('settings-link-$url'),
      onTap: onTap,
      height: 38,
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      radius: XtRadius.menu,
      child: Row(
        children: [
          Icon(icon, size: 15, color: XtColors.textSecondary(context)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              AppLanguage.tr(context, label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.medium.copyWith(
                fontSize: 13,
                color: XtColors.textPrimary(context),
              ),
            ),
          ),
          if (copied)
            Text(
              AppLanguage.tr(context, 'Copied'),
              style: theme.typography.normal.copyWith(
                fontSize: 12,
                color: XtColors.accent(context),
              ),
            ),
          const SizedBox(width: 6),
          XtIconButton(
            key: ValueKey('settings-copy-$url'),
            icon: copied ? LucideIcons.check : LucideIcons.copy,
            size: 30,
            iconSize: 14,
            tooltip: AppLanguage.tr(context, 'Copy link'),
            onPressed: onCopy,
          ),
        ],
      ),
          ),
        ),
      ),
    );
  }
}

/// SettingsText: 13px secondary body, 15px top margin.
class _SettingsText extends StatelessWidget {
  final String text;
  final Color? color;

  const _SettingsText(this.text, {this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 15),
      child: Text(
        AppLanguage.tr(context, text),
        style: theme.typography.normal.copyWith(
          fontSize: 13,
          color: color ?? XtColors.textSecondary(context),
        ),
      ),
    );
  }
}
