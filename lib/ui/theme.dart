import 'package:flutter/material.dart';

/// Colours and shapes of the app: a dark Material 3 look with soft rounded cards, a left rail and one blue accent.
class Palette {
  static const background = Color(0xFF101113);
  static const rail = Color(0xFF141517);
  static const card = Color(0xFF1D1F22);
  static const cardHigh = Color(0xFF26292D);
  static const outline = Color(0xFF2E3136);
  static const text = Color(0xFFEDEEF0);
  static const muted = Color(0xFF9BA0A8);
  static const accent = Color(0xFF3B8BFF);
  static const ok = Color(0xFF34C759);
  static const warn = Color(0xFFFFB020);
  static const danger = Color(0xFFFF5C5C);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Palette.accent, brightness: Brightness.dark).copyWith(
    surface: Palette.background,
    primary: Palette.accent,
    onSurface: Palette.text,
    surfaceContainerHighest: Palette.cardHigh,
    outline: Palette.outline,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.background,
    fontFamily: 'Segoe UI',
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Palette.text),
      titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Palette.text),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Palette.text),
      bodyMedium: TextStyle(fontSize: 14, color: Palette.text),
      bodySmall: TextStyle(fontSize: 12.5, color: Palette.muted),
    ),
    dividerColor: Palette.outline,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : Palette.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Palette.accent : Palette.cardHigh),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.cardHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Palette.accent, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Palette.accent,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.text,
        side: const BorderSide(color: Palette.outline),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      ),
    ),
    sliderTheme: const SliderThemeData(activeTrackColor: Palette.accent, thumbColor: Palette.accent, inactiveTrackColor: Palette.cardHigh),
  );
}
