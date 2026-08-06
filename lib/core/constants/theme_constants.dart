import 'package:flutter/material.dart';

class ThemeConstants {
  static const Color background = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF1A1A2E);
  static const Color surfaceLight = Color(0xFF252540);
  // ponytail: bg de episódio assistido — verde-escuro, distinto de surface/surfaceLight.
  // Modelo agora é conjunto (markEpisodeWatched em local_storage), não mais high-water-mark,
  // então a cor marca exatamente os eps vistos — prefixo contíguo não é mais pressuposto.
  static const Color watched = Color(0xFF245636);
  static const Color primary = Color(0xFF00E5FF);
  static const Color primaryLight = Color(0xFF66F5FF);
  static const Color primaryDark = Color(0xFF00B8CC);
  static const Color accent = Color(0xFFFF6B6B);
  static const Color white = Colors.white;
  static const Color textSecondary = Color(0xFFAAAAAA);
  static const Color textMuted = Color(0xFF777777);

  // ponytail: 10-foot UI scale (projetor/TV — leitura a 3m).
  // Reutilizado por SectionHeader / cards / dialogs para consistência.
  static const double cardMinSize = 36.0;
  static const double minFontSecondary = 16.0;
  static const double minFontTitle = 22.0;
  static const double sectionHeaderTitle = 24.0;
  static const double cardWidthTv = 160.0;
  static const double cardWidthMobile = 130.0;
  static const double bannerWidthTv = 360.0;
  static const double bannerHeightTv = 200.0;
  static const double focusBorderWidth = 2.5;
  static const double focusGlowBlur = 18.0;
}
