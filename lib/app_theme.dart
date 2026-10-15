import 'package:flutter/material.dart';

/// Shared colors and Material theme for the Listening Tracker experience.
abstract final class ListeningPalette {
  static const background = Color(0xFF09090B);
  static const surface = Color(0xFF141416);
  static const surfaceRaised = Color(0xFF1C1C1F);
  static const separator = Color(0xFF29292D);
  static const mint = Color(0xFF9BE8CC);
  static const cyan = Color(0xFF9BCBD6);
  static const amber = Color(0xFFE8C98A);
  static const urgent = Color(0xFFE58E8E);
  static const text = Color(0xFFF3F3F5);
  static const muted = Color(0xFF929297);
}

abstract final class ListeningTheme {
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: ListeningPalette.mint,
      secondary: ListeningPalette.cyan,
      surface: ListeningPalette.surface,
      error: ListeningPalette.urgent,
      onPrimary: ListeningPalette.background,
      onSecondary: ListeningPalette.background,
      onSurface: ListeningPalette.text,
    ),
    scaffoldBackgroundColor: ListeningPalette.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: ListeningPalette.background,
      foregroundColor: ListeningPalette.text,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: ListeningPalette.text,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: ListeningPalette.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dividerTheme: const DividerThemeData(
      color: ListeningPalette.separator,
      thickness: 1,
      space: 1,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? ListeningPalette.background
              : ListeningPalette.muted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? ListeningPalette.mint
              : ListeningPalette.separator),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: ListeningPalette.background,
      indicatorColor: ListeningPalette.mint.withValues(alpha: 0.14),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? ListeningPalette.mint
              : ListeningPalette.muted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ListeningPalette.mint,
      linearTrackColor: ListeningPalette.separator,
    ),
    textTheme: ThemeData.dark().textTheme.apply(
      bodyColor: ListeningPalette.text,
      displayColor: ListeningPalette.text,
      fontFamily: null,
    ),
  );
}
