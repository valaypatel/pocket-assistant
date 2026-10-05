part of '../main.dart';

/// Colours from the "Assistant" home exploration (prototypes/short-circuit-mobile-home).
class Sc {
  static const bg = Color(0xfffffdf9);
  static const ink = Color(0xff15171b);
  static const muted = Color(0xff827970);
  static const faint = Color(0xff8e857e);
  static const line = Color(0xffebe5de);
  static const surface = Color(0xfff2f0eb);
  static const hero = Color(0xfff4e8d9);
  static const warmCard = Color(0xfff4eee7);
  static const accent = Color(0xfff05b3d);
  static const accentInk = Color(0xffd85b3a);
  static const accentSoft = Color(0xfffff0e8);
  static const tileBg = Color(0xffffe8d7);
  static const tileInk = Color(0xffd46a36);
  static const chip = Color(0xffe8e9e6);
  static const dark = Color(0xff17191d);
  static const green = Color(0xff299b68);
  static const orange = Color(0xffe58a37);
  static const danger = Color(0xffb34732);
  static const dangerSoft = Color(0xfffff0eb);
  static const neutralButton = Color(0xffeee9e3);
  static const neutralInk = Color(0xff604f42);
  static const circuitCard = Color(0xffe8f0e9);
  static const circuitMark = Color(0xff26342a);
  static const circuitMarkInk = Color(0xffe5f5bc);
}

ThemeData buildScTheme() {
  const radius = BorderRadius.all(Radius.circular(14));
  const border = OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: Color(0xffe4ddd5)),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Sc.accent,
      brightness: Brightness.light,
      primary: Sc.accent,
      surface: Sc.bg,
    ),
    scaffoldBackgroundColor: Sc.bg,
    textTheme: ThemeData.light().textTheme.apply(
      bodyColor: Sc.ink,
      displayColor: Sc.ink,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: Sc.accent, width: 1.4),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Sc.dark,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Sc.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Sc.accent
            : const Color(0xffd4cec7),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
  );
}

const _scTitle = TextStyle(
  fontSize: 30,
  height: 1.05,
  fontWeight: FontWeight.w800,
  letterSpacing: -1.4,
);

/// The Circuit device icon (assets/brand/circuit-device.svg): the board with a waveform on its
/// screen and a recording dot. Drawn from the app's own device colours (Sc.circuitMark,
/// Sc.circuitMarkInk, Sc.accent), and used wherever the device is named. Decorative.
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
    style: const TextStyle(
      color: Color(0xff73767e),
      fontSize: 12,
      fontWeight: FontWeight.w700,
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

/// "Section name .......... action" row.
class ScSectionRow extends StatelessWidget {
  const ScSectionRow(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: -.5,
          ),
        ),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Text(
              action!,
              style: const TextStyle(
                color: Color(0xff6b55d9),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
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
      style: const TextStyle(
        color: Color(0xff77716c),
        fontSize: 11,
        fontWeight: FontWeight.w800,
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
        ScIconButton(
          icon: LucideIcons.arrowLeft,
          tooltip: 'Back to $label',
          onPressed: onBack,
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
      ScTone.primary => (Sc.accent, Colors.white),
      ScTone.danger => (Sc.dangerSoft, Sc.danger),
      ScTone.dark => (Sc.dark, Colors.white),
      ScTone.neutral => (Sc.neutralButton, Sc.neutralInk),
    };
    final button = Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: enabled ? bg : Sc.neutralButton,
          borderRadius: BorderRadius.circular(size * .3),
          child: InkWell(
            borderRadius: BorderRadius.circular(size * .3),
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              width: expand ? double.infinity : size,
              height: size,
              child: Center(
                child: busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fg,
                        ),
                      )
                    : Icon(
                        icon,
                        size: 20,
                        color: enabled ? fg : const Color(0xffb3aaa2),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    if (caption == null) return button;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: Text(
            caption!,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Sc.faint,
            ),
          ),
        ),
      ],
    );
  }
}

