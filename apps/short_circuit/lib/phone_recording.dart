part of 'main.dart';

// Recording a voice note on the phone itself, with no Circuit needed. The Kotlin
// PhoneRecorderService captures and encrypts the audio (the same CNT1 format Circuit
// writes, so playback, transcription and backup open it with the code they already
// have); this file owns the key, the note and the screen.

const _phoneRecorder = MethodChannel('circuit/phone_recorder');
const _phoneRecorderEvents = EventChannel('circuit/phone_recorder_events');

/// A recording shorter than this is not worth keeping as a note.
const _shortestPhoneRecording = Duration(seconds: 1);

/// The key and note numbers for recordings made on this phone.
///
/// They are separate from Circuit's on purpose: the encryption must never see the
/// same note number twice under one key, and Circuit chooses its own numbers. Here a
/// number is the larger of "last one + 1" and the seconds since 2026, so it grows even
/// if the saved counter is lost, and a restored backup carries the key forward.
class PhoneRecordingIds {
  const PhoneRecordingIds._();

  static const keyPreference = 'phone_key_id';
  static const lastNotePreference = 'phone_last_note_id';
  static final _epoch = DateTime.utc(2026);

  /// This phone's recording key, made on first use. An existing key is never replaced.
  static Future<({int keyId, Uint8List key})> key(
    SharedPreferences preferences,
  ) async {
    final saved = preferences.getInt(keyPreference);
    if (saved != null) {
      final key = await NoteKeys.get(saved);
      if (key != null) return (keyId: saved, key: key);
    }
    final random = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    var id = 0;
    do {
      id =
          random.nextInt(0x7ffffffe) +
          1; // fits the signed 32-bit id Kotlin takes
    } while (await NoteKeys.has(id));
    await NoteKeys.save(id, key);
    await preferences.setInt(keyPreference, id);
    return (keyId: id, key: key);
  }

  static int numberAfter(int last, DateTime now) =>
      max(last + 1, now.toUtc().difference(_epoch).inSeconds);

  static Future<int> nextNote(
    SharedPreferences preferences, {
    DateTime? now,
  }) async {
    final number = numberAfter(
      preferences.getInt(lastNotePreference) ?? 0,
      now ?? DateTime.now(),
    );
    await preferences.setInt(lastNotePreference, number);
    return number;
  }
}

String phoneRecordingClock(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final minutes = seconds ~/ 60;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
}

/// What the person is told when a recording ends for a reason other than their Stop.
String? phoneRecordingEndMessage(String? reason) => switch (reason) {
  'limit' => 'Stopped at 10 minutes. Your note is saved.',
  'storage' =>
    'Storage is nearly full, so the recording stopped. Your note is saved.',
  'error' ||
  'interrupted' => 'The recording was interrupted. What was recorded is saved.',
  _ => null,
};

String phoneRecordingFailureMessage(String? reason) => switch (reason) {
  'storage' =>
    'Not enough free storage to record. Free some space and try again.',
  'microphone' => 'The microphone is busy or unavailable. Close other apps using it and try again.',
  _ => 'Could not start recording. Please try again.',
};

mixin _PhoneRecordingState {
  /// The running recording as the service last reported it, or null.
  final ValueNotifier<Map<String, dynamic>?> _phoneRecording = ValueNotifier(
    null,
  );
  StreamSubscription<dynamic>? _phoneRecorderSubscription;
  bool _phoneSheetOpen = false;
  final Set<String> _phoneSaving = {};
}

extension _PhoneRecording on _CircuitHomePageState {
  bool get _phoneRecordingActive => _phoneRecording.value != null;

  void _listenForPhoneRecording() {
    _phoneRecorderSubscription = _phoneRecorderEvents
        .receiveBroadcastStream()
        .listen(_handlePhoneRecorderEvent, onError: (Object _) {});
    unawaited(_recoverPhoneRecording());
  }

  /// A recording that ended while the app was closed (stopped from the notification,
  /// reached its limit, or the system ended the service) is still on disk. Save it.
  Future<void> _recoverPhoneRecording() async {
    try {
      final snapshot = await _phoneRecorder.invokeMapMethod<String, dynamic>(
        'snapshot',
      );
      if (snapshot != null &&
          (snapshot['state'] == 'recording' || snapshot['state'] == 'paused')) {
        _phoneRecording.value = Map<String, dynamic>.from(snapshot);
        return;
      }
      final pending = await _phoneRecorder.invokeMapMethod<String, dynamic>(
        'pending',
      );
      if (pending == null) return;
      await _saveFinishedPhoneRecording(
        path: pending['path'] as String?,
        durationMs: (pending['durationMs'] as num?)?.toInt() ?? 0,
        startedAt: (pending['startedAt'] as num?)?.toInt() ?? 0,
        reason: pending['reason'] as String?,
      );
    } on PlatformException {
      // The recorder is only unavailable if the native side is missing.
    }
  }

