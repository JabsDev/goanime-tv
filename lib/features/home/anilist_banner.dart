import 'package:flutter/material.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../shared/widgets/cached_image.dart';

class AnilistBanner extends StatefulWidget {
  final VoidCallback onTap;

  const AnilistBanner({super.key, required this.onTap});

  @override
  State<AnilistBanner> createState() => _AnilistBannerState();
}

class _AnilistBannerState extends State<AnilistBanner> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    return Focus(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (_) {},
            child: AnimatedContainer(
              duration: s.animDuration,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: _isFocused
                    ? const LinearGradient(
                        colors: [Color(0xFF7B73FF), Color(0xFF5C51E0)],
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF6C63FF), Color(0xFF3F51B5)],
                      ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _isFocused ? ThemeConstants.primary : Colors.transparent,
                  width: 2,
                ),
                boxShadow: (_isFocused && s.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 1,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                children: [
                  CachedImage(
                    url: 'https://anilist.co/img/icons/icon.svg',
                    width: 36,
                    height: 36,
                    fallback: const Icon(
                      Icons.bookmark,
                      color: Colors.white, size: 36,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Conectar com AniList',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Veja suas listas de animes aqui',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios,
                      color: Colors.white, size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
