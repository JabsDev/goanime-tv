import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../constants/app_constants.dart';
import 'anilist_service.dart';

/// Local LAN pairing server for AniList login without typing a token on the TV.
///
/// Flow:
///  1. The TV starts this server and shows a QR of [pairUrl].
///  2. The phone scans it and opens the TV-hosted page.
///  3. The page links to AniList's OAuth (implicit) with `redirect_uri` pointing
///     back to this server's `/callback`.
///  4. After the user authorizes, AniList redirects the phone to `/callback`
///     with the token in the URL fragment. A tiny JS reads the fragment and
///     POSTs the token to `/token`.
///  5. The server validates + saves the token and completes [onLoggedIn].
///
/// No external backend and no manual copy/paste are required.
class AniListPairingServer {
  HttpServer? _server;
  final _loggedIn = Completer<bool>();
  String? _ip;
  int? _port;

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

  String get _authorizeUrl {
    final redirect = 'http://$_ip:$_port/callback';
    return 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=${AppConstants.anilistClientId}'
        '&response_type=token'
        '&redirect_uri=${Uri.encodeComponent(redirect)}';
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/' || path.isEmpty) {
        _html(req, _landingPage());
      } else if (path == '/callback') {
        _html(req, _callbackPage());
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

  Future<void> _handleToken(HttpRequest req) async {
    String token = req.uri.queryParameters['token'] ?? '';
    if (token.isEmpty && req.method == 'POST') {
      token = (await utf8.decodeStream(req)).trim();
    }
    token = token.trim();
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

  void _html(HttpRequest req, String body, {int status = 200}) {
    req.response
      ..statusCode = status
      ..headers.set(HttpHeaders.contentTypeHeader, 'text/html; charset=utf-8')
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..write(body);
    req.response.close();
  }

  String _landingPage() {
    return '''<!doctype html><html lang="pt-br"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
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
<a class="btn" href="$_authorizeUrl">Entrar com AniList</a>
</div></body></html>''';
  }

  String _callbackPage() {
    return '''<!doctype html><html lang="pt-br"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
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
  function q(name, str){ var m = str.match(new RegExp(name+'=([^&]+)')); return m ? decodeURIComponent(m[1]) : ''; }
  var hash = window.location.hash.substring(1);
  var token = q('access_token', hash);
  var m = document.getElementById('m');
  if(!token){ m.textContent = 'Não recebi o token. Volte à TV e tente novamente.'; return; }
  fetch('/token', {method:'POST', body: token})
    .then(function(r){ return r.ok; })
    .then(function(ok){
      document.getElementById('c').innerHTML = ok
        ? '<h1>Pronto! ✅</h1><p>Login concluído. Pode voltar para a TV.</p>'
        : '<h1>Falhou</h1><p>Token inválido. Tente novamente na TV.</p>';
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
    await _server?.close(force: true);
    _server = null;
  }
}
