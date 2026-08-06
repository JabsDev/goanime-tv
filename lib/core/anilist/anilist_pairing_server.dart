import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../constants/app_constants.dart';
import 'anilist_service.dart';

/// Loopback pairing server for AniList login without typing a token on the TV.
///
/// Flow (Implicit Grant — no client_secret in the APK, no LAN required):
///  1. The TV starts this server bound to `127.0.0.1:8090` and the WebView
///     loads the authorize URL, which points AniList's redirect_uri back to
///     `http://127.0.0.1:8090/callback`.
///  2. After the user authorizes on AniList (inside the in-app WebView), the
///     browser is redirected to `/callback#access_token=...&state=...`. The
///     token travels in the URL fragment (never sent to any server), per the
///     OAuth2 Implicit Grant.
///  3. The callback page's JS reads `access_token` and `state` from
///     `location.hash`, then POSTs both (with a CSRF token) to `/token`.
///  4. The server validates the state and CSRF token and saves the token via
///     [AniListService.saveToken]. On success, [onLoggedIn] completes with
///     `true`.
///
/// Note: PKCE (Authorization Code Flow) is NOT supported by AniList — the
/// token endpoint rejects code+verifier exchanges with `401 invalid_client`.
/// Implicit Grant is the supported no-secret flow (see
/// https://docs.anilist.co/guide/auth/implicit).
///
/// Why loopback (127.0.0.1) instead of LAN IP: the redirect_uri is registered
/// once in the AniList developer console and must be stable across devices. A
/// LAN IP changes per network, so it can't be registered. `127.0.0.1` is
/// always the local device, so the same redirect_uri works on every install
/// — and the in-app WebView is the one performing the OAuth, so it hits the
/// server running in the same process. No external device can reach the
/// loopback server, which is also a security improvement over the previous
/// `InternetAddress.anyIPv4` bind.
class AniListPairingServer {
  HttpServer? _server;
  final _loggedIn = Completer<bool>();
  static const int _port = 8090;
  static const String _host = '127.0.0.1';

  // OAuth state for the current session — generated fresh per authorize-URL
  // load and validated against the state AniList echoes back on the callback.
  String? _state;
  String? _csrfToken;

  // Rate limiting: IP → { count, windowStart (epoch ms) }.
  final Map<String, _RateEntry> _rateLimitStore = {};
  static const int _rateLimitMax = 5;
  static const Duration _rateLimitWindow = Duration(seconds: 60);

  Future<bool> get onLoggedIn => _loggedIn.future;

  /// Base URL served by this server — always `http://127.0.0.1:8090/`.
  String? get pairUrl => _server != null ? 'http://$_host:$_port/' : null;

  bool get isRunning => _server != null;

