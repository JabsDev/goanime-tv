/// Sincronia A/V no player mpv (media_kit).
///
/// Sintoma alvo: em aparelho fraco (projetor H713, 1 GB) o vídeo começa
/// engasgado e, depois de estabilizar, o áudio fica ADIANTADO em relação ao
/// vídeo. Causa típica: o decode/render não acompanha o relógio de áudio
/// (`video-sync=audio`, default do mpv). Sem `framedrop`, o mpv exibe cada
/// frame atrasado em vez de descartá-lo, e o vídeo "fica para trás" do áudio.
///
/// Lógica pura (sem bpy/IO) para ser testável — a aplicação no player vive em
/// `features/player/player_screen.dart`.
class AvSync {
  const AvSync._();

  /// Passo do ajuste manual (◀ ▶ com o botão A/V focado).
  static const int stepMs = 50;

  /// Limite do ajuste manual: ±2 s.
  static const int maxAbsMs = 2000;

  /// Propriedades mpv aplicadas ANTES de cada `open()`.
  ///
  /// - `video-sync=audio`: o áudio é o relógio (default do mpv; explícito para
  ///   não depender do default de build).
  /// - `framedrop=vo`: descarta frame atrasado no VO em vez de exibi-lo fora
  ///   de hora — é o que impede o vídeo de ficar para trás do áudio.
  /// - `ao=audiotrack,opensles`: o media_kit força `opensles` (deprecado no
  ///   Android 13, latência alta). `audiotrack` reporta a latência real por
  ///   timestamp; `opensles` fica como fallback se o driver não existir.
  /// - `cache-on-disk=no`: o media_kit liga cache em disco; em eMMC lento
  ///   isso vira I/O disputando com o decode no começo do episódio.
  /// - `demuxer-max-back-bytes` (só aparelho fraco): o media_kit reserva
  ///   32 MB de cache "para trás" (seek). 8 MB libera RAM sem mexer no
  ///   buffer de leitura à frente.
  static Map<String, String> mpvProperties({
    bool android = true,
    required bool lowEnd,
  }) {
    return {
      'video-sync': 'audio',
      'framedrop': 'vo',
      'cache-on-disk': 'no',
      if (android) 'ao': 'audiotrack,opensles',
      if (lowEnd) 'demuxer-max-back-bytes': '8388608',
    };
  }

  /// `audio-delay` do mpv, em segundos. Positivo ATRASA o áudio (o vídeo entra
  /// antes) — exatamente a correção para "áudio adiantado".
  static String delaySeconds(int ms) => (ms / 1000).toStringAsFixed(3);

  static int clampDelay(int ms) => ms.clamp(-maxAbsMs, maxAbsMs);

  /// Ajuste por passo, arredondado ao múltiplo de [stepMs] mais próximo.
  static int nudge(int currentMs, int deltaMs) {
    final rounded = ((currentMs + deltaMs) / stepMs).round() * stepMs;
    return clampDelay(rounded);
  }

  /// Rótulo curto do botão; `0` = sem ajuste (estado de fábrica).
  static String label(int ms) {
    if (ms == 0) return 'A/V 0';
    final sign = ms > 0 ? '+' : '-';
    return 'A/V $sign${ms.abs()}ms';
  }
}
