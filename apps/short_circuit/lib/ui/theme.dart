part of '../main.dart';

/// Shared palette and components for the complete Short-Circuit redesign.
class Sc {
  static const bg = Color(0xfffffdf9);
  static const ink = Color(0xff15171b);
  static const muted = Color(0xff71675e);
  static const faint = Color(0xff71675e);
  static const line = Color(0xffebe5de);
  static const surface = Color(0xfff2f0eb);
  static const hero = Color(0xfff4e8d9);
  static const warmCard = Color(0xfff4eee7);
  static const accent = Color(0xfff05b3d);
  static const accentInk = Color(0xffa93c27);
  static const accentSoft = Color(0xfffff0e8);
  static const tileBg = Color(0xffffe8d7);
  static const tileInk = Color(
    0xffa5522a,
  ); // darkened from d46a36: 3.0:1 became 4.6:1 on tileBg
  static const chip = Color(0xffe8e9e6);
  static const dark = Color(0xff17191d);
  static const green = Color(0xff299b68);
  static const orange = Color(
    0xffd27e32,
  ); // darkened from e58a37: 2.6:1 became 3.05:1 on bg
  static const danger = Color(0xffb34732);
  static const dangerSoft = Color(0xfffff0eb);
  static const neutralButton = Color(0xffeee9e3);
  static const neutralInk = Color(0xff604f42);
  static const circuitCard = Color(0xffe8f0e9);
  static const circuitMark = Color(0xff26342a);
  static const circuitMarkInk = Color(0xffe5f5bc);
}

/// The light theme: every value is the one the app has always used.
ThemeData buildScTheme() => _buildTheme(ScPalette.light, Brightness.light);

/// The dark theme (defined, not yet switched on in the app: see ShortCircuitApp).
ThemeData buildScDarkTheme() =>
    _buildTheme(ScPalette.darkMode, Brightness.dark);

ThemeData _buildTheme(ScPalette p, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // 14 is the radius inputs have always had; the token scale (ScRadius) takes over as screens are redone.
  const radius = BorderRadius.all(Radius.circular(14));
  final border = OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: dark ? p.line : const Color(0xffe4ddd5)),
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Roboto',
    extensions: [ScColors(p)],
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      primary: p.accent,
      surface: p.bg,
    ),
    scaffoldBackgroundColor: p.bg,
    textTheme: (dark ? ThemeData.dark() : ThemeData.light()).textTheme.apply(
      fontFamily: 'Roboto',
      bodyColor: p.ink,
      displayColor: p.ink,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? p.surface : Colors.white,
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: p.accent, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.dark,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w600,
        fontSize: 13,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? p.surface : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor:
            p.accentInk, // the bright accent is under 4.5:1 as text
        textStyle: ScType.label.copyWith(fontFamily: 'Roboto'),
        minimumSize: const Size(48, 48),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.accent
            : (dark ? const Color(0xff4a443d) : const Color(0xffd4cec7)),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
  );
}

const _scTitle = TextStyle(
  fontSize: 34,
  height: 1.08,
  fontWeight: FontWeight.w600,
  letterSpacing: -1.4,
);

/// The Circuit device icon (assets/brand/circuit-device.svg): the board with a waveform on its
/// screen and a recording dot. Drawn from the app's own device colours (context.sc.circuitMark,
/// context.sc.circuitMarkInk, context.sc.accent), and used wherever the device is named. Decorative.
class ScDeviceMark extends StatelessWidget {
  const ScDeviceMark({super.key, this.size = 43});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size,
      height: size,
      child: const CustomPaint(painter: _DeviceMarkPainter()),
    ),
  );
}

class _DeviceMarkPainter extends CustomPainter {
  const _DeviceMarkPainter();

