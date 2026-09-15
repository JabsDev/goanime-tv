import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/subtitles/ai_providers.dart';
import '../../core/subtitles/model_manager.dart';
import '../../core/subtitles/mt_provider.dart';
import '../../core/subtitles/srt_parser.dart';
import '../../core/subtitles/subtitle_job_manager.dart';
import '../../core/subtitles/subtitle_store.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../../shared/widgets/tv_button.dart';
import '../player/exo_dash_player_screen.dart';
import '../player/player_screen.dart';

/// Tela dedicada da legenda IA (D-pad navegável): escolhe a rota, mostra os
/// modelos (instalado/faltando/baixar com %), acompanha cada fase do job
/// com mensagem (nunca 0% mudo), exibe erro legível com Tentar de novo e
/// toca/apaga o resultado. Substitui a seção inline do picker de fonte.
class AiSubtitleScreen extends StatefulWidget {
  final Anime anime;
  final CatalogEpisode episode;
  final int episodeIndex;
  final List<CatalogEpisode> episodeList;
  final AnimeSource provider;
  final List<VideoSource> sources;

  const AiSubtitleScreen({
    super.key,
    required this.anime,
    required this.episode,
    required this.episodeIndex,
    required this.episodeList,
    required this.provider,
    required this.sources,
  });

  @override
  State<AiSubtitleScreen> createState() => _AiSubtitleScreenState();
}

class _AiSubtitleScreenState extends State<AiSubtitleScreen> {
  late String _route; // 'translate' | 'transcribe'
  late String _sttId; // tiny | base | small | sensevoice
  late String _mtId; // leve | completa
  Future<File?>? _cached;
  final Map<String, double> _downloading = {};
  List<SubtitleRef> _cands = [];
  bool _sawDone = false;

