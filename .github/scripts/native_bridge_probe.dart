// Standalone validation of the actual packaged bridge. This is deliberately
// not a Flutter UI smoke test and never calls configuration/session APIs.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:xenterm_app/bridge/native_bridge.dart';

typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

void main(List<String> arguments) {
  if (!Platform.isMacOS || arguments.length != 3) {
    throw ArgumentError(
      'macOS only: native_bridge_probe.dart <app executable> '
      '<expected core version> <fresh profile path>',
    );
  }
  final executable = File(arguments[0]).absolute;
  final expectedVersion = arguments[1];
  final profile = Directory(arguments[2]).absolute;
  final runnerTemp = Platform.environment['RUNNER_TEMP'];
  if (runnerTemp == null ||
      runnerTemp.isEmpty ||
      profile.parent.path != Directory(runnerTemp).absolute.path ||
      !executable.path.startsWith('${Directory(runnerTemp).absolute.path}/')) {
    throw StateError('The probe is restricted to this CI runner temporary area');
  }
  if (!executable.path.endsWith('/XenTerm.app/Contents/MacOS/xenterm_app')) {
    throw StateError('Expected the extracted XenTerm app bundle layout');
  }
  if (!executable.existsSync()) {
    throw StateError('The packaged app executable is missing');
  }
  if (Platform.environment['XENTERM_DATA_DIR'] != profile.path) {
    throw StateError('The probe must pin its own fresh temporary profile');
  }
  if (FileSystemEntity.typeSync(profile.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Refusing to use a pre-existing profile path');
  }

  final expectedLibrary = executable.parent.parent.uri
      .resolve('Frameworks/libxenterm_bridge.dylib')
      .toFilePath();
  final opened = <String>[];
  final library = NativeBridge.loadLibrary<DynamicLibrary>(
    executable: executable.path,
    name: 'libxenterm_bridge.dylib',
    libraryExists: (path) =>
        FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound,
    openLibrary: (path) {
      opened.add(path);
      return DynamicLibrary.open(path);
    },
  );
  if (opened.length != 1 || opened.single != expectedLibrary) {
    throw StateError('The production loader did not select bundle Frameworks');
  }

  // These two exports only allocate/read/free the compiled-in version string;
  // neither calls the Rust profile/store/runtime initializer. The nonexistent
  // pinned directory is a second guard against unintended configuration work.
  final version = library.lookupFunction<_VersionNative, _VersionDart>(
    'xenterm_core_version',
  );
  final release = library.lookupFunction<_FreeNative, _FreeDart>(
    'xenterm_string_free',
  );
  final pointer = version();
  if (pointer == nullptr) throw StateError('Core version returned null');
  late final String actualVersion;
  try {
    actualVersion = pointer.toDartString();
  } finally {
    release(pointer);
  }
  if (actualVersion != expectedVersion) {
    throw StateError(
      'Wrong packaged bridge version: $actualVersion != $expectedVersion',
    );
  }
  if (FileSystemEntity.typeSync(profile.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('The version-only probe unexpectedly created a profile');
  }
  stdout.writeln(
    jsonEncode({
      'probe': 'packaged-bridge-version-only',
      'library': opened.single,
      'coreVersion': actualVersion,
      'profileCreated': false,
      'flutterUiStarted': false,
    }),
  );
}
