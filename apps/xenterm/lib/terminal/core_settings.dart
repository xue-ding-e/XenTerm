/// Shared, observable core settings for the Flutter shell.
///
/// The Rust settings service is also called by CLI/MCP. This controller only
/// serializes protocol requests and publishes confirmed snapshots; it never
/// duplicates validation, merges a full document, or rolls stale values back
/// over a later successful write.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/native_bridge.dart';

typedef SettingsReader = Future<CoreSettings> Function();
typedef SettingsWriter = Future<CoreSettingsWriteResult> Function(
  Map<String, dynamic> values,
  String expectedRevision,
);

class CoreSettingsController extends ChangeNotifier {
  final SettingsReader _reader;
  final SettingsWriter _writer;
  CoreSettings settings = const CoreSettings();
  bool loaded = false;
  String? error;
  bool _disposed = false;
  int _pendingWrites = 0;
  Future<void> _tail = Future.value();
  Future<void>? _refreshing;
  bool get saving => _pendingWrites > 0;

  /// Read-only provenance shown only in an explicit user-selected import.
  Map<String, dynamic> legacyPreferencePreview = const {};

  CoreSettingsController({SettingsReader? reader, SettingsWriter? writer})
      : _reader = reader ?? loadSettingsFromCore,
        _writer = writer ?? ((values, revision) => saveSettingsToCore(
          values, expectedRevision: revision,
        ));

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (failure, stack) {
        result.completeError(failure, stack);
      }
    });
    return result.future;
  }

  Future<void> load({bool clearError = true}) {
    final refreshing = _refreshing;
    if (refreshing != null) return refreshing;
    final next = _enqueue(() async {
      try {
        final snapshot = await _reader();
        final changed = !loaded || snapshot.revision != settings.revision;
        settings = snapshot;
        loaded = true;
        final hadError = error != null;
        if (clearError) error = null;
        if (changed || (clearError && hadError)) _changed();
      } catch (failure) {
        error = failure is NativeBridgeError ? failure.message : '$failure';
        _changed();
      }
    });
    _refreshing = next;
    next.whenComplete(() { if (identical(_refreshing, next)) _refreshing = null; });
    return next;
  }

  Future<String?> update(Map<String, dynamic> values) {
    final patch = Map<String, dynamic>.unmodifiable(values);
    _pendingWrites++;
    _changed();
    return _enqueue(() async {
      try {
        if (!loaded) {
          error = 'Settings are not loaded. Reload before changing them.';
          return error;
        }
        error = null;
        final result = await _writer(patch, settings.revision);
        if (!result.ok) {
          error = result.error ?? 'Could not save settings';
          // A conflict/error never authorizes silently replaying the mutation.
          return error;
        }
        settings = result.settings!;
        loaded = true;
        return null;
      } catch (failure) {
        error = '$failure';
        return error;
      } finally {
        _pendingWrites--;
        _changed();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
