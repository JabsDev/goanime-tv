import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/anilist/anilist_service.dart';

/// Login AniList via WebView em processo (na própria TV).
///
/// Carrega a URL de autorização AniList direto (Implicit Grant:
/// `response_type=token` — o `access_token` vem no fragment da redirect URI) e
/// abre como ROTA FULL-SCREEN: o WebView aninhado num Dialog não recebe foco
/// D-pad/touch na Fire TV (o frame inteiro vira um bloco só). Em rota própria o
/// input chega no conteúdo HTML.
///
/// Fluxo canônico (sem servidor loopback): o AniList redireciona para a página
/// de pin `https://anilist.co/api/v2/oauth/pin#access_token=...`. O
/// `NavigationDelegate.onNavigationRequest` intercepta essa URL ANTES de a
/// WebView renderizá-la (o token nunca fica exposto), extrai o token do fragment,
/// valida e completa `AniListService.saveToken` → esta tela fecha com `true`.
///
/// Nenhuma navegação para fora de `https://anilist.co` escapa sem interceptação.
///
/// Teste/QA: na TV nem o D-pad nem o adb focam os inputs HTML (sem IME). Quando
/// `ANILIST_TEST_EMAIL`/`ANILIST_TEST_PASS` forem passados via `--dart-define`,
/// o login é preenchido e submetido por injeção de JS na própria página do
/// AniList. Sem defines, nenhum dado é injetado.
class AnilistWebLoginScreen extends StatefulWidget {
  final String url;

  const AnilistWebLoginScreen({super.key, required this.url});

  @override
  State<AnilistWebLoginScreen> createState() => _AnilistWebLoginScreenState();
}

class _AnilistWebLoginScreenState extends State<AnilistWebLoginScreen> {
  late final WebViewController _controller;
  bool _filled = false;
  bool _loading = false;
  String? _error;
  String _expectedState = '';
  bool _completed = false;

  static const _testEmail = String.fromEnvironment('ANILIST_TEST_EMAIL');
  static const _testPass = String.fromEnvironment('ANILIST_TEST_PASS');

  /// Preenche os campos da página do AniList e submete por JS. O SPA do
  /// AniList monta o formulário alguns instantes após o load, então o script
  /// faz polling: Fase A espera os inputs aparecerem (setter nativo + eventos,
  /// já que `.value` direto não atualiza o estado do front), Fase B espera o
  /// Turnstile do Cloudflare concluir e então clica no botão "Login". Resultado
  /// reportado de forma assíncrona via canal [FillLog].
  String get _fillJs => '''
(function() {
  function setVal(el, v) {
    var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    setter.call(el, v);
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
  }
  function findInputs() {
    var inputs = Array.prototype.slice.call(document.querySelectorAll('input'));
    var email = null, pass = null;
    for (var i = 0; i < inputs.length; i++) {
      var t = inputs[i];
      if (t.type === 'password') { pass = pass || t; }
      else if (t.type === 'text' || /email/i.test(t.type + ' ' + (t.name||'') + ' ' + (t.id||'') + ' ' + (t.placeholder||''))) { email = email || t; }
    }
    return { email: email, pass: pass };
  }
  var tries = 0;
  var iv1 = setInterval(function() {
    tries++;
    var f = findInputs();
    if (f.email && f.pass) {
      clearInterval(iv1);
      setVal(f.email, '$_testEmail');
      setVal(f.pass, '$_testPass');
      var at = 0;
      var iv2 = setInterval(function() {
        at++;
        var el = document.querySelector('input[name="cf-turnstile-response"]');
        var ready = el && el.value && el.value.length > 20;
        if (ready || at >= 20) {
          clearInterval(iv2);
          var info = { email:true, pass:true, turnstile: ready ? 'ok' : 'timeout', form: !!document.querySelector('form') };
          if (ready) {
            var btn = Array.prototype.slice.call(document.querySelectorAll('button')).find(function(b){ return /^\\s*login/i.test(b.textContent || ''); });
            var form = document.querySelector('form');
            if (btn) { info.submit = 'btn'; btn.click(); }
            else if (form && form.requestSubmit) { info.submit = 'requestSubmit'; form.requestSubmit(); }
            else { info.submit = 'none'; }
          }
          FillLog.postMessage(JSON.stringify(info));
        }
      }, 500);
    } else if (tries >= 12) {
      clearInterval(iv1);
      FillLog.postMessage(JSON.stringify({ email: !!f.email, pass: !!f.pass, timeout: true }));
    }
  }, 300);
})();
''';

