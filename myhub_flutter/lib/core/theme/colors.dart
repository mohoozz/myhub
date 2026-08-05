import 'package:flutter/material.dart';

/// Design-spec color palette, light & dark variants.
abstract final class AppColors {
  // Brand primary.
  static const Color primaryLight = Color(0xFF2563EB);
  static const Color primaryDark = Color(0xFF3B82F6);

  // Page background.
  static const Color backgroundLight = Color(0xFFEEF4FB);
  static const Color backgroundDark = Color(0xFF000000);

  // Card surface.
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF121212);

  // Navigation (rail / bar) background.
  static const Color navBackgroundLight = Color(0xFFFFFFFF);
  static const Color navBackgroundDark = Color(0xFF0A0A0A);

  // Primary text.
  static const Color textPrimaryLight = Color(0xFF1A1A2E);
  static const Color textPrimaryDark = Color(0xFFE0E0E0);

  // Secondary text.
  static const Color textSecondaryLight = Color(0xFF6B7280);
  static const Color textSecondaryDark = Color(0xFF888888);

  // Divider / hairline.
  static const Color dividerLight = Color(0xFFE5E7EB);
  static const Color dividerDark = Color(0xFF1E1E1E);

  // Input fill.
  static const Color inputBackgroundLight = Color(0xFFFFFFFF);
  static const Color inputBackgroundDark = Color(0xFF1A1A1A);

  // Selection highlight (background + foreground).
  static const Color selectionBgLight = Color(0xFFEEF4FB);
  static const Color selectionFgLight = Color(0xFF2563EB);
  static const Color selectionBgDark = Color(0xFF1A2744);
  static const Color selectionFgDark = Color(0xFF3B82F6);
}
