import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'device_profile.dart';

/// Benchmark de vídeo: toca clipes H.264 locais em 480p/720p/1080p e mede os
/// fps efetivos do pipeline real do mpv (decode + filtros + saída de vídeo).
///
/// Por que não um microbenchmark de CPU: um A53 de 1,3 GHz pode pontuar bem
/// em inteiros/float e ainda engasgar em 720p por causa do decode/render e da
/// disputa de RAM com o Flutter. O fps medido aqui é a evidência que importa
/// para decidir o teto de qualidade.
///
/// A ordem é crescente e o teste para na primeira resolução que não sustenta
/// tempo real — não adianta medir 1080p num aparelho que já falhou em 720p.
///
/// IMPORTANTE: o [VideoController] devolvido em [onController] precisa estar
/// na árvore de widgets (um `Video` pequeno já basta). Sem ninguém consumindo
/// a textura, o mpv para de entregar frames e a medição vira lixo.
class VideoBenchmarkRunner {
  VideoBenchmarkRunner({this.onStage, this.onController});

  /// Progresso legível ("Testando 720p…") para a UI.
  final void Function(String stage)? onStage;

  /// Recebe o controller para exibir o clipe; `null` ao terminar/descartar.
  final void Function(VideoController? controller)? onController;

  /// Resoluções testadas, em ordem crescente.
  static const List<int> heights = [480, 720, 1080];

  static const Duration warmup = Duration(milliseconds: 1200);
  static const Duration window = Duration(milliseconds: 4000);
  static const Duration sampleEvery = Duration(milliseconds: 400);
  static const Duration firstFrameTimeout = Duration(seconds: 8);

  String assetFor(int height) => 'asset:///assets/bench/bench_${height}p.mp4';

  Player? _player;

  /// Roda o teste completo. Devolve `null` quando nada pôde ser medido
  /// (desktop sem libmpv, clipes ausentes, propriedades indisponíveis).
  Future<VideoBenchmark?> run() async {
    final sw = Stopwatch()..start();
    Player? player;
    try {
      player = Player();
      _player = player;
      onController?.call(VideoController(player));

      final fpsByHeight = <int, double>{};
      var containerFps = 30.0;
      var hardwareDecode = false;

      for (final height in heights) {
        onStage?.call('Testando ${height}p…');
        _StepResult? step;
        try {
          step = await _measure(player, height).timeout(
            const Duration(seconds: 20),
          );
        } catch (e) {
          // Timeout/erro numa resolução não invalida o que já foi medido.
          debugPrint('[VideoBenchmark] ${height}p abortou: $e');
          step = null;
        }
        if (step == null) break;
        containerFps = step.containerFps;
        hardwareDecode = step.hardwareDecode;
        fpsByHeight[height] = step.fps;
        if (!videoSustainsFps(step.fps, step.containerFps)) break;
      }

      if (fpsByHeight.isEmpty) return null;
      onStage?.call('Concluído');
      return VideoBenchmark(
        fpsByHeight: fpsByHeight,
        containerFps: containerFps,
        hardwareDecode: hardwareDecode,
        elapsed: sw.elapsed,
      );
    } catch (e) {
      debugPrint('[VideoBenchmark] falhou: $e');
      return null;
    } finally {
      onController?.call(null);
      _player = null;
      try {
        await player?.dispose();
      } catch (e) {
        debugPrint('[VideoBenchmark] dispose falhou: $e');
      }
    }
  }

