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
        (states) =>
            states.contains(WidgetState.selected) ? Sc.accent : const Color(0xffd4cec7),
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

/// Small uppercase label above a title.
class ScEyebrow extends StatelessWidget {
  const ScEyebrow(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
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

/// "‹ Back" link with an optional eyebrow on the right.
class ScBackRow extends StatelessWidget {
  const ScBackRow({super.key, required this.label, required this.onBack, this.eyebrow});
  final String label;
  final VoidCallback onBack;
  final String? eyebrow;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GestureDetector(
          onTap: onBack,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '‹ $label',
              style: const TextStyle(
                color: Color(0xff6b55d9),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        if (eyebrow != null) ScEyebrow(eyebrow!),
      ],
    ),
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
          active ? Icons.pause : Icons.play_arrow_rounded,
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
                Text(title, style: const TextStyle(fontSize: 14, color: Color(0xff332d28))),
                if (caption != null) ...[
                  const SizedBox(height: 3),
                  Text(caption!, style: const TextStyle(fontSize: 11, color: Sc.faint)),
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
            const Icon(Icons.chevron_right, color: Color(0xff9f968d)),
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
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.description_outlined, Icons.description, 'Notes'),
    (Icons.check_box_outlined, Icons.check_box, 'Tasks'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
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
          BoxShadow(color: Color(0x1a252b35), blurRadius: 24, offset: Offset(0, 8)),
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
                        color: i == index ? Sc.accentInk : const Color(0xff92939a),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _items[i].$3,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: i == index ? Sc.accentInk : const Color(0xff92939a),
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
