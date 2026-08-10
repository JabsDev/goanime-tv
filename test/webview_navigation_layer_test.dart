import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/features/navigation/webview_navigation_layer.dart';

void main() {
  group('WebViewNavigationLayer.commandForKey', () {
    KeyDownEvent down(LogicalKeyboardKey k) => KeyDownEvent(
          physicalKey: PhysicalKeyboardKey(0),
          logicalKey: k,
          timeStamp: Duration.zero,
        );

    test('setas mapeiam para move', () {
      expect(
          WebViewNavigationLayer.commandForKey(down(LogicalKeyboardKey.arrowUp)),
          "__gatvNav.move('up')");
      expect(
          WebViewNavigationLayer.commandForKey(
              down(LogicalKeyboardKey.arrowDown)),
          "__gatvNav.move('down')");
      expect(
          WebViewNavigationLayer.commandForKey(
              down(LogicalKeyboardKey.arrowLeft)),
          "__gatvNav.move('left')");
      expect(
          WebViewNavigationLayer.commandForKey(
              down(LogicalKeyboardKey.arrowRight)),
          "__gatvNav.move('right')");
    });

    test('select/enter/space mapeiam para activate', () {
      for (final k in [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.space,
      ]) {
        expect(WebViewNavigationLayer.commandForKey(down(k)),
            '__gatvNav.activate()');
      }
    });

    test('teclas alheias e key up não geram comando', () {
      expect(WebViewNavigationLayer.commandForKey(down(LogicalKeyboardKey.keyA)),
          isNull);
      final up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey(0),
        logicalKey: LogicalKeyboardKey.arrowDown,
        timeStamp: Duration.zero,
      );
      expect(WebViewNavigationLayer.commandForKey(up), isNull);
    });
  });

  group('WebViewNavigationLayer.source', () {
    test('destaque é outline no próprio elemento (nunca caixa copiada)', () {
      final src = WebViewNavigationLayer.source;
      expect(src, contains('classList.add'));
      expect(src, contains('outline'));
      // Sem box fixo posicionado (o bug de dessincronização das versões antigas).
      expect(src, isNot(contains('position:fixed')));
      expect(src, isNot(contains('gatv-nav-box')));
    });

    test('fonte é JS válido (chaves balanceadas)', () {
      final src = WebViewNavigationLayer.source;
      int depth = 0;
      for (final ch in src.split('')) {
        if (ch == '{') depth++;
        if (ch == '}') depth--;
        expect(depth >= 0, isTrue, reason: 'chave fechando sem abrir');
      }
      expect(depth, 0, reason: 'chaves desbalanceadas');
    });
  });
}