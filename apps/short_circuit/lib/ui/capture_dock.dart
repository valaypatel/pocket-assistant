part of '../main.dart';

/// What the dock above the navigation bar shows. Only one thing at a time.
enum DockMode { hidden, pill, recording }

/// The one place for capturing. At rest it is a small floating pill (just the icon while the list is
/// being scrolled); while something records it grows into a full-width bar with the timer, a level
/// meter and Stop, and folds back when the recording ends. It never covers the navigation bar.
class CaptureDock extends StatefulWidget {
  const CaptureDock({
    super.key,
    required this.mode,
    this.collapsed = false,
    this.pillLabel = 'Record',
    this.pillIcon = LucideIcons.mic,
    this.pillTooltip,
    this.onPill,
    this.onLongPress,
    this.title = 'Recording',
    this.elapsed,
    this.level,
    this.paused = false,
    this.onTogglePause,
    this.onStop,
    this.onOpen,
  });

  final DockMode mode;

  /// Icon only (while scrolling down), unless a recording is showing.
  final bool collapsed;
  final String pillLabel;
  final IconData pillIcon;
  final String? pillTooltip;
  final VoidCallback? onPill;
  final VoidCallback? onLongPress;

  final String title;
  final Duration Function()? elapsed;
  final double Function()? level;
  final bool paused;
  final VoidCallback? onTogglePause;
  final VoidCallback? onStop;

  /// Tapping the bar itself opens the full controls.
  final VoidCallback? onOpen;

  @override
  State<CaptureDock> createState() => _CaptureDockState();
}

class _CaptureDockState extends State<CaptureDock> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTick();
  }

  @override
  void didUpdateWidget(CaptureDock old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _syncTick();
      if (widget.mode == DockMode.recording) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Recording started',
          Directionality.of(context),
        );
      }
    }
  }

  void _syncTick() {
    _tick?.cancel();
    _tick = null;
    if (widget.mode == DockMode.recording) {
      // The clock and the meter move without the page being rebuilt.
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.of(context).disableAnimations;
    final duration = still ? Duration.zero : const Duration(milliseconds: 260);
    if (widget.mode == DockMode.hidden) return const SizedBox.shrink();
    final recording = widget.mode == DockMode.recording;
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = constraints.maxWidth;
        return Align(
          alignment: Alignment.centerRight,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: recording ? context.sc.ink : context.sc.accent,
              borderRadius: BorderRadius.circular(ScRadius.pill),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: AnimatedSize(
              duration: duration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerRight,
              child: AnimatedSwitcher(
                duration: duration,
                child: recording
                    ? KeyedSubtree(
                        key: const ValueKey('bar'),
                        child: SizedBox(width: full, child: _bar(context)),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('pill'),
                        child: _pill(context),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pill(BuildContext context) {
    final fg = context.sc.onAccent;
    return Tooltip(
      message: widget.pillTooltip ?? widget.pillLabel,
      child: Semantics(
        button: true,
        label: widget.pillTooltip ?? widget.pillLabel,
        excludeSemantics: true,
        child: InkWell(
          onTap: widget.onPill,
          onLongPress: widget.onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56, minWidth: 56),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.collapsed ? 16 : 20,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.pillIcon, size: 24, color: fg),
                  if (!widget.collapsed) ...[
                    const SizedBox(width: ScSpace.sm),
                    Text(
                      widget.pillLabel,
                      style: ScType.label.copyWith(
                        fontFamily: 'Roboto',
                        fontSize: 16,
                        color: fg,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final fg = context.sc.bg;
    final elapsed = widget.elapsed?.call() ?? Duration.zero;
    final level = (widget.level?.call() ?? 0).clamp(0.0, 1.0);
    return Semantics(
      container: true,
      label: widget.paused ? '${widget.title}, paused' : widget.title,
      child: InkWell(
        onTap: widget.onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              ScSpace.xl,
              ScSpace.sm,
              ScSpace.sm,
              ScSpace.sm,
            ),
            child: Row(
              children: [
                _PulseDot(active: !widget.paused),
                const SizedBox(width: ScSpace.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.paused ? 'Paused' : widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ScType.caption.copyWith(
                          color: fg.withValues(alpha: .8),
                        ),
                      ),
                      ExcludeSemantics(
                        child: Text(
                          phoneRecordingClock(elapsed.inMilliseconds),
                          style: ScType.subtitle.copyWith(
                            fontFamily: 'Roboto',
                            color: fg,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!widget.paused) _LevelMeter(level: level, color: fg),
                if (widget.onTogglePause != null)
                  _BarButton(
                    icon: widget.paused ? LucideIcons.play : LucideIcons.pause,
                    tooltip: widget.paused
                        ? 'Resume recording'
                        : 'Pause recording',
                    onPressed: widget.onTogglePause,
                    color: fg,
                  ),
                _BarButton(
                  icon: LucideIcons.square,
                  tooltip: 'Stop and save',
                  onPressed: widget.onStop,
                  color: fg,
                  filled: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A red dot that breathes while recording (still when motion is reduced or the recording is paused).
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.active});
  final bool active;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final move = widget.active && !MediaQuery.of(context).disableAnimations;
    if (move && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!move) {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(_PulseDot old) {
    super.didUpdateWidget(old);
    didChangeDependencies();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: FadeTransition(
      opacity: Tween<double>(begin: .35, end: 1).animate(_controller),
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: context.sc.accent,
          shape: BoxShape.circle,
        ),
      ),
    ),
  );
}

/// Five bars that follow the microphone level.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.color});
  final double level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const shape = [.5, .8, 1.0, .8, .5];
    return ExcludeSemantics(
      child: SizedBox(
        width: 44,
        height: 28,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final s in shape)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 4,
                height: 4 + 24 * (level * s).clamp(0.0, 1.0),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .85),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.color,
    this.filled = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final bool filled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: ScSpace.xs),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        backgroundColor: filled ? context.sc.accent : Colors.transparent,
        foregroundColor: filled ? context.sc.onAccent : color,
      ),
      icon: Icon(icon, size: 20),
    ),
  );
}
