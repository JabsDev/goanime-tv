import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/anilist/anilist_pairing_server.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/cached_image.dart';

class AnilistLoginDialog extends StatefulWidget {
  const AnilistLoginDialog({super.key});

  @override
  State<AnilistLoginDialog> createState() => _AnilistLoginDialogState();
}

class _AnilistLoginDialogState extends State<AnilistLoginDialog> {
  WebViewController? _controller;
  bool _isLoading = true;
  bool _showManual = false;
  final _tokenController = TextEditingController();
  bool _saving = false;
  String? _error;

  AniListPairingServer? _pairing;
  bool _pairingStarting = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _pairing?.dispose();
    super.dispose();
  }

  Future<void> _startPairing() async {
    setState(() {
      _showManual = true;
      _pairingStarting = true;
      _error = null;
    });
    final server = AniListPairingServer();
    final ok = await server.start();
    if (!mounted) {
      await server.dispose();
      return;
    }
    if (!ok) {
      // No LAN available – fall back to manual token entry.
      setState(() => _pairingStarting = false);
      return;
    }
    setState(() {
      _pairing = server;
      _pairingStarting = false;
    });
    // Wait until the phone completes login, then close.
    server.onLoggedIn.then((loggedIn) {
      if (loggedIn && mounted) Navigator.pop(context, true);
    });
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) async {
          if (!mounted) return;
          setState(() => _isLoading = false);
          await _checkTokenFromWebView();
        },
        onNavigationRequest: (request) {
          if (request.url.contains('access_token')) {
            _checkTokenFromUrl(request.url);
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(AniListService.authUrl));
  }

  Future<String?> _getCurrentUrl() async {
    try {
      final result = await _controller!
          .runJavaScriptReturningResult('window.location.href');
      if (result is String) {
        // result may be JSON-encoded "..." or raw
        if (result.length >= 2 &&
            result.startsWith('"') &&
            result.endsWith('"')) {
          return result.substring(1, result.length - 1);
        }
        return result;
      }
    } catch (e) {
      debugPrint('[AnilistLoginDialog] getCurrentUrl error: $e');
    }
    return null;
  }

  Future<void> _checkTokenFromWebView() async {
    final url = await _getCurrentUrl();
    if (url != null) _checkTokenFromUrl(url);
  }

  void _checkTokenFromUrl(String url) {
    final match = RegExp(r'access_token=([^&]+)').firstMatch(url);
    if (match != null) {
      _handleToken(match.group(1)!);
    }
  }

  Future<void> _handleToken(String token) async {
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
        _error = 'Token inválido. Tente novamente.';
        _showManual = true;
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
    final authUrl = AniListService.authUrl;
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(24),
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
            if (!_showManual) ...[
              const Text(
                'Faça login no AniList usando o controle remoto',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 4),
              const Text(
                'Depois de autorizar, o login será feito automaticamente',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: ThemeConstants.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      if (_controller != null)
                        WebViewWidget(controller: _controller!),
                      if (_isLoading)
                        const Center(
                          child: CircularProgressIndicator(
                            color: ThemeConstants.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Semantics(
                    button: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _startPairing,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Text(
                            'Usar celular',
                            style: TextStyle(
                              color: ThemeConstants.primary,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
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
                  ),
                ],
              ),
            ],
            if (_showManual) ...[
              if (_pairingStarting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                            color: ThemeConstants.primary),
                        SizedBox(height: 16),
                        Text('Preparando pareamento...',
                            style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                )
              else if (_pairing?.pairUrl != null) ...[
                const Text(
                  '1. Escaneie o QR code com a câmera do celular',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 4),
                const Text(
                  '2. Toque em "Entrar com AniList" e autorize',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 4),
                const Text(
                  '3. O login na TV acontece sozinho — sem digitar nada',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: _pairing!.pairUrl!,
                      version: QrVersions.auto,
                      size: 200,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: ThemeConstants.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Aguardando login no celular...',
                      style: TextStyle(
                        color: ThemeConstants.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _pairing!.pairUrl!,
                    style: const TextStyle(
                        color: ThemeConstants.textSecondary, fontSize: 12),
                  ),
                ),
              ] else ...[
                // Fallback: no LAN — QR of the AniList auth + paste token.
                const Text(
                  'Escaneie o QR, autorize e cole o token abaixo:',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: authUrl,
                      version: QrVersions.auto,
                      size: 180,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: ThemeConstants.background,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _error != null
                          ? Colors.red
                          : ThemeConstants.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: TextField(
                    controller: _tokenController,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration.collapsed(
                      hintText: 'Token (começa com eyJ...)',
                      hintStyle: TextStyle(
                        color: ThemeConstants.textSecondary
                            .withValues(alpha: 0.5),
                      ),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
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
                  // "Conectar" only in the paste-token fallback mode.
                  if (_pairing?.pairUrl == null && !_pairingStarting) ...[
                    const SizedBox(width: 12),
                    Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _saving ? null : _doLogin,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            decoration: BoxDecoration(
                              color: _saving
                                  ? ThemeConstants.primary
                                      .withValues(alpha: 0.5)
                                  : ThemeConstants.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Conectar',
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
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
