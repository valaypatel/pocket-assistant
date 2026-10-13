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

class _CaptureDockState extends State<CaptureDock>
    with TickerProviderStateMixin {
  // 0 = the pill, 1 = the full-width bar. 0 = label showing, 1 = icon only.
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    value: widget.mode == DockMode.recording ? 1 : 0,
  );
  late final AnimationController _collapse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.collapsed ? 1 : 0,
  );
  Timer? _tick;
  bool _still = false;

  @override
  void initState() {
    super.initState();
    _syncTick();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.of(context).disableAnimations;
  }

  void _go(AnimationController c, double target) {
    if (_still) {
      c.value = target;
    } else {
      c.animateTo(target, curve: Curves.linear);
    }
  }

  @override
  void didUpdateWidget(CaptureDock old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _go(_morph, widget.mode == DockMode.recording ? 1 : 0);
      _syncTick();
      if (widget.mode == DockMode.recording) {
        SemanticsService.sendAnnouncement(
          View.of(context),
          'Recording started',
          Directionality.of(context),
        );
      }
    }
    if (old.collapsed != widget.collapsed) {
      _go(_collapse, widget.collapsed ? 1 : 0);
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
    _morph.dispose();
    _collapse.dispose();
    super.dispose();
  }

  /// Natural width of the pill with its label, so the grow into the bar is a plain interpolation.
  double _pillWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: widget.pillLabel,
        style: ScType.label.copyWith(fontFamily: 'Roboto', fontSize: 16),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return 20 + 24 + ScSpace.sm + painter.width + 20;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == DockMode.hidden) return const SizedBox.shrink();
    final expandedPill = _pillWidth(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final full = constraints.maxWidth;
        return AnimatedBuilder(
          animation: Listenable.merge([_morph, _collapse]),
          builder: (context, _) {
            final m = Curves.easeInOutCubic.transform(_morph.value);
            final c = Curves.easeOutCubic.transform(_collapse.value);
            final pillW = lerpDouble(expandedPill, 56, c)!;
            final width = lerpDouble(pillW, full, m)!;
            // Two lines of text and the padding, so large text makes the bar taller, never clipped.
            final scaler = MediaQuery.textScalerOf(context);
            final barHeight = max(
              64.0,
              scaler.scale(13 * 18 / 13) + scaler.scale(18 * 24 / 18) + 16,
            );
            final height = lerpDouble(56, barHeight, m)!;
            final barOpacity = ((m - .45) / .55).clamp(0.0, 1.0);
            final pillOpacity = (1 - m / .55).clamp(0.0, 1.0);
            return Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: Color.lerp(context.sc.accent, context.sc.ink, m),
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
                child: Stack(
                  children: [
                    if (pillOpacity > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: m > .5,
                          child: Opacity(
                            opacity: pillOpacity,
                            child: _pill(context, c, expandedPill),
                          ),
                        ),
                      ),
                    if (barOpacity > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: m <= .5,
                          child: Opacity(
                            opacity: barOpacity,
                            // Anchored to the right, where the pill was, so Stop lands under the thumb.
                            child: OverflowBox(
                              alignment: Alignment.centerRight,
                              minWidth: full,
                              maxWidth: full,
                              minHeight: barHeight,
                              maxHeight: barHeight,
                              child: _bar(context, full),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _pill(BuildContext context, double collapse, double expandedWidth) {
    final fg = context.sc.onAccent;
    final label = 1 - collapse;
    return Tooltip(
      message: widget.pillTooltip ?? widget.pillLabel,
      child: Semantics(
        button: true,
        label: widget.pillTooltip ?? widget.pillLabel,
        excludeSemantics: true,
        child: InkWell(
          onTap: widget.onPill,
          onLongPress: widget.onLongPress,
          child: Center(
            child: OverflowBox(
              maxWidth: expandedWidth,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.pillIcon, size: 24, color: fg),
                  ClipRect(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: label,
                      child: Opacity(
                        opacity: label,
                        child: Padding(
                          padding: const EdgeInsets.only(left: ScSpace.sm),
                          child: Text(
                            widget.pillLabel,
                            maxLines: 1,
                            softWrap: false,
                            style: ScType.label.copyWith(
                              fontFamily: 'Roboto',
                              fontSize: 16,
                              color: fg,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context, double full) {
    // The meter is the first thing to go when the bar is tight (a narrow phone or large text).
    final roomy =
        full >= 340 && MediaQuery.textScalerOf(context).scale(16) <= 20;
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
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            phoneRecordingClock(elapsed.inMilliseconds),
                            maxLines: 1,
                            softWrap: false,
                            style: ScType.subtitle.copyWith(
                              fontFamily: 'Roboto',
                              color: fg,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!widget.paused && roomy)
                  _LevelMeter(level: level, color: fg),
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