  // Waveform bars on the icon's 1024 canvas: x, y, height (40 wide).
  static const _bars = [
    (364.0, 437.0, 56.0),
    (428.0, 395.0, 140.0),
    (492.0, 351.0, 228.0),
    (556.0, 407.0, 116.0),
    (620.0, 441.0, 48.0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 1024);
    RRect box(double x, double y, double w, double h, double r) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));
    final dark = Paint()..color = Sc.circuitMark;
    final light = Paint()..color = Sc.circuitMarkInk;
    canvas.drawRRect(box(0, 0, 1024, 1024, 224), dark);
    canvas.drawRRect(box(270, 230, 484, 564, 114), light);
    canvas.drawRRect(box(318, 278, 388, 366, 68), dark);
    for (final (x, y, h) in _bars) {
      canvas.drawRRect(box(x, y, 40, h, 20), light);
    }
    canvas.drawCircle(const Offset(512, 714), 34, dark);
    canvas.drawCircle(const Offset(512, 714), 15, Paint()..color = Sc.accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The brand icon (assets/brand/app-icon.svg) drawn from the app's own colours, so it stays
/// sharp at any size: a coral rounded square, a cream speech bubble, five ink waveform bars.
/// Decorative: it carries no meaning of its own, so screen readers skip it.
class ScBrandMark extends StatelessWidget {
  const ScBrandMark({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size,
      height: size,
      child: const CustomPaint(painter: _BrandMarkPainter()),
    ),
  );
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter();

  // Geometry on the icon's 1024 x 1024 canvas.
  static const _bars = [
    (356.0, 445.0, 94.0),
    (424.0, 399.0, 186.0),
    (492.0, 360.0, 264.0),
    (560.0, 417.0, 150.0),
    (628.0, 455.0, 74.0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 1024;
    canvas.scale(k);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 1024, 1024),
        const Radius.circular(224),
      ),
      Paint()..color = Sc.accent,
    );
    final bubble = Path()
      ..moveTo(390, 280)
      ..lineTo(634, 280)
      ..cubicTo(708, 280, 752, 324, 752, 398)
      ..lineTo(752, 586)
      ..cubicTo(752, 660, 708, 704, 634, 704)
      ..lineTo(478, 704)
      ..lineTo(342, 774)
      ..lineTo(342, 694)
      ..cubicTo(296, 678, 272, 640, 272, 586)
      ..lineTo(272, 398)
      ..cubicTo(272, 324, 316, 280, 390, 280)
      ..close();
    canvas.drawPath(bubble, Paint()..color = Sc.bg);
    final ink = Paint()..color = Sc.ink;
    for (final (x, y, h) in _bars) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, 40, h),
          const Radius.circular(20),
        ),
        ink,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Small uppercase label above a title.
class ScEyebrow extends StatelessWidget {
  const ScEyebrow(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: context.sc.muted,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 1,
    ),
  );
}

class ScTitle extends StatelessWidget {
  const ScTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: _scTitle);
}

/// Responsive section heading with a labeled, accessible action.
class ScSectionRow extends StatelessWidget {
  const ScSectionRow(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              letterSpacing: -.5,
            ),
          ),
        ),
        if (action != null)
          Flexible(
            child: TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: context.sc.accentInk,
                minimumSize: const Size(48, 48),
              ),
              child: Text(action!, textAlign: TextAlign.end),
            ),
          ),
      ],
    ),
  );
}

/// Small grey caps label used above grouped rows.
class ScGroupLabel extends StatelessWidget {
  const ScGroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: context.sc.muted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: .9,
      ),
    ),
  );
}

/// Back arrow (icon button) with an optional eyebrow on the right.
class ScBackRow extends StatelessWidget {
  const ScBackRow({
    super.key,
    required this.label,
    required this.onBack,
    this.eyebrow,
  });
  final String label;
  final VoidCallback onBack;
  final String? eyebrow;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TextButton.icon(
          onPressed: onBack,
          icon: const Icon(LucideIcons.arrowLeft, size: 18),
          label: Text(label),
          style: TextButton.styleFrom(
            foregroundColor: context.sc.neutralInk,
            padding: const EdgeInsets.only(right: 12),
            minimumSize: const Size(48, 48),
          ),
        ),
        if (eyebrow != null)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: ScEyebrow(eyebrow!),
            ),
          ),
      ],
    ),
  );
}

enum ScTone { neutral, primary, danger, dark }

/// Square-rounded icon-only button. The tooltip doubles as the screen-reader
/// label and as the long-press hint, so the icon never has to carry text.
class ScIconButton extends StatelessWidget {
  const ScIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.tone = ScTone.neutral,
    this.busy = false,
    this.size = 48,
    this.expand = false,
    this.caption,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final ScTone tone;
  final bool busy;
  final double size;

  /// Stretch to the available width (one primary action per screen).
  final bool expand;