  Future<void> _startPhoneRecording() async {
    if (_phoneRecordingActive) {
      _openPhoneRecorder();
      return;
    }
    var permission = await Permission.microphone.status;
    if (!permission.isGranted) {
      permission = await Permission.microphone.request();
    }
    if (!permission.isGranted) {
      if (!mounted) return;
      final blocked = permission.isPermanentlyDenied;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            blocked
                ? 'Microphone access is off. Turn it on in the phone settings to record.'
                : 'Short-Circuit needs the microphone to record a note.',
          ),
          action: blocked
              ? SnackBarAction(label: 'Settings', onPressed: openAppSettings)
              : null,
        ),
      );
      return;
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      final ids = await PhoneRecordingIds.key(preferences);
      final number = await PhoneRecordingIds.nextNote(preferences);
      final directory = await _phoneRecorder.invokeMethod<String>('directory');
      final path = '$directory/phone-note-$number.cnote';
      _phoneRecording.value = {
        'state': 'starting',
        'elapsedMs': 0,
        'level': 0.0,
        'path': path,
      };
      await _phoneRecorder.invokeMethod<void>('start', {
        'path': path,
        'key': base64Encode(ids.key),
        'keyId': ids.keyId,
        'noteId': number,
      });
      Telemetry.event('phone_record_started');
      _openPhoneRecorder();
      // The service reports back within a moment; if it never does, do not stay stuck.
      unawaited(
        Future<void>.delayed(const Duration(seconds: 5), () {
          if (_phoneRecording.value?['state'] == 'starting') {
            _phoneRecording.value = null;
            _closePhoneRecorderSheet();
            _setStatus('Could not start recording.');
          }
        }),
      );
    } catch (error) {
      _phoneRecording.value = null;
      _setStatus('Could not start recording.');
      debugPrint('Short-Circuit: phone recording failed to start: $error');
    }
  }

  Future<void> _handlePhoneRecorderEvent(dynamic event) async {
    if (event is! Map) return;
    final data = Map<String, dynamic>.from(event);
    switch (data['state']) {
      case 'recording':
      case 'paused':
        // Keeps the note's path from when it started.
        _phoneRecording.value = {...?_phoneRecording.value, ...data};
      case 'failed':
        _phoneRecording.value = null;
        _closePhoneRecorderSheet();
        Telemetry.event('phone_record_failed', {
          'reason': (data['reason'] as String? ?? 'unknown'),
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                phoneRecordingFailureMessage(data['reason'] as String?),
              ),
            ),
          );
        }
      case 'discarded':
        _phoneRecording.value = null;
        _closePhoneRecorderSheet();
        unawaited(_phoneRecorder.invokeMethod<void>('clearPending'));
      case 'stopped':
        _phoneRecording.value = null;
        _closePhoneRecorderSheet();
        await _saveFinishedPhoneRecording(
          path: data['path'] as String?,
          durationMs: (data['durationMs'] as num?)?.toInt() ?? 0,
          startedAt: (data['startedAt'] as num?)?.toInt() ?? 0,
          reason: data['reason'] as String?,
        );
    }
  }

  /// Turns a finished recording into a note, then starts transcription if it is on.
  Future<void> _saveFinishedPhoneRecording({
    required String? path,
    required int durationMs,
    required int startedAt,
    required String? reason,
  }) async {
    if (path == null || !_phoneSaving.add(path)) return;
    try {
      await _saveFinishedPhoneRecordingNow(
        path: path,
        durationMs: durationMs,
        startedAt: startedAt,
        reason: reason,
      );
    } finally {
      _phoneSaving.remove(path);
    }
  }

  Future<void> _saveFinishedPhoneRecordingNow({
    required String path,
    required int durationMs,
    required int startedAt,
    required String? reason,
  }) async {
    final file = File(path);
    final exists = await file.exists();
    if (!exists || durationMs < _shortestPhoneRecording.inMilliseconds) {
      if (exists) await file.delete();
      await _phoneRecorder.invokeMethod<void>('clearPending');
      if (mounted && reason == 'stopped') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Nothing was recorded.')));
      }
      return;
    }
    if (_notes.any((note) => note.audioPath == path)) {
      await _phoneRecorder.invokeMethod<void>('clearPending');
      return;
    }
    final note = CircuitNote(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: startedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(startedAt)
          : DateTime.now(),
      status: 'Saved on this phone.',
      audioPath:
          path, // set at creation: a note without audio is treated as lost
    );
    final notes = [note, ..._notes];
    final preferences = await SharedPreferences.getInstance();
    await _writeSecret(
      preferences,
      _notesKey,
      jsonEncode(notes.map((item) => item.toJson()).toList()),
    );
    // Only now is the note stored, so only now is the recording no longer "pending".
    await _phoneRecorder.invokeMethod<void>('clearPending');
    if (mounted) _update(() => _notes = notes);
    Telemetry.event('phone_record_saved', {
      'minutes': (durationMs / 60000).round(),
      'ended': reason ?? 'stopped',
    });
    final message = phoneRecordingEndMessage(reason);
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    if (!_geminiConnected) {
      await _setNoteStatus(note.id, 'Saved. Add a Gemini key to transcribe.');
    } else if (_autoTranscribe) {
      await _setNoteStatus(note.id, 'Saved. Transcription starting…');
      await _transcribeNote(note.id);
    } else {
      await _setNoteStatus(note.id, 'Saved. Ready to transcribe.');
    }
  }

  void _openPhoneRecorder() {
    if (_phoneSheetOpen || !mounted) return;
    _phoneSheetOpen = true;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => PhoneRecorderSheet(
        recording: _phoneRecording,
        onPause: () => _phoneRecorder.invokeMethod<void>('pause'),
        onResume: () => _phoneRecorder.invokeMethod<void>('resume'),
        onStop: () => _phoneRecorder.invokeMethod<void>('stop'),
        onDiscard: () => _phoneRecorder.invokeMethod<void>('discard'),
      ),
    ).whenComplete(() => _phoneSheetOpen = false);
  }

  void _closePhoneRecorderSheet() {
    if (_phoneSheetOpen && mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
  }
}

