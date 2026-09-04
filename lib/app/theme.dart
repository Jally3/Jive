import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Legacy dark palette kept for player constants and backwards-compatible tests.
/// Application widgets should read colors from `context.appColors` instead.
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

@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.elevated,
    required this.divider,
    required this.text,
    required this.secondary,
    required this.tertiary,
    required this.accent,
    required this.accentForeground,
    required this.accentPressed,
    required this.onAccent,
    required this.success,
    required this.error,
    required this.scrim,
    required this.navigationHomeAlpha,
    required this.navigationPageAlpha,
  });

  static const dark = AppPalette(
    background: AppColors.background,
    surface: AppColors.surface,
    elevated: AppColors.elevated,
    divider: AppColors.divider,
    text: AppColors.text,
    secondary: AppColors.secondary,
    tertiary: AppColors.tertiary,
    accent: AppColors.accent,
    accentForeground: AppColors.accent,
    accentPressed: AppColors.accentPressed,
    onAccent: AppColors.onAccent,
    success: AppColors.success,
    error: AppColors.error,
    scrim: AppColors.scrim,
    navigationHomeAlpha: 0.30,
    navigationPageAlpha: 0.78,
  );

  static const light = AppPalette(
    background: Color(0xFFF7F5F0),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFEFEAE1),
    divider: Color(0xFFD8D1C5),
    text: Color(0xFF1A1C1E),
    secondary: Color(0xFF555C65),
    tertiary: Color(0xFF747B84),
    accent: Color(0xFFF2B84B),
    accentForeground: Color(0xFF8A5700),
    accentPressed: Color(0xFFD99A2B),
    onAccent: Color(0xFF17120A),
    success: Color(0xFF237A3B),
    error: Color(0xFFB3261E),
    scrim: Color(0x52000000),
    navigationHomeAlpha: 0.82,
    navigationPageAlpha: 0.94,
  );

  final Color background;
  final Color surface;
  final Color elevated;
  final Color divider;
  final Color text;
  final Color secondary;
  final Color tertiary;
  final Color accent;
  final Color accentForeground;
  final Color accentPressed;
  final Color onAccent;
  final Color success;
  final Color error;
  final Color scrim;
  final double navigationHomeAlpha;
  final double navigationPageAlpha;

  @override
  AppPalette copyWith({
    Color? background,
    Color? surface,
    Color? elevated,
    Color? divider,
    Color? text,
    Color? secondary,
    Color? tertiary,
    Color? accent,
    Color? accentForeground,
    Color? accentPressed,
    Color? onAccent,
    Color? success,
    Color? error,
    Color? scrim,
    double? navigationHomeAlpha,
    double? navigationPageAlpha,
  }) => AppPalette(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    elevated: elevated ?? this.elevated,
    divider: divider ?? this.divider,
    text: text ?? this.text,
    secondary: secondary ?? this.secondary,
    tertiary: tertiary ?? this.tertiary,
    accent: accent ?? this.accent,
    accentForeground: accentForeground ?? this.accentForeground,
    accentPressed: accentPressed ?? this.accentPressed,
    onAccent: onAccent ?? this.onAccent,
    success: success ?? this.success,
    error: error ?? this.error,
    scrim: scrim ?? this.scrim,
    navigationHomeAlpha: navigationHomeAlpha ?? this.navigationHomeAlpha,
    navigationPageAlpha: navigationPageAlpha ?? this.navigationPageAlpha,
  );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      elevated: Color.lerp(elevated, other.elevated, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      text: Color.lerp(text, other.text, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      tertiary: Color.lerp(tertiary, other.tertiary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentForeground: Color.lerp(
        accentForeground,
        other.accentForeground,
        t,
      )!,
      accentPressed: Color.lerp(accentPressed, other.accentPressed, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      success: Color.lerp(success, other.success, t)!,
      error: Color.lerp(error, other.error, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      navigationHomeAlpha:
          navigationHomeAlpha +
          (other.navigationHomeAlpha - navigationHomeAlpha) * t,
      navigationPageAlpha:
          navigationPageAlpha +
          (other.navigationPageAlpha - navigationPageAlpha) * t,
    );
  }
}

extension AppThemeContext on BuildContext {
  AppPalette get appColors =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;
}

ThemeData buildLightTheme() => _buildTheme(AppPalette.light, Brightness.light);

ThemeData buildDarkTheme() => _buildTheme(AppPalette.dark, Brightness.dark);

/// Backwards-compatible alias for existing dark-theme widget tests.
ThemeData buildTheme() => buildDarkTheme();

ThemeData _buildTheme(AppPalette colors, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: colors.accent,
        brightness: brightness,
        surface: colors.surface,
        primary: colors.accent,
        onPrimary: colors.onAccent,
        error: colors.error,
      ).copyWith(
        onSurface: colors.text,
        outline: colors.divider,
        surfaceContainerHighest: colors.elevated,
      );

  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: colors.background,
    focusColor: colors.accentForeground.withValues(alpha: 0.24),
    colorScheme: scheme,
    extensions: [colors],
    textTheme: ThemeData(
      brightness: brightness,
    ).textTheme.apply(bodyColor: colors.text, displayColor: colors.text),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.background,
      foregroundColor: colors.text,
      elevation: 0,
      centerTitle: false,
      systemOverlayStyle: isDark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      indicatorColor: colors.elevated,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.accentForeground
              : colors.tertiary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected)
              ? colors.accentForeground
              : colors.tertiary,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.elevated,
      selectedColor: colors.accent,
      disabledColor: colors.surface,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(color: colors.secondary, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: colors.onAccent, fontSize: 13),
      checkmarkColor: colors.onAccent,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      color: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return states.contains(WidgetState.focused)
              ? colors.accentPressed
              : colors.accent;
        }
        return colors.elevated;
      }),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            minimumSize: const Size(44, 48),
            backgroundColor: colors.accent,
            foregroundColor: colors.onAccent,
            disabledBackgroundColor: colors.accent.withValues(alpha: 0.45),
            disabledForegroundColor: colors.onAccent.withValues(alpha: 0.65),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ).copyWith(
            side: WidgetStateBorderSide.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? BorderSide(color: colors.text, width: 2)
                  : null,
            ),
          ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: colors.accentForeground),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: colors.text),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colors.accentForeground),
      ),
    ),
    dividerColor: colors.divider,
    cardColor: colors.surface,
    useMaterial3: true,
  );
}
