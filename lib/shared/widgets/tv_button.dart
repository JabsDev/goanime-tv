import 'package:flutter/material.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import 'focus_key_handler.dart';

class TVButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final bool isPrimary;
  final double width;
  final bool autofocus;

  const TVButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.isPrimary = true,
    this.width = 200,
    this.autofocus = false,
  });

  @override
  State<TVButton> createState() => _TVButtonState();
}

class _TVButtonState extends State<TVButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onPressed),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            onHover: (_) {},
            child: AnimatedContainer(
              duration: s.animDuration,
              width: widget.width,
              height: 56,
              decoration: BoxDecoration(
                color: widget.isPrimary
                    ? ThemeConstants.primary
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.isPrimary
                      ? ThemeConstants.primary
                      : ThemeConstants.textSecondary,
                  width: _isFocused ? 3 : 1,
                ),
                boxShadow: (_isFocused && s.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.4),
                          blurRadius: 15,
                          spreadRadius: 1,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, color: Colors.white, size: 24),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
