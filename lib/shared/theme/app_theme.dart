import 'package:flutter/material.dart';
import '../../core/constants/theme_constants.dart';

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ThemeConstants.background,
      colorScheme: const ColorScheme.dark(
        primary: ThemeConstants.primary,
        secondary: ThemeConstants.accent,
        surface: ThemeConstants.surface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: ThemeConstants.background,
        elevation: 0,
        centerTitle: true,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.bold,
          color: ThemeConstants.white,
        ),
        headlineMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: ThemeConstants.white,
        ),
        titleLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: ThemeConstants.white,
        ),
        titleMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: ThemeConstants.white,
        ),
        bodyLarge: TextStyle(
          fontSize: 18,
          color: ThemeConstants.white,
        ),
        bodyMedium: TextStyle(
          fontSize: 16,
          color: ThemeConstants.textSecondary,
        ),
        labelLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: ThemeConstants.white,
        ),
      ),
      focusColor: ThemeConstants.primary.withValues(alpha: 0.25),
    );
  }
}
