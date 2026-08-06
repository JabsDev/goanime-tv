import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/theme_constants.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';

/// Screen that resolves SuperFlix streams through a real WebView so it can pass
/// the Cloudflare Turnstile challenge that gates the player pages (plain HTTP
/// and TLS-impersonation clients get blocked). The page is rendered, the
/// challenge solves (managed/interactive), then in-page fetch calls to
/// /player/bootstrap and /player/source enumerate every server's video_url.
/// The (non-gated) external redirect + getVideo step is finished in Dart.
class SuperFlixWebScreen extends StatefulWidget {
  final Anime anime;
  final Episode episode;

  const SuperFlixWebScreen({
    super.key,
    required this.anime,
    required this.episode,
  });

  /// Opens the resolver and returns the resolved video sources (may be empty).
  static Future<List<VideoSource>> resolve(
    BuildContext context, {
    required Anime anime,
    required Episode episode,
  }) async {
    final result = await Navigator.push<List<VideoSource>>(
      context,
      MaterialPageRoute(
        builder: (_) => SuperFlixWebScreen(anime: anime, episode: episode),
        fullscreenDialog: true,
      ),
    );
    return result ?? [];
  }

  @override
  State<SuperFlixWebScreen> createState() => _SuperFlixWebScreenState();
}

class _SuperFlixWebScreenState extends State<SuperFlixWebScreen> {
  late final WebViewController _controller;
  final _completer = Completer<List<Map<String, String>>>();
  Timer? _pollTimer;
  Timer? _timeout;
  bool _extracting = false;
  bool _done = false;
  bool _needsUser = false;
  String _status = 'Abrindo player...';

  String get _tmdbId => widget.anime.superFlixTmdbId ?? '';

  String? get _season {
    final m = RegExp('/serie/$_tmdbId/(\\d+)/').firstMatch(widget.episode.url);
    return m?.group(1);
  }

