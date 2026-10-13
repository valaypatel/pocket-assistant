part of '../main.dart';

/// What is going on in the background, shown on every screen from one overlay (MaterialApp.builder):
///  - a pill under the status bar for the one thing that needs attention most:
///    a recording (on Circuit or on this phone) before a sync problem before a sync in progress;
///  - a snackbar above the navigation bar for playback (on this phone or on Circuit).
/// The home page builds both and publishes them after each of its builds.
final ValueNotifier<Widget?> statusPill = ValueNotifier(null);
final ValueNotifier<Widget?> statusSnack = ValueNotifier(null);

/// False while a page (a note's own page, say) is open over Home. On the main pages the playback
/// bar is part of the page's bottom area (above Capture a thought), so nothing is covered; on a
/// pushed page, which has no such area, the overlay floats it just above the bottom edge.
final ValueNotifier<bool> statusOnTabPage = ValueNotifier(true);

/// Watches the pages pushed over Home so the snackbar knows where the bottom of the screen is.
class StatusRouteObserver extends NavigatorObserver {
  void _set(Route<dynamic>? top) {
    final onTabPage = top == null || top.isFirst || top is! PageRoute;
    if (statusOnTabPage.value == onTabPage) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => statusOnTabPage.value = onTabPage,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _set(newRoute);
}

final statusRouteObserver = StatusRouteObserver();

/// True while a sheet that sits where the pill is (the full recording view) is open.
final ValueNotifier<bool> statusPillHidden = ValueNotifier(false);

class StatusOverlay extends StatefulWidget {
  const StatusOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<StatusOverlay> createState() => _StatusOverlayState();
}

class _StatusOverlayState extends State<StatusOverlay> {
  // Its own Overlay: this sits above the app's Navigator, and anything inside it that needs an
  // Overlay (a tooltip on the Stop button, say) would otherwise find none.
  late final OverlayEntry _entry = OverlayEntry(builder: _content);

  @override
  void didUpdateWidget(StatusOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);

