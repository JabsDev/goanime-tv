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
      expect(WebViewNavigationLayer.commandForKey(down(LogicalKeyboardKey.arrowUp)),
          "__gatvNav.move('up')");
      expect(WebViewNavigationLayer.commandForKey(down(LogicalKeyboardKey.arrowDown)),
          "__gatvNav.move('down')");
      expect(WebViewNavigationLayer.commandForKey(down(LogicalKeyboardKey.arrowLeft)),
          "__gatvNav.move('left')");
      expect(WebViewNavigationLayer.commandForKey(down(LogicalKeyboardKey.arrowRight)),
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

    test('context menu mapeia para toggle', () {
      expect(
          WebViewNavigationLayer.commandForKey(
              down(LogicalKeyboardKey.contextMenu)),
          '__gatvNav.toggle()');
    });

    test('teclas alheias e key up não geram comando', () {
      expect(
          WebViewNavigationLayer.commandForKey(down(LogicalKeyboardKey.keyA)),
          isNull);
      final up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey(0),
        logicalKey: LogicalKeyboardKey.arrowDown,
        timeStamp: Duration.zero,
      );
      expect(WebViewNavigationLayer.commandForKey(up), isNull);
    });
  });
}