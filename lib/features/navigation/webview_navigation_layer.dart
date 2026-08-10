import 'package:flutter/services.dart';

/// Camada de navegação D-pad no WebView de login AniList (TV).
///
/// Plano: PLANO_DPAD_WEBVIEW_LOGIN_MELHORADO.md
///
/// História (pra não repetir): o motor espacial/linear "inventava" foco com
/// caixa posicionada via getBoundingClientRect + índice que dessincronizava
/// com a página. E o WebView nativo não recebe as setas sozinho (Falha 1 do
/// plano). A solução é a Camada 1 do plano, feita honesta:
///
/// - Flutter captura as setas/OK no `Focus` e traduz para comandos JS.
/// - O JS percorre os elementos focáveis NA ORDEM DO DOM (como TAB), foca com
///   `focus()` nativo (que abre o IME do SO em inputs) e destaca com `outline`
///   no próprio elemento — nada de posições copiadas, nada de índices fixos.
/// - Enter = `click()` no elemento real focado (igual ao browser).
///
/// A camada só é injetada sob a flag `WEBVIEW_NAV` e nunca quando credenciais
/// de teste estão presentes.
class WebViewNavigationLayer {
  /// Flag que liga a camada. Off por padrão (não interferir no build atual).
  static const bool enabled = bool.fromEnvironment('WEBVIEW_NAV');

  /// Canal JS→Flutter de diagnóstico.
  static const String channel = 'NavCtl';

  /// Logs extras: reporta `document.activeElement` a cada keydown.
  static const bool debug = bool.fromEnvironment('WEBVIEW_NAV_DEBUG');

  static const String _sel =
      'a[href], button, select, textarea, '
      'input:not([type="hidden"]):not([type="submit"]), '
      '[role="button"], [contenteditable], [tabindex], iframe, .submit';
  // ponytail: .submit = botão 'Login' do AniList é uma `<div class="submit">`
  // com @click, sem role/tabindex (login.vue do SPA). Sem a classe, o D-pad
  // pulava da senha direto para o link 'Forgot password?'.

