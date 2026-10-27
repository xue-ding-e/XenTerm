// Control-only helper. The integration target starts production app.main and
// exports live geometry; native_desktop_driver.py supplies actual X11 events.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class NativeDesktopSteps {
  NativeDesktopSteps()
    : runtime = Directory(_required('XENTERM_UI_TEST_RUNTIME')),
      sourceSha = _required('XENTERM_UI_TEST_SOURCE_SHA') {
    if (!runtime.isAbsolute || !runtime.existsSync()) {
      throw StateError('The isolated UI runtime must already exist');
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceSha)) {
      throw StateError('An exact tested product revision is required');
    }
    Directory('${runtime.path}/steps').createSync();
    Directory('${runtime.path}/acks').createSync();
  }

  final Directory runtime;
  final String sourceSha;
  int _count = 0;

  static String _required(String name) {
    final value = Platform.environment[name];
    if (value == null || value.isEmpty) {
      throw StateError('Missing control-only test setting: $name');
    }
    return value;
  }

  Future<void> _step(
    WidgetTester tester,
    String name,
    Map<String, Object?> operation,
  ) async {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'Invalid checkpoint identifier');
    }
    final id = '${(++_count).toString().padLeft(3, '0')}-$name';
    final request = {
      ...operation,
      'pid': pid,
      'source_sha': sourceSha,
    };
    final result = await tester.runAsync<Map<String, dynamic>>(() async {
      final temporary = File('${runtime.path}/steps/$id.pending');
      await temporary.writeAsString(jsonEncode(request), flush: true);
      await temporary.rename('${runtime.path}/steps/$id.json');
      final ack = File('${runtime.path}/acks/$id.json');
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        if (await ack.exists()) {
          return (jsonDecode(await ack.readAsString()) as Map)
              .cast<String, dynamic>();
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw StateError('Native desktop checkpoint timed out: $id');
    });
    expect(result, isNotNull, reason: 'External native driver must run');
    expect(result!['ok'], isTrue, reason: '$id: ${result['error']}');
    await tester.pump(const Duration(milliseconds: 100));
    final renderingError = tester.takeException();
    if (renderingError != null) throw renderingError;
  }

  Future<void> click(
    WidgetTester tester,
    String name,
    Finder target, {
    int button = 1,
  }) async {
    expect(target.hitTestable(), findsOneWidget,
        reason: 'The semantic target must be visible before an OS click');
    final point = tester.getCenter(target);
    await _step(tester, name, {
      'operation': 'click',
      'point': [point.dx, point.dy],
      'device_pixel_ratio': tester.view.devicePixelRatio,
      'button': button,
    });
  }

  Future<void> drag(
    WidgetTester tester, String name, Offset start, Offset end,
  ) => _step(tester, name, {
    'operation': 'drag',
    'start': [start.dx, start.dy], 'end': [end.dx, end.dy],
    'device_pixel_ratio': tester.view.devicePixelRatio,
  });

  Future<void> scroll(
    WidgetTester tester, String name, Finder area, int ticks,
  ) {
    final point = tester.getCenter(area);
    return _step(tester, name, {
      'operation': 'scroll', 'point': [point.dx, point.dy], 'ticks': ticks,
      'device_pixel_ratio': tester.view.devicePixelRatio,
    });
  }

  Future<void> key(WidgetTester tester, String name, String key) =>
      _step(tester, name, {'operation': 'key', 'key': key});

  Future<void> setClipboard(WidgetTester tester, String name, String text) =>
      _step(tester, name, {'operation': 'set_clipboard', 'text': text});

  Future<void> expectClipboard(WidgetTester tester, String name, String text) =>
      _step(tester, name, {'operation': 'assert_clipboard', 'text': text});

  Future<void> enterText(
    WidgetTester tester,
    String name,
    Finder field,
    String text,
  ) async {
    await click(tester, '$name-focus', field);
    await key(tester, '$name-select', 'ctrl+a');
    await setClipboard(tester, '$name-clipboard', text);
    await key(tester, '$name-paste', 'ctrl+v');
  }

  Future<void> screenshot(WidgetTester tester, String name) =>
      _step(tester, name, {'operation': 'screenshot'});

  Future<void> resize(WidgetTester tester, String name, Size size) =>
      _step(tester, name, {
        'operation': 'resize',
        'size': [size.width.toInt(), size.height.toInt()],
      });

  Future<void> complete() async {
    if (_count == 0) throw StateError('No physical desktop steps executed');
    final temporary = File('${runtime.path}/test-complete.pending');
    await temporary.writeAsString(jsonEncode({
      'ok': true,
      'source_sha': sourceSha,
      'steps': _count,
    }), flush: true);
    await temporary.rename('${runtime.path}/test-complete.json');
  }
}
