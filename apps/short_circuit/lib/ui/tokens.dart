part of '../main.dart';

// Design tokens for the redesign (docs/app-redesign-plan.md, section 6): one place for spacing,
// corner radius, type and colour roles, with a light and a dark value for every colour. New and
// redesigned screens read these instead of writing numbers or Color(0x...) inline.
//
// Colours: `Sc.*` (theme.dart) are the light values and still work everywhere. `context.sc` gives the
// palette for the current brightness; a screen that reads colours from it follows dark mode. Dark mode
// is defined here and in buildScDarkTheme() but is switched on in the app (themeMode) only once the
// screens read `context.sc`, so no screen is ever shown with light colours on a dark page.

/// Spacing on a 4-point scale.
class ScSpace {
  const ScSpace._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Every step, smallest first (used by tests).
  static const List<double> scale = [xs, sm, md, lg, xl, xxl];
}

/// Corner radius: chips, inputs and rows, cards; pill for buttons and badges.
class ScRadius {
  const ScRadius._();
  static const double chip = 8;
  static const double input = 12;
  static const double card = 16;
  static const double pill = 99;

  static BorderRadius get chipBorder => BorderRadius.circular(chip);
  static BorderRadius get inputBorder => BorderRadius.circular(input);
  static BorderRadius get cardBorder => BorderRadius.circular(card);
  static BorderRadius get pillBorder => BorderRadius.circular(pill);
}

