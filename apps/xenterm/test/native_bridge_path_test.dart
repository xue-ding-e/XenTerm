import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';

void main() {
  test('bridge primary path matches the released desktop bundle', () {
    final name = Platform.isWindows
        ? 'xenterm_bridge.dll'
        : Platform.isMacOS
        ? 'libxenterm_bridge.dylib'
        : 'libxenterm_bridge.so';
    final executable = File.fromUri(
      Directory.systemTemp.uri.resolve(
        Platform.isMacOS
            ? 'XenTerm%20build/XenTerm.app/Contents/MacOS/xenterm_app'
            : 'XenTerm%20build/bundle/xenterm',
      ),
    ).path;
    final expected = File.fromUri(
      Directory.systemTemp.uri.resolve(
        Platform.isMacOS
            ? 'XenTerm%20build/XenTerm.app/Contents/Frameworks/$name'
            : Platform.isWindows
            ? 'XenTerm%20build/bundle/$name'
            : 'XenTerm%20build/bundle/lib/$name',
      ),
    ).path;
    expect(NativeBridge.libraryPathForExecutable(executable, name), expected);
  });

  test('macOS uses Frameworks before the adjacent local-build layout', () {
    expect(
      NativeBridge.libraryPathsForExecutable(
        '/Applications/XenTerm 测试 #100%.app/Contents/MacOS/xenterm_app',
        'libxenterm_bridge.dylib',
        operatingSystem: 'macos',
      ),
      [
        '/Applications/XenTerm 测试 #100%.app/Contents/Frameworks/'
            'libxenterm_bridge.dylib',
        '/Applications/XenTerm 测试 #100%.app/Contents/MacOS/'
            'libxenterm_bridge.dylib',
      ],
    );
  });

  test('macOS flat builds do not search outside their executable directory', () {
    expect(
      NativeBridge.libraryPathsForExecutable(
        '/tmp/XenTerm build/xenterm',
        'libxenterm_bridge.dylib',
        operatingSystem: 'macos',
      ),
      ['/tmp/XenTerm build/libxenterm_bridge.dylib'],
    );
  });

  test('Linux uses bundle/lib before the adjacent local-build layout', () {
    expect(
      NativeBridge.libraryPathsForExecutable(
        '/opt/XenTerm 测试 #100%/bundle/xenterm',
        'libxenterm_bridge.so',
        operatingSystem: 'linux',
      ),
      [
        '/opt/XenTerm 测试 #100%/bundle/lib/libxenterm_bridge.so',
        '/opt/XenTerm 测试 #100%/bundle/libxenterm_bridge.so',
      ],
    );
  });

  test('Windows still uses only the DLL alongside the executable', () {
    expect(
      NativeBridge.libraryPathsForExecutable(
        r'C:\Program Files\XenTerm 测试 #100%\xenterm.exe',
        'xenterm_bridge.dll',
        operatingSystem: 'windows',
      ),
      [r'C:\Program Files\XenTerm 测试 #100%\xenterm_bridge.dll'],
    );
  });

  test('Windows UNC bundle paths retain their server and share', () {
    expect(
      NativeBridge.libraryPathsForExecutable(
        r'\\server\share\XenTerm build\xenterm.exe',
        'xenterm_bridge.dll',
        operatingSystem: 'windows',
      ),
      [r'\\server\share\XenTerm build\xenterm_bridge.dll'],
    );
  });

  for (final os in ['macos', 'linux', 'windows']) {
    final executable = switch (os) {
      'macos' => '/Applications/XenTerm.app/Contents/MacOS/xenterm_app',
      'windows' => r'C:\Program Files\XenTerm\xenterm.exe',
      _ => '/opt/XenTerm/bundle/xenterm',
    };
    final name = switch (os) {
      'macos' => 'libxenterm_bridge.dylib',
      'windows' => 'xenterm_bridge.dll',
      _ => 'libxenterm_bridge.so',
    };
    final packaged = switch (os) {
      'macos' => '/Applications/XenTerm.app/Contents/Frameworks/$name',
      'windows' => 'C:\\Program Files\\XenTerm\\$name',
      _ => '/opt/XenTerm/bundle/lib/$name',
    };

    test('$os opens a bridge present only in the released bundle layout', () {
      final opened = <String>[];
      final fakeLibrary = Object();
      expect(
        NativeBridge.loadLibrary(
          executable: executable,
          name: name,
          operatingSystem: os,
          libraryExists: (path) => path == packaged,
          openLibrary: (path) {
            opened.add(path);
            return fakeLibrary;
          },
        ),
        same(fakeLibrary),
      );
      expect(opened, [packaged]);
    });
  }

  test('an adjacent Linux development bridge remains supported', () {
    const adjacent = '/opt/XenTerm/bundle/libxenterm_bridge.so';
    expect(
      NativeBridge.loadLibrary(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        libraryExists: (path) => path == adjacent,
        openLibrary: (path) => path,
      ),
      adjacent,
    );
  });

  test('an adjacent macOS development bridge remains supported', () {
    const adjacent =
        '/Applications/XenTerm.app/Contents/MacOS/libxenterm_bridge.dylib';
    expect(
      NativeBridge.loadLibrary(
        executable: '/Applications/XenTerm.app/Contents/MacOS/xenterm_app',
        name: 'libxenterm_bridge.dylib',
        operatingSystem: 'macos',
        libraryExists: (path) => path == adjacent,
        openLibrary: (path) => path,
      ),
      adjacent,
    );
  });

  test('the packaged bridge wins when both candidates are valid', () {
    final opened = <String>[];
    const packaged = '/opt/XenTerm/bundle/lib/libxenterm_bridge.so';
    expect(
      NativeBridge.loadLibrary(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        libraryExists: (_) => true,
        openLibrary: (path) {
          opened.add(path);
          return path;
        },
      ),
      packaged,
    );
    expect(opened, [packaged]);
  });

  test('a candidate inspection error is preserved without fallback', () {
    final inspected = <String>[];
    expect(
      () => NativeBridge.loadLibrary<Object>(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        libraryExists: (path) {
          inspected.add(path);
          throw StateError('synthetic permission denied');
        },
        openLibrary: (_) => fail('must not open after inspection failure'),
      ),
      throwsA(
        isA<NativeBridgeError>()
            .having(
              (error) => error.message,
              'attempted path',
              contains('/opt/XenTerm/bundle/lib/libxenterm_bridge.so'),
            )
            .having(
              (error) => error.message,
              'original inspection failure',
              contains('synthetic permission denied'),
            ),
      ),
    );
    expect(inspected, ['/opt/XenTerm/bundle/lib/libxenterm_bridge.so']);
  });

  test('a present but broken packaged bridge never falls back to a stale one', () {
    final opened = <String>[];
    expect(
      () => NativeBridge.loadLibrary<Object>(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        libraryExists: (_) => true,
        openLibrary: (path) {
          opened.add(path);
          throw ArgumentError('synthetic dependency not found');
        },
      ),
      throwsA(
        isA<NativeBridgeError>()
            .having(
              (error) => error.message,
              'attempted path',
              contains('/opt/XenTerm/bundle/lib/libxenterm_bridge.so'),
            )
            .having(
              (error) => error.message,
              'original loader failure',
              contains('synthetic dependency not found'),
            ),
      ),
    );
    expect(opened, ['/opt/XenTerm/bundle/lib/libxenterm_bridge.so']);
  });

  test('missing libraries report every trusted location without opening any', () {
    expect(
      () => NativeBridge.loadLibrary<Object>(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        libraryExists: (_) => false,
        openLibrary: (_) => fail('must not load a nonexistent candidate'),
      ),
      throwsA(
        isA<NativeBridgeError>().having(
          (error) => error.message,
          'searched paths',
          'xenterm_bridge library not found. Searched: '
              '/opt/XenTerm/bundle/lib/libxenterm_bridge.so, '
              '/opt/XenTerm/bundle/libxenterm_bridge.so',
        ),
      ),
    );
  });

  test('an explicit override is authoritative even when it fails to load', () {
    final opened = <String>[];
    expect(
      () => NativeBridge.loadLibrary<Object>(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        overridePath: '/explicit/test-only-bridge.so',
        libraryExists: (_) => fail('override must go directly to the loader'),
        openLibrary: (path) {
          opened.add(path);
          throw ArgumentError('synthetic wrong architecture');
        },
      ),
      throwsA(
        isA<NativeBridgeError>().having(
          (error) => error.message,
          'original loader failure',
          contains('synthetic wrong architecture'),
        ),
      ),
    );
    expect(opened, ['/explicit/test-only-bridge.so']);
  });

  test('a successful explicit override bypasses bundle discovery', () {
    const override = '/explicit/test-only-bridge.so';
    expect(
      NativeBridge.loadLibrary(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        overridePath: override,
        libraryExists: (_) => fail('override must go directly to the loader'),
        openLibrary: (path) => path,
      ),
      override,
    );
  });

  test('an empty override uses the packaged bridge', () {
    const packaged = '/opt/XenTerm/bundle/lib/libxenterm_bridge.so';
    expect(
      NativeBridge.loadLibrary(
        executable: '/opt/XenTerm/bundle/xenterm',
        name: 'libxenterm_bridge.so',
        operatingSystem: 'linux',
        overridePath: '',
        libraryExists: (path) => path == packaged,
        openLibrary: (path) => path,
      ),
      packaged,
    );
  });
}
