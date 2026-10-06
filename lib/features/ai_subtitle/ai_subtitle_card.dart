import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/subtitles/ai_providers.dart';
import '../../core/subtitles/audio_extract.dart';
import '../../core/subtitles/legendai/legendai_client.dart';
import '../../core/subtitles/legendai/legendai_connection.dart';
import '../../core/subtitles/legendai/legendai_job_manager.dart';
import '../../core/subtitles/legendai/legendai_protocol.dart';
import '../../core/subtitles/legendai/legendai_remote_job.dart';
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
import 'legendai_job_card.dart';

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
  late String _sttId; // tier: sensevoice | jav03 (Fase 1: só tiers altos)
  late String _mtId; // tier: manga | completa (Fase 1: só tiers altos)
  Future<File?>? _cached;
  Map<String, double> _downloading = {};
  late Future<Map<String, bool>> _statuses;
  Future<bool>? _lowEnd;
  List<SubtitleRef> _cands = [];
  bool _sawDone = false;

  /// Fase 3: rota escolhida no card — 'device' (aparelho) ou 'pc' (LegendAI).
  late String _where;
  bool _sawRemoteDone = false;
  String? _remoteError;

  /// Fase 5: extração+upload do áudio em andamento (fallback DASH/token).
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _where = SettingsService.instance.subtitleSource;
    _cands = widget.sources.expand((s) => s.subtitleCandidates).toList();
    final hasEnEs = _cands.any(
      (c) =>
          SrtParser.detectLang(tag: '${c.label} ${c.lang}', filename: c.uri) ==
              'en' ||
          SrtParser.detectLang(tag: '${c.label} ${c.lang}', filename: c.uri) ==
              'es',
    );
    _route = hasEnEs ? 'translate' : 'transcribe';
    _sttId = SettingsService.instance.sttModel;
    _mtId = SettingsService.instance.mtEngine;
    // O estado de job é global e terminava "grudado" em `done` (mostrava
    // "Legenda pronta." e escondia o botão de gerar, inclusive para outro
    // episódio). Ao (re)abrir o card sem job rodando, volta para idle.
    SubtitleJobManager.instance.resetIdleState();
    _refreshCached();
    // 1 único probe p/ todos os tiers (pronto de cada modelo).
    _statuses = AiProviders.readyMap([
      ...AiProviders.sttTiers.values.map((t) => t.id),
      ...AiProviders.mtTiers.values,
      'silero-vad',
    ]);
    _lowEnd = _lowEndSafe();
    // Fase 3: carrega o espelho da fila remota e, se já houver PC pareado,
    // revalida a conexão (fire-and-forget — nunca bloqueia a UI).
    // ignore: discarded_futures
    LegendAiJobManager.instance.init();
    if (LegendAiConnection.instance.isConfigured) {
      // ignore: discarded_futures
      LegendAiConnection.instance.refresh();
    }
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
          final resp = await req.close().timeout(const Duration(seconds: 15));
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
        tag: '${c.label} ${c.lang}',
        filename: c.uri,
      );
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
      tag: '${cand.label} ${cand.lang}',
      filename: cand.uri,
    )!;
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
    // Sem VAD o STT fatia em janelas de 30s (~43 falas em 23 min, texto
    // emendado e sem timing). Baixa os 3 MB automaticamente; se não der
    // (rede metrada/offline), bloqueia com aviso em vez de gerar legenda
    // ruim em silêncio.
    if (!await _ensureVad()) return;
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

  /// Garante o VAD (3 MB) antes de transcrever. Sem ele o STT cai nas janelas
  /// fixas de 30 s e devolve ~1 fala por janela (Haibane EP3: 43 falas em
  /// 24 min, texto emendado). Tenta baixar automático; se falhar
  /// (rede metrada/offline), bloqueia — nunca gera legenda ruim em silêncio.
  Future<bool> _ensureVad() async {
    if (_downloading.containsKey('silero-vad')) return false;
    try {
      if (await const ModelManager().isReady('silero-vad')) return true;
    } catch (_) {}
    _snack('Baixando o VAD (3 MB) — melhora a transcrição…');
    try {
      await _downloadModel('silero-vad');
    } catch (e) {
      _snack('Não foi possível baixar o VAD: $e');
    }
    var ok = false;
    try {
      ok = await const ModelManager().isReady('silero-vad');
    } catch (_) {}
    if (!ok) {
      _snack(
        'Sem o VAD a transcrição fica incompleta. '
        'Baixe "silero · corta silêncio" acima e tente de novo.',
      );
    }
    return ok;
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
        'silero-vad',
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
      label: 'PT-BR (IA)',
      lang: 'pt',
      uri: srt.path,
      isAI: true,
    );
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
        _whereSelector(),
        if (_where == 'pc') ...[
          ..._pcSection(),
        ] else ...[
          Text(
            _route == 'translate'
                ? '${_cands.length} candidata(s) EN/ES na fonte · rota: traduzir'
                : 'Nenhuma candidata EN/ES · rota: gerar do áudio japonês',
            style: const TextStyle(
              color: ThemeConstants.textSecondary,
              fontSize: 14,
            ),
          ),
          if (_route == 'transcribe') ...[
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
            // VAD (3 MB) decide a qualidade: sem ele o STT fatia em janelas
            // fixas de 30s e devolve ~1 cue por janela — dozens de falas curtas
            // do episódio ficam SEM legenda (relato Haibane EP3: 43 cues num
            // episódio de 24 min). O aviso fica aqui, no card, em vez de
            // escondido nas Configurações.
            FutureBuilder<bool>(
              future: _lowEnd,
              builder: (context, snap) => AiModelRow(
                heading: 'VAD',
                tiers: const ['vad'],
                tierIds: const {'vad': 'silero-vad'},
                tierLabels: const {'vad': 'silero · corta silêncio'},
                selected: 'vad',
                onSelect: (_) {},
                statuses: _statuses,
                downloading: _downloading,
                onDownload: _downloadModel,
                lowEnd: snap.data ?? false,
              ),
            ),
            FutureBuilder<Map<String, bool>>(
              future: _statuses,
              builder: (context, snap) {
                final ready = snap.data?['silero-vad'] == true;
                if (ready) return const SizedBox.shrink();
                return const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Sem o VAD o STT usa janelas fixas de 30 s e muitas falas '
                    'curtas ficam sem legenda. São 3 MB — vale baixar.',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 14),
                  ),
                );
              },
            ),
          ],
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
              final hint =
                  snap.data ?? SubtitleJobManager.instance.lastCrashHint;
              if (hint == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  hint,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 15,
                  ),
                ),
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
              return _buildCachedActions();
            },
          ),
          const SizedBox(height: 4),
          const Text(
            'Legenda gerada por IA, pode conter erros.',
            style: TextStyle(color: ThemeConstants.textSecondary, fontSize: 13),
          ),
          const Text(
            'Pode sair do app ou bloquear a tela: a geração continua '
            'em segundo plano (notificação de progresso).',
            style: TextStyle(color: ThemeConstants.textSecondary, fontSize: 13),
          ),
        ],
      ],
    );
  }

  /// Seletor "Onde gerar" + status da conexão com o PC.
  Widget _whereSelector() {
    final configured = LegendAiConnection.instance.isConfigured;
    return ValueListenableBuilder<LegendAiStatus>(
      valueListenable: LegendAiConnection.instance.status,
      builder: (context, status, _) {
        final pcEnabled = configured && status != LegendAiStatus.offline;
        final statusText = switch (status) {
          LegendAiStatus.online => LegendAiConnection.instance.healthLabel,
          LegendAiStatus.checking => 'Conectando ao PC…',
          LegendAiStatus.offline => 'PC não encontrado',
          LegendAiStatus.unconfigured => 'PC não configurado',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Onde gerar',
              style: TextStyle(
                color: ThemeConstants.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _whereChip(
                  'No aparelho',
                  selected: _where == 'device',
                  enabled: true,
                  onTap: () => _setWhere('device'),
                ),
                _whereChip(
                  'No PC (LegendAI)',
                  selected: _where == 'pc',
                  enabled: pcEnabled,
                  onTap: pcEnabled
                      ? () => _setWhere('pc')
                      : () {
                          _snack(
                            configured
                                ? 'O PC não respondeu. Confira se o LegendAI '
                                      'está aberto e o IP nas Configurações.'
                                : 'Configure o endereço do LegendAI em '
                                      'Configurações → LegendAI (PC).',
                          );
                        },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              configured
                  ? 'LegendAI · $statusText'
                  : 'PC não configurado — veja Configurações → LegendAI (PC).',
              style: TextStyle(
                color: status == LegendAiStatus.offline
                    ? Colors.orangeAccent
                    : ThemeConstants.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  Widget _whereChip(
    String label, {
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled || selected ? 1 : 0.5,
      child: TVButton(
        label: label,
        isPrimary: selected,
        width: 210,
        onPressed: onTap,
      ),
    );
  }

  void _setWhere(String value) {
    if (_where == value) return;
    setState(() => _where = value);
    // Persiste a escolha como padrão (próximo card abre no mesmo modo).
    // ignore: discarded_futures
    SettingsService.instance.setSubtitleSource(value);
    if (value == 'pc') {
      // ignore: discarded_futures
      LegendAiJobManager.instance.init();
      if (LegendAiConnection.instance.isConfigured) {
        // ignore: discarded_futures
        LegendAiConnection.instance.refresh();
      }
    }
  }

  /// Conteúdo da rota "No PC": status do job remoto deste episódio + botão
  /// "Gerar no PC"/cancelar/retry.
  List<Widget> _pcSection() {
    final manager = LegendAiJobManager.instance;
    return [
      const Text(
        'O PC baixa o stream, transcreve com Whisper e traduz. O aparelho '
        'só recebe o SRT pronto — economiza bateria e usa a GPU do PC.',
        style: TextStyle(
          color: ThemeConstants.textSecondary,
          fontSize: 14,
          height: 1.4,
        ),
      ),
      if (_remoteError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _remoteError!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 14),
          ),
        ),
      const SizedBox(height: 12),
      ValueListenableBuilder<List<RemoteJob>>(
        valueListenable: manager.jobs,
        builder: (context, _, __) {
          final job = manager.jobForEpisode(
            animeKey: widget.anime.name,
            ep: widget.episode.number,
          );
          if (job != null && job.downloaded && !_sawRemoteDone) {
            _sawRemoteDone = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _refreshCached();
            });
          }
          // Fallback de upload (Fase 5): o PC não abriu o stream (DASH/token).
          final needsUpload =
              job != null &&
              job.state == LegendAiState.error &&
              job.error?.code == 'unsupported_stream';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LegendAiJobCard(
                job: job,
                onStart: _startRemote,
                onCancel: () {
                  if (job != null) {
                    // ignore: discarded_futures
                    manager.cancel(job);
                  }
                },
              ),
              if (_route == 'transcribe' || needsUpload) ...[
                const SizedBox(height: 12),
                Opacity(
                  opacity: _uploading ? 0.6 : 1,
                  child: TVButton(
                    label: _uploading
                        ? 'Enviando áudio…'
                        : 'Enviar áudio do aparelho',
                    isPrimary: false,
                    width: 280,
                    onPressed: _uploading ? () {} : _startRemoteUpload,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Para fontes que o PC não consegue baixar (DASH/token): o '
                  'aparelho extrai o áudio e envia. Usa mais dados móveis.',
                  style: TextStyle(
                    color: ThemeConstants.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          );
        },
      ),
      _buildCachedActions(),
      const SizedBox(height: 8),
      const Text(
        'Legenda gerada por IA, pode conter erros.',
        style: TextStyle(color: ThemeConstants.textSecondary, fontSize: 13),
      ),
    ];
  }

  /// Botões do SRT em cache ("Assistir com IA" / "Apagar"), compartilhados
  /// pelas rotas local e remota.
  Widget _buildCachedActions() {
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
                autofocus: _sawDone || _sawRemoteDone,
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
                  // Apagar a legenda precisa liberar o card: sem reset o estado
                  // global ficava em `done` ("Legenda pronta.") e o botão de
                  // gerar não voltava.
                  SubtitleJobManager.instance.resetIdleState();
                  _refreshCached();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Enfileira o episódio no LegendAI. A rota define a origem: rota S envia a
  /// legenda EN/ES pronta (o PC só traduz, Fase 5); rota L1 envia a URL para o
  /// PC transcrever (Fase 3). Erros viram mensagem amigável.
  Future<void> _startRemote() async {
    if (widget.sources.isEmpty) return;
    if (!LegendAiConnection.instance.isConfigured) {
      _snack(
        'Configure o endereço do LegendAI em Configurações → LegendAI (PC).',
      );
      return;
    }
    setState(() => _remoteError = null);
    // Reenvio remoto (inclusive "Gerar de novo"): libera o refresh do SRT em
    // cache quando o download do PC terminar.
    _sawRemoteDone = false;
    try {
      if (_route == 'translate') {
        await _startRemoteSrt();
      } else {
        await _startRemoteUrl();
      }
    } catch (e) {
      final msg = friendlyLegendAiError(e);
      if (mounted) setState(() => _remoteError = msg);
      _snack(msg);
    }
  }

  /// Rota S remota: baixa a candidata EN/ES e manda o texto para o PC traduzir.
  Future<void> _startRemoteSrt() async {
    final cand = _pickCandidate();
    if (cand == null) {
      _snack('Sem legenda EN/ES nesta fonte. Troque p/ gerar do áudio.');
      return;
    }
    final srcLang = SrtParser.detectLang(
      tag: '${cand.label} ${cand.lang}',
      filename: cand.uri,
    )!;
    final text = await _fetchSrt(cand.uri, widget.sources.first.headers);
    if (text == null) {
      _snack('Não foi possível baixar a legenda fonte.');
      return;
    }
    final job = await LegendAiJobManager.instance.generateSrt(
      animeKey: widget.anime.name,
      ep: widget.episode.number,
      srt: text,
      sourceLang: srcLang,
      tag: '$srcLang-ai',
    );
    if (job == null) {
      _snack('LegendAI não está configurado.');
    } else if (job.isDone) {
      _snack('O PC já tinha esta legenda. Baixando…');
    } else {
      _snack('Legenda $srcLang enviada — o PC só traduz.');
    }
  }

  /// Rota L1 remota: o PC baixa o stream e transcreve.
  Future<void> _startRemoteUrl() async {
    final src = widget.sources.first;
    final job = await LegendAiJobManager.instance.generate(
      animeKey: widget.anime.name,
      ep: widget.episode.number,
      url: src.url,
      headers: src.headers,
      // A rota remota por URL sempre transcreve o áudio; o SRT é JA→PT.
      tag: 'ja-ai',
    );
    if (job == null) {
      _snack('LegendAI não está configurado.');
    } else if (job.isDone) {
      _snack('O PC já tinha esta legenda. Baixando…');
    } else {
      _snack('Enviado para o PC. Acompanhe o progresso aqui.');
    }
  }

  /// Fallback de upload (Fase 5): extrai o áudio no aparelho e envia ao PC.
  /// Para DASH/token que o ffmpeg do PC não abre.
  Future<void> _startRemoteUpload() async {
    if (widget.sources.isEmpty) return;
    if (!LegendAiConnection.instance.isConfigured) {
      _snack(
        'Configure o endereço do LegendAI em Configurações → LegendAI (PC).',
      );
      return;
    }
    final src = widget.sources.first;
    setState(() {
      _remoteError = null;
      _uploading = true;
    });
    Directory? tmp;
    try {
      tmp = await Directory.systemTemp.createTemp('legendai_up');
      final pcmPath = '${tmp.path}/ep${widget.episode.number}.pcm';
      _snack('Extraindo o áudio no aparelho…');
      await AudioExtract.extractPcm16k(
        url: src.url,
        headers: src.headers,
        outPath: pcmPath,
      );
      final file = File(pcmPath);
      if (!await file.exists() || await file.length() < 1024) {
        throw StateError('Não foi possível extrair o áudio desta fonte.');
      }
      final job = await LegendAiJobManager.instance.generateUpload(
        animeKey: widget.anime.name,
        ep: widget.episode.number,
        audioFile: file,
        format: 's16le',
      );
      if (job == null) {
        _snack('LegendAI não está configurado.');
      } else {
        _snack('Áudio enviado ao PC. Acompanhe o progresso aqui.');
      }
    } catch (e) {
      final msg = friendlyLegendAiError(e);
      if (mounted) setState(() => _remoteError = msg);
      _snack(msg);
    } finally {
      if (mounted) setState(() => _uploading = false);
      try {
        await tmp?.delete(recursive: true);
      } catch (_) {}
    }
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
          Text(
            st.error ?? 'Falhou.',
            style: const TextStyle(color: Colors.redAccent, fontSize: 16),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [TVButton(label: 'Tentar de novo', onPressed: onRetry)],
          ),
        ],
      );
    }
    if (st.phase == JobPhase.done) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            st.message.isEmpty ? 'Legenda pronta.' : st.message,
            style: const TextStyle(color: Colors.greenAccent, fontSize: 16),
          ),
          const SizedBox(height: 12),
          // Botão de regerar sempre visível: o estado `done` escondia o
          // "Gerar legenda" e travava uma nova geração (bug reportado).
          TVButton(label: 'Gerar de novo', isPrimary: false, onPressed: onStart),
        ],
      );
    }
    if (busy) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            st.message.isEmpty ? 'Trabalhando…' : st.message,
            style: const TextStyle(color: Colors.white, fontSize: 17),
          ),
          if (st.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                st.detail,
                style: const TextStyle(
                  color: ThemeConstants.textSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: st.progress <= 0 ? null : st.progress,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(ThemeConstants.primary),
          ),
          const SizedBox(height: 4),
          Text(
            '${(st.progress * 100).toInt()}%',
            style: const TextStyle(
              color: ThemeConstants.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          TVButton(label: 'Cancelar', isPrimary: false, onPressed: onCancel),
        ],
      );
    }
    return TVButton(
      label: 'Gerar legenda',
      autofocus: true,
      onPressed: onStart,
    );
  }
}
