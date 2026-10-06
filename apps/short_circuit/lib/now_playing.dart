part of 'main.dart';

// The player bar: while a note plays, a bar above the bottom navigation shows which note,
// where it is, and lets the person pause or resume, stop, or move to another point. It is
// only there while something plays, so it never takes space otherwise.

/// What is playing right now, as the player last reported it.
class NowPlaying {
  const NowPlaying({
    required this.title,
    this.state = 'playing',
    this.positionMs = 0,
    this.durationMs = 0,
    this.part,
    this.parts,
  });

  final String title;

  /// For a long note stored as several parts: which one is playing, of how many.
  final int? part;
  final int? parts;

  /// 'playing' or 'paused'.
  final String state;
  final int positionMs;
  final int durationMs;

  bool get paused => state == 'paused';

  NowPlaying copyWith({String? state, int? positionMs, int? durationMs}) =>
      NowPlaying(
        title: title,
        state: state ?? this.state,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        part: part,
        parts: parts,
      );
}

/// The bar's next state from a status report, or null once playback is over: it finished
/// ('completed'), was stopped (by the person, or by leaving the app), or never started.
NowPlaying? nextNowPlaying(NowPlaying current, Map<String, dynamic>? status) {
  final state = status?['state'] as String?;
  if (state != 'playing' && state != 'paused') return null;
  return current.copyWith(
    state: state,
    positionMs: (status?['positionMs'] as num?)?.toInt() ?? current.positionMs,
    durationMs: (status?['durationMs'] as num?)?.toInt() ?? current.durationMs,
  );
}

mixin _NowPlayingState {
  final ValueNotifier<NowPlaying?> _nowPlaying = ValueNotifier(null);
  Timer? _nowPlayingTimer;

  /// A long note is playing as a series of parts: between two of them the player reports
  /// "completed", which must not take the bar down.
  bool _sequencePlaying = false;
}

extension _NowPlayingControls on _CircuitHomePageState {
  void _startNowPlaying(String title, {int? part, int? parts}) {
    _nowPlaying.value = NowPlaying(title: title, part: part, parts: parts);
    _nowPlayingTimer?.cancel();
    _nowPlayingTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _pollNowPlaying(),
    );
    unawaited(_pollNowPlaying());
  }

  Future<void> _pollNowPlaying() async {
    final current = _nowPlaying.value;
    if (current == null) {
      _nowPlayingTimer?.cancel();
      return;
    }
    try {
      final status = await _relayChannel.invokeMapMethod<String, dynamic>(
        'playbackStatus',
      );
      final next = nextNowPlaying(current, status);
      if (next == null && _sequencePlaying) return; // between two parts
      _nowPlaying.value = next;
      if (next == null) _nowPlayingTimer?.cancel();
    } on PlatformException {
      _nowPlaying.value = null;
      _nowPlayingTimer?.cancel();
    }
  }

  Future<void> _pauseNowPlaying() async {
    await _relayChannel.invokeMethod<bool>('pausePlayback');
    await _pollNowPlaying();
  }

  Future<void> _resumeNowPlaying() async {
    await _relayChannel.invokeMethod<bool>('resumePlayback');
    await _pollNowPlaying();
  }

  Future<void> _stopNowPlaying() async {
    _playbackToken++; // ends a part-by-part playback too
    _sequencePlaying = false;
    _nowPlaying.value = null;
    _nowPlayingTimer?.cancel();
    await _relayChannel.invokeMethod<void>('stopPlayback');
  }

  Future<void> _seekNowPlaying(int positionMs) async {
    await _relayChannel.invokeMethod<void>('seekPlayback', {
      'positionMs': positionMs,
    });
    await _pollNowPlaying();
  }

  /// The bar when something plays, or nothing.
  Widget _nowPlayingBar() => ValueListenableBuilder<NowPlaying?>(
    valueListenable: _nowPlaying,
    builder: (context, playing, _) => playing == null
        ? const SizedBox.shrink()
        : NowPlayingBar(
            playing: playing,
            onPause: _pauseNowPlaying,
            onResume: _resumeNowPlaying,
            onStop: _stopNowPlaying,
            onSeek: _seekNowPlaying,
          ),
  );
}

String nowPlayingClock(int milliseconds) {
  final seconds = (milliseconds < 0 ? 0 : milliseconds) ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class NowPlayingBar extends StatefulWidget {
  const NowPlayingBar({
    super.key,
    required this.playing,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onSeek,
  });

  final NowPlaying playing;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final ValueChanged<int> onSeek;

  @override
  State<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<NowPlayingBar> {
  /// While a finger is on the slider it shows the finger, not the player.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final playing = widget.playing;
    final duration = max(playing.durationMs, 1);
    final position = (_dragging ?? playing.positionMs.toDouble()).clamp(
      0.0,
      duration.toDouble(),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      decoration: const BoxDecoration(
        color: Sc.surface,
        border: Border(top: BorderSide(color: Sc.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playing.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${playing.parts == null ? '' : 'Part ${playing.part} of ${playing.parts} · '}'
                      '${nowPlayingClock(position.round())} / '
                      '${nowPlayingClock(playing.durationMs)}'
                      '${playing.paused ? ' · Paused' : ''}',
                      style: const TextStyle(color: Sc.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: playing.paused ? 'Resume' : 'Pause',
                iconSize: 26,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: playing.paused ? widget.onResume : widget.onPause,
                icon: Icon(
                  playing.paused ? LucideIcons.play : LucideIcons.pause,
                ),
              ),
              IconButton(
                tooltip: 'Stop',
                iconSize: 24,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: widget.onStop,
                icon: const Icon(LucideIcons.square),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Sc.accent,
              thumbColor: Sc.accent,
              inactiveTrackColor: Sc.line,
            ),
            child: Slider(
              value: position,
              max: duration.toDouble(),
              semanticFormatterCallback: (value) =>
                  '${nowPlayingClock(value.round())} of '
                  '${nowPlayingClock(playing.durationMs)}',
              onChanged: playing.durationMs <= 0
                  ? null
                  : (value) => setState(() => _dragging = value),
              onChangeEnd: (value) {
                setState(() => _dragging = null);
                widget.onSeek(value.round());
              },
            ),
          ),
        ],
      ),
    );
  }
}