/// Cancel / confirm pair for dialogs, as icons. The confirm icon carries the
/// outcome (check, trash, plus) and the tooltip names it for screen readers.
List<Widget> scDialogActions(
  BuildContext context, {
  required IconData confirmIcon,
  required String confirmTooltip,
  required VoidCallback onConfirm,
  VoidCallback? onCancel,
  bool danger = false,
}) => [
  ScIconButton(
    icon: LucideIcons.x,
    tooltip: 'Cancel',
    onPressed: onCancel ?? () => Navigator.pop(context, null),
  ),
  ScIconButton(
    icon: confirmIcon,
    tooltip: confirmTooltip,
    tone: danger ? ScTone.danger : ScTone.primary,
    onPressed: onConfirm,
  ),
];

/// Evenly spaced row of icon buttons (e.g. play / review / retry / delete).
class ScActionBar extends StatelessWidget {
  const ScActionBar({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: children,
  );
}

/// Rounded tile with a tinted icon, title, subtitle and optional trailing widget.
class ScTile extends StatelessWidget {
  const ScTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.footer,
    this.subtitleColor,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget? footer;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Sc.line),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Sc.tileBg,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon, size: 19, color: Sc.tileInk),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: subtitleColor ?? const Color(0xff85878d),
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
            if (footer != null) ...[const SizedBox(height: 8), footer!],
          ],
        ),
      ),
    ),
  );
}

/// Round dark play button.
class ScPlayButton extends StatelessWidget {
  const ScPlayButton({super.key, required this.onPressed, this.active = false});
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => Material(
    color: onPressed == null ? const Color(0xffcfcac4) : Sc.dark,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onPressed,
      child: SizedBox(
        width: 31,
        height: 31,
        child: Icon(
          active ? LucideIcons.pause : LucideIcons.play,
          size: 18,
          color: Colors.white,
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
      color: Sc.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xff777a80),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
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
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xffe7e1da))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xff332d28),
                  ),
                ),
                if (caption != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    caption!,
                    style: const TextStyle(fontSize: 11, color: Sc.faint),
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
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: valueColor ?? const Color(0xff6d5e51),
                ),
              ),
            ),
          ?trailing,
          if (onTap != null && trailing == null && value == null)
            const Icon(
              LucideIcons.chevronRight,
              size: 18,
              color: Color(0xff9f968d),
            ),
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
    this.icon,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: danger ? Sc.dangerSoft : Sc.neutralButton,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: busy ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (icon != null)
                Icon(icon, size: 17, color: danger ? Sc.danger : Sc.neutralInk),
              if (busy || icon != null) const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: onPressed == null && !busy
                      ? const Color(0xffa89f97)
                      : (danger ? Sc.danger : Sc.neutralInk),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Floating bottom navigation, as in the prototype.
class ScNavBar extends StatelessWidget {
  const ScNavBar({super.key, required this.index, required this.onSelect});
  final int index;
  final ValueChanged<int> onSelect;

  static const _items = [
    (LucideIcons.house, LucideIcons.house, 'Home'),
    (LucideIcons.fileText, LucideIcons.fileText, 'Notes'),
    (LucideIcons.squareCheck, LucideIcons.squareCheck, 'Tasks'),
    (LucideIcons.settings, LucideIcons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1a252b35),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == index ? Sc.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        i == index ? _items[i].$2 : _items[i].$1,
                        size: 20,
                        color: i == index
                            ? Sc.accentInk
                            : const Color(0xff92939a),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _items[i].$3,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: i == index
                              ? Sc.accentInk
                              : const Color(0xff92939a),
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
  );
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
      color: tag ? Colors.transparent : Sc.accentSoft,
      borderRadius: BorderRadius.circular(99),
      border: tag ? Border.all(color: Sc.line) : null,
    ),
    child: Text(
      tag ? '#$text' : text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: tag ? Sc.neutralInk : Sc.accentInk,
      ),
    ),
  );
}
