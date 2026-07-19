import 'package:flutter/material.dart';
import '../../core/constants/theme_constants.dart';
import 'cached_image.dart';
import 'focus_key_handler.dart';

class FocusableCard extends StatefulWidget {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final double width;
  final double height;
  final VoidCallback onTap;
  final bool isPoster;

  const FocusableCard({
    super.key,
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.width = 150,
    this.height = 210,
    required this.onTap,
    this.isPoster = true,
  });

  @override
  State<FocusableCard> createState() => _FocusableCardState();
}

class _FocusableCardState extends State<FocusableCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (_) {},
            child: AnimatedScale(
              scale: _isFocused ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _isFocused
                        ? ThemeConstants.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                  boxShadow: _isFocused
                      ? [
                          BoxShadow(
                            color: ThemeConstants.primary.withValues(alpha: 0.5),
                            blurRadius: 15,
                            spreadRadius: 1,
                          ),
                        ]
                      : [],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(7),
                        ),
                        child: CachedImage(
                          url: widget.imageUrl,
                          width: widget.width,
                          fit: BoxFit.cover,
                          fallback: _buildPlaceholder(),
                        ),
                      ),
                    ),
                    Container(
                      width: widget.width,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: _isFocused
                            ? ThemeConstants.primaryDark.withValues(alpha: 0.3)
                            : ThemeConstants.surface,
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(8),
                        ),
                      ),
                      child: Text(
                        widget.title,
                        style: TextStyle(
                          color: ThemeConstants.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: ThemeConstants.surfaceLight,
      child: const Center(
        child: Icon(
          Icons.movie,
          color: ThemeConstants.textMuted,
          size: 36,
        ),
      ),
    );
  }
}

class FocusableBannerCard extends StatefulWidget {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final double width;
  final double height;
  final VoidCallback onTap;

  const FocusableBannerCard({
    super.key,
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.width = 300,
    this.height = 170,
    required this.onTap,
  });

  @override
  State<FocusableBannerCard> createState() => _FocusableBannerCardState();
}

class _FocusableBannerCardState extends State<FocusableBannerCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (_) {},
            child: AnimatedScale(
              scale: _isFocused ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _isFocused
                        ? ThemeConstants.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                  boxShadow: _isFocused
                      ? [
                          BoxShadow(
                            color:
                                ThemeConstants.primary.withValues(alpha: 0.5),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ]
                      : [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.imageUrl != null &&
                          widget.imageUrl!.isNotEmpty)
                        CachedImage(
                          url: widget.imageUrl,
                          fit: BoxFit.cover,
                          fallback: _buildPlaceholder(),
                        )
                      else
                        _buildPlaceholder(),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.center,
                            colors: [
                              Colors.black.withValues(alpha: 0.95),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 12,
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            color: ThemeConstants.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_isFocused)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: ThemeConstants.primary,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.play_arrow,
                              color: ThemeConstants.white,
                              size: 22,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: ThemeConstants.surfaceLight,
      child: const Center(
        child: Icon(Icons.movie,
            color: ThemeConstants.textMuted, size: 48),
      ),
    );
  }
}
