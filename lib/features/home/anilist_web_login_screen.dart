import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/anilist/anilist_pairing_server.dart';

/// Login AniList via WebView em processo (na própria TV).
///
/// Carrega a URL de autorização AniList direto (Implicit Grant:
/// `response_type=token` — o `access_token` vem no fragment da redirect URI)
/// e abre como ROTA FULL-SCREEN: o WebView aninhado num Dialog não recebe
/// foco D-pad/touch na Fire TV (o frame inteiro vira um bloco só). Em rota
/// própria — como a tela do SuperFlix — o input chega no conteúdo HTML.
///
/// O redirect cai em `/callback#access_token=...`; a página de callback do
/// servidor loopback lê o fragment e POSTa o token para `/token`, que o salva
/// e completa [AniListPairingServer.onLoggedIn] → esta tela fecha sozinha.
///
/// Teste/QA: na Fire TV nem o D-pad nem o adb focam os inputs HTML (sem IME).
/// Quando `ANILIST_TEST_EMAIL`/`ANILIST_TEST_PASS` forem passados via
/// `--dart-define`, o login é preenchido e submetido por injeção de JS na
/// própria página do AniList. Sem defines, nenhum dado é injetado.
class AnilistWebLoginScreen extends StatefulWidget {
  final String url;
  final AniListPairingServer? pairing;

  const AnilistWebLoginScreen({super.key, required this.url, this.pairing});

  @override
  State<AnilistWebLoginScreen> createState() => _AnilistWebLoginScreenState();
}

class _AnilistWebLoginScreenState extends State<AnilistWebLoginScreen> {
  late final WebViewController _controller;
  bool _filled = false;

  static const _testEmail = String.fromEnvironment('ANILIST_TEST_EMAIL');
  static const _testPass = String.fromEnvironment('ANILIST_TEST_PASS');

  /// Preenche os campos da página do AniList e submete por JS. O SPA do
  /// AniList monta o formulário alguns instantes após o load, então o script
  /// faz polling: Fase A espera os inputs aparecerem (setter nativo +
  /// eventos, já que `.value` direto não atualiza o estado do front), Fase B
  /// espera o Turnstile do Cloudflare concluir e então clica no botão "Login".
  /// Resultado reportado de forma assíncrona via canal [FillLog].
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
    // Login concluído in-process → fecha esta tela; o dialog (abaixo na
    // pilha) também fecha via próprio listener do servidor.
    widget.pairing?.onLoggedIn.then((ok) {
      if (ok && mounted) Navigator.of(context).pop(true);
    });
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('FillLog',
          onMessageReceived: (m) => debugPrint('[AnilistWeb] fill: ${m.message}'))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) => debugPrint('[AnilistWeb] start: $url'),
        onPageFinished: _onPageFinished,
        onWebResourceError: (e) =>
            debugPrint('[AnilistWeb] error: ${e.description}'),
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _onPageFinished(String url) async {
    debugPrint('[AnilistWeb] finished: $url');
    if (_filled) return;
    // Detect either the authorize URL OR the login page after redirect.
    // The authorize URL returns HTTP 302 to the login page; we check both.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      appBar: AppBar(
        title: const Text('Entrar com AniList'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}