  /// Optional one-word caption under the icon, for actions whose icon alone
  /// would be ambiguous (device actions). Not used for obvious icons.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final (bg, fg) = switch (tone) {
      ScTone.primary => (context.sc.accent, context.sc.ink),
      ScTone.danger => (context.sc.dangerSoft, context.sc.danger),
      ScTone.dark => (context.sc.ink, context.sc.bg),
      ScTone.neutral => (context.sc.neutralButton, context.sc.neutralInk),
    };
    final targetSize = size < 48 ? 48.0 : size;
    final button = Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: enabled ? bg : context.sc.neutralButton,
          borderRadius: BorderRadius.circular(size * .3),
          child: InkWell(
            borderRadius: BorderRadius.circular(size * .3),
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              width: expand ? double.infinity : targetSize,
              height: targetSize,
              child: Center(
                child: busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: enabled ? fg : context.sc.muted,
                        ),
                      )
                    : expand
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              icon,
                              size: 18,
                              color: enabled ? fg : context.sc.muted,
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                caption ?? tooltip,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: enabled ? fg : context.sc.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : Icon(
                        icon,
                        size: 20,
                        color: enabled ? fg : context.sc.muted,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    if (caption == null || expand) return button;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: Text(
            caption!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.sc.muted,
            ),
          ),
        ),
      ],
    );
  }
}

/// Dialogs name the consequence in a visible text action.
List<Widget> scDialogActions(
  BuildContext context, {
  required IconData confirmIcon,
  required String confirmTooltip,
  required VoidCallback onConfirm,
  VoidCallback? onCancel,
  bool danger = false,
}) => [
  TextButton(
    onPressed: onCancel ?? () => Navigator.pop(context, null),
    child: const Text('Cancel'),
  ),
  Tooltip(
    message: confirmTooltip,
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: danger ? context.sc.danger : context.sc.ink,
        foregroundColor: danger
            ? (ThemeData.estimateBrightnessForColor(context.sc.danger) ==
                      Brightness.dark
                  ? Colors.white
                  : context.sc.bg)
            : context.sc.bg,
        minimumSize: const Size(48, 48),
      ),
      onPressed: onConfirm,
      icon: Icon(confirmIcon, size: 18),
      label: Text(confirmTooltip),
    ),
  ),
];

/// Action controls reflow rather than clipping at narrow widths or large text.
class ScActionBar extends StatelessWidget {
  const ScActionBar({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 16,
    alignment: WrapAlignment.spaceBetween,
    children: children,
  );
}

/// A tonal surface reserved for a primary summary or device status.
class ScPanel extends StatelessWidget {
  const ScPanel({super.key, required this.child, this.color = Sc.hero});
  final Widget child;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

/// Quiet divided row with a tinted icon, title, subtitle and optional trailing widget.
class ScTile extends StatelessWidget {
  const ScTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.meta = const [],
    this.status,
    this.statusIcon,
    this.statusColor,
    this.trailing,
    this.onTap,
    this.footer,
    this.subtitleColor,
    this.badge,
  });
  final IconData icon;
  final String title;

  /// One line of detail, for tiles that are not notes. A note passes [meta] and [status] instead.
  final String subtitle;

  /// Short facts shown under the title, joined with " · " (when it was made, how long, where from).
  final List<String> meta;

  /// Where the item stands ("Transcription ready", "Sync failed"), on its own line under [meta].
  final String? status;
  final IconData? statusIcon;
  final Color? statusColor;