  String get _playerUrl {
    final season = _season ?? '1';
    // Use .pro directly (the canonical player host the others redirect to).
    return '${AppConstants.superFlixBase}/serie/$_tmdbId/$season/${widget.episode.number}';
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      )
      ..addJavaScriptChannel('SFResult', onMessageReceived: _onResult)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => _tryExtract(),
      ))
      ..loadRequest(Uri.parse(_playerUrl));

    // Poll in case the challenge resolves without a fresh onPageFinished.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _tryExtract(),
    );
    _timeout = Timer(const Duration(seconds: 90), () {
      if (!_completer.isCompleted) _completer.complete([]);
    });

    _completer.future.then(_finish);
  }

  Future<void> _tryExtract() async {
    if (_extracting || _done) return;
    _extracting = true;
    try {
      final ready = await _controller.runJavaScriptReturningResult(
        "(typeof CSRF_TOKEN !== 'undefined' && typeof PAGE_TOKEN !== 'undefined' "
        "&& document.title.indexOf('Verifica') === -1) ? '1' : '0'",
      );
      final readyStr = ready.toString().replaceAll('"', '');
      if (readyStr != '1') {
        if (mounted) {
          setState(() {
            _needsUser = true;
            _status = 'Complete a verificação na tela (use o controle)';
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _needsUser = false;
          _status = 'Extraindo servidores...';
        });
      }
      _done = true;
      _pollTimer?.cancel();
      await _controller.runJavaScript(_extractionJs);
    } catch (_) {
      // page not ready yet
    } finally {
      _extracting = false;
    }
  }

  void _onResult(JavaScriptMessage message) {
    if (_completer.isCompleted) return;
    try {
      final list = (jsonDecode(message.message) as List)
          .map((e) => {
                'name': (e['name'] ?? 'Auto').toString(),
                'url': (e['url'] ?? '').toString(),
              })
          .where((e) => e['url']!.isNotEmpty)
          .toList();
      _completer.complete(list);
    } catch (_) {
      _completer.complete([]);
    }
  }

  Future<void> _finish(List<Map<String, String>> servers) async {
    _timeout?.cancel();
    if (servers.isEmpty) {
      if (mounted) Navigator.pop(context, <VideoSource>[]);
      return;
    }
    if (mounted) setState(() => _status = 'Resolvendo vídeo...');
    // SuperFlix not implemented yet
    if (mounted) Navigator.pop(context, <VideoSource>[]);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Stack(
        children: [
          // The WebView must render (and be interactive) for Turnstile to run.
          Positioned.fill(child: WebViewWidget(controller: _controller)),
          // While the challenge needs the user, show only a bottom hint banner
          // (non-blocking). Otherwise show a full loading overlay.
          if (_needsUser)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.black.withValues(alpha: 0.75),
                child: Row(
                  children: [
                    const Icon(Icons.verified_user,
                        color: ThemeConstants.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.65),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                          color: ThemeConstants.primary),
                      const SizedBox(height: 20),
                      Text(
                        _status,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'SuperFlix',
                        style: TextStyle(
                            color: ThemeConstants.textSecondary, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            top: 24,
            left: 16,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => Navigator.pop(context, <VideoSource>[]),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 28),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// In-page JS: reads tokens, enumerates bootstrap servers, and calls
  /// /player/source for each to collect their video_url. Same-origin fetch
  /// carries the cf_clearance cookie automatically. Posts a JSON array back.
  static const String _extractionJs = '''
    (async function() {
      function reVal(re){ var m = document.documentElement.innerHTML.match(re); return m ? m[1] : ''; }
      try {
        var csrf = (typeof CSRF_TOKEN !== 'undefined' && CSRF_TOKEN) || reVal(/CSRF_TOKEN\\s*=\\s*"([^"]+)"/);
        var pageToken = (typeof PAGE_TOKEN !== 'undefined' && PAGE_TOKEN) || reVal(/PAGE_TOKEN\\s*=\\s*"([^"]+)"/);
        var contentId = (typeof INITIAL_CONTENT_ID !== 'undefined' && INITIAL_CONTENT_ID) || reVal(/INITIAL_CONTENT_ID\\s*=\\s*(\\d+)/);
        var contentType = (typeof CONTENT_TYPE !== 'undefined' && CONTENT_TYPE) || reVal(/CONTENT_TYPE\\s*=\\s*"([^"]+)"/);
        if (!csrf || !pageToken) { SFResult.postMessage('[]'); return; }
        var hdr = {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-Requested-With': 'XMLHttpRequest',
          'X-Page-Token': pageToken
        };
        var bootBody = 'contentid=' + contentId + '&type=' + contentType +
          '&_token=' + encodeURIComponent(csrf) +
          '&page_token=' + encodeURIComponent(pageToken) +
          '&pageToken=' + encodeURIComponent(pageToken);
        var br = await fetch('/player/bootstrap', {method:'POST', headers:hdr, body:bootBody, credentials:'include'});
        var bj = await br.json();
        var options = (bj.data && bj.data.options) || [];
        var out = [];
        for (var i=0; i<options.length; i++) {
          var o = options[i];
          var id = String(o.ID);
          if (id.indexOf('fallback') === 0) continue;
          var srcBody = 'video_id=' + encodeURIComponent(id) +
            '&page_token=' + encodeURIComponent(pageToken) +
            '&host=&site=&_token=' + encodeURIComponent(csrf);
          try {
            var sr = await fetch('/player/source', {method:'POST', headers:hdr, body:srcBody, credentials:'include'});
            var sj = await sr.json();
            if (sj.data && sj.data.video_url) {
              out.push({name: (o.name || 'Auto'), url: sj.data.video_url});
            }
          } catch (e) {}
        }
        SFResult.postMessage(JSON.stringify(out));
      } catch (e) {
        SFResult.postMessage('[]');
      }
    })();
  ''';
}
