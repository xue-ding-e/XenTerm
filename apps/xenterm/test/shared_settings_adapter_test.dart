import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';
import 'package:xenterm_app/terminal/core_settings.dart';
import 'package:xenterm_app/theme/app_fonts.dart';
import 'package:xenterm_app/theme/legacy_preferences.dart';

import 'support/shared_settings_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('snapshot parser rejects an old bridge without a revision', () {
    expect(() => CoreSettings.fromCoreJson({'font_size': 15}), throwsFormatException);
  });

  test('writes publish only confirmed snapshots and serialize revisions', () async {
    final fixture = SettingsFixture();
    final gate = Completer<void>();
    var count = 0;
    final controller = CoreSettingsController(
      reader: fixture.read,
      writer: (patch, revision) async {
        count++;
        if (count == 1) await gate.future;
        return fixture.write(patch, revision);
      },
    )..settings = fixture.snapshot..loaded = true;
    addTearDown(controller.dispose);
    final first = controller.update({'font_size': 21});
    final second = controller.update({'ui_font_size': 19});
    await Future<void>.delayed(Duration.zero);
    expect(controller.settings.fontSize, 13, reason: 'no optimistic synthetic snapshot');
    expect(controller.saving, isTrue);
    expect(count, 1);
    gate.complete();
    expect(await first, isNull);
    expect(await second, isNull);
    expect(fixture.calls.map((call) => call.$2), ['r0', 'r1']);
    expect(controller.settings.fontSize, 21);
    expect(controller.settings.uiFontSize, 19);
    expect(controller.saving, isFalse);
  });

  test('a rejected update cannot roll back a previous successful write', () async {
    final fixture = SettingsFixture();
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    expect(await controller.update({'font_size': 23}), isNull);
    fixture.rejectNext = 'revision conflict; reload';
    expect(await controller.update({'ui_font_size': 25}), contains('revision conflict'));
    expect(controller.settings.fontSize, 23);
    expect(controller.settings.uiFontSize, 14);
    expect(controller.settings.revision, 'r1');
    expect(fixture.calls.length, 2, reason: 'no automatic retry after conflict');
  });

  test('explicit refresh observes another client and a failed read retains known values', () async {
    final fixture = SettingsFixture();
    var failRead = false;
    final controller = CoreSettingsController(
      reader: () async {
        if (failRead) throw StateError('profile read unavailable');
        return fixture.snapshot;
      }, writer: fixture.write,
    );
    addTearDown(controller.dispose);
    await controller.load();
    fixture.values['font_size'] = 27;
    fixture.revision++;
    await controller.load();
    expect(controller.settings.fontSize, 27);
    failRead = true;
    await controller.load();
    expect(controller.settings.fontSize, 27);
    expect(controller.loaded, isTrue);
    expect(controller.error, contains('unavailable'));
  });

  test('font presenter reads and writes the same service without private preference writes', () async {
    final old = jsonEncode({'uiSize': 10, 'terminalSize': 28, 'imported': []});
    SharedPreferences.setMockInitialValues({'xenterm.fonts.v1': old});
    final fixture = SettingsFixture();
    final controller = fixture.controller();
    final fonts = AppFonts()..bindSettings(controller);
    addTearDown(fonts.dispose);
    addTearDown(controller.dispose);
    await fonts.load();
    expect(fonts.terminalSize, 13, reason: 'legacy values need explicit review');
    fonts.setTerminalSize(22);
    await Future<void>.delayed(Duration.zero);
    expect(fixture.calls.single.$1, {'font_size': 22});
    expect(fonts.terminalSize, 22);
    expect(fonts.uiSize, 14);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('xenterm.fonts.v1'), old);
    final restarted = AppFonts()..bindSettings(fixture.controller());
    addTearDown(restarted.dispose);
    expect(restarted.terminalSize, 22);
  });

  test('legacy preview preserves exact legal values and source keys without automatic import', () async {
    final old = jsonEncode({'uiSize': 28.0, 'terminalSize': 10.0,
      'uiFamily': 'fixture-ui', 'terminalFamily': '', 'imported': []});
    SharedPreferences.setMockInitialValues({
      'xenterm.fonts.v1': old, 'xenterm.language': 'zh', 'xenterm.theme.light': false,
    });
    final preview = await readLegacyAppearancePreferences();
    expect(preview, {
      'language': 'zh', 'theme_pref': 'dark', 'ui_font_size': 28,
      'font_size': 10, 'ui_font_family': 'fixture-ui', 'font_family': '',
    });
    final fixture = SettingsFixture();
    final controller = fixture.controller();
    addTearDown(controller.dispose);
    expect(fixture.calls, isEmpty);
    expect(await controller.update({'ui_font_size': preview['ui_font_size']}), isNull);
    expect(fixture.values['ui_font_size'], 28);
    expect(fixture.values['language'], 'system', reason: 'only selected fields were imported');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('xenterm.fonts.v1'), old);
    expect(prefs.getString('xenterm.language'), 'zh');
    expect(prefs.getBool('xenterm.theme.light'), isFalse);
  });
}