  /// A small marker for the corner of the icon, such as where a note was recorded.
  final Widget? badge;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget? footer;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final p = context.sc;
    final detail = meta.isNotEmpty ? meta.join(' · ') : subtitle;
    final detailColor = subtitleColor ?? p.muted;
    return Material(
      color: p.bg,
      shape: Border(bottom: BorderSide(color: p.line)),
      child: InkWell(
        borderRadius: ScRadius.cardBorder,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: ScSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: ScRadius.inputBorder,
                        ),
                        child: Icon(icon, size: 22, color: p.accentInk),
                      ),
                      if (badge != null)
                        Positioned(right: -6, bottom: -6, child: badge!),
                    ],
                  ),
                  const SizedBox(width: ScSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ScType.body.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 22 / 16,
                          ),
                        ),
                        if (detail.isNotEmpty) ...[
                          const SizedBox(height: ScSpace.xs / 2),
                          Text(
                            detail,
                            style: ScType.caption.copyWith(
                              color: detailColor,
                              height: 1.4,
                            ),
                          ),
                        ],
                        if (status != null && status!.isNotEmpty) ...[
                          const SizedBox(height: ScSpace.xs),
                          Row(
                            children: [
                              if (statusIcon != null) ...[
                                Icon(
                                  statusIcon,
                                  size: 14,
                                  color: statusColor ?? p.muted,
                                ),
                                const SizedBox(width: ScSpace.xs),
                              ],
                              Flexible(
                                child: Text(
                                  status!,
                                  style: ScType.caption.copyWith(
                                    color: statusColor ?? p.muted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: ScSpace.sm),
                    trailing!,
                  ],
                ],
              ),
              if (footer != null) ...[
                const SizedBox(height: ScSpace.sm),
                // In line with the title and text, not under the icon.
                Padding(
                  padding: const EdgeInsets.only(left: 44 + ScSpace.md),
                  child: footer!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small labelled action under a list row ("Transcribe", "Sync now"). The label says what it does, so
/// nothing is a bare icon, and it sits in line with the row's text.
class ScActionChip extends StatelessWidget {
  const ScActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.sc;
    final enabled = onPressed != null && !busy;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: p.neutralButton,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: enabled ? onPressed : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: ScSpace.md + 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: p.neutralInk,
                        ),
                      )
                    else
                      Icon(icon, size: 16, color: p.neutralInk),
                    const SizedBox(width: ScSpace.sm),
                    Text(
                      label,
                      style: ScType.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: enabled ? p.neutralInk : p.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum ScStripTone { neutral, progress, danger, good }

/// One line of status at the top of a list: what is true right now and, when it helps, what to do.
/// Colours come from the theme, so it follows dark mode. A problem or a running sync is announced to
/// screen readers when it appears.
class ScStatusStrip extends StatelessWidget {
  const ScStatusStrip({
    super.key,
    required this.tone,
    required this.title,
    this.detail,
    this.leading,
    this.progress,
    this.showProgress = false,
    this.actions = const [],
  });

  final ScStripTone tone;
  final String title;
  final String? detail;
  final IconData? leading;

  /// 0 to 1 for a determinate bar; with [showProgress] and no value the bar is indeterminate.
  final double? progress;
  final bool showProgress;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = context.sc;
    final (background, accent) = switch (tone) {
      ScStripTone.neutral => (p.surface, p.muted),
      ScStripTone.progress => (p.hero, p.accent),
      ScStripTone.danger => (p.dangerSoft, p.danger),
      ScStripTone.good => (p.circuitCard, p.green),
    };
    final titleColor = tone == ScStripTone.danger ? p.danger : p.ink;
    final stacked = MediaQuery.textScalerOf(context).scale(14) > 19;
    return Semantics(
      container: true,
      liveRegion: tone == ScStripTone.danger || tone == ScStripTone.progress,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ScSpace.md + 2,
          vertical: ScSpace.md,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: ScRadius.inputBorder,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (tone == ScStripTone.progress)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  )
                else if (leading != null)
                  ExcludeSemantics(
                    child: Icon(leading, size: 20, color: accent),
                  ),
                const SizedBox(width: ScSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: ScType.label.copyWith(color: titleColor),
                      ),
                      if (detail != null && detail!.isNotEmpty)
                        Text(
                          detail!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: ScType.caption.copyWith(color: p.ink),
                        ),
                    ],
                  ),
                ),
                // Beside the text normally; under it when text is large and there is no room.
                if (actions.isNotEmpty && !stacked) ...[
                  const SizedBox(width: ScSpace.sm),
                  ...actions,
                ],
              ],
            ),
            if (actions.isNotEmpty && stacked)
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(spacing: ScSpace.sm, children: actions),
              ),
            if (showProgress) ...[
              const SizedBox(height: ScSpace.md),
              ClipRRect(
                borderRadius: ScRadius.pillBorder,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  color: accent,
                  backgroundColor: p.bg,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Round dark play button.
class ScPlayButton extends StatelessWidget {
  const ScPlayButton({super.key, required this.onPressed, this.active = false});
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => Material(
    color: onPressed == null ? context.sc.chip : context.sc.ink,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onPressed,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Icon(
          active ? LucideIcons.pause : LucideIcons.play,
          size: 18,
          color: onPressed == null ? context.sc.muted : context.sc.bg,
        ),
      ),
    ),
  );
}

class ScStat extends StatelessWidget {
  const ScStat({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 77),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.sc.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: context.sc.muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -1,
          ),
        ),
      ],
    ),
  );
}