  /// JS injetado: TAB-like na ordem do DOM, foco nativo, destaque real.
  static const String source = '''
(function() {
  if (window.__gatvNav) return;
  window.__gatvNav = {};
  var PROBE = $debug;
  var SEL = '$_sel';

  function activeTag() {
    var a = document.activeElement;
    return a ? (a.tagName + (a.type ? '[' + a.type + ']' : '')) : 'none';
  }
  function report(ev, extra) {
    var s = { ev: ev, active: activeTag() };
    if (extra) for (var k in extra) s[k] = extra[k];
    try { window.NavCtl && NavCtl.postMessage(JSON.stringify(s)); } catch(e) {}
  }
  function isText(el) {
    if (!el) return false;
    if (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /text|email|password|search|number|tel/.test(el.type))) return true;
    return el.isContentEditable === true;
  }
  function visible(e) {
    var b = e.getBoundingClientRect();
    return b.width > 0 && b.height > 0;
  }
  function collect() {
    var els = document.querySelectorAll(SEL);
    var out = [];
    for (var i = 0; i < els.length; i++) {
      if (visible(els[i])) out.push(els[i]);
    }
    return out;
  }
  // Sempre recalcula: lista fresca a cada tecla, sem índices guardados.
  function move(dir) {
    var items = collect();
    if (!items.length) return;
    var cur = document.activeElement;
    var idx = -1;
    for (var i = 0; i < items.length; i++) {
      if (items[i] === cur || items[i].contains(cur)) { idx = i; break; }
    }
    var step = (dir === 'down' || dir === 'right') ? 1 : -1;
    if (idx < 0) {
      // Sem âncora: primeira tecla cai no primeiro campo editável (email).
      for (var j = 0; j < items.length; j++) {
        if (isText(items[j])) { setFocus(items[j]); return; }
      }
      setFocus(items[0]);
      return;
    }
    var t = idx + step;
    if (t < 0 || t >= items.length) return;
    setFocus(items[t]);
  }
  function setFocus(el) {
    try {
      el.focus({ preventScroll: true });
      if (el.scrollIntoView) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
    } catch(e) {}
    highlight(el);
    report('focus', { tag: el.tagName + ':' + (el.type || '') });
    // Sincroniza o preview do teclado overlay (só se já houver valor).
    if (isText(el) && (el.value || '').length) reportChar(el);
  }
  // Destaque no PRÓPRIO elemento: outline real, dessincronização impossível.
  function highlight(el) {
    var prev = document.querySelector('.gatv-nav-hl');
    if (prev && prev !== el) prev.classList.remove('gatv-nav-hl');
    if (el) el.classList.add('gatv-nav-hl');
  }
  function activate() {
    var el = document.activeElement;
    if (!el) return;
    if (isText(el)) {
      // Já está focado via setFocus; reforça e reporta (IME vira overlay no app).
      try { el.focus(); } catch(e) {}
      report('activate-input');
      return;
    }
    if (el.tagName === 'IFRAME') { try { el.focus(); } catch(e) {} report('activate-iframe'); return; }
    try { el.click(); report('click', { tag: el.tagName }); } catch(e) {}
  }
  // Digitação via teclado overlay do app: setter nativo + evento (mesmo
  // padrão do _fillJs), inserindo na posição do cursor quando existe.
  function setTextValue(el, v) {
    var proto = el.tagName === 'TEXTAREA'
      ? window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement.prototype;
    var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch(e) {}
  }
  function typed() {
    var a = document.activeElement;
    if (!isText(a)) return null;
    var v = a.value || '';
    var idx = (a.selectionStart !== null && a.selectionStart !== undefined) ? a.selectionStart : v.length;
    return { el: a, v: v, idx: idx };
  }
  function char(ch) {
    var t = typed();
    if (!t) return;
    setTextValue(t.el, t.v.slice(0, t.idx) + ch + t.v.slice(t.idx));
    try { t.el.setSelectionRange(t.idx + 1, t.idx + 1); } catch(e) {}
    reportChar(t.el);
  }
  function backspace() {
    var t = typed();
    if (!t || !t.v.length) return;
    var n = Math.max(0, t.idx - 1);
    setTextValue(t.el, t.v.slice(0, n) + t.v.slice(t.idx));
    try { t.el.setSelectionRange(n, n); } catch(e) {}
    reportChar(t.el);
  }
  // Manda o valor atual (mascarado p/ senhas) para o teclado overlay exibir.
  function reportChar(el) {
    var v = el.value || '';
    var masked = el.type === 'password' || el.type === 'search';
    report('char', { len: v.length, masked: masked ? 1 : 0, text: masked ? new Array(v.length + 1).join('•') : v });
  }
  function init() {
    var style = document.createElement('style');
    style.textContent = '.gatv-nav-hl{outline:3px solid #ff8c00 !important;outline-offset:2px;border-radius:4px;}';
    document.head.appendChild(style);
    // Foco inicial no primeiro campo editável, se houver.
    var items = collect();
    for (var j = 0; j < items.length; j++) {
      if (isText(items[j])) { setFocus(items[j]); return; }
    }
    report('ready', { count: items.length });
  }
  // API pública Flutter→JS
  window.__gatvNav.move = move;
  window.__gatvNav.activate = activate;
  window.__gatvNav.char = char;
  window.__gatvNav.backspace = backspace;
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    setTimeout(init, 300);
  }
})();
''';

  /// Direção D-pad a partir de um [LogicalKeyboardKey] (setas).
  static final Map<LogicalKeyboardKey, String> _arrowMap = {
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
  };

  /// Traduz um [KeyEvent] do remoto/TV em comando JS. Retorna o comando
  /// `runJavaScript` a executar, ou `null` se a tecla não pertence à camada.
  static String? commandForKey(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final k = event.logicalKey;
    final dir = _arrowMap[k];
    if (dir != null) return '__gatvNav.move(\'$dir\')';
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      return '__gatvNav.activate()';
    }
    return null;
  }
}