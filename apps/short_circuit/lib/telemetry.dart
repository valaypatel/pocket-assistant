import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Usage events and crash reports through Firebase.
///
/// What is never sent: note text, transcripts, song titles, chat messages, key ids,
/// device addresses, API keys, or the text of an error (an error message can contain
/// a request URL with a key in it). Only the names listed in [_events], with numbers,
/// true/false values and short lowercase words, and the type and stack of a crash.
///
/// It does nothing when there is no google-services.json in the build, in debug
/// builds, in tests, or when the person has switched it off in Settings.
class Telemetry {
  const Telemetry._();

  static const preferenceKey = 'share_diagnostics';

  static const _events = {
    'note_synced',
    'transcription_done',
    'song_identified',
    'pairing_repair_needed',
    'test_report',
    'phone_record_started',
    'phone_record_saved',
    'phone_record_failed',
  };
  static final _word = RegExp(r'^[a-z0-9_]{1,24}$');

  static bool _ready = false;
  static bool _enabled = false;

  /// Whether this build has Firebase set up at all.
  static bool get available => _ready;

  /// Whether reports are being sent right now.
  static bool get enabled => _ready && _enabled;

  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      debugPrint('Short-Circuit: Firebase is not set up in this build');
      return;
    }
    _ready = true;
    final preferences = await SharedPreferences.getInstance();
    await setEnabled(preferences.getBool(preferenceKey) ?? true, save: false);

    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      previous?.call(details);
      if (enabled) unawaited(_crashlytics.recordFlutterFatalError(details));
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      // Switched off: leave the error to Flutter's normal handling, do not swallow it.
      if (!enabled) return false;
      unawaited(_crashlytics.recordError(error, stack, fatal: true));
      return true;
    };
  }

  static FirebaseCrashlytics get _crashlytics => FirebaseCrashlytics.instance;

  static Future<void> setEnabled(bool value, {bool save = true}) async {
    _enabled = value;
    if (save) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(preferenceKey, value);
    }
    if (!_ready) return;
    final collect = value && !kDebugMode;
    await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(collect);
    await _crashlytics.setCrashlyticsCollectionEnabled(collect);
  }

  static void event(String name, [Map<String, Object> parameters = const {}]) {
    if (!enabled || !_events.contains(name)) return;
    final clean = <String, Object>{};
    parameters.forEach((key, value) {
      if (value is bool) {
        clean[key] = value ? 1 : 0;
      } else if (value is num) {
        clean[key] = value;
      } else if (value is String && _word.hasMatch(value)) {
        clean[key] = value;
      }
    });
    unawaited(
      FirebaseAnalytics.instance
          .logEvent(name: name, parameters: clean)
          .catchError((Object _) {}),
    );
  }

  /// A handled error worth knowing about. Only where it happened and its type are
  /// recorded, never its message.
  static void nonFatal(String where, Object error, [StackTrace? stack]) {
    if (!enabled) return;
    unawaited(
      _crashlytics
          .recordError(
            StateError('$where: ${error.runtimeType}'),
            stack,
            reason: where,
          )
          .catchError((Object _) {}),
    );
  }

  /// Settings > "Send a test report": one event and one handled error, so the Firebase
  /// console can be checked. Returns false when nothing was sent.
  static Future<bool> sendTestReport() async {
    if (!enabled) return false;
    event('test_report');
    try {
      await _crashlytics.recordError(
        StateError('Test report from Settings'),
        StackTrace.current,
        reason: 'test_report',
      );
      await _crashlytics.sendUnsentReports();
    } catch (_) {
      return false;
    }
    return true;
  }

  /// Size in whole megabytes, so a number does not identify a note.
  static int megabytes(int bytes) => (bytes / (1024 * 1024)).round();
}
