import 'dart:io';

import 'package:flutter/foundation.dart';

import 'legendai_connection.dart';
import 'legendai_queue_sync.dart';
import 'legendai_remote_job.dart';

/// Fachada da rota remota que a UI consome. Um único espelho da fila do PC
/// (mesmo em qualquer tela) por cima do [`LegendAiQueueSync`].
///
/// Espelha o papel do `SubtitleJobManager`, mas para jobs no LegendAI: o PC é
/// a fonte de verdade e este objeto só projeta estado/baixa o SRT.
class LegendAiJobManager {
  LegendAiJobManager._({LegendAiQueueSync? sync})
    : sync = sync ?? LegendAiQueueSync();

  static final LegendAiJobManager instance = LegendAiJobManager._();

  final LegendAiQueueSync sync;

  LegendAiConnection get connection => LegendAiConnection.instance;

  /// Espelho da fila remota (mais recente primeiro).
  ValueListenable<List<RemoteJob>> get jobs => sync.jobs;

  Future<void> init() => sync.init();

  RemoteJob? jobFor({required String animeKey, required int ep}) =>
      sync.jobForClientId(LegendAiQueueSync.clientJobIdFor(animeKey, ep));

  /// Job remoto do episódio, de qualquer rota (URL, rota S ou upload).
  RemoteJob? jobForEpisode({required String animeKey, required int ep}) =>
      sync.jobForEpisode(animeKey, ep);

  /// Enfileira o episódio no PC (rota remota só tem áudio→SRT por URL).
  Future<RemoteJob?> generate({
    required String animeKey,
    required int ep,
    required String url,
    Map<String, String> headers = const {},
    String sourceLang = 'auto',
    String tag = 'ja-ai',
    String? preferredStt,
    String? preferredTranslation,
  }) {
    return sync.submit(
      animeKey: animeKey,
      episode: ep,
      url: url,
      headers: headers,
      sourceLang: sourceLang,
      tag: tag,
      preferredStt: preferredStt,
      preferredTranslation: preferredTranslation,
    );
  }

  /// Rota S remota (Fase 5): traduz no PC um SRT EN/ES já pronto.
  Future<RemoteJob?> generateSrt({
    required String animeKey,
    required int ep,
    required String srt,
    required String sourceLang,
    String tag = 'en-ai',
  }) {
    return sync.submitSrt(
      animeKey: animeKey,
      episode: ep,
      srt: srt,
      sourceLang: sourceLang,
      tag: tag,
    );
  }

  /// Fallback de upload (Fase 5): envia o áudio já extraído pelo aparelho.
  Future<RemoteJob?> generateUpload({
    required String animeKey,
    required int ep,
    required File audioFile,
    String format = 's16le',
    String sourceLang = 'auto',
    String tag = 'ja-ai',
  }) {
    return sync.submitUpload(
      animeKey: animeKey,
      episode: ep,
      audioFile: audioFile,
      format: format,
      sourceLang: sourceLang,
      tag: tag,
    );
  }

  Future<void> refresh() => sync.refresh();

  Future<void> cancel(RemoteJob job) => sync.cancel(job);

  Future<void> remove(RemoteJob job) => sync.remove(job);

  /// @visibleForTesting permite injetar um sync (mock de conexão).
  @visibleForTesting
  static LegendAiJobManager createForTest(LegendAiQueueSync sync) =>
      LegendAiJobManager._(sync: sync);
}
