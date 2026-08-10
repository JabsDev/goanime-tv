import 'package:flutter/material.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/cached_image.dart';
import 'anilist_web_login_screen.dart';

class AnilistLoginDialog extends StatefulWidget {
  const AnilistLoginDialog({super.key});

  @override
  State<AnilistLoginDialog> createState() => _AnilistLoginDialogState();
}

class _AnilistLoginDialogState extends State<AnilistLoginDialog> {
  // B11: o fluxo de login é um único caminho: WebView interno que intercepta
  // o redirect pin do AniList e salva o token automaticamente. O QR foi
  // removido porque, no Implicit Grant do AniList, o token viaja no fragment
  // da URL (nunca chega a servidor nenhum) e o redirect é fixo no pin page —
  // browser/celular nunca conseguem devolvê-lo para a TV sem app companion.
  void _openWebLogin() {
    Navigator.of(context)
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => AnilistWebLoginScreen(url: AniListService.authUrl),
          ),
        )
        .then((loggedIn) {
          if (loggedIn == true && mounted) Navigator.pop(context, true);
        });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                children: [
                  CachedImage(
                    url: 'https://anilist.co/img/icons/icon.svg',
                    width: 32,
                    height: 32,
                    fallback: const Icon(
                      Icons.bookmark,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Conectar AniList',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Semantics(
                button: true,
                child: Material(
                  color: ThemeConstants.primary,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    autofocus: true, // D-pad cai na ação principal na TV
                    onTap: _openWebLogin,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      child: Text(
                        'Entrar com AniList',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'O login acontece dentro do app — sem colar nenhum token.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              const SizedBox(height: 24),
              Semantics(
                button: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => Navigator.pop(context, false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(
                          color: ThemeConstants.textSecondary,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}