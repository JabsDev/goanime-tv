import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/player/av_sync.dart';

/// Self-checks do tuning de sincronia A/V (lógica pura, sem player).
void main() {
  test('mpvProperties liga framedrop=vo e video-sync=audio', () {
    final props = AvSync.mpvProperties(lowEnd: false);
    expect(props['video-sync'], 'audio');
    // Sem isto o vídeo atrasado é exibido mesmo assim e o áudio "adianta".
    expect(props['framedrop'], 'vo');
    expect(props['cache-on-disk'], 'no');
    // audiotrack primeiro (latência real por timestamp), opensles de fallback.
    expect(props['ao'], 'audiotrack,opensles');
    // Aparelho forte não paga o custo de cache "para trás" reduzido.
    expect(props.containsKey('demuxer-max-back-bytes'), isFalse);
  });

  test('mpvProperties só mexe em ao no Android', () {
    final props = AvSync.mpvProperties(android: false, lowEnd: false);
    expect(props.containsKey('ao'), isFalse);
    expect(props['framedrop'], 'vo');
  });

  test('aparelho fraco reduz o cache para trás (RAM)', () {
    final props = AvSync.mpvProperties(lowEnd: true);
    expect(props['demuxer-max-back-bytes'], '8388608');
    // O buffer de leitura à frente NÃO é reduzido: não trocar stall por sync.
    expect(props.containsKey('demuxer-max-bytes'), isFalse);
  });

  test('delaySeconds: positivo adianta? não — atrasa o áudio no mpv', () {
    expect(AvSync.delaySeconds(150), '0.150');
    expect(AvSync.delaySeconds(-150), '-0.150');
    expect(AvSync.delaySeconds(0), '0.000');
  });

  test('nudge anda de 50 em 50 e não passa de ±2 s', () {
    expect(AvSync.nudge(0, AvSync.stepMs), 50);
    expect(AvSync.nudge(50, -AvSync.stepMs), 0);
    expect(AvSync.nudge(0, -AvSync.stepMs), -50);
    expect(AvSync.nudge(AvSync.maxAbsMs, AvSync.stepMs), AvSync.maxAbsMs);
    expect(AvSync.nudge(-AvSync.maxAbsMs, -AvSync.stepMs), -AvSync.maxAbsMs);
  });

  test('clampDelay limita leitura de disco corrompida', () {
    expect(AvSync.clampDelay(99999), AvSync.maxAbsMs);
    expect(AvSync.clampDelay(-99999), -AvSync.maxAbsMs);
    expect(AvSync.clampDelay(120), 120);
  });

  test('label mostra o ajuste atual', () {
    expect(AvSync.label(0), 'A/V 0');
    expect(AvSync.label(150), 'A/V +150ms');
    expect(AvSync.label(-200), 'A/V -200ms');
  });
}