/// Row used in settings and device pages: title + small caption, value or chevron.
class ScRow extends StatelessWidget {
  const ScRow({
    super.key,
    required this.title,
    this.caption,
    this.value,
    this.valueColor,
    this.onTap,
    this.trailing,
  });
  final String title;
  final String? caption;
  final String? value;
  final Color? valueColor;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: ScSpace.lg),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.sc.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: ScType.body.copyWith(
                    fontWeight: FontWeight.w500,
                    color: context.sc.ink,
                  ),
                ),
                if (caption != null) ...[
                  const SizedBox(height: ScSpace.xs / 2),
                  Text(
                    caption!,
                    style: ScType.caption.copyWith(color: context.sc.muted),
                  ),
                ],
              ],
            ),
          ),
          if (value != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                value!,
                textAlign: TextAlign.end,
                style: ScType.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: valueColor ?? context.sc.muted,
                ),
              ),
            ),
          ?trailing,
          if (onTap != null && trailing == null && value == null)
            Icon(LucideIcons.chevronRight, size: 18, color: context.sc.muted),
        ],
      ),
    ),
  );
}

/// Full-width soft button; `danger` for destructive actions.
class ScButton extends StatelessWidget {
  const ScButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.primary = false,
    this.icon,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  /// The one main action on a screen: the accent colour.
  final bool primary;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.sc;
    final disabled = onPressed == null && !busy;
    final background = primary
        ? (disabled ? p.neutralButton : p.accent)
        : (danger ? p.dangerSoft : p.neutralButton);
    final foreground = disabled
        ? p.muted
        : primary
        ? p.onAccent
        : (danger ? p.danger : p.neutralInk);
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: background,
        borderRadius: ScRadius.inputBorder,
        child: InkWell(
          borderRadius: ScRadius.inputBorder,
          onTap: busy ? null : onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ScSpace.lg,
                vertical: ScSpace.md,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: foreground,
                      ),
                    )
                  else if (icon != null)
                    Icon(icon, size: 18, color: foreground),
                  if (busy || icon != null) const SizedBox(width: ScSpace.sm),
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: ScType.label.copyWith(color: foreground),
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
}

/// Persistent destinations stay in one place while notes and devices update.
class ScNavBar extends StatelessWidget {
  const ScNavBar({super.key, required this.index, required this.onSelect});
  final int index;
  final ValueChanged<int> onSelect;

  static const _items = [
    (LucideIcons.fileText, 'Notes'),
    (LucideIcons.squareCheck, 'Tasks'),
    (LucideIcons.cpu, 'Circuit'),
    (LucideIcons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.sc;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            ScSpace.md,
            ScSpace.sm,
            ScSpace.md,
            ScSpace.sm,
          ),
          child: Row(
            children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == index,
                    button: true,
                    child: TextButton(
                      onPressed: () => onSelect(i),
                      style: TextButton.styleFrom(
                        foregroundColor: i == index ? p.accentInk : p.muted,
                        backgroundColor: i == index ? p.accentSoft : p.bg,
                        minimumSize: const Size(48, 60),
                        padding: const EdgeInsets.symmetric(
                          vertical: ScSpace.sm,
                          horizontal: ScSpace.xs,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: ScRadius.inputBorder,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_items[i].$1, size: 22),
                          const SizedBox(height: ScSpace.xs),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _items[i].$2,
                              maxLines: 1,
                              style: ScType.caption.copyWith(
                                fontWeight: FontWeight.w600,
                                fontFamily: 'Roboto',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small read-only label for categories (filled) and tags (outlined).
class ScChip extends StatelessWidget {
  const ScChip(this.text, {super.key, this.tag = false});
  final String text;
  final bool tag;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: tag ? Colors.transparent : context.sc.accentSoft,
      borderRadius: BorderRadius.circular(99),
      border: tag ? Border.all(color: context.sc.line) : null,
    ),
    child: Text(
      tag ? '#$text' : text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: tag ? context.sc.neutralInk : context.sc.accentInk,
      ),
    ),
  );
}

/// Masked credentials and passphrases share one accessible reveal control.
class ScSecretField extends StatefulWidget {
  const ScSecretField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
  });
  final TextEditingController controller;
  final String label;
  final bool enabled;
  @override
  State<ScSecretField> createState() => _ScSecretFieldState();
}

class _ScSecretFieldState extends State<ScSecretField> {
  bool _obscure = true;
  @override
  void didUpdateWidget(ScSecretField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _obscure = true;
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    enabled: widget.enabled,
    obscureText: _obscure,
    enableSuggestions: false,
    autocorrect: false,
    decoration: InputDecoration(
      labelText: widget.label,
      suffixIcon: IconButton(
        tooltip: '${_obscure ? 'Show' : 'Hide'} ${widget.label.toLowerCase()}',
        onPressed: widget.enabled
            ? () => setState(() => _obscure = !_obscure)
            : null,
        icon: Icon(_obscure ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
      ),
    ),
  );
}
