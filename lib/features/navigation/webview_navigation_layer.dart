import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Camada de navegação D-pad no WebView de login AniList (TV).
///
/// Plano: PLANO_DPAD_WEBVIEW_LOGIN_MELHORADO.md
/// - Camada 1 (TAB): movimenta o foco nativo via `focus()` ordenado por `tabIndex`
///   quando o feletor espacial falha.
/// - Camada 2 (foco espacial): coleta de clicáveis + busca geométrica (cone 45°),
///   com destaque (box), `MutationObserver` preservando o alvo por âncora.
/// - Camada 3 (cursor livre): toggle via MENU; setas movem o cursor em px;
///   OK → `elementFromPoint` + `click()`.
///
/// As setas/Enter do remoto são capturadas aqui (Flutter-side) e traduzidas para
/// comandos JS via [WebViewController.runJavaScript]. O JS da página também
/// registra um handler próprio de `keydown` como fallback para WebViews que não
/// entregam o evento ao Flutter primeiro. A camada só é injetada sob a flag
/// `WEBVIEW_NAV` e nunca quando credenciais de teste estão presentes.
class WebViewNavigationLayer {
  /// Flag que liga a camada. Off por padrão (não interferir no build atual);
  /// ligada pelo processo `--dart-define=WEBVIEW_NAV=true`.
  static const bool enabled = bool.fromEnvironment('WEBVIEW_NAV');

  /// Toggle para logs de estado (activeElement/modo/alvo) via canal [channel].
  static const String channel = 'NavCtl';

  /// Logs extras de Fase 0: reporta `document.activeElement` a cada keydown.
  static const bool debug = bool.fromEnvironment('WEBVIEW_NAV_DEBUG');

  static const int _cursorStep = 12;

