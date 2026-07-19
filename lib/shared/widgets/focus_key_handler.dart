import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps [Focus.onKeyEvent] to intercept remote control activation keys
/// (Select, Enter, NumpadEnter, Space) and call [onTap] directly.
///
/// ponytail: FireTV remote envia Select logo seguido de ArrowRight (~7ms).
/// InkWell.onTap perde a race com a trava de foco do ArrowRight, e o tap
/// nunca dispara. Tratando Select aqui e chamando onTap direto, bypass do
/// InkWell activation. Reaproveitado do workaround inline do _EpisodeCard.
class FocusKeyHandler {
  static KeyEventResult handle(FocusNode node, KeyEvent event, VoidCallback onTap) {
    if (event is KeyDownEvent) {
      final k = event.logicalKey;
      if (k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.numpadEnter ||
          k == LogicalKeyboardKey.space) {
        onTap();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }
}