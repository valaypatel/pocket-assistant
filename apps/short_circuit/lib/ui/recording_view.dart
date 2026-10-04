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
