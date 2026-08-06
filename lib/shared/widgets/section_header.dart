import 'package:flutter/material.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onSeeAll;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 6,
            height: 28,
            decoration: BoxDecoration(
              color: ThemeConstants.primary,
              borderRadius: BorderRadius.circular(3),
              boxShadow: s.shadowsEnabled
                  ? [
                      BoxShadow(
                        color: ThemeConstants.primary.withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 0,
                      ),
                    ]
                  : [],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: ThemeConstants.sectionHeaderTitle,
                    fontWeight: FontWeight.bold,
                    color: ThemeConstants.white,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: ThemeConstants.minFontSecondary,
                        color: ThemeConstants.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onSeeAll != null)
            Semantics(
              button: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onSeeAll,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(
                      'Ver Todos',
                      style: TextStyle(
                        fontSize: 16,
                        color: ThemeConstants.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}