  /// Binds the loopback IPv4 address on the fixed port registered with AniList.
  /// Returns `false` if the port is already in use (rare on a TV, but surfaced
  /// so the UI can tell the user to close whatever is holding it).
  Future<bool> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
    } catch (e) {
      debugPrint('[AniListPairing] Could not bind 127.0.0.1:$_port — $e');
      return false;
    }
    debugPrint('[AniListPairing] Serving at $pairUrl');
    _server!.listen(_handle, onError: (e) {
      debugPrint('[AniListPairing] Server error: $e');
    });
    return true;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Cryptographically random base64url string, [byteLength] bytes, no padding.
  String _randomBase64Url(int byteLength) {
    final random = Random.secure();
    final bytes = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// ponytail: authorize URL for the current session. Implicit Grant
  /// (`response_type=token`): AniList returns the JWT in the redirect fragment.
  String get _authorizeUrl {
    return 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=${AppConstants.anilistClientId}'
        '&response_type=token'
        '&state=$_state'
        '&redirect_uri=${Uri.encodeComponent(AppConstants.anilistRedirectUri)}';
  }

  /// Gera a sessão e retorna a URL de autorização pronta para o WebView.
  /// A landing page também chama isso, mas o WebView da TV pode carregar a URL
  /// direto — poupa o clique intermediário (que não chega ao WebView da Fire TV).
  String? get authorizeUrl {
    if (_server == null) return null;
    _startSession();
    return _authorizeUrl;
  }

  void _startSession() {
    _csrfToken = _randomBase64Url(32);
    // currentState vem default como '' (não-null), então `??` nunca dispara e
    // _state ficava vazio → /token rejeitava com 403. Cai no random se vazio.
    final cs = AniListService.currentState;
    _state = cs.isNotEmpty ? cs : _randomBase64Url(32);
  }

  // ---------------------------------------------------------------------------
  // Request routing
  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/' || path.isEmpty) {
        _html(req, _landingPage());
      } else if (path == '/callback') {
        _html(req, _callbackPage(_csrfToken));
      } else if (path == '/token') {
        await _handleToken(req);
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    } catch (e) {
      debugPrint('[AniListPairing] Handle error: $e');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // /token handler
  // ---------------------------------------------------------------------------

  Future<void> _handleToken(HttpRequest req) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // -----------------------------------------------------------------------
    // Rate limiting (T-01-04): max 5 POST / 60s per client IP → 429
    // -----------------------------------------------------------------------
    final clientIp = req.connectionInfo?.remoteAddress.address ?? 'unknown';
    final rateEntry = _rateLimitStore.putIfAbsent(
      clientIp,
      () => _RateEntry(0, now),
    );
    if (now - rateEntry.windowStart > _rateLimitWindow.inMilliseconds) {
      rateEntry.count = 0;
      rateEntry.windowStart = now;
    }
    rateEntry.count++;
    if (rateEntry.count > _rateLimitMax) {
      _html(req, _resultPage(false), status: 429);
      return;
    }

    // Parse POST body.
    final body = req.method == 'POST' ? await utf8.decodeStream(req) : '';
    final params = Uri.splitQueryString(body);

    final token = params['token'] ?? '';
    final state = params['state'] ?? '';
    final csrfToken = params['csrf_token'] ?? '';

    // -----------------------------------------------------------------------
    // State validation (T-01-02): missing/wrong state → 403
    // -----------------------------------------------------------------------
    if (state.isEmpty || state != _state) {
      _html(req, _resultPage(false), status: 403);
      return;
    }

    // -----------------------------------------------------------------------
    // CSRF token validation (T-01-02): missing/wrong token → 403
    // -----------------------------------------------------------------------
    final expectedCsrf = _csrfToken;
    if (csrfToken.isEmpty ||
        expectedCsrf == null ||
        csrfToken != expectedCsrf) {
      _html(req, _resultPage(false), status: 403);
      return;
    }
    // Single-use CSRF token — invalidate after first check.
    _csrfToken = null;

    // -----------------------------------------------------------------------
    // Origin / Referer validation (T-01-03)
    // -----------------------------------------------------------------------
    final origin = req.headers.value('origin');
    final referer = req.headers.value('referer');
    final tvOrigin = 'http://$_host:$_port';
    if (origin != null && origin != tvOrigin) {
      _html(req, _resultPage(false), status: 403);
      return;
    }
    if (referer != null && !referer.startsWith(tvOrigin)) {
      _html(req, _resultPage(false), status: 403);
      return;
    }

    // -----------------------------------------------------------------------
    // Save token (Implicit Grant): the callback page POSTs the access token
    // it read from the URL fragment. On success completes [onLoggedIn].
    // -----------------------------------------------------------------------
    var ok = false;

    if (token.startsWith('eyJ')) {
      ok = await AniListService.saveToken(token);
    }

    _html(
      req,
      _resultPage(ok),
      status: ok ? 200 : 400,
    );
    if (ok && !_loggedIn.isCompleted) _loggedIn.complete(true);
  }

  // ---------------------------------------------------------------------------
  // HTML helpers
  // ---------------------------------------------------------------------------

  /// Sends an HTML response with CORS header restricted to the loopback origin.
  Future<void> _html(HttpRequest req, String body, {int status = 200}) async {
    final origin = 'http://$_host:$_port';
    req.response
      ..statusCode = status
      ..headers.set(HttpHeaders.contentTypeHeader, 'text/html; charset=utf-8')
      ..headers.set('Access-Control-Allow-Origin', origin)
      ..write(body);
    try {
      await req.response.close();
    } catch (_) {}
  }

  /// Landing page — generates a fresh CSRF token and state on every load
  /// and reads the state from `AniListService.currentState` so it matches the URL
  /// the WebView is about to navigate to.
  String _landingPage() {
    _startSession();
    final authUrl = _authorizeUrl;
    return '''<!doctype html><html lang="pt-br"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="csrf-token" content="$_csrfToken">
<title>Login AniList - GoAnime TV</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0b0f14;color:#fff;
margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}
.card{max-width:420px;width:100%;background:#151b23;border-radius:16px;padding:28px;text-align:center;
box-shadow:0 8px 40px rgba(0,0,0,.4)}
h1{font-size:22px;margin:0 0 8px}p{color:#9aa7b4;font-size:15px;line-height:1.5}
a.btn{display:block;margin-top:20px;background:#3b82f6;color:#fff;text-decoration:none;
padding:16px;border-radius:12px;font-size:18px;font-weight:600}
</style></head><body><div class="card">
<h1>Conectar AniList</h1>
<p>Toque no botão abaixo, faça login no AniList e autorize o aplicativo. O login na TV será feito automaticamente.</p>
<a class="btn" href="$authUrl">Entrar com AniList</a>
<p style="margin-top:20px;font-size:13px;color:#9aa7b4">Servidor loopback 127.0.0.1:$_port — visível apenas para este dispositivo.</p>
</div></body></html>''';
  }

  /// Callback page — Implicit Grant puts the access token in the URL fragment
  /// (`location.hash`), which is never sent to the server. The JS reads
  /// `access_token` and `state` from the hash and POSTs both (with the CSRF
  /// token) to the local `/token` endpoint.
  String _callbackPage(String? csrfToken) {
    final token = csrfToken ?? '';
    return '''<!doctype html><html lang="pt-br"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="csrf-token" content="$token">
<title>Autorizando...</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0b0f14;color:#fff;
margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px;text-align:center}
.card{max-width:420px;width:100%;background:#151b23;border-radius:16px;padding:28px}
h1{font-size:20px}p{color:#9aa7b4}
</style></head><body><div class="card" id="c">
<h1>Autorizando...</h1><p id="m">Concluindo o login, aguarde.</p>
</div>
<script>
(function(){
  var hash = location.hash.substring(1);
  var params = new URLSearchParams(hash);
  var token = params.get('access_token');
  var state = params.get('state');
  var csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute('content');
  var m = document.getElementById('m');
  if(!token){ m.textContent = 'Não recebi o token. Volte à TV e tente novamente.'; return; }
  fetch('/token', {
    method:'POST',
    headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body: 'token=' + encodeURIComponent(token) + '&state=' + encodeURIComponent(state) + '&csrf_token=' + encodeURIComponent(csrfToken)
  })
    .then(function(r){ return r.ok; })
    .then(function(ok){
      document.getElementById('c').innerHTML = ok
        ? '<h1>Pronto! ✅</h1><p>Login concluído. Pode voltar para a TV.</p>'
        : '<h1>Falhou</h1><p>Não foi possível concluir o login. Tente novamente na TV.</p>';
    })
    .catch(function(){ m.textContent = 'Erro de conexão com a TV.'; });
})();
</script></body></html>''';
  }

  String _resultPage(bool ok) {
    return '''<!doctype html><html lang="pt-br"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${ok ? 'OK' : 'Erro'}</title>
<style>body{font-family:system-ui,sans-serif;background:#0b0f14;color:#fff;margin:0;
display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center;padding:24px}</style>
</head><body><div><h1>${ok ? 'Login concluído ✅' : 'Token inválido'}</h1>
<p>${ok ? 'Pode voltar para a TV.' : 'Tente novamente.'}</p></div></body></html>''';
  }

  Future<void> dispose() async {
    if (!_loggedIn.isCompleted) _loggedIn.complete(false);
    _rateLimitStore.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

/// Per-IP rate limit entry.
class _RateEntry {
  int count;
  int windowStart; // epoch milliseconds
  _RateEntry(this.count, this.windowStart);
}