/// Type scale. Sizes are in logical pixels and scale with the phone's font size. Nothing essential is
/// below 14; caption (13) is for secondary detail only. Colour is not set here, so a style takes the
/// colour of the surface it is on.
class ScType {
  const ScType._();
  static const TextStyle display = TextStyle(
    fontSize: 28,
    height: 34 / 28,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle title = TextStyle(
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle subtitle = TextStyle(
    fontSize: 18,
    height: 24 / 18,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle body = TextStyle(fontSize: 16, height: 24 / 16);

  /// Transcripts: a little larger and looser, because Devanagari and Gujarati need the room.
  static const TextStyle transcript = TextStyle(fontSize: 17, height: 26 / 17);
  static const TextStyle label = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle caption = TextStyle(fontSize: 13, height: 18 / 13);

  /// Every style, for tests.
  static const List<TextStyle> all = [
    display,
    title,
    subtitle,
    body,
    transcript,
    label,
    caption,
  ];
}

/// Colour roles, one value per role for a given brightness.
@immutable
class ScPalette {
  const ScPalette({
    required this.bg,
    required this.ink,
    required this.muted,
    required this.line,
    required this.surface,
    required this.hero,
    required this.warmCard,
    required this.accent,
    required this.onAccent,
    required this.accentInk,
    required this.accentSoft,
    required this.tileBg,
    required this.tileInk,
    required this.chip,
    required this.dark,
    required this.green,
    required this.orange,
    required this.danger,
    required this.dangerSoft,
    required this.neutralButton,
    required this.neutralInk,
    required this.circuitCard,
    required this.circuitMark,
    required this.circuitMarkInk,
  });

  final Color bg; // page background
  final Color ink; // main text
  final Color muted; // secondary text
  final Color line; // hairlines and borders
  final Color surface; // raised or grouped surface
  final Color hero;
  final Color warmCard;
  final Color accent; // primary action
  final Color onAccent; // text and icons on the accent
  final Color accentInk; // accent-coloured text
  final Color accentSoft;
  final Color tileBg;
  final Color tileInk;
  final Color chip;
  final Color dark; // snack bar and other always-dark surfaces
  final Color green; // success
  final Color orange; // warning
  final Color danger;
  final Color dangerSoft;
  final Color neutralButton;
  final Color neutralInk;
  final Color circuitCard;
  final Color circuitMark;
  final Color circuitMarkInk;

  /// The palette the app has always had. Every value equals the matching `Sc.*` constant.
  static const light = ScPalette(
    bg: Sc.bg,
    ink: Sc.ink,
    muted: Sc.muted,
    line: Sc.line,
    surface: Sc.surface,
    hero: Sc.hero,
    warmCard: Sc.warmCard,
    accent: Sc.accent,
    onAccent: Sc.ink,
    accentInk: Sc.accentInk,
    accentSoft: Sc.accentSoft,
    tileBg: Sc.tileBg,
    tileInk: Sc.tileInk,
    chip: Sc.chip,
    dark: Sc.dark,
    green: Sc.green,
    orange: Sc.orange,
    danger: Sc.danger,
    dangerSoft: Sc.dangerSoft,
    neutralButton: Sc.neutralButton,
    neutralInk: Sc.neutralInk,
    circuitCard: Sc.circuitCard,
    circuitMark: Sc.circuitMark,
    circuitMarkInk: Sc.circuitMarkInk,
  );

  /// Warm dark counterpart. Every text pair in it is at least 4.5:1 and every icon colour at least 3:1
  /// (test/tokens_test.dart).
  static const darkMode = ScPalette(
    bg: Color(0xff14120f),
    ink: Color(0xfff3efe9),
    muted: Color(0xffb3a99f),
    line: Color(0xff2e2a25),
    surface: Color(0xff1e1b17),
    hero: Color(0xff2a2218),
    warmCard: Color(0xff221e19),
    accent: Color(0xfff05b3d),
    onAccent: Color(0xff15171b),
    accentInk: Color(0xffffa58c),
    accentSoft: Color(0xff3a231b),
    tileBg: Color(0xff3a2a1e),
    tileInk: Color(0xffffb27e),
    chip: Color(0xff2a2926),
    dark: Color(0xff0e0d0b),
    green: Color(0xff4cc58a),
    orange: Color(0xfff0a35b),
    danger: Color(0xffff8a73),
    dangerSoft: Color(0xff3b1f19),
    neutralButton: Color(0xff2a2622),
    neutralInk: Color(0xffe0d3c6),
    circuitCard: Color(0xff1d2a20),
    circuitMark: Color(0xff0f1a12),
    circuitMarkInk: Color(0xffe5f5bc),
  );

  /// Pairs of (text colour, the colour it sits on) that must reach 4.5:1.
  List<(String, Color, Color)> get textPairs => [
    ('ink on bg', ink, bg),
    ('ink on surface', ink, surface),
    ('ink on hero', ink, hero),
    ('ink on warmCard', ink, warmCard),
    ('ink on chip', ink, chip),
    ('ink on circuitCard', ink, circuitCard),
    ('muted on bg', muted, bg),
    ('muted on surface', muted, surface),
    ('muted on warmCard', muted, warmCard),
    ('muted on hero', muted, hero),
    ('muted on chip', muted, chip),
    ('accentInk on accentSoft', accentInk, accentSoft),
    ('accentInk on bg', accentInk, bg),
    ('onAccent on accent', onAccent, accent),
    ('danger on bg', danger, bg),
    ('danger on dangerSoft', danger, dangerSoft),
    ('neutralInk on neutralButton', neutralInk, neutralButton),
    ('tileInk on tileBg', tileInk, tileBg),
    ('circuitMarkInk on circuitMark', circuitMarkInk, circuitMark),
  ];

  /// Pairs for icons and other graphics that must reach 3:1.
  List<(String, Color, Color)> get graphicPairs => [
    ('green on bg', green, bg),
    ('orange on bg', orange, bg),
    ('accent on bg', accent, bg),
    ('tileInk on bg', tileInk, bg),
  ];
}

/// Carries the palette in the theme, so `context.sc` follows the theme's brightness.
@immutable
class ScColors extends ThemeExtension<ScColors> {
  const ScColors(this.palette);
  final ScPalette palette;

  @override
  ScColors copyWith({ScPalette? palette}) => ScColors(palette ?? this.palette);

  @override
  ScColors lerp(ThemeExtension<ScColors>? other, double t) =>
      t < 0.5 || other is! ScColors ? this : other;
}

extension ScThemeContext on BuildContext {
  /// The colour palette for the current theme (light unless a dark theme is active).
  ScPalette get sc =>
      Theme.of(this).extension<ScColors>()?.palette ?? ScPalette.light;
}

/// WCAG 2.x contrast ratio between two opaque colours.
double scContrast(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final la = luminance(a);
  final lb = luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
