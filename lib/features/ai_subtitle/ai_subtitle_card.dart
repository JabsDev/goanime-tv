import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/subtitles/ai_providers.dart';
import '../../core/subtitles/model_manager.dart';
import '../../core/subtitles/srt_parser.dart';
import '../../core/subtitles/subtitle_job_manager.dart';
import '../../core/subtitles/subtitle_store.dart';
import '../../core/utils/device_capability.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../shared/widgets/tv_button.dart';
import '../player/exo_dash_player_screen.dart';
import '../player/player_screen.dart';
import 'ai_model_row.dart';

/// Card da legenda IA dentro do picker (etapa Legenda, estudo §3.2): decisão
/// completa (rota auto + Voz + Tradução + Gerar + Resultado) sem sair do
/// dialog. Rota não é escolha manual: candidata EN/ES ⇒ Rota S; senão
/// transcrição do áudio. Estado do card = ValueNotifier(s) do
/// SubtitleJobManager + 1 Future único de status dos modelos.
class AiSubtitleCard extends StatefulWidget {
  final Anime anime;
  final CatalogEpisode episode;
  final int episodeIndex;
  final List<CatalogEpisode> episodeList;
  final AnimeSource provider;
  final List<VideoSource> sources;

  const AiSubtitleCard({
    super.key,
    required this.anime,
    required this.episode,
    required this.episodeIndex,
    required this.episodeList,
    required this.provider,
    required this.sources,
  });

  @override
  State<AiSubtitleCard> createState() => _AiSubtitleCardState();
}

class _AiSubtitleCardState extends State<AiSubtitleCard> {
  late String _route; // 'translate' | 'transcribe' (auto)
  late String _sttId; // tier: tiny | sensevoice | base | small
  late String _mtId; // tier: minima | leve | media | completa
  Future<File?>? _cached;
  Map<String, double> _downloading = {};
  late Future<Map<String, bool>> _statuses;
  Future<bool>? _lowEnd;
  List<SubtitleRef> _cands = [];
  bool _sawDone = false;

  @override
  void initState() {
    super.initState();
    _cands = widget.sources.expand((s) => s.subtitleCandidates).toList();
    final hasEnEs = _cands.any((c) =>
        SrtParser.detectLang(tag: '${c.label} ${c.lang}', filename: c.uri) ==
            'en' ||
        SrtParser.detectLang(tag: '${c.label} ${c.lang}', filename: c.uri) ==
            'es');
    _route = hasEnEs ? 'translate' : 'transcribe';
    _sttId = SettingsService.instance.sttModel;
    _mtId = SettingsService.instance.mtEngine;
    _refreshCached();
    // 1 único probe p/ todos os tiers (pronto de cada modelo).
    _statuses = AiProviders.readyMap([
      ...AiProviders.sttTiers.values.map((t) => t.id),
      ...AiProviders.mtTiers.values,
    ]);
    _lowEnd = _lowEndSafe();
  }

  /// Path ausente em teste/host não deve derrubar o card.
  static Future<bool> _lowEndSafe() async {
    try {
      return await DeviceCapability.isLowEnd();
    } catch (_) {
      return false;
    }
  }

  void _refreshCached() {
    setState(() {
      _cached = _findCached();
    });
  }

