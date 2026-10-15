import 'package:flutter/material.dart';

/// Kaha design tokens (see vault note 14 - UX Design System).
class KahaColors {
  static const ink = Color(0xFF16221D);
  static const brand = Color(0xFF0E5A47);
  static const brandWash = Color(0xFFDCEBE4);
  static const charge = Color(0xFFF2C94C); // calamansi: only the money-forward action
  static const chargeInk = Color(0xFF1E1A08);
  static const bg = Color(0xFFEEF2EC);
  static const surface = Color(0xFFFBFCF9);
  static const warn = Color(0xFF9A4A06);
  static const warnWash = Color(0xFFFCEBD7);
  static const danger = Color(0xFFB42318);
}

ThemeData kahaTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: KahaColors.brand,
    brightness: brightness,
    primary: brightness == Brightness.light ? KahaColors.brand : const Color(0xFF3FB28E),
  );
  final light = brightness == Brightness.light;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: light ? KahaColors.bg : const Color(0xFF111A17),
    appBarTheme: AppBarTheme(
      backgroundColor: light ? KahaColors.surface : const Color(0xFF16211D),
      foregroundColor: light ? KahaColors.ink : const Color(0xFFE6EEE9),
      elevation: 0,
      scrolledUnderElevation: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: light ? Colors.white : const Color(0xFF1C2925),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(64, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: light ? Colors.white : const Color(0xFF1C2925),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: light ? const Color(0xFFE2E8E0) : const Color(0xFF2C3B35))),
      margin: EdgeInsets.zero,
    ),
  );
}
