import 'package:flutter/material.dart';

abstract final class AppColors {
  static const background = Color(0xFF0B0D10);
  static const surface = Color(0xFF13171C);
  static const elevated = Color(0xFF1B2027);
  static const divider = Color(0xFF252B33);
  static const text = Color(0xFFF5F7FA);
  static const secondary = Color(0xFFA8B0BA);
  static const tertiary = Color(0xFF69737F);
  static const accent = Color(0xFFF2B84B);
  static const accentPressed = Color(0xFFD99A2B);
  static const onAccent = Color(0xFF17120A);
  static const success = Color(0xFF63C174);
  static const error = Color(0xFFF06A6A);
  static const scrim = Color(0x99000000);
}

ThemeData buildTheme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: AppColors.background,
  colorScheme: const ColorScheme.dark(
    surface: AppColors.surface,
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    error: AppColors.error,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: AppColors.background,
    foregroundColor: AppColors.text,
    elevation: 0,
    centerTitle: false,
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: AppColors.surface,
    indicatorColor: AppColors.elevated,
    iconTheme: WidgetStateProperty.resolveWith(
      (states) => IconThemeData(
        color: states.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.tertiary,
      ),
    ),
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => TextStyle(
        fontSize: 12,
        color: states.contains(WidgetState.selected)
            ? AppColors.accent
            : AppColors.tertiary,
      ),
    ),
  ),
  chipTheme: const ChipThemeData(
    backgroundColor: AppColors.elevated,
    selectedColor: AppColors.accent,
    disabledColor: AppColors.surface,
    side: BorderSide.none,
    shape: StadiumBorder(),
    labelStyle: TextStyle(color: AppColors.secondary, fontSize: 13),
    secondaryLabelStyle: TextStyle(color: AppColors.onAccent, fontSize: 13),
    checkmarkColor: AppColors.onAccent,
    padding: EdgeInsets.symmetric(horizontal: 4),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(44, 48),
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.onAccent,
      disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.45),
      disabledForegroundColor: AppColors.onAccent.withValues(alpha: 0.65),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: AppColors.surface,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: AppColors.divider),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: AppColors.divider),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: AppColors.accent),
    ),
  ),
  useMaterial3: true,
);
