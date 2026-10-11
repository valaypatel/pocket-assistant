part of 'main.dart';

enum CircuitPlaybackPhase { idle, requesting, playing, stopping }

extension _CircuitPlayback on _CircuitHomePageState {
  void _playbackState(CircuitPlaybackPhase phase, String feedback) {
    if (!mounted) return;
    if (phase == CircuitPlaybackPhase.idle ||
        phase == CircuitPlaybackPhase.playing) {
      _playbackRequestTimer?.cancel();
    }
    _update(() {
      _circuitPlayback = phase;
      _circuitPlaybackFeedback = feedback;
    });
  }

  bool _applyCircuitPlaybackStatus(String status) {
    if (status.startsWith('Playing latest recording')) {
      _playbackState(CircuitPlaybackPhase.playing, 'Playing on Circuit');
    } else if (status.startsWith('Playback complete') ||
        status.startsWith('Playback stopped') ||
        status.startsWith('Playback failed')) {
      _playbackState(CircuitPlaybackPhase.idle, status);
    } else if (status.startsWith('Audio is busy') &&
        (_circuitPlayback == CircuitPlaybackPhase.requesting ||
            _circuitPlayback == CircuitPlaybackPhase.stopping)) {
      _playbackState(
        CircuitPlaybackPhase.idle,
        'Circuit is busy. Try again when it finishes.',
      );
    } else {
      return false;
    }
    return true;
  }

  /// Circuit says whether it is recording. An indicator left over from a recording that a restart
  /// of the board cut short (no "saved" or "stopped" ever arrives) is cleared here.
  void _applyCircuitRecordingSnapshot(String message) {
    final recording = RegExp(
      r'^recording=(\w+)$',
      multiLine: true,
    ).firstMatch(message)?.group(1);
    if (recording == 'idle' && _recordingAudio) {
      _update(() {
        _recordingAudio = false;
        _recordingStartedAt = null;
        _songClipArmed = false;
      });
    }
  }

  void _applyCircuitPlaybackSnapshot(String message) {
    _applyCircuitRecordingSnapshot(message);
    if (message.contains('\nplayback_stop=1')) {
      _update(() => _circuitPlaybackSupportsStop = true);
    }
    final state = RegExp(
      r'^playback=(\w+)$',
      multiLine: true,
    ).firstMatch(message)?.group(1);
    if (state == 'playing') {
      // A status query also recovers playback when the app resumes or a BLE
      // notification was missed. Do not undo a Stop that is awaiting its reply.
      if (_circuitPlayback == CircuitPlaybackPhase.stopping) return;
      final ms =
          int.tryParse(
            RegExp(
                  r'^playback_ms=(\d+)$',
                  multiLine: true,
                ).firstMatch(message)?.group(1) ??
                '',
          ) ??
          0;
      _playbackState(
        CircuitPlaybackPhase.playing,
        'Playing on Circuit · ${phoneRecordingClock(ms)}',
      );
    } else if (state == 'idle' &&
        (_circuitPlayback == CircuitPlaybackPhase.playing ||
            _circuitPlayback == CircuitPlaybackPhase.stopping)) {
      _playbackState(CircuitPlaybackPhase.idle, 'Playback ended on Circuit');
    }
  }

  Future<void> _playAudio() => _requestCircuitPlayback(stop: false);
  Future<void> _stopCircuitPlayback() => _requestCircuitPlayback(stop: true);

  Future<void> _requestCircuitPlayback({required bool stop}) async {
    if (_audioBusy || _recordingAudio) return;
    if (stop
        ? !_circuitPlaybackSupportsStop ||
              _circuitPlayback != CircuitPlaybackPhase.playing
        : _circuitPlayback != CircuitPlaybackPhase.idle) {
      return;
    }
    final pending = stop
        ? CircuitPlaybackPhase.stopping
        : CircuitPlaybackPhase.requesting;
    _playbackState(
      pending,
      stop ? 'Stopping playback…' : 'Requesting playback…',
    );
    _playbackRequestTimer?.cancel();
    _playbackRequestTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _circuitPlayback != pending) return;
      // A failed Stop must not pretend that the board has stopped.
      _playbackState(
        stop ? CircuitPlaybackPhase.playing : CircuitPlaybackPhase.idle,
        stop
            ? 'Circuit did not confirm Stop. Try again.'
            : 'Circuit did not confirm playback. Try again.',
      );
    });
    try {
      await _writeCircuit(stop ? '@audio-play-stop' : '@audio-play');
    } catch (error) {
      if (_circuitPlayback != pending) return;
      _playbackState(
        stop ? CircuitPlaybackPhase.playing : CircuitPlaybackPhase.idle,
        'Could not ${stop ? 'stop playback' : 'play recording'}: $error',
      );
    }
  }
}
