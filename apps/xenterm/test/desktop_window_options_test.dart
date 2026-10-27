import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xenterm_app/main.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS uses an AppKit-owned titlebar outside the Flutter content', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final options = desktopWindowOptions;
    // window_manager 0.5.2 removes .fullSizeContentView for normal, rather than
    // relying on a guessed traffic-light width or Flutter-only empty padding.
    expect(options.titleBarStyle, TitleBarStyle.normal);
    expect(options.windowButtonVisibility, isTrue);
    expect(options.minimumSize, const Size(940, 600));
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    test('$platform retains the hidden native titlebar', () {
      debugDefaultTargetPlatformOverride = platform;
      final options = desktopWindowOptions;
      expect(options.titleBarStyle, TitleBarStyle.hidden);
      expect(options.minimumSize, const Size(940, 600));
    });
  }
}
