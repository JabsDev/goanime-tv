import 'package:flutter/material.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import 'focus_key_handler.dart';

/// Top bar padrão do app — gradient surface→background, ícone opcional, título
/// grande, botão de voltar focável (D-pad) e slot de actions. Usada por telas
/// secundárias (Busca, Favoritos) para bater visualmente com a Home.
class AppTopBar extends StatelessWidget {
  final String title;
  final IconData? icon;
  final List<Widget> actions;
  final VoidCallback? onBack;

  const AppTopBar({
    super.key,
    required this.title,
    this.icon,
    this.actions = const [],
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top + 16;
    return Container(
      padding: EdgeInsets.only(left: 32, right: 32, top: top, bottom: 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ThemeConstants.surface, ThemeConstants.background],
          stops: [0, 1],
        ),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            _TopBarBackButton(onTap: onBack!),
            const SizedBox(width: 16),
          ],
          if (icon != null) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ThemeConstants.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: ThemeConstants.primary, size: 28),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: ThemeConstants.white,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _TopBarBackButton extends StatefulWidget {
  final VoidCallback onTap;
  const _TopBarBackButton({required this.onTap});

  @override
  State<_TopBarBackButton> createState() => _TopBarBackButtonState();
}

class _TopBarBackButtonState extends State<_TopBarBackButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: s.animDuration,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isFocused ? ThemeConstants.primary : Colors.transparent,
                  width: ThemeConstants.focusBorderWidth,
                ),
                boxShadow: (_isFocused && s.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.5),
                          blurRadius: s.focusGlowBlur,
                        ),
                      ]
                    : [],
              ),
              child: Icon(
                Icons.arrow_back,
                color: _isFocused ? ThemeConstants.primary : ThemeConstants.white,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}