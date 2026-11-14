import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Docket's reds: the bright one glows on dark and black, the deep one carries
/// the light theme and sits under the bright one as its container.
const emberRed = Color(0xFFE13A26);
const emberDeep = Color(0xFF831613);

/// One accent on quiet neutrals: the chat is the content, not the chrome.
const defaultAccent = emberRed;

/// Accents to pick from, besides the wallpaper's (Material You).
const accents = <String, Color>{
  'Ember': emberRed,
  'Indigo': Color(0xFF4F5BD5),
  'Teal': Color(0xFF00897B),
  'Green': Color(0xFF43A047),
  'Amber': Color(0xFFFFB300),
  'Orange': Color(0xFFF4511E),
  'Rose': Color(0xFFD81B60),
  'Purple': Color(0xFF8E24AA),
  'Slate': Color(0xFF546E7A),
};

/// Light, dark, or dark on true black for OLED screens (the default).
enum ThemeChoice { system, light, dark, amoled }

/// How the app looks, kept in settings and applied as it changes.
class Appearance extends ChangeNotifier {
  Appearance(this._read, this._write);

  final String? Function(String key) _read;
  final void Function(String key, String value) _write;

  ThemeChoice get choice => ThemeChoice.values.asNameMap()[_read('theme.mode')] ?? ThemeChoice.amoled;
  set choice(ThemeChoice value) => _set('theme.mode', value.name);

  /// 'wallpaper', or an accent name from [accents].
  String get accent => _read('theme.accent') ?? 'Ember';
  set accent(String value) => _set('theme.accent', value);

  /// Text size, 0.85 to 1.3 times the phone's own.
  double get textScale => double.tryParse(_read('theme.textScale') ?? '') ?? 1.0;
  set textScale(double value) => _set('theme.textScale', value.toStringAsFixed(2));

  ThemeMode get mode => switch (choice) {
        ThemeChoice.system => ThemeMode.system,
        ThemeChoice.light => ThemeMode.light,
        ThemeChoice.dark || ThemeChoice.amoled => ThemeMode.dark,
      };

  /// The seed colour: the wallpaper's main colour when asked for and the
  /// phone has one (Android 12+), else the chosen accent.
  Color seed(Color? wallpaper) => accent == 'wallpaper' ? wallpaper ?? defaultAccent : accents[accent] ?? defaultAccent;

  void _set(String key, String value) {
    _write(key, value);
    notifyListeners();
  }
}

/// WCAG contrast of two colours, 1 to 21.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

/// An accent's two shades and what is written on the bright one: [bright]
/// for buttons, switches, links and progress, readable on black; [deep]
/// under white text (your chat bubbles, what is selected); [on] white or
/// black, whichever reads better on [bright].
({Color bright, Color deep, Color on}) accentPair(Color seed) {
  if (seed == emberRed) return (bright: emberRed, deep: emberDeep, on: Colors.white);
  final hsl = HSLColor.fromColor(seed);
  var bright = hsl;
  // Lighter until it reads on black (4.5:1), as the bright red does.
  while (contrast(bright.toColor(), Colors.black) < 4.5 && bright.lightness < 0.9) {
    bright = bright.withLightness((bright.lightness + 0.02).clamp(0.0, 1.0));
  }
  var deep = HSLColor.fromAHSL(1, hsl.hue, hsl.saturation.clamp(0.0, 0.75), 0.28);
  // Dark enough for white text, comfortably.
  while (contrast(deep.toColor(), Colors.white) < 7 && deep.lightness > 0.08) {
    deep = deep.withLightness(deep.lightness - 0.02);
  }
  final b = bright.toColor();
  return (bright: b, deep: deep.toColor(), on: contrast(b, Colors.white) >= 4.0 ? Colors.white : Colors.black);
}