  Future<File?> _findCached() async {
    for (final tag in const ['en-ai', 'es-ai', 'ja-ai']) {
      try {
        final f = await SubtitleStore.get(
          animeKey: widget.anime.name,
          ep: widget.episode.number,
          tag: tag,
        );
        if (f != null) return f;
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _fetchSrt(String uri, Map<String, String> headers) async {
    String? out;
    try {
      if (uri.startsWith('http')) {
        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse(uri));
          headers.forEach(req.headers.set);
          final resp =
              await req.close().timeout(const Duration(seconds: 15));
          if (resp.statusCode != 200) return null;
          out = await resp
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 15));
        } finally {
          client.close();
        }
      } else {
        final f = File(uri.replaceFirst('file://', ''));
        if (await f.exists()) out = await f.readAsString();
      }
    } catch (_) {
      return null;
    }
    return out;
  }

  SubtitleRef? _pickCandidate() {
    SubtitleRef? en;
    SubtitleRef? es;
    for (final c in _cands) {
      final lang = SrtParser.detectLang(
          tag: '${c.label} ${c.lang}', filename: c.uri);
      if (lang == 'en') en ??= c;
      if (lang == 'es') es ??= c;
    }
    return en ?? es;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _start() async {
    _sawDone = false;
    try {
      if (_route == 'translate') {
        await _startTranslate();
      } else {
        await _startTranscribe();
      }
    } catch (e) {
      // IO/plugin ausente (ex.: teste) nunca derruba o card.
      _snack('Não foi possível iniciar: $e');
    }
  }

  Future<void> _startTranslate() async {
    final cand = _pickCandidate();
    if (cand == null) {
      _snack('Sem legenda EN/ES nesta fonte. Troque p/ Gerar do áudio.');
      return;
    }
    final srcLang = SrtParser.detectLang(
        tag: '${cand.label} ${cand.lang}', filename: cand.uri)!;
    final mt = await AiProviders.makeMtForSrc(srcLang);
    if (mt == null) {
      _snack('Modelo de tradução não instalado. Baixe acima (só Wi-Fi).');
      return;
    }
    final text = await _fetchSrt(cand.uri, widget.sources.first.headers);
    if (text == null) {
      _snack('Não foi possível baixar a legenda fonte.');
      return;
    }
    await SubtitleJobManager.instance.enqueueTranslate(
      animeKey: widget.anime.name,
      ep: widget.episode.number,
      srcSrt: text,
      srcLang: srcLang,
      mt: mt,
    );
  }

  Future<void> _startTranscribe() async {
    if (widget.sources.isEmpty) return;
    final stt = await AiProviders.makeStt(stt: _sttId);
    if (stt == null) {
      _snack('Modelo de voz ($_sttId) não instalado. Baixe acima.');
      return;
    }
    // Hy-MT2 cobre JA→PT direto e EN→PT (tiny) no mesmo provider.
    final mt = await AiProviders.makeMt(engine: _mtId);
    if (mt == null) {
      _snack('Modelo de tradução não instalado. Baixe acima.');
      return;
    }
    final src = widget.sources.first;
    await SubtitleJobManager.instance.enqueueTranscribe(
      animeKey: widget.anime.name,
      ep: widget.episode.number,
      videoUrl: src.url,
      headers: src.headers,
      sttFor: () => stt,
      mt: mt,
    );
  }

  Future<void> _downloadModel(String modelId) async {
    setState(() => _downloading[modelId] = 0);
    try {
      await const ModelManager().downloadModel(
        modelId,
        onProgress: (_, p) {
          if (mounted) setState(() => _downloading[modelId] = p);
        },
      );
      _statuses = AiProviders.readyMap([
        ...AiProviders.sttTiers.values.map((t) => t.id),
        ...AiProviders.mtTiers.values,
      ]);
      _snack('Modelo pronto.');
    } on ModelDownloadException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) {
        setState(() => _downloading.remove(modelId));
      }
    }
  }

  void _playWithSub(File srt) {
    final sub = SubtitleRef(
        label: 'PT-BR (IA)', lang: 'pt', uri: srt.path, isAI: true);
    final withSub = widget.sources.map((s) => s.withSubtitle(sub)).toList();
    final nav = Navigator.of(context);
    nav.pop(); // fecha o picker
    final player = widget.provider == AnimeSource.animeFire
        ? ExoDashPlayerScreen(
            anime: widget.anime,
            provider: widget.provider,
            episodeIndex: widget.episodeIndex,
            episodeList: widget.episodeList,
            initialSources: withSub,
            initialIndex: 0,
          )
        : PlayerScreen(
            anime: widget.anime,
            provider: widget.provider,
            episodeIndex: widget.episodeIndex,
            episodeList: widget.episodeList,
            initialSources: withSub,
            initialIndex: 0,
          );
    nav.push(MaterialPageRoute(builder: (_) => player));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _route == 'translate'
              ? '${_cands.length} candidata(s) EN/ES na fonte · rota: traduzir'
              : 'Nenhuma candidata EN/ES · rota: gerar do áudio japonês',
          style: const TextStyle(
              color: ThemeConstants.textSecondary, fontSize: 14),
        ),
        if (_route == 'transcribe')
          FutureBuilder<bool>(
            future: _lowEnd,
            builder: (context, snap) => AiModelRow(
              heading: 'Voz',
              tiers: AiProviders.sttTierOrder,
              tierIds: {
                for (final e in AiProviders.sttTiers.entries)
                  e.key: e.value.id,
              },
              tierLabels: AiProviders.sttTierLabels,
              selected: _sttId,
              onSelect: (t) {
                setState(() => _sttId = t);
                SettingsService.instance.setSttModel(t);
              },
              statuses: _statuses,
              downloading: _downloading,
              onDownload: _downloadModel,
              lowEnd: snap.data ?? false,
            ),
          ),
        FutureBuilder<bool>(
          future: _lowEnd,
          builder: (context, snap) => AiModelRow(
            heading: 'Tradução',
            tiers: AiProviders.mtTierOrder,
            tierIds: AiProviders.mtTiers,
            tierLabels: AiProviders.mtTierLabels,
            selected: _mtId,
            onSelect: (t) {
              setState(() => _mtId = t);
              SettingsService.instance.setMtEngine(t);
            },
            statuses: _statuses,
            downloading: _downloading,
            onDownload: _downloadModel,
            lowEnd: snap.data ?? false,
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<String?>(
          future: SubtitleJobManager.consumeCrashHint(),
          builder: (context, snap) {
            // Arquivo some no retry (_dropStale preserva em memória).
            final hint = snap.data ?? SubtitleJobManager.instance.lastCrashHint;
            if (hint == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(hint,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 15)),
            );
          },
        ),
        ValueListenableBuilder<JobState>(
          valueListenable: SubtitleJobManager.instance.state,
          builder: (context, st, _) => _JobCard(
            state: st,
            busy: SubtitleJobManager.instance.isBusy,
            onStart: _start,
            onCancel: () => SubtitleJobManager.instance.cancelCurrent(),
            onRetry: _start,
          ),
        ),
        ValueListenableBuilder<JobState>(
          valueListenable: SubtitleJobManager.instance.state,
          builder: (context, st, _) {
            if (st.phase == JobPhase.done && !_sawDone) {
              _sawDone = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _refreshCached();
              });
            }
            return FutureBuilder<File?>(
              future: _cached,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SizedBox.shrink();
                }
                final file = snap.data;
                if (file == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      TVButton(
                        label: 'Assistir com IA',
                        autofocus: _sawDone,
                        onPressed: () => _playWithSub(file),
                      ),
                      TVButton(
                        label: 'Apagar',
                        isPrimary: false,
                        onPressed: () async {
                          try {
                            await file.delete();
                            await File('${file.path}.meta.json').delete();
                          } catch (_) {}
                          _refreshCached();
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(height: 4),
        const Text('Legenda gerada por IA, pode conter erros.',
            style: TextStyle(
                color: ThemeConstants.textSecondary, fontSize: 13)),
      ],
    );
  }
}

