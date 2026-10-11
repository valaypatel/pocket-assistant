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
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScEyebrow(
              song ? 'Music recognition · Circuit' : 'Recording · Circuit',
            ),
            const SizedBox(height: 14),
            Text(
              song ? 'What’s playing?' : 'Leave nothing\non your mind.',
              style: _scTitle,
            ),
            const SizedBox(height: 32),
            Center(
              child: Container(
                width: 112,
                height: 112,
                decoration: const BoxDecoration(
                  color: Sc.circuitCard,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: song
                      ? const Icon(
                          LucideIcons.music,
                          size: 40,
                          color: Sc.circuitMark,
                        )
                      : const ScDeviceMark(size: 64),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              song ? 'Listening for a song' : 'Recording on Circuit',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Sc.muted, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Text(
              clock,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 56,
                fontWeight: FontWeight.w400,
                letterSpacing: -2,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (song) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: (elapsed.inMilliseconds / (_songClipSeconds * 1000))
                    .clamp(0.0, 1.0),
                minHeight: 5,
                color: Sc.accent,
                backgroundColor: Sc.line,
              ),
            ],
            const SizedBox(height: 24),
            ScPanel(
              color: Sc.surface,
              child: Text(
                song
                    ? remaining.isNegative
                          ? 'Finishing up…'
                          : 'Hold Circuit close to the music. It stops by itself.'
                    : 'Your recording is saved on Circuit, then synced to this phone. You can keep browsing while it records.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Sc.neutralInk,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 24),
            ScIconButton(
              expand: true,
              size: 56,
              icon: LucideIcons.square,
              tone: ScTone.primary,
              busy: busy,
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
    this.decorated = true,
  });

  final Duration elapsed;
  final bool song;
  final bool busy;
  final VoidCallback onStop;
  final VoidCallback onExpand;

  /// False when something else draws the pill's shape, as RecordingMorph does while it
  /// grows from and folds back into the Circuit indicator.
  final bool decorated;

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
      // Not excludeSemantics: the Stop button inside must stay its own control for TalkBack. The
      // title and timer are skipped below so they are not read twice.
      child: Material(
        color: decorated ? Sc.dark : Colors.transparent,
        borderRadius: BorderRadius.circular(decorated ? 28 : 0),
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
                      child: ExcludeSemantics(
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
                                      fontWeight: FontWeight.w600,
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
                                fontWeight: FontWeight.w600,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
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