class PhoneRecorderSheet extends StatelessWidget {
  const PhoneRecorderSheet({
    required this.recording,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onDiscard,
  });

  final ValueNotifier<Map<String, dynamic>?> recording;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final VoidCallback onDiscard;

  Future<void> _confirmDiscard(BuildContext context, int elapsedMs) async {
    // A few seconds is not worth a question; anything longer might be someone's work.
    if (elapsedMs < 5000) {
      onDiscard();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text('It will be deleted and cannot be recovered.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Keep recording'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true) onDiscard();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: recording,
      builder: (context, data, _) {
        final state = data?['state'] as String? ?? 'starting';
        final elapsed = (data?['elapsedMs'] as num?)?.toInt() ?? 0;
        final level = ((data?['level'] as num?)?.toDouble() ?? 0).clamp(
          0.0,
          1.0,
        );
        final paused = state == 'paused';
        final interrupted = data?['interrupted'] == true;
        final limitMs = (data?['limitMs'] as num?)?.toInt() ?? 600000;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          decoration: BoxDecoration(
            color: Sc.bg,
            borderRadius: BorderRadius.circular(24),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ScEyebrow(
                    paused ? 'Paused' : 'Recording on this phone',
                  ),
                ),
                const SizedBox(height: 10),
                Semantics(
                  label:
                      '${paused ? 'Paused' : 'Recording'}, ${phoneRecordingClock(elapsed)}',
                  excludeSemantics: true,
                  child: Center(
                    child: Text(
                      phoneRecordingClock(elapsed),
                      style: const TextStyle(
                        fontSize: 56,
                        fontWeight: FontWeight.w300,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    interrupted
                        ? 'Paused because another app is using the microphone.'
                        : 'Stops by itself at ${phoneRecordingClock(limitMs)}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: interrupted ? Sc.orange : Sc.muted),
                  ),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: paused ? 0 : max(level, .04),
                    minHeight: 6,
                    color: Sc.accent,
                    backgroundColor: Sc.line,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: () => _confirmDiscard(context, elapsed),
                        icon: const Icon(LucideIcons.trash2, size: 18),
                        label: const Text('Discard'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: state == 'starting'
                            ? null
                            : (paused ? onResume : onPause),
                        icon: Icon(
                          paused ? LucideIcons.mic : LucideIcons.pause,
                          size: 18,
                        ),
                        label: Text(paused ? 'Resume' : 'Pause'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 52),
                    backgroundColor: Sc.accent,
                  ),
                  onPressed: state == 'starting' ? null : onStop,
                  icon: const Icon(LucideIcons.check, size: 20),
                  label: const Text('Stop and save'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
