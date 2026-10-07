import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/constants/theme_constants.dart';

/// Player de fallback por WebView: abre a página do episódio no site do
/// provedor dentro de um navegador embarcado. É o caminho para quando a
/// extração nativa falha — os sites PT-BR passaram a usar players com
/// JavaScript (Blogger SPA, `animeq-player`, Cloudflare no CDN do AnimeFire),
/// que um cliente HTTP puro não resolve; o Chromium do WebView resolve.
///
/// Controles (D-pad): OK = play/pause, ←/→ = -/+10s, BACK = sair. O app injeta
/// um helper JS (`window.__gaPlayer`) e opera o `<video>` direto — funciona
/// mesmo quando o site não trata teclado.
class WebViewPlayerScreen extends StatefulWidget {
  const WebViewPlayerScreen({
    super.key,
    required this.url,
    this.title,
  });

  final String url;
  final String? title;

  @override
  State<WebViewPlayerScreen> createState() => _WebViewPlayerScreenState();
}

class _WebViewPlayerScreenState extends State<WebViewPlayerScreen> {
  late final WebViewController _controller;
  final FocusNode _rootFocus = FocusNode();
  bool _loading = true;
  String? _loadError;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// JS que expõe o controle do `<video>`, tenta autoplay e auto-clica no
  /// botão "Assistir" da página do provedor (o D-pad do Flutter não chega no
  /// site, então a navegação inicial precisa ser automática).
  static const _helperJs = r'''
(function(){
  function report(o){ try { if (window.gaNet) gaNet.postMessage(JSON.stringify(o)); } catch(e){} }
  if (!window.__gaNetHooked) {
    window.__gaNetHooked = true;
    try {
      var of = window.fetch;
      if (of) window.fetch = function(){
        var a=arguments; var u=(typeof a[0]==='string')?a[0]:(a[0]&&a[0].url);
        return of.apply(this,a).then(function(r){ report({t:'fetch',u:u,s:r.status}); return r; },
                                     function(e){ report({t:'fetch',u:u,s:'ERR'}); throw e; });
      };
    } catch(e){}
    try {
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m,u){ this.__u=u; return oo.apply(this,arguments); };
      XMLHttpRequest.prototype.send = function(){ var x=this;
        x.addEventListener('loadend', function(){ report({t:'xhr',u:x.__u,s:x.status}); });
        return os.apply(this,arguments); };
    } catch(e){}
  }
  if (window.__gaPlayer) { window.__gaPlayer.attach(); window.__gaPlayer.autoWatch(); return; }
  window.__gaPlayer = {
    v: function(){ return document.querySelector('video'); },
    play: function(){ var v=this.v(); if(!v) return; try { v.play(); } catch(e){} },
    toggle: function(){ var v=this.v(); if(!v) return; try { v.paused ? v.play() : v.pause(); } catch(e){} },
    seek: function(d){ var v=this.v(); if(!v) return; try { v.currentTime = Math.max(0, (v.currentTime||0) + d); } catch(e){} },
    full: function(){
      try {
        if (document.fullscreenElement) { document.exitFullscreen(); }
        else { var v=this.v()||document.documentElement; (v.requestFullscreen||function(){}).call(v); }
      } catch(e){}
    },
    autoWatch: function(){
      try {
        if (document.querySelector('video')) return true;
        if (window.__gaWatched) return false;
        var els = document.querySelectorAll('a,button,[role="button"]');
        for (var i=0;i<els.length;i++){
          var t=(els[i].textContent||'').replace(/\s+/g,' ').trim().toLowerCase();
          if (t.indexOf('assistir')>=0) { window.__gaWatched=true; els[i].click(); return true; }
        }
      } catch(e){}
      return false;
    },
    attach: function(){
      var v = this.v(); if(!v) return;
      try { v.muted = false; } catch(e){}
      try { v.play(); } catch(e){}
      if (!v.__gaWired) {
        v.__gaWired = true;
        v.addEventListener('ended', function(){
          try { window.NavCtl && NavCtl.postMessage(JSON.stringify({ev:'ended'})); } catch(e){}
        });
      }
    }
  };
  window.__gaPlayer.attach();
  window.__gaPlayer.autoWatch();
  // Retry: o player pode montar o <video> só depois / o botão aparecer tarde.
  var tries=0;
  var iv=setInterval(function(){
    tries++;
    window.__gaPlayer.attach();
    if (!window.__gaPlayer.v()) window.__gaPlayer.autoWatch();
    if(tries>=120) clearInterval(iv);
  }, 700);
})();
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('gaNet', onMessageReceived: (m) {
        debugPrint('[WVNET] ${m.message}');
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (_) {
          _controller.runJavaScript(_helperJs);
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (e) {
          // Só erro do frame principal: sub-recursos (ads, trackers) falham
          // o tempo todo e não devem cobrir o player.
          if (e.isForMainFrame != true) return;
          if (!mounted) return;
          setState(() {
            _loading = false;
            _loadError = e.description;
          });
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
    // Android: permite autoplay sem gesto (TV não tem toque).
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _run(String js) async {
    try {
      await _controller.runJavaScript(js);
    } catch (_) {}
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHideControls();
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      _run('window.__gaPlayer && window.__gaPlayer.toggle();');
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _run('window.__gaPlayer && window.__gaPlayer.seek(-10);');
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _run('window.__gaPlayer && window.__gaPlayer.seek(10);');
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      // Deixa o foco nativo do site (se houver) — não consome.
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _rootFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(
              child: WebViewWidget(controller: _controller),
            ),
            if (_loading)
              const Center(
                child: CircularProgressIndicator(color: Color(0xFF21D3FF)),
              ),
            if (_loadError != null && !_loading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Não foi possível abrir o player do site.\n$_loadError',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
              ),
            if (_controlsVisible)
              Positioned(
                left: 16,
                top: 12,
                child: Row(
                  children: [
                    _ChipButton(
                      icon: Icons.arrow_back,
                      label: 'Voltar',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    if (widget.title != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          widget.title!,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                        ),
                      ),
                  ],
                ),
              ),
            if (_controlsVisible)
              Positioned(
                right: 16,
                bottom: 16,
                child: Row(
                  children: [
                    _ChipButton(
                      icon: Icons.replay_10,
                      label: '-10s',
                      onTap: () =>
                          _run('window.__gaPlayer && window.__gaPlayer.seek(-10);'),
                    ),
                    const SizedBox(width: 8),
                    _ChipButton(
                      icon: Icons.play_arrow,
                      label: 'Play/Pause',
                      onTap: () =>
                          _run('window.__gaPlayer && window.__gaPlayer.toggle();'),
                    ),
                    const SizedBox(width: 8),
                    _ChipButton(
                      icon: Icons.forward_10,
                      label: '+10s',
                      onTap: () =>
                          _run('window.__gaPlayer && window.__gaPlayer.seek(10);'),
                    ),
                    const SizedBox(width: 8),
                    _ChipButton(
                      icon: Icons.fullscreen,
                      label: 'Tela cheia',
                      onTap: () =>
                          _run('window.__gaPlayer && window.__gaPlayer.full();'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  const _ChipButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ThemeConstants.accent.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: ThemeConstants.accent, size: 18),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