  Future<void> dispose() async {
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  Future<_StepResult?> _measure(Player player, int height) async {
    // Assina o primeiro frame ANTES do open para não perder o evento. Confere
    // a altura para não aceitar um evento atrasado do clipe anterior.
    final firstFrame = player.stream.videoParams
        .firstWhere(
          (p) =>
              (p.w ?? 0) > 0 &&
              (p.h ?? 0) > 0 &&
              ((p.h ?? 0) - height).abs() <= 2,
        )
        // Se o timeout/descarte fechar o stream antes do frame, o firstWhere
        // estoura StateError — engolir aqui evita erro assíncrono solto.
        .then<VideoParams?>((p) => p, onError: (Object _) => null);
    await player.open(Media(assetFor(height)));
    VideoParams? first;
    try {
      first = await firstFrame.timeout(firstFrameTimeout);
    } catch (_) {
      first = null;
    }
    if (first == null) {
      debugPrint('[VideoBenchmark] ${height}p sem primeiro frame');
      return null;
    }

    await Future<void>.delayed(warmup); // descarta o pico de inicialização

    final containerFps = await _number(player, 'container-fps') ?? 30;
    final hwdec = await _text(player, 'hwdec-current');
    final hardwareDecode = hwdec.isNotEmpty && hwdec != 'no';
    final dropsBefore = await _drops(player);
    final posBefore = await _number(player, 'time-pos');

    final samples = <double>[];
    final sw = Stopwatch()..start();
    while (sw.elapsed < window) {
      final fps = await _number(player, 'estimated-vf-fps');
      if (fps != null && fps > 0) samples.add(fps);
      await Future<void>.delayed(sampleEvery);
    }
    final elapsed = sw.elapsed;
    final dropsAfter = await _drops(player);
    final posAfter = await _number(player, 'time-pos');

    final int? dropped = (dropsBefore != null && dropsAfter != null)
        ? (dropsAfter - dropsBefore).clamp(0, 1 << 20)
        : null;
    // Playback atrasado (VO/GPU lento) não vira "drop" quando o mpv não está
    // autorizado a descartar: o relógio do vídeo simplesmente anda mais devagar
    // que o relógio de parede. Isso também limita o fps efetivo.
    final double? played = (posBefore != null &&
            posAfter != null &&
            posAfter > posBefore)
        ? posAfter - posBefore
        : null;

    final fps = aggregateFps(
      samples: samples,
      targetFps: containerFps,
      droppedFrames: dropped,
      elapsed: elapsed,
      playedSeconds: played,
    );
    if (fps == null) {
      debugPrint('[VideoBenchmark] ${height}p sem amostras de fps');
      return null;
    }
    debugPrint(
      '[VideoBenchmark] ${height}p → ${fps.toStringAsFixed(1)} fps '
      '(alvo ${containerFps.toStringAsFixed(1)}, hwdec=$hwdec, '
      'pos=${played?.toStringAsFixed(2) ?? '?'}/${elapsed.inMilliseconds / 1000}s, '
      'amostra=${samples.map((e) => e.toStringAsFixed(1)).join('/')})',
    );
    return _StepResult(
      fps: fps,
      containerFps: containerFps,
      hardwareDecode: hardwareDecode,
    );
  }

  Future<String> _text(Player player, String property) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return '';
    try {
      final value = await platform.getProperty(property);
      return value.trim();
    } catch (_) {
      return '';
    }
  }

  Future<double?> _number(Player player, String property) async {
    final raw = await _text(player, property);
    if (raw.isEmpty) return null;
    return double.tryParse(raw.replaceAll(',', '.'));
  }

  /// `frame-drop-count` (saída) + `decoder-frame-drop-count` (decode).
  Future<int?> _drops(Player player) async {
    final vo = int.tryParse(await _text(player, 'frame-drop-count'));
    final dec = int.tryParse(await _text(player, 'decoder-frame-drop-count'));
    if (vo == null && dec == null) return null;
    return (vo ?? 0) + (dec ?? 0);
  }
}

class _StepResult {
  const _StepResult({
    required this.fps,
    required this.containerFps,
    required this.hardwareDecode,
  });

  final double fps;
  final double containerFps;
  final bool hardwareDecode;
}

/// Combina as amostras de `estimated-vf-fps` com o tempo realmente tocado e
/// os frames descartados.
///
/// Mediana das amostras (ignora picos isolados) e, quando disponível, o menor
/// entre: fps implícito pelo avanço do relógio do vídeo (`alvo × tocado/parede`)
/// e o teto conservador por drops (`alvo − drops/segundo`). Drops e atraso de
/// relógio não podem ser mascarados por uma média otimista.
@visibleForTesting
double? aggregateFps({
  required List<double> samples,
  required double targetFps,
  int? droppedFrames,
  required Duration elapsed,
  double? playedSeconds,
}) {
  final valid = samples.where((e) => e.isFinite && e > 0).toList();
  if (valid.isEmpty) return null;
  valid.sort();
  var fps = valid[valid.length ~/ 2];

  final seconds = elapsed.inMicroseconds / 1e6;
  if (seconds > 0 && targetFps > 0) {
    if (playedSeconds != null && playedSeconds > 0) {
      final clockFps = targetFps * (playedSeconds / seconds);
      if (clockFps.isFinite && clockFps > 0 && clockFps < fps) {
        fps = clockFps;
      }
    }
    if (droppedFrames != null && droppedFrames > 0) {
      final delivered = targetFps - droppedFrames / seconds;
      if (delivered.isFinite && delivered > 0 && delivered < fps) {
        fps = delivered;
      }
    }
  }
  return fps.clamp(0.0, 120.0);
}