/// Card vivo do job: fase + detalhe + barra + % + cancelar / erro + retry.
class _JobCard extends StatelessWidget {
  final JobState state;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  const _JobCard({
    required this.state,
    required this.busy,
    required this.onStart,
    required this.onCancel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final st = state;
    if (st.phase == JobPhase.failed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(st.error ?? 'Falhou.',
              style:
                  const TextStyle(color: Colors.redAccent, fontSize: 16)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              TVButton(label: 'Tentar de novo', onPressed: onRetry),
            ],
          ),
        ],
      );
    }
    if (st.phase == JobPhase.done) {
      return Text(st.message.isEmpty ? 'Legenda pronta.' : st.message,
          style: const TextStyle(color: Colors.greenAccent, fontSize: 16));
    }
    if (busy) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(st.message.isEmpty ? 'Trabalhando…' : st.message,
              style: const TextStyle(color: Colors.white, fontSize: 17)),
          if (st.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(st.detail,
                  style: const TextStyle(
                      color: ThemeConstants.textSecondary, fontSize: 14)),
            ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
              value: st.progress <= 0 ? null : st.progress,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(
                  ThemeConstants.primary)),
          const SizedBox(height: 4),
          Text('${(st.progress * 100).toInt()}%',
              style: const TextStyle(
                  color: ThemeConstants.textSecondary, fontSize: 14)),
          const SizedBox(height: 12),
          TVButton(
              label: 'Cancelar', isPrimary: false, onPressed: onCancel),
        ],
      );
    }
    return TVButton(
        label: 'Gerar legenda', autofocus: true, onPressed: onStart);
  }
}