  Widget _content(BuildContext context) {
    final media = MediaQuery.of(context);
    final still = media.disableAnimations;
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        Positioned(
          top: media.padding.top + 8,
          left: 12,
          right: 12,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListenableBuilder(
                listenable: Listenable.merge([statusPill, statusPillHidden]),
                builder: (context, _) => AnimatedSwitcher(
                  duration: still
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, -.4),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: statusPillHidden.value
                      ? const SizedBox.shrink(key: ValueKey('hidden'))
                      : (statusPill.value ??
                            const SizedBox.shrink(key: ValueKey('none'))),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: media.padding.bottom + 16,
          left: 12,
          right: 12,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListenableBuilder(
                listenable: Listenable.merge([statusSnack, statusOnTabPage]),
                builder: (context, _) => AnimatedSwitcher(
                  duration: still
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, .4),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: statusOnTabPage.value
                      ? const SizedBox.shrink(key: ValueKey('none'))
                      : (statusSnack.value ??
                            const SizedBox.shrink(key: ValueKey('none'))),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A dark pill: an icon, one line of what is happening, an optional second line, an optional
/// action, and an optional progress bar along the bottom. Tapping the pill opens the place to deal
/// with it.
class StatusPillBar extends StatelessWidget {
  const StatusPillBar({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.progress,
    this.actionLabel,
    this.onAction,
    this.warning = false,
    required this.onTap,
    this.semanticHint,
  });

  final IconData icon;
  final String title;
  final String? detail;

  /// 0 to 100 once known; null shows no bar.
  final int? progress;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool warning;
  final VoidCallback onTap;
  final String? semanticHint;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: detail == null ? title : '$title, $detail',
      hint: semanticHint,
      onTap: onTap,
      child: Material(
        color: context.sc.dark,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        elevation: 4,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: warning ? context.sc.orange : Colors.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            if (detail != null)
                              Text(
                                detail!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xffc9ccd2),
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (actionLabel != null)
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: context.sc.accent,
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: onAction,
                        child: Text(actionLabel!),
                      ),
                  ],
                ),
              ),
              if (progress != null)
                LinearProgressIndicator(
                  value: progress!.clamp(0, 100) / 100,
                  minHeight: 3,
                  color: context.sc.accent,
                  backgroundColor: const Color(0xff2d3036),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bottom snackbar for playback on Circuit: what it is doing and a Stop.
class StatusSnackBar extends StatelessWidget {
  const StatusSnackBar({
    super.key,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: text,
      child: Material(
        color: context.sc.dark,
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Icon(icon, size: 20, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: ExcludeSemantics(
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
              if (actionLabel != null)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: context.sc.accent,
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _StatusUi on _CircuitHomePageState {
  void _publishStatusUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      statusPill.value = _statusPill();
      statusSnack.value = _statusSnack();
    });
  }

  /// One pill, most urgent first: a recording, a sync that needs attention, a sync in progress.
  Widget? _statusPill() {
    if (_recordingAudio) {
      return KeyedSubtree(
        key: const ValueKey('recording-circuit'),
        child: _recordingIsland(),
      );
    }
    final recording = _phoneRecording.value;
    if (recording != null) {
      final paused = recording['state'] == 'paused';
      final elapsed = (recording['elapsedMs'] as num?)?.toInt() ?? 0;
      return StatusPillBar(
        key: const ValueKey('recording-phone'),
        icon: paused ? LucideIcons.pause : LucideIcons.mic,
        title: paused ? 'Paused' : 'Recording on this phone',
        detail: phoneRecordingClock(elapsed),
        actionLabel: 'Stop',
        onAction: () => _phoneRecorder.invokeMethod<void>('stop'),
        onTap: _startPhoneRecording, // opens the controls while recording
        semanticHint: 'Opens the recording controls',
      );
    }
    final syncing = _syncActive || _syncingNoteId != null;
    // Notes and the Circuit page show a sync in their own status.
    if (_page == _AppPage.notes || _page == _AppPage.circuit) return null;
    if (_syncError != null && !syncing) {
      return StatusPillBar(
        key: const ValueKey('sync-error'),
        icon: LucideIcons.refreshCwOff,
        title: 'Sync needs attention',
        detail: _syncError,
        warning: true,
        actionLabel: 'Retry',
        onAction: _retrySync,
        onTap: () => _goTo(_AppPage.circuit),
        semanticHint: 'Opens Circuit',
      );
    }
    if (syncing) {
      final progress = _syncProgress;
      return StatusPillBar(
        key: const ValueKey('syncing'),
        icon: LucideIcons.refreshCw,
        title: progress == null
            ? 'Syncing from Circuit'
            : 'Syncing from Circuit · $progress%',
        progress: progress,
        onTap: () => _goTo(_AppPage.circuit),
        semanticHint: 'Opens Circuit',
      );
    }
    return null;
  }

  /// Playback: a note playing on this phone (with its own controls) or on Circuit.
  Widget? _statusSnack() {
    final playing = _nowPlaying.value;
    if (playing != null) {
      return Material(
        key: const ValueKey('playback-phone'),
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: NowPlayingBar(
          playing: playing,
          onPause: _pauseNowPlaying,
          onResume: _resumeNowPlaying,
          onStop: _stopNowPlaying,
          onSeek: _seekNowPlaying,
        ),
      );
    }
    // The Circuit page already shows playback in its own card.
    if (_circuitPlayback == CircuitPlaybackPhase.idle ||
        _page == _AppPage.circuit) {
      return null;
    }
    final stoppable =
        _circuitPlayback == CircuitPlaybackPhase.playing &&
        _circuitPlaybackSupportsStop;
    return StatusSnackBar(
      key: const ValueKey('playback-circuit'),
      icon: LucideIcons.audioLines,
      text: (_circuitPlaybackFeedback ?? '').isEmpty
          ? 'Playing on Circuit'
          : _circuitPlaybackFeedback!,
      actionLabel: stoppable ? 'Stop' : null,
      onAction: _stopCircuitPlayback,
    );
  }
}
