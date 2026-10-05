part of '../main.dart';

/// Full-screen view shown while Circuit records. A song clip counts down to its
/// automatic stop; a voice note counts up until the user stops it.
class RecordingView extends StatelessWidget {
  const RecordingView({
    super.key,
    required this.elapsed,
    required this.song,
    required this.busy,
    required this.onStop,
  });

  final Duration elapsed;
  final bool song;
  final bool busy;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final remaining = Duration(seconds: _songClipSeconds) - elapsed;
    final shown = song
        ? (remaining.isNegative ? Duration.zero : remaining)
        : elapsed;
    final clock = '${_two(shown.inMinutes)}:${_two(shown.inSeconds % 60)}';
    // The glow breathes once a second (the screen already rebuilds each second).
    final glow = elapsed.inSeconds.isEven ? 14.0 : 26.0;
    // Scaffold gives its body loose width, so without this the column shrinks to
    // its widest line and hugs the left edge instead of centring.
    return SizedBox.expand(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Spacer(flex: 2),
            // Sized to include the glow, so it never runs into the text below.
            SizedBox(
              width: 220,
              height: 220,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeInOut,
                  width: 132,
                  height: 132,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Sc.accent),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x14f05b3d),
                        spreadRadius: glow,
                      ),
                      BoxShadow(
                        color: const Color(0x0af05b3d),
                        spreadRadius: glow * 1.7,
                      ),
                    ],
                  ),
                  child: Icon(
                    song ? LucideIcons.music : LucideIcons.circle,
                    size: 38,
                    color: Sc.accent,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              song ? 'Listening for a song' : 'Recording on Circuit',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              clock,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.5,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (song) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: SizedBox(
                  width: 180,
                  child: LinearProgressIndicator(
                    value: (elapsed.inMilliseconds / (_songClipSeconds * 1000))
                        .clamp(0.0, 1.0),
                    minHeight: 5,
                    color: Sc.accent,
                    backgroundColor: Sc.line,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              song
                  ? remaining.isNegative
                        ? 'Finishing up…'
                        : 'Hold Circuit close to the music. It stops by itself.'
                  : "Speak naturally. Press stop when you're done.",
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Sc.muted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const Spacer(flex: 3),
            // Anchored at the bottom, where a thumb reaches it.
            ScIconButton(
              size: 72,
              icon: LucideIcons.square,
              tone: ScTone.primary,
              tooltip: song ? 'Stop listening early' : 'Stop recording',
              onPressed: busy ? null : onStop,
            ),
          ],
        ),
      ),
    );
  }
}

/// "00:12": a voice note counts up, a song clip counts down to its automatic stop.
String _recordingClock(Duration elapsed, bool song) {
  final remaining = Duration(seconds: _songClipSeconds) - elapsed;
  final shown = song
      ? (remaining.isNegative ? Duration.zero : remaining)
      : elapsed;
  return '${_two(shown.inMinutes)}:${_two(shown.inSeconds % 60)}';
}

/// What a recording looks like right now, read fresh on every tick.
class RecordingSnapshot {
  const RecordingSnapshot({
    required this.active,
    required this.elapsed,
    required this.song,
    required this.busy,
  });
  final bool active;
  final Duration elapsed;
  final bool song;
  final bool busy;
}

/// The compact recording indicator: a dark pill under the status bar, so the rest of the
/// app stays usable while Circuit records. It shows the device icon, what is happening, the
/// timer and a Stop button; tapping anywhere else on it opens the full view.
class RecordingIsland extends StatelessWidget {
  const RecordingIsland({
    super.key,
    required this.elapsed,
    required this.song,
    required this.busy,
    required this.onStop,
    required this.onExpand,
  });

  final Duration elapsed;
  final bool song;
  final bool busy;
  final VoidCallback onStop;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final remaining = Duration(seconds: _songClipSeconds) - elapsed;
    final clock = _recordingClock(elapsed, song);
    final title = song ? 'Listening for a song' : 'Recording on Circuit';
    final detail = song && remaining.isNegative ? 'Finishing up…' : clock;
    final still = MediaQuery.of(context).disableAnimations;
    // The dot beats once a second; it stays solid for people who turn animation off.
    final dotOn = still || elapsed.inSeconds.isEven;
    return Semantics(
      container: true,
      button: true,
      label: title,
      hint: 'Opens the full recording view',
      onTap: onExpand,
      excludeSemantics: true,
      child: Material(
        color: Sc.dark,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onExpand,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  children: [
                    const ScDeviceMark(size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              AnimatedOpacity(
                                opacity: dotOn ? 1 : 0.3,
                                duration: still
                                    ? Duration.zero
                                    : const Duration(milliseconds: 400),
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Sc.accent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xb3ffffff),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ScIconButton(
                      size: 48,
                      icon: LucideIcons.square,
                      tone: ScTone.primary,
                      tooltip: song ? 'Stop listening early' : 'Stop recording',
                      onPressed: busy ? null : onStop,
                    ),
                  ],
                ),
              ),
              if (song)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LinearProgressIndicator(
                    value: (elapsed.inMilliseconds / (_songClipSeconds * 1000))
                        .clamp(0.0, 1.0),
                    minHeight: 3,
                    color: Sc.accent,
                    backgroundColor: const Color(0x33ffffff),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full recording view in a sheet, for when the pill is tapped. It keeps its own
/// one-second clock, closes itself when the recording ends, and Minimise leaves recording
/// running.
class RecordingSheet extends StatefulWidget {
  const RecordingSheet({super.key, required this.read, required this.onStop});

  final RecordingSnapshot Function() read;
  final Future<void> Function() onStop;

  @override
  State<RecordingSheet> createState() => _RecordingSheetState();
}

class _RecordingSheetState extends State<RecordingSheet> {
  Timer? _tick;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.read();
    if (!snapshot.active && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(LucideIcons.chevronDown, size: 18),
                label: const Text('Minimise'),
              ),
            ),
          ),
          Expanded(
            child: RecordingView(
              elapsed: snapshot.elapsed,
              song: snapshot.song,
              busy: snapshot.busy,
              onStop: () async {
                await widget.onStop();
                if (mounted) Navigator.of(context).maybePop();
              },
            ),
          ),
        ],
      ),
    );
  }
}