  /// JS injetado. Um único arquivo cobre as Camadas 1-3 (operam sobre o mesmo
  /// índice de clicáveis), MENU alterna foco↔cursor.
  static const String source = '''
(function() {
  if (window.__gatvNav) return;
  var NAV_STEP = $_cursorStep;
  var PROBE = $debug;
  var SEL = [
    'a[href]', 'button', 'select', 'textarea',
    'input[type="text"], input[type="email"], input[type="password"], input[type="search"]',
    'input[type="checkbox"], input[type="radio"]',
    '[role="button"], [contenteditable], [tabindex]'
  ].join(',');
  var NAV = {
    mode: 'focus',       // 'focus' | 'cursor'
    items: [],
    idx: -1,
    cursor: { x: 80, y: 80 },
    step: NAV_STEP
  };
  var box = null, cur = null, debounce = null;
  var lastFlutterCmd = 0;

  function jsHandle() { lastFlutterCmd = Date.now(); }

  function log(msg) {
    try { window.NavCtl && NavCtl.postMessage(JSON.stringify({evt:'log', msg: msg})); } catch(e) {}
  }
  function report(ev, extra) {
    var s = { ev: ev, mode: NAV.mode, active: activeTag(), count: NAV.items.length, idx: NAV.idx };
    if (extra) for (var k in extra) s[k] = extra[k];
    try { window.NavCtl && NavCtl.postMessage(JSON.stringify(s)); } catch(e) {}
  }
  function activeTag() {
    var a = document.activeElement;
    return a ? (a.tagName + (a.type ? '[' + a.type + ']' : '')) : 'none';
  }
  function r(e) {
    var b = e.getBoundingClientRect();
    return { x: b.left, y: b.top, w: b.width, h: b.height, cx: b.left + b.width/2, cy: b.top + b.height/2 };
  }
  function visible(e) {
    var b = e.getBoundingClientRect();
    return b.width > 0 && b.height > 0 && b.top >= -50 && b.left >= -50 &&
           b.top < innerHeight + 50 && b.left < innerWidth + 50;
  }
  function collect() {
    var els = document.querySelectorAll(SEL);
    NAV.items = [];
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (!visible(el)) continue;
      var t = (el.tagName + ':' + (el.type || '') + ':' + (el.value || '') + ':' + el.textContent
        + ':' + el.href + ':' + el.className).slice(0, 64);
      el.setAttribute('data-nav-id', i + ':' + t.length);
      NAV.items.push(el);
    }
    report('state');
    mark();
  }
  // ==== Motor geométrico (Camada 2) ====
  function idxFromCur() {
    for (var i = 0; i < NAV.items.length; i++) {
      if (NAV.items[i] === document.activeElement) return i;
    }
    return NAV.idx;
  }
  function moveFocus(dir) {
    if (!NAV.items.length) return;
    var curEl = NAV.idx >= 0 && NAV.idx < NAV.items.length ? NAV.items[NAV.idx] : document.activeElement;
    var curRect = curEl && curEl.getBoundingClientRect().width ? r(curEl) : {cx: innerWidth/2, cy: innerHeight/2};
    var best = -1, bestScore = Infinity;
    for (var i = 0; i < NAV.items.length; i++) {
      var t = r(NAV.items[i]), d = dxdy(dir, t, curRect);
      if (d === null) continue;
      var score = d.dist + d.off * 0.5;   // distância + penalidade de desalinhamento
      if (score < bestScore) { bestScore = score; best = i; }
    }
    if (best >= 0) setIdx(best, true);
  }
  // Robusto: escore look a 45° (cone): elementos à frente com menor separação
  // perpendicular ganham; se o alvo está exatamente na mesma linha/coluna é o favorito.
  function dxdy(dir, t, c) {
    var vx = t.cx - c.cx, vy = t.cy - c.cy;
    var along, offIdx;
    if (dir === 'up')  { if (vy >= 0) return null; along = -vy; offIdx = Math.abs(vx); }
    if (dir === 'down'){ if (vy <= 0) return null; along = vy;  offIdx = Math.abs(vx); }
    if (dir === 'left'){ if (vx >= 0) return null; along = -vx; offIdx = Math.abs(vy); }
    if (dir === 'right'){ if (vx <= 0) return null; along = vx; offIdx = Math.abs(vy); }
    return { dist: Math.sqrt(along*along + offIdx*offIdx), off: offIdx };
  }
  function setIdx(i, focus) {
    NAV.idx = i;
    var el = NAV.items[i];
    mark(el);
    if (focus && el) {
      if (isText(el)) { el.focus({ preventScroll: true }); report('focus-input', { sx: el.scrollTop, sy: el.scrollLeft }); }
      else { el.focus(); scrollInto(el); }
    }
    report('idx', { i: i, tag: el ? (el.tagName + ':' + (el.type||'')) : 'none' });
  }
  function isText(el) {
    if (!el) return false;
    if (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /text|email|password|search|number|tel/.test(el.type))) return true;
    return el.isContentEditable === true;
  }
  function scrollInto(el) {
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' });
  }
  function mark(el) {
    if (!box) {
      box = document.createElement('div');
      box.className = 'gatv-nav-box';
      box.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;box-sizing:border-box;border:3px solid #ff8c00;background:rgba(255,140,0,.08);transition:all 90ms ease;border-radius:4px;';
      document.documentElement.appendChild(box);
      cur = document.createElement('div');
      cur.className = 'gatv-nav-cur';
      cur.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;width:14px;height:14px;border:2px solid #4fc3f7;background:rgba(79,195,247,.25);border-radius:50%;';
      document.documentElement.appendChild(cur);
    }
    if (NAV.mode === 'cursor') {
      var x = NAV.cursor.x, y = NAV.cursor.y;
      cur.style.left = (x - 7) + 'px'; cur.style.top = (y - 7) + 'px';
      cur.style.display = 'block'; box.style.display = 'none';
      return;
    }
    cur.style.display = 'none';
    var t = el || (NAV.idx >= 0 && NAV.idx < NAV.items.length ? NAV.items[NAV.idx] : null);
    if (t) {
      var b = t.getBoundingClientRect();
      box.style.left = (b.left - 2) + 'px'; box.style.top = (b.top - 2) + 'px';
      box.style.width = (b.width + 4) + 'px'; box.style.height = (b.height + 4) + 'px';
      box.style.display = 'block';
    } else {
      box.style.display = 'none';
    }
  }
  function activate() {
    if (NAV.mode === 'cursor') {
      var el = document.elementFromPoint(NAV.cursor.x, NAV.cursor.y);
      if (el) {
        var t = el.closest(SEL) || el;
        if (t && t.click) { hitFocus(t); t.click(); report('click', {x: NAV.cursor.x, y: NAV.cursor.y, tag: t.tagName}); }
        else el.focus();
      }
      return;
    }
    var el = NAV.idx >= 0 && NAV.idx < NAV.items.length ? NAV.items[NAV.idx] : document.activeElement;
    if (!el) return;
    if (isText(el)) { el.focus(); report('activate-input'); return; }
    if (el.tagName === 'IFRAME') { el.focus(); report('activate-iframe'); return; }
    hitFocus(el);
    try { el.click(); report('click', { tag: el.tagName, sel: navOf(el) }); }
    catch(e) { if (el.closest) { var fc = el.closest(SEL); if (fc && fc !== el) fc.click(); } }
  }
  function navOf(el) {
    return (el.getAttribute && el.getAttribute('data-nav-id')) || '';
  }
  function hitFocus(el) {
    if (isText(el)) return;
    try { el.focus(); } catch(e) {}
  }
  function toggleMode() {
    NAV.mode = NAV.mode === 'focus' ? 'cursor' : 'focus';
    if (NAV.mode === 'cursor') { NAV.cursor.x = NAV.cursor.x || 80; NAV.cursor.y = NAV.cursor.y || 80; }
    if (NAV.mode === 'focus') { NAV.idx = idxFromCur(); }
    mark();
    report('mode', { mode: NAV.mode });
  }
  function moveCursor(dir) {
    if (dir === 'up') NAV.cursor.y -= NAV.step;
    if (dir === 'down') NAV.cursor.y += NAV.step;
    if (dir === 'left') NAV.cursor.x -= NAV.step;
    if (dir === 'right') NAV.cursor.x += NAV.step;
    NAV.cursor.x = Math.min(Math.max(0, NAV.cursor.x), innerWidth);
    NAV.cursor.y = Math.min(Math.max(0, NAV.cursor.y), innerHeight);
    mark(); report('cursor', { x: NAV.cursor.x, y: NAV.cursor.y });
  }
  // CANal público Flutter→JS
  window.__gatvNav = {
    move: function(dir) {
      jsHandle();
      if (NAV.mode === 'cursor') moveCursor(dir);
      else moveFocus(dir);
    },
    activate: function() { jsHandle(); activate(); },
    toggle: function() { jsHandle(); toggleMode(); },
    collect: function() { collect(); },
    getState: function() { return { mode: NAV.mode, active: activeTag(), idx: NAV.idx, count: NAV.items.length }; }
  };
  // Fallback: página também escuta keydown quando o evento chega até aqui.
  document.addEventListener('keydown', function(e) {
    if (!window.__gatvNav) return;
    // se o Flutter já direcionou o comando via runJavaScript, não processar de novo
    if (Date.now() - lastFlutterCmd < 150) return;
    var k = e.keyCode;
    if (PROBE) report('probe', { active: activeTag(), key: e.key, code: k });
    if (k >= 19 && k <= 22 || e.key === 'ArrowUp' || e.key === 'ArrowDown' || e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      e.preventDefault(); e.stopPropagation();
      var d = { 19: 'up', 20: 'down', 21: 'left', 22: 'right' };
      window.__gatvNav.move(d[k] || e.key.replace('Arrow', '').toLowerCase());
    } else if (k === 13 || k === 66 || e.key === 'Enter') {
      e.preventDefault(); e.stopPropagation(); window.__gatvNav.activate();
    } else if (k === 82 || e.key === 'Menu' || e.key === 'ContextMenu') {
      e.preventDefault(); e.stopPropagation(); window.__gatvNav.toggle();
    }
  }, true);
  // re-coleta após SPA (debounce) — preserva âncora atual
  var MO = new MutationObserver(function() {
    clearTimeout(debounce);
    debounce = setTimeout(function(){ collect(); }, 300);
  });
  if (document.body) MO.observe(document.body, { childList: true, subtree: true });
  setTimeout(collect, 300);
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
    if (k == LogicalKeyboardKey.contextMenu) {
      return '__gatvNav.toggle()';
    }
    return null;
  }
}