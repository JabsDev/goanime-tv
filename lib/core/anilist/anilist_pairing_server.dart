import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/digests/sha256.dart';
import '../constants/app_constants.dart';
import 'anilist_service.dart';

/// Local LAN pairing server for AniList login without typing a token on the TV.
///
/// Flow:
///  1. The TV starts this server and shows a QR of [pairUrl].
///  2. The phone scans it and opens the TV-hosted page.
///  3. The page links to AniList's OAuth (PKCE) with `redirect_uri` pointing
///     back to this server's `/callback`.
///  4. After the user authorizes, AniList redirects the phone to `/callback`
///     with `?code=...&state=...` query params. A tiny JS reads the code and
///     POSTs it (together with a CSRF token) to `/token`.
///  5. The server validates the state, exchanges the code via AniList's token
///     endpoint using PKCE, saves the token, and completes [onLoggedIn].
class AniListPairingServer {
  HttpServer? _server;
  final _loggedIn = Completer<bool>();
  String? _ip;
  int? _port;

  // PKCE session state — generated fresh per landing page load.
  String? _codeVerifier;
  String? _state;
  String? _csrfToken;

  // Rate limiting: IP → { count, windowStart (epoch ms) }.
  final Map<String, _RateEntry> _rateLimitStore = {};
  static const int _rateLimitMax = 5;
  static const Duration _rateLimitWindow = Duration(seconds: 60);

  Future<bool> get onLoggedIn => _loggedIn.future;

  /// Base pairing URL to encode in the QR code (e.g. http://192.168.0.10:8090/).
  String? get pairUrl =>
      (_ip != null && _port != null) ? 'http://$_ip:$_port/' : null;

  bool get isRunning => _server != null;

  Future<bool> start() async {
    _ip = await _lanIp();
    if (_ip == null) {
      debugPrint('[AniListPairing] No LAN IP found');
      return false;
    }
    for (final port in const [8090, 8091, 8092, 8093, 8099]) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _port = port;
        break;
      } catch (_) {
        continue;
      }
    }
    if (_server == null) {
      debugPrint('[AniListPairing] Could not bind any port');
      return false;
    }
    debugPrint('[AniListPairing] Serving at $pairUrl');
    _server!.listen(_handle, onError: (e) {
      debugPrint('[AniListPairing] Server error: $e');
    });
    return true;
  }

  // ---------------------------------------------------------------------------
  // PKCE helpers
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

  /// SHA-256 digest → unpadded base64url.
  String _sha256Base64Url(String input) {
    final digest = SHA256Digest();
    final inputBytes = Uint8List.fromList(utf8.encode(input));
    final hash = Uint8List(digest.digestSize);
    digest.update(inputBytes, 0, inputBytes.length);
    digest.doFinal(hash, 0);
    return base64Url.encode(hash).replaceAll('=', '');
  }

  /// PKCE authorize URL for the current session.  Generates a new code_verifier
  /// and state on each call so that every landing-page refresh gets fresh
  /// credentials.
  String get _authorizeUrl {
    final redirect = 'http://$_ip:$_port/callback';
    _codeVerifier = _randomBase64Url(128);
    _state = _randomBase64Url(32);
    final challenge = _sha256Base64Url(_codeVerifier!);
    return 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=${AppConstants.anilistClientId}'
        '&response_type=code'
        '&code_challenge=$challenge'
        '&code_challenge_method=S256'
        '&state=$_state'
        '&redirect_uri=${Uri.encodeComponent(redirect)}';
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
      // Window expired — reset.
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

    final code = params['code'] ?? '';
    final state = params['state'] ?? '';
    final csrfToken = params['csrf_token'] ?? '';

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
    final tvOrigin = 'http://$_ip:$_port';
    if (origin != null && origin != tvOrigin) {
      _html(req, _resultPage(false), status: 403);
      return;
    }
    if (referer != null && !referer.startsWith(tvOrigin)) {
      _html(req, _resultPage(false), status: 403);
      return;
    }

    // -----------------------------------------------------------------------
    // State validation and code exchange
    // -----------------------------------------------------------------------
    var ok = false;

    if (state.isNotEmpty && state == _state && code.isNotEmpty) {
      final token = await AniListService.exchangeCodeForToken(
        code,
        _codeVerifier ?? '',
      );
      if (token != null) {
        ok = true;
      }
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

  /// Sends an HTML response with CORS header restricted to the TV's own origin.
  Future<void> _html(HttpRequest req, String body, {int status = 200}) async {
    final origin = 'http://$_ip:$_port';
    req.response
      ..statusCode = status
      ..headers.set(HttpHeaders.contentTypeHeader, 'text/html; charset=utf-8')
      ..headers.set('Access-Control-Allow-Origin', origin)
      ..write(body);
    try {
      await req.response.close();
    } catch (_) {}
  }

  /// Landing page — generates a fresh PKCE session on every load.
  String _landingPage() {
    // Invalidate any previous session and generate fresh credentials.
    _csrfToken = _randomBase64Url(32);
    final authUrl = _authorizeUrl; // also sets _codeVerifier and _state
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
<p style="margin-top:20px;font-size:13px;color:#ffa500">⚠ Este servidor é apenas para uso em rede local. O token de acesso é transmitido por HTTP em sua rede local.</p>
</div></body></html>''';
  }

  /// Callback page — reads the authorization `code` from the query string
  /// and POSTs it together with the CSRF token to the local `/token` endpoint.
  /// AniList sends the redirect as a full-page navigation (not fragment),
  /// so we read from `location.search` (query string).
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
  function q(name){ var m = location.search.match(new RegExp('[?&]' + name + '=([^&]*)')); return m ? decodeURIComponent(m[1]) : ''; }
  var code = q('code');
  var state = q('state');
  var csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute('content');
  var m = document.getElementById('m');
  if(!code){ m.textContent = 'Não recebi o código. Volte à TV e tente novamente.'; return; }
  fetch('/token', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body: 'code=' + encodeURIComponent(code) + '&state=' + encodeURIComponent(state) + '&csrf_token=' + encodeURIComponent(csrfToken)})
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

  /// Best-effort LAN IPv4 discovery, preferring private ranges.
  static Future<String?> _lanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      String? fallback;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
          fallback ??= ip;
        }
      }
      return fallback;
    } catch (e) {
      debugPrint('[AniListPairing] LAN IP error: $e');
      return null;
    }
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