  @override
  void initState() {
    super.initState();
    // O state da sessão vem no próprio authorize URL; guardamos para validar o
    // estado ecoado pelo AniList no callback (contra CSRF/reaplay).
    final uri = Uri.tryParse(widget.url);
    if (uri != null) _expectedState = uri.queryParameters['state'] ?? '';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('FillLog',
          onMessageReceived: (m) => debugPrint('[AnilistWeb] fill: ${m.message}'))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigationRequest,
        onPageStarted: _onPageStarted,
        onPageFinished: _onPageFinished,
        onWebResourceError: (e) {
          debugPrint(
              '[AnilistWeb] resource error: ${e.description} (code=${e.errorCode})');
          // Fase 7: erro de rede/DNS/TLS (códigos negativos do WebView Android)
          // com feedback de conexão; sem derrubar o fluxo — dá pra tentar de novo.
          if (_connectionLikeError(e.errorCode) &&
              !_loading &&
              _error == null) {
            _handleCallbackError(
                'Sem conexão. Verifique sua internet e tente novamente.');
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.parse(request.url);
    // Intercepta o redirect final do AniList que devolve o token ANTES de
    // renderizar (token no fragment nunca fica exposto na página).
    if (AniListService.isOAuthCallback(request.url)) {
      if (request.url.contains('#') || request.url.contains('access_token')) {
        _handleCallback(request.url);
      } else {
        // Fragment ausente: trata como falha, não navega.
        _handleCallbackError('Não foi possível obter o token. Tente novamente.');
      }
      return NavigationDecision.prevent;
    }
    // Só navega dentro do AniList; qualquer outra origem é bloqueada.
    if (uri.host != 'anilist.co') {
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  void _onPageStarted(String url) {
    // Log redigido (Fase 9): nunca imprimir o fragment/token.
    debugPrint('[AnilistWeb] start: ${_redact(url)}');
  }

  /// Códigos de erro do WebView Android que indicam problema de conexão
  /// (host lookup/connect/timeout/SSL), não falha de conteúdo.
  bool _connectionLikeError(int code) {
    const networkCodes = {-1, -2, -6, -7, -8, -11};
    return networkCodes.contains(code);
  }

  Future<void> _onPageFinished(String url) async {
    debugPrint('[AnilistWeb] finished: ${_redact(url)}');
    if (_completed || _filled) return;
    final bool isAuthorizeOrLoginPage = url.startsWith('https://anilist.co/') && (
      url.contains('/api/v2/oauth/authorize') ||
      url.contains('/login') ||
      url.contains('?') ||
      url.contains('#')
    );
    if (!isAuthorizeOrLoginPage || url.contains('/callback')) {
      return;
    }
    if (_testEmail.isEmpty || _testPass.isEmpty) return;
    _filled = true;
    await _controller.runJavaScript(_fillJs);
  }

  Future<void> _handleCallback(String rawUrl) async {
    if (_completed) return;
    final token = AniListService.extractAccessToken(rawUrl);
    if (token == null || !AniListService.isJwtToken(token)) {
      _handleCallbackError('Token inválido ou incompleto. Tente novamente.');
      return;
    }
    final state = _stateFrom(rawUrl);
    if (_expectedState.isNotEmpty && state != _expectedState) {
      _handleCallbackError('Sessão expirada. Repita o login.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final ok = await AniListService.saveToken(token);
    if (!mounted) return;
    if (ok) {
      _completed = true;
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _loading = false;
        _error = 'Token inválido ou expirado. Tente novamente.';
      });
    }
  }

  String? _stateFrom(String rawUrl) {
    final hashIndex = rawUrl.indexOf('#');
    if (hashIndex < 0) return null;
    return Uri.splitQueryString(rawUrl.substring(hashIndex + 1))['state'];
  }

  void _handleCallbackError(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  /// Redige query+fragment de uma URL para log (nunca expor o token).
  String _redact(String url) {
    final i = url.indexOf('?');
    if (i < 0) return url;
    return url.substring(0, i) + '…';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Entrar com AniList'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_error != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (_loading)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Autorizando...',
                          style: TextStyle(color: Colors.white, fontSize: 16)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}