ThemeData buildTheme(Brightness brightness, {Color seed = defaultAccent, bool black = false}) {
  final dark = brightness == Brightness.dark;
  final pair = accentPair(seed);
  var scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.neutral,
  );
  // The accent as it is (the neutral variant would mute it), on neutral greys that are the same for every accent,
  // so text reads the same whichever is chosen.
  scheme = dark
      ? scheme.copyWith(
          primary: pair.bright,
          onPrimary: pair.on,
          primaryContainer: pair.deep,
          onPrimaryContainer: Colors.white,
          secondary: pair.bright,
          onSecondary: pair.on,
          secondaryContainer: pair.deep,
          onSecondaryContainer: Colors.white,
          surface: black ? Colors.black : const Color(0xFF121212),
          surfaceDim: black ? Colors.black : const Color(0xFF0E0E0E),
          surfaceBright: const Color(0xFF2C2C2C),
          surfaceContainerLowest: black ? Colors.black : const Color(0xFF0E0E0E),
          surfaceContainerLow: black ? const Color(0xFF0B0B0B) : const Color(0xFF161616),
          surfaceContainer: black ? const Color(0xFF121212) : const Color(0xFF1C1C1C),
          surfaceContainerHigh: black ? const Color(0xFF1A1A1A) : const Color(0xFF242424),
          surfaceContainerHighest: black ? const Color(0xFF262626) : const Color(0xFF2E2E2E),
          onSurface: const Color(0xFFF2F2F2),
          onSurfaceVariant: const Color(0xFFA8A8A8),
          outline: const Color(0xFF6E6E6E),
          outlineVariant: const Color(0xFF2A2A2A),
        )
      : scheme.copyWith(
          primary: pair.deep,
          onPrimary: Colors.white,
          secondary: pair.deep,
          onSecondary: Colors.white,
          secondaryContainer: Color.alphaBlend(pair.bright.withValues(alpha: 0.18), Colors.white),
          onSecondaryContainer: const Color(0xFF141414),
          surface: Colors.white,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: const Color(0xFFF7F7F7),
          surfaceContainer: const Color(0xFFF2F2F2),
          surfaceContainerHigh: const Color(0xFFECECEC),
          surfaceContainerHighest: const Color(0xFFE4E4E4),
          onSurface: const Color(0xFF141414),
          onSurfaceVariant: const Color(0xFF555555),
          outline: const Color(0xFF8A8A8A),
          outlineVariant: const Color(0xFFDDDDDD),
        );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  const pill = StadiumBorder();
  final pillButton = ButtonStyle(
    shape: const WidgetStatePropertyAll(pill),
    minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 20)),
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500, color: scheme.onSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(style: pillButton),
    elevatedButtonTheme: ElevatedButtonThemeData(style: pillButton),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: pillButton.copyWith(side: WidgetStatePropertyAll(BorderSide(color: scheme.primary, width: 1.5))),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(pill),
        foregroundColor: WidgetStatePropertyAll(dark ? pair.bright : pair.deep),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(pill),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.secondaryContainer : scheme.surfaceContainer),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.onSecondaryContainer : scheme.onSurface),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: pill,
      side: BorderSide.none,
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.secondaryContainer,
      secondarySelectedColor: scheme.secondaryContainer,
      checkmarkColor: scheme.onSecondaryContainer,
      labelStyle: base.textTheme.labelLarge?.copyWith(color: scheme.onSurface),
      secondaryLabelStyle: base.textTheme.labelLarge?.copyWith(color: scheme.onSecondaryContainer),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    // A step below the cards, so a card in a sheet still shows as one.
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      modalBackgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(28))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? scheme.surfaceContainerHighest : const Color(0xFF262626),
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(color: const Color(0xFFF2F2F2)),
      actionTextColor: pair.bright,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.outline),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.primary : scheme.surfaceContainerHighest),
      trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.transparent : scheme.outline),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      trackHeight: 6,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      thumbColor: scheme.primary,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(3),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      iconColor: scheme.onSurfaceVariant,
      // What is chosen (the open chat, a persona) in the deep shade, as in the drawer.
      selectedTileColor: scheme.secondaryContainer,
      selectedColor: scheme.onSecondaryContainer,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: pair.bright.withValues(alpha: 0.35),
      selectionHandleColor: scheme.primary,
    ),
    extensions: [Accent(seed, bright: dark ? pair.bright : pair.deep, deep: pair.deep, on: dark ? pair.on : Colors.white)],
  );
}

/// The accent (Settings › Appearance, or the wallpaper's) and its shades:
/// [bright] for what glows or is pressed in it, such as Talk's wave and the
/// recorder's buttons, [on] for what is drawn on it, [deep] under white text.
class Accent extends ThemeExtension<Accent> {
  const Accent(this.seed, {required this.bright, required this.deep, required this.on});

  final Color seed;
  final Color bright;
  final Color deep;
  final Color on;

  static Accent _of(BuildContext context) {
    final found = Theme.of(context).extension<Accent>();
    if (found != null) return found;
    final pair = accentPair(defaultAccent);
    return Accent(defaultAccent, bright: pair.bright, deep: pair.deep, on: pair.on);
  }

  /// The accent's bright shade.
  static Color of(BuildContext context) => _of(context).bright;

  /// What is drawn on [of]: white or black.
  static Color onOf(BuildContext context) => _of(context).on;

  /// The accent's deep shade, under white text.
  static Color deepOf(BuildContext context) => _of(context).deep;

  @override
  Accent copyWith({Color? seed, Color? bright, Color? deep, Color? on}) =>
      Accent(seed ?? this.seed, bright: bright ?? this.bright, deep: deep ?? this.deep, on: on ?? this.on);

  @override
  Accent lerp(Accent? other, double t) => other == null
      ? this
      : Accent(
          Color.lerp(seed, other.seed, t)!,
          bright: Color.lerp(bright, other.bright, t)!,
          deep: Color.lerp(deep, other.deep, t)!,
          on: Color.lerp(on, other.on, t)!,
        );
}

/// Markdown headings and links in answers and notes, in the app's colours.
/// gpt_markdown reads its own theme (it builds on material_ui), whose
/// defaults show headings dark on a dark background; MaterialApp's builder
/// provides this instead.
GptMarkdownThemeData markdownTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final text = theme.textTheme;
  return GptMarkdownThemeData(
    brightness: theme.brightness,
    h1: text.headlineSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
    h2: text.titleLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
    h3: text.titleMedium?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
    h4: text.titleSmall?.copyWith(color: scheme.onSurface),
    h5: text.bodyLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
    h6: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
    linkColor: scheme.primary,
    hrLineColor: scheme.outlineVariant,
  );
}
