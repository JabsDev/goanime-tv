import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/anilist/anilist_pairing_server.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/cached_image.dart';
import 'anilist_qr_scanner_screen.dart';
import 'anilist_web_login_screen.dart';

class AnilistLoginDialog extends StatefulWidget {
  const AnilistLoginDialog({super.key});

  @override
  State<AnilistLoginDialog> createState() => _AnilistLoginDialogState();
}

class _AnilistLoginDialogState extends State<AnilistLoginDialog> {
  AniListPairingServer? _pairing;
  bool _showScanner = false;
  final _tokenController = TextEditingController();
  bool _saving = false;
  String? _error;
  bool _isScannerActive = false;

  @override
  void initState() {
    super.initState();
    _startPairingServer();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _pairing?.dispose();
    super.dispose();
  }

  Future<void> _startPairingServer() async {
    final server = AniListPairingServer();
    final ok = await server.start();
    if (!mounted) {
      await server.dispose();
      return;
    }
    if (ok) {
      setState(() => _pairing = server);
      // Backup path: server's /callback JS extracts token from fragment, POSTs
      // to /token, server saves → onLoggedIn completes → dialog closes.
      server.onLoggedIn.then((loggedIn) {
        if (loggedIn && mounted) {
          setState(() => _isScannerActive = false);
          Navigator.pop(context, true);
        }
      });
    } else {
      // Port 8090 in use — scanner intercept still works, just no server backup.
      debugPrint('[AnilistLoginDialog] Pairing server unavailable (port in use)');
    }
  }

  Future<void> _handleScannerToken(String token) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await AniListService.saveToken(token);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Token inválido ou expirado. Tente novamente.';
        _showScanner = false;
      });
    }
  }

  Future<void> _doLogin() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Insira o token do AniList');
      return;
    }
    if (!token.startsWith('eyJ')) {
      setState(() => _error = 'Token inválido. Deve começar com "eyJ..."');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await AniListService.saveToken(token);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Token inválido ou expirado. Tente novamente.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        // B7: em TV o conteúdo (QR 250px + textos + botões) estourava a altura
        // e cortava o "Cancelar" no rodapé. Scroll revela tudo.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
            const SizedBox(height: 16),
            if (_showScanner) ...[
              QRCodeScannerScreen(
                qrUrl: AniListService.authUrl,
                onTokenCaptured: _handleScannerToken,
              ),
            ] else ...[
              Semantics(
                button: true,
                child: Material(
                  color: ThemeConstants.primary,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: () {
                      if (_pairing?.isRunning ?? false) {
                        final url = _pairing!.authorizeUrl;
                        if (url == null) return;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AnilistWebLoginScreen(
                              url: url,
                              pairing: _pairing,
                            ),
                          ),
                        );
                      } else {
                        setState(() => _error =
                            'Servidor de login indisponível. Use a opção "Inserir token".');
                      }
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 14),
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
              const SizedBox(height: 20),
              const Text(
                'Ou escaneie o QR Code na TV',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 4),
              const Text(
                'Use o app no celular para escanear e aprovar',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: ThemeConstants.primary.withValues(alpha: 0.3),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: QrImageView(
                        data: AniListService.authUrl,
                        version: QrVersions.auto,
                        // B7: em TV landscape (960x540dp) o QR 250dp + textos +
                        // botões estouravam a altura do dialog e cortavam o
                        // "Cancelar". Em telas baixas encolhe o QR para caber.
                        size: MediaQuery.of(context).size.height < 700 ? 170 : 250,
                        gapless: false,
                        backgroundColor: Colors.white,
                        errorStateBuilder: (context, error) {
                          return const Center(
                            child: Text(
                              'QR Code não disponível',
                              style: TextStyle(color: Colors.white),
                            ),
                          );
                        },
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red, fontSize: 14),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Semantics(
                    button: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => setState(() => _showScanner = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: const Text(
                            'Usar Câmera',
                            style: TextStyle(
                              color: ThemeConstants.primary,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Semantics(
                    button: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => setState(() => _showScanner = false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: const Text(
                            'Inserir token',
                            style: TextStyle(
                              color: ThemeConstants.primary,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Semantics(
                button: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => Navigator.pop(context, false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
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
          ],
          ),
        ),
      ),
    );
  }
}