  static const _sttModels = ['tiny', 'sensevoice', 'base', 'small'];
  static const _sttModelIds = {
    'tiny': 'whisper-tiny-ja',
    'sensevoice': 'sensevoice-ja',
    'base': 'whisper-base',
    'small': 'whisper-small',
  };

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
  }

  void _refreshCached() {
    setState(() {
      _cached = _findCached();
    });
  }

  Future<File?> _findCached() async {
    for (final tag in const ['en-ai', 'es-ai', 'ja-ai']) {
      final f = await SubtitleStore.get(
        animeKey: widget.anime.name,
        ep: widget.episode.number,
        tag: tag,
      );
      if (f != null) return f;
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
          out = await resp.transform(utf8.decoder).join().timeout(
              const Duration(seconds: 15));
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _start() async {
    _sawDone = false;
    if (_route == 'translate') {
      await _startTranslate();
    } else {
      await _startTranscribe();
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
      _snack(
          'Modelo de tradução não instalado. Baixe abaixo (só Wi-Fi).');
      return;
    }
    final text =
        await _fetchSrt(cand.uri, widget.sources.first.headers);
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
      _snack('Modelo de voz ($_sttId) não instalado. Baixe abaixo.');
      return;
    }
    MtProvider? mt;
    SttProvider? sttFinal = stt;
    if (stt.id == 'whisper-tiny-ja') {
      mt = await AiProviders.makeMt(
          engine: _mtId == 'completa' ? 'completa' : 'leve');
    } else {
      // Transcrição gera JA: NLLB direto; senão cadeia LFM+Marian;
      // sem eles, cai p/ tiny+Marian avisando.
      mt = await AiProviders.makeMtForTranscribe();
      if (mt == null) {
        mt = await AiProviders.makeMtChainJaPt();
      }
      if (mt == null) {
        _snack('Sem NLLB neste aparelho — usando voz leve (tiny) + Marian.');
        final tiny = await AiProviders.makeStt(stt: 'tiny');
        mt = tiny == null
            ? null
            : await AiProviders.makeMt(engine: 'leve');
        if (tiny != null && mt != null) sttFinal = tiny;
      }
    }
    if (mt == null) {
      _snack('Modelo de tradução não instalado. Baixe abaixo.');
      return;
    }
    final src = widget.sources.first;
    await SubtitleJobManager.instance.enqueueTranscribe(
      animeKey: widget.anime.name,
      ep: widget.episode.number,
      videoUrl: src.url,
      headers: src.headers,
      sttFor: () => sttFinal!,
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
      _snack('Modelo pronto.');
    } on ModelDownloadException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _downloading.remove(modelId));
    }
  }

  void _playWithSub(File srt) {
    final sub = SubtitleRef(
        label: 'PT-BR (IA)', lang: 'pt', uri: srt.path, isAI: true);
    final withSub = widget.sources.map((s) => s.withSubtitle(sub)).toList();
    final nav = Navigator.of(context);
    nav.pop();
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
    nav.push(
      MaterialPageRoute(builder: (_) => player),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      appBar: AppBar(
        backgroundColor: ThemeConstants.surface,
        title: Text('Legenda IA · EP${widget.episode.number}',
            style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
        children: [
          _SectionTitle('1 · Origem'),
          _OptionRow(
            label: 'Traduzir legenda existente',
            description: _cands.isEmpty
                ? 'Nenhuma legenda EN/ES nesta fonte'
                : '${_cands.length} candidata(s) EN/ES · rápido, sem voz',
            selected: _route == 'translate',
            enabled: _cands.isNotEmpty,
            onTap: () => setState(() => _route = 'translate'),
          ),
          _OptionRow(
            label: 'Gerar do áudio japonês',
            description:
                'Transcreve + traduz · lento (uma vez por EP, vale 5 dias)',
            selected: _route == 'transcribe',
            onTap: () => setState(() => _route = 'transcribe'),
          ),
          const SizedBox(height: 24),
          _SectionTitle('2 · Modelos (HuggingFace, só Wi-Fi)'),
          if (_route == 'transcribe')
            ..._sttModels.map((id) => _ModelOptionRow(
                  modelId: _sttModelIds[id]!,
                  selected: _sttId == id,
                  onSelect: () {
                    setState(() => _sttId = id);
                    SettingsService.instance.setSttModel(id);
                  },
                  downloading: _downloading[_sttModelIds[id]!],
                  onDownload: () =>
                      _downloadModel(_sttModelIds[id]!),
                )),
          _ModelOptionRow(
            modelId: _mtId == 'completa'
                ? 'nllb-600M-int8'
                : 'marian-en-pt-int8',
            selectLabel: _mtId == 'completa' ? 'NLLB' : 'Marian',
            selected: true,
            onSelect: () {
              final next = _mtId == 'completa' ? 'leve' : 'completa';
              setState(() => _mtId = next);
              SettingsService.instance.setMtEngine(next);
            },
            downloading: _downloading[_mtId == 'completa'
                ? 'nllb-600M-int8'
                : 'marian-en-pt-int8'],
            onDownload: () => _downloadModel(_mtId == 'completa'
                ? 'nllb-600M-int8'
                : 'marian-en-pt-int8'),
          ),
          if (_route == 'transcribe')
            _ModelOptionRow(
              modelId: 'lfm-ja-en',
              selectLabel: 'LFM JA→EN (p/ voz base/small)',
              selected: true,
              onSelect: () {},
              downloading: _downloading['lfm-ja-en'],
              onDownload: () => _downloadModel('lfm-ja-en'),
            ),
          const SizedBox(height: 24),
          _SectionTitle('3 · Gerar'),
          FutureBuilder<String?>(
            future: SubtitleJobManager.consumeCrashHint(),
            builder: (context, snap) {
              if (snap.data == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(snap.data!,
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
              onCancel: () =>
                  SubtitleJobManager.instance.cancelCurrent(),
              onRetry: _start,
            ),
          ),
          const SizedBox(height: 24),
          _SectionTitle('4 · Resultado'),
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
                    return const Text('Verificando…',
                        style: TextStyle(
                            color: ThemeConstants.textSecondary,
                            fontSize: 16));
                  }
                  final file = snap.data;
                  if (file == null) {
                    return const Text(
                        'Nenhuma legenda gerada ainda para este EP.',
                        style: TextStyle(
                            color: ThemeConstants.textSecondary,
                            fontSize: 16));
                  }
                  return Wrap(
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
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          const Text('Legenda gerada por IA, pode conter erros.',
              style: TextStyle(
                  color: ThemeConstants.textSecondary, fontSize: 14)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text,
          style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white)),
    );
  }
}

/// Linha selecionável D-pad (mesmo padrão visual do picker de fonte).
class _OptionRow extends StatefulWidget {
  final String label;
  final String description;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  const _OptionRow({
    required this.label,
    required this.description,
    required this.selected,
    this.enabled = true,
    required this.onTap,
  });

  @override
  State<_OptionRow> createState() => _OptionRowState();
}

class _OptionRowState extends State<_OptionRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Focus(
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (n, e) => widget.enabled
            ? FocusKeyHandler.handle(n, e, widget.onTap)
            : KeyEventResult.ignored,
        child: Semantics(
          button: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.enabled ? widget.onTap : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? ThemeConstants.primary.withValues(alpha: 0.25)
                      : _focused
                          ? ThemeConstants.primary.withValues(alpha: 0.15)
                          : ThemeConstants.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: widget.selected || _focused
                        ? ThemeConstants.primary
                        : Colors.transparent,
                    width: _focused ? 3 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.label,
                        style: TextStyle(
                            color: widget.enabled
                                ? Colors.white
                                : Colors.white38,
                            fontSize: 17,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(widget.description,
                        style: const TextStyle(
                            color: ThemeConstants.textSecondary,
                            fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Linha de modelo: status instalado/faltando + baixar com % + selecionar.
class _ModelOptionRow extends StatelessWidget {
  final String modelId;
  final String? selectLabel;
  final bool selected;
  final VoidCallback onSelect;
  final double? downloading;
  final VoidCallback onDownload;
  const _ModelOptionRow({
    required this.modelId,
    this.selectLabel,
    required this.selected,
    required this.onSelect,
    required this.downloading,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final spec = aiModelCatalog[modelId]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: FutureBuilder<bool>(
        future: const ModelManager().isReady(modelId),
        builder: (context, snap) {
          final ready = snap.data ?? false;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _OptionRow(
                  label:
                      '${selectLabel ?? spec.label} — ${ready ? 'instalado' : 'faltando'} (${spec.mb} MB)',
                  description: downloading != null
                      ? 'Baixando… ${(downloading! * 100).toInt()}%'
                      : spec.hint,
                  selected: selected,
                  onTap: onSelect,
                ),
              ),
              if (!ready && downloading == null) ...[
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: TVButton(
                    label: 'Baixar',
                    width: 150,
                    onPressed: onDownload,
                  ),
                ),
              ],
            ],
          );
        },
      ),
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
      return const Text('Legenda pronta — veja o resultado abaixo.',
          style: TextStyle(color: Colors.greenAccent, fontSize: 16));
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
