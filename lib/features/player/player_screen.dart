import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/storage/local_storage.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/utils/quality_picker.dart';
import '../../shared/widgets/focus_key_handler.dart';

class PlayerScreen extends StatefulWidget {
  final Anime anime;
  final AnimeSource provider;
  final List<CatalogEpisode> episodeList;
  final int episodeIndex;
  final List<VideoSource>? initialSources;
  final int initialIndex;

  const PlayerScreen({
    super.key,
    required this.anime,
    required this.provider,
    required this.episodeList,
    required this.episodeIndex,
    this.initialSources,
    this.initialIndex = 0,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final AnimeRepository _repo = AnimeRepository();
  late final Player _player;
  late final VideoController _videoController;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription? _errorSub;

  // ponytail: VN minimaliza repaints por tick de posição (~10/s). Antes, cada
  // tick chamava setState() da tela inteira, repintando gradientes full-screen.
  // Agora só a sub-árvore de progresso (timer + barra) reconstrói.
  final ValueNotifier<double> _positionVN = ValueNotifier<double>(0);
  final ValueNotifier<double> _durationVN = ValueNotifier<double>(0);
  DateTime? _lastProgressSave;

  bool _isPlaying = false;
  bool _isLoading = true;
  double _positionSec = 0;
  double _durationSec = 0;
  bool _videoReady = false;
  bool _controlsVisible = true;
  Timer? _controlsTimer;
  Timer? _loadTimeout;
  String? _error;

  List<VideoSource> _sources = [];
  int _selectedQualityIndex = 0;

  bool _showNextOverlay = false;
  int _countdownSec = 10;
  Timer? _countdownTimer;

  // ponytail: push do progresso ao AniList quando o ep atinge 75% assistido.
  // Throttle por episódio (uma chamada por playback). Fire-and-forget p/ não
  // acoplar player a rede.
  bool _anilistPushedForThisEp = false;

  // ponytail: retry deve re-resolver as fontes (URL pode ter expirado/403).
  // Antes o botão "Tentar novamente" só rejogava widget.initialSources mortas.
  bool _forceReresolve = false;

  // B12: guarda de auto-avanço deduplicado — timeout de load, completed com
  // arquivo vazio e erro de stream podem disparar em sequência; sem o flag,
  // o mesmo índice morto avança duas vezes e PULA uma fonte boa.
  bool _autoAdvancing = false;

  // D-pad-focusable control buttons (back/quality/visibility/replay/play/forward).
  late final FocusNode _backNode = FocusNode();
  late final FocusNode _qualityNode = FocusNode();
  late final FocusNode _visibilityNode = FocusNode();
  late final FocusNode _replayNode = FocusNode();
  late final FocusNode _playNode = FocusNode();
  late final FocusNode _forwardNode = FocusNode();
  List<FocusNode> get _controlNodes => [
        _backNode,
        _qualityNode,
        _visibilityNode,
        _replayNode,
        _playNode,
        _forwardNode,
      ];
  bool get _aControlIsFocused =>
      _controlNodes.any((n) => n.hasPrimaryFocus);

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      List<VideoSource> sources;
      int startIndex = widget.initialIndex;
      // ponytail: retry re-resolve as fontes do provider escolhido — a URL pode
      // ter expirado/403. Antes o "Tentar novamente" só rejogava as mortas.
      if (widget.initialSources != null && !_forceReresolve) {
        sources = widget.initialSources!;
        debugPrint('[Player] Using ${sources.length} pre-selected sources');
      } else {
        _forceReresolve = false;
        final providers = await _repo.resolveProvidersForEpisode(
          widget.anime,
          widget.episodeIndex + 1,
        );
        sources = providers.providers[widget.provider] ?? const <VideoSource>[];
      }
      if (!mounted) return;
      if (sources.isEmpty) {
        setState(() {
          _error = 'Não foi possível carregar o vídeo. Tente outra fonte.';
          _isLoading = false;
        });
        return;
      }
      if (startIndex >= sources.length) startIndex = 0;
      // Fase 3: auto-seleciona a melhor qualidade quando o usuário não fez
      // escolha explícita (retry/auto-next). Ordena best-first para o
      // auto-avanço de fontes mortas caminhar da melhor para a pior. O índice
      // explícito vindo do diálogo é remapeado para a ordem nova.
      final chosen = sources[startIndex];
      final ordered = sortBestFirst(sources);
      final mapped = ordered.indexWhere((s) => identical(s, chosen));
      startIndex = mapped >= 0 ? mapped : 0;
      setState(() => _sources = ordered);
      await _playSource(startIndex);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Erro ao carregar: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _playSource(int index) async {
    if (index >= _sources.length) return;
    final src = _sources[index];
    debugPrint('[Player] Attempting source $index: ${src.url} (${src.quality})');
    _autoAdvancing = false;
    setState(() {
      _selectedQualityIndex = index;
      _isLoading = true;
      _error = null;
      _videoReady = false;
      _anilistPushedForThisEp = false;
    });
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      debugPrint('[Player] Loading timeout for source $index');
      // ponytail: timeout = source morta (404/vazio). Auto-avança em vez de só mostrar erro.
      if (_selectedQualityIndex < _sources.length - 1) {
        _advanceSource();
      } else {
        setState(() {
          _error = 'O servidor não está respondendo. Tente novamente.';
          _isLoading = false;
        });
      }
    });
    try {
      await _player.stop();
      // Fase 3: streams adaptativas (HLS/DASH) — mpv parte de uma bitrate
      // conservadora; forçamos a melhor disponível. No-op para mp4 direto.
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty('hls-bitrate', 'highest');
      }
      final headers = <String, String>{};
      if (src.headers.isNotEmpty) headers.addAll(src.headers);
      await _player.open(
        Media(src.url, httpHeaders: headers),
        play: true,
      );
      if (!mounted) return;
      debugPrint('[Player] Source $index opened successfully');
      _listenStreams();
      setState(() => _isLoading = false);
      _showControls();
      _restoreProgress();
    } catch (e) {
      _loadTimeout?.cancel();
      debugPrint('[Player] Error source $index: $e');
      if (!mounted) return;
      if (index < _sources.length - 1) {
        await _playSource(index + 1);
      } else {
        setState(() {
          _error = 'Erro ao reproduzir: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _listenStreams() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _player.stream.playing.listen((p) {
      if (!mounted) return;
      debugPrint('[Player] Playing: $p');
      setState(() => _isPlaying = p);
    });
    _positionSub = _player.stream.position.listen((p) {
      if (!mounted) return;
      _positionSec = p.inMilliseconds / 1000.0;
      _positionVN.value = _positionSec;
      if (_videoReady) _saveProgress();
    });
    _durationSub = _player.stream.duration.listen((d) {
      if (!mounted) return;
      _durationSec = d.inMilliseconds / 1000.0;
      _durationVN.value = _durationSec;
      debugPrint('[Player] Duration: ${_durationSec}s');
      if (_durationSec >= 10 && !_videoReady) {
        _loadTimeout?.cancel();
        _videoReady = true;
        _showControls();
        _prefetchNextEpisode();
        debugPrint('[Player] Video is ready, duration: ${_durationSec}s');
      }
    });
    _completedSub = _player.stream.completed.listen((_) {
      if (!mounted) return;
      debugPrint('[Player] Completed event (ready: $_videoReady, dur: ${_durationSec}s, pos: ${_positionSec}s)');
      // ponytail: completed com dur=0 = arquivo vazio/404 (visto em AnimeFire 720p hd/3.mp4).
      // Antes o early-return só jogava pro timeout. Auto-avança agora.
      if (!_videoReady) {
        _advanceSource();
        return;
      }
      if (_positionSec / _durationSec > 0.8) {
        _triggerAutoNext();
      }
    });
    _errorSub = _player.stream.error.listen((e) {
      if (!mounted) return;
      debugPrint('[Player] Error event: $e (ready=$_videoReady, playing=$_isPlaying)');
      // ponytail: guard de fatalidade. mpv pode disparar stream.error para
      // eventos não-fatais (warning de codec, segment retry, brief stall).
      // Antes, QUALQUER erro fatalizava e mostrava overlay — mesmo com o
      // vídeo ainda tocando. Só fatalizamos se o vídeo realmente não está
      // tocando/ready. Bug reportado: "erro apareceu mas o anime continuou".
      if (_videoReady && _isPlaying) {
        debugPrint('[Player] Ignoring non-fatal error event (video still playing)');
        return;
      }
      // B12: erro fatal (vídeo nunca ficou pronto) = fonte morta — tenta a
      // próxima qualidade automaticamente antes de desistir e mostrar erro.
      if (!_videoReady) {
        _advanceSource();
        return;
      }
      setState(() {
        _error = _friendlyError(e);
        _isLoading = false;
      });
    });
  }

  /// B12: compõe mensagem de erro com contexto (qualidade + host da fonte) em
  /// vez do vago "Verifique o vídeo." — o usuário sabe o que falhou.
  String _friendlyError(Object e) {
    final detail = e.toString();
    if (detail.contains('format') || detail.contains('unsupported')) {
      return 'Formato de vídeo não suportado. Tente outra fonte.';
    }
    final src = _selectedQualityIndex < _sources.length
        ? _sources[_selectedQualityIndex]
        : null;
    String host = '';
    try {
      host = Uri.parse(src?.url ?? '').host;
    } catch (_) {}
    final parts = <String>[
      if ((src?.quality ?? '').isNotEmpty) src!.quality,
      if (host.isNotEmpty) host,
    ];
    final sourceLabel = parts.join(' de ');
    return 'Não foi possível reproduzir'
        '${sourceLabel.isEmpty ? '' : ' $sourceLabel'}. '
        'A fonte pode estar fora do ar. Tente novamente ou escolha outra.';
  }

  /// B12: avança para a próxima fonte quando a atual está morta (timeout,
  /// arquivo vazio no completed, ou erro de stream) — deduplicado pelo flag
  /// [_autoAdvancing] para não pular fontes quando eventos disparam juntos.
  void _advanceSource() {
    if (_autoAdvancing) return;
    if (_selectedQualityIndex >= _sources.length - 1) return;
    _autoAdvancing = true;
    _playSource(_selectedQualityIndex + 1);
  }

  /// Fase 4: pré-busca do próximo episódio. Dispara assim que o vídeo fica
  /// pronto; `resolveProvidersForEpisode` cacheia o resultado, então o auto-
  /// next (ou o próximo tap) abre sem a fila de resolução das 4 fontes.
  /// Fire-and-forget — nunca bloqueia o playback atual.
  void _prefetchNextEpisode() {
    if (widget.episodeIndex >= widget.episodeList.length - 1) return;
    final next = widget.episodeIndex + 2; // 1-based número do próximo ep
    _repo
        .resolveProvidersForEpisode(widget.anime, next)
        .then((_) {}, onError: (e) =>
            debugPrint('[Player] Prefetch next ep $next failed: $e'));
  }

  void _saveProgress() {
    if (_durationSec < 10) return;
    // ponytail: throttle de 8s. Antes a cada tick (~10/s) chama setString no
    // disco. So flush final no dispose garante última posição.
    final now = DateTime.now();
    if (_lastProgressSave != null &&
        now.difference(_lastProgressSave!).inSeconds < 8) {
      return;
    }
    _lastProgressSave = now;
    _writeWatchProgressToDisk(widget.episodeIndex);
    _maybePushAnilistProgress();
  }

  void _writeWatchProgressToDisk(int episodeNumber) {
    final posMs = (_positionSec * 1000).toInt();
    LocalStorage.saveWatchProgress(
      animeKey: widget.anime.name,
      episodeNumber: episodeNumber,
      position: Duration(milliseconds: posMs),
      totalEpisodes: widget.episodeList.length,
    );
    LocalStorage.addToHistory(
      animeKey: widget.anime.name,
      title: widget.anime.name,
      imageUrl: widget.anime.imageUrl,
      lastEpisode: episodeNumber,
      totalEpisodes: widget.episodeList.length,
      anilistId: widget.anime.anilistId,
    );
  }

  Future<void> _maybePushAnilistProgress() async {
    if (_anilistPushedForThisEp) return;
    if (_positionSec / _durationSec < 0.75) return;
    _anilistPushedForThisEp = true;
    // ponytail: marca localmente no MESMO gate de 75% do AniList — convergência.
    // Antes só empurrava pro AniList; a grid local usava high-water-mark e
    // quebrava em fluxos não-contíguos. Reuso o gate p/ nao criar nova decisão.
    LocalStorage.markEpisodeWatched(
      animeKey: widget.anime.name,
      episodeIndex: widget.episodeIndex,
    );
    final id = widget.anime.anilistId;
    if (id == null) return;
    final newProgress = widget.episodeIndex + 1;
    // guard anti-decremento: não regredir o AniList ao reassistir um ep anterior
    // já visto. Compara com o progresso cached (do último getUserAnimeList ou
    // push espelhado em memória). cached null = anime novo/fora do cache → push.
    final cached = await AniListService.getCachedProgress(id);
    if (cached != null && newProgress <= cached) {
      debugPrint(
          '[Player] AniList push skipped: newProgress $newProgress <= cached $cached (reassistindo)');
      return;
    }
    // status: COMPLETED ao cruzar o último ep (total do AniList é confiável,
    // includes séries em lançamento com episódios totais previstos). Fallback
    // p/ episodeList.length se anime.episodes nulo. Senão CURRENT.
    final total = widget.anime.episodes ?? widget.episodeList.length;
    final status = (total > 0 && newProgress >= total) ? 'COMPLETED' : 'CURRENT';
    AniListService.updateProgress(
            mediaId: id, progress: newProgress, status: status)
        .then((ok) => debugPrint(
            '[Player] AniList push ep $newProgress/$id status=$status ok=$ok'))
        .catchError((e) => debugPrint('[Player] AniList push error: $e'));
  }

  void _restoreProgress() {
    final progress = LocalStorage.getWatchProgress(widget.anime.name);
    if (progress != null && progress['episode'] == widget.episodeIndex) {
      final posMs = progress['position'] as int? ?? 0;
      if (posMs > 5000) {
        _player.seek(Duration(milliseconds: posMs));
      }
    }
  }

  void _triggerAutoNext() {
    if (_showNextOverlay) return;
    if (widget.episodeIndex >= widget.episodeList.length - 1) return;
    setState(() {
      _showNextOverlay = true;
      _countdownSec = 10;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _countdownSec--);
      if (_countdownSec <= 0) {
        t.cancel();
        _playNextEpisode();
      }
    });
  }

  void _playNextEpisode() {
    _countdownTimer?.cancel();
    if (widget.episodeIndex < widget.episodeList.length - 1) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            anime: widget.anime,
            provider: widget.provider,
            episodeList: widget.episodeList,
            episodeIndex: widget.episodeIndex + 1,
          ),
        ),
      );
    }
  }

  void _cancelAutoNext() {
    _countdownTimer?.cancel();
    setState(() => _showNextOverlay = false);
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
    _showControls();
  }

  void _seekRelative(double seconds) {
    final pos = _positionSec + seconds;
    final clamped = pos.clamp(0.0, _durationSec);
    _player.seek(Duration(milliseconds: (clamped * 1000).toInt()));
    _showControls();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // ponytail: se overlay de erro está visível, deixa Select/Enter chegar ao
    // Focus do botão "Tentar novamente" (que tem autofocus). Sem isto, Select
    // era consumido aqui como _togglePlayPause — vídeo pausava mas o overlay
    // continuava (bug reportado: "Tentar novamente não removeu a mensagem").
    if (_error != null) return KeyEventResult.ignored;
    // Any directional key wake-ups the controls overlay if it auto-hid.
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      if (!_controlsVisible) {
        _showControls();
        return KeyEventResult.handled;
      }
    }
    // DPAD / remote handling for Android TV
    switch (k) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.mediaRewind:
        // If a control button is focused, let D-pad traverse between buttons.
        if (_aControlIsFocused) return KeyEventResult.ignored;
        _seekRelative(-10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.mediaFastForward:
        if (_aControlIsFocused) return KeyEventResult.ignored;
        _seekRelative(10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.mediaPlayPause:
        // A focused control button handles Select itself (FocusKeyHandler,
        // returns handled and stops here). If none is focused, treat Select
        // as play/pause as before.
        if (_aControlIsFocused) return KeyEventResult.ignored;
        _togglePlayPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        // let focus traversal handle it
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowDown:
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        debugPrint('[Player] Hiding controls automatically');
        setState(() => _controlsVisible = false);
      }
    });
  }

  String _formatTime(double sec) {
    if (sec.isNaN || sec.isInfinite || sec < 0) return '0:00';
    final d = Duration(milliseconds: (sec * 1000).toInt());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _countdownTimer?.cancel();
    _controlsTimer?.cancel();
    _loadTimeout?.cancel();
    for (final n in _controlNodes) {
      n.dispose();
    }
    // ponytail: flush final — garante última posição mesmo com throttle de 8s.
    if (_videoReady && _durationSec >= 10) {
      _writeWatchProgressToDisk(widget.episodeIndex);
    }
    _positionVN.dispose();
    _durationVN.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Stack(
          children: [
            Video(controller: _videoController),
            // B9: _isLoading e _error eram blocos irmãos independentes no
            // Stack — em janelas transitórias coexistiam e pintavam spinner
            // + erro juntos ("spinner fantasma"). Exclusivos agora.
            if (_isLoading && _error == null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: ThemeConstants.primary),
                    const SizedBox(height: 16),
                    Text(
                      _sources.isNotEmpty
                          ? 'Carregando ${_sources[_selectedQualityIndex].quality}...'
                          : 'Carregando vídeo...',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              _buildErrorState(),
            if (!_controlsVisible && _videoReady && !_showNextOverlay)
              Positioned.fill(
                child: Semantics(
                  button: true,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _showControls,
                      child: Container(),
                    ),
                  ),
                ),
              ),
            if (_controlsVisible)
              _buildControlsOverlay(),
            if (_showNextOverlay)
              _buildNextOverlay(),
          ],
        ),
      ),
    );
  }

  /// Builds a D-pad-focusable player control button: [Focus] + FocusKeyHandler
/// (Select/Enter call [onTap] directly, bypassing the InkWell race) + a
/// focus highlight ring. While focused, the ancestor key handler lets D-pad
/// traverse between buttons instead of seeking.
  Widget _controlButton({
    required FocusNode node,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Focus(
      focusNode: node,
      onKeyEvent: (n, e) => FocusKeyHandler.handle(n, e, onTap),
      onFocusChange: (focused) {
        if (focused) _controlsTimer?.cancel(); // keep overlay visible while focused
        setState(() {});
      },
      child: Builder(
        builder: (context) {
          final focused = node.hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: focused
                  ? Border.all(
                      color: ThemeConstants.primary,
                      width: ThemeConstants.focusBorderWidth,
                    )
                  : Border.all(color: Colors.transparent, width: 0),
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: ThemeConstants.primary.withValues(alpha: 0.4),
                        blurRadius: ThemeConstants.focusGlowBlur,
                      ),
                    ]
                  : const [],
            ),
            child: child,
          );
        },
      ),
    );
  }

  Widget _buildControlsOverlay() {
    return Positioned.fill(
      child: Focus(
        autofocus: true,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.7),
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: 0.7),
              ],
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 16, right: 16,
                ),
                child: Row(
                  children: [
                    _controlButton(
                      node: _backNode,
                      onTap: () => Navigator.pop(context),
                      child: Semantics(
                        button: true,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.arrow_back,
                                  color: Colors.white, size: 28),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    _controlButton(
                      node: _qualityNode,
                      onTap: _showQualitySelector,
                      child: Semantics(
                        button: true,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _sources.length > 1
                                ? _showQualitySelector
                                : null,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color:
                                    ThemeConstants.primary.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.settings,
                                      color: Colors.white, size: 20),
                                  const SizedBox(width: 6),
                                  Text(
                                    _sources[_selectedQualityIndex].quality,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _controlButton(
                      node: _visibilityNode,
                      onTap: () {
                        debugPrint('[Player] Toggle controls manually');
                        if (_controlsVisible) {
                          _controlsTimer?.cancel();
                          setState(() => _controlsVisible = false);
                        } else {
                          _showControls();
                        }
                      },
                      child: Semantics(
                        button: true,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              if (_controlsVisible) {
                                _controlsTimer?.cancel();
                                setState(() => _controlsVisible = false);
                              } else {
                                _showControls();
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                _controlsVisible
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _controlButton(
                    node: _replayNode,
                    onTap: () => _seekRelative(-10),
                    child: Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _seekRelative(-10),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            child: const Icon(Icons.replay_10,
                                color: Colors.white70, size: 48),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  _controlButton(
                    node: _playNode,
                    onTap: _togglePlayPause,
                    child: Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _togglePlayPause,
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            child: Icon(
                              _isPlaying
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              color: Colors.white70,
                              size: 72,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  _controlButton(
                    node: _forwardNode,
                    onTap: () => _seekRelative(10),
                    child: Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _seekRelative(10),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            child: const Icon(Icons.forward_10,
                                color: Colors.white70, size: 48),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              // ponytail: sub-árvore isolada. Resolvers de tick só reconstruem
              // este Padding; gradientes full-screen e ícones ficam estáticos.
              ValueListenableBuilder<double>(
                valueListenable: _durationVN,
                builder: (context, durSec, _) {
                  return ValueListenableBuilder<double>(
                    valueListenable: _positionVN,
                    builder: (context, posSec, _) {
                      return Padding(
                        padding: const EdgeInsets.only(
                            left: 24, right: 24, bottom: 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(_formatTime(posSec),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 14)),
                                const Spacer(),
                                Text(_formatTime(durSec),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 14)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final width = constraints.maxWidth;
                                return GestureDetector(
                                  onTapDown: (details) {
                                    if (durSec <= 0 || width <= 0) return;
                                    final fraction =
                                        (details.localPosition.dx / width)
                                            .clamp(0.0, 1.0);
                                    _player.seek(Duration(
                                        milliseconds:
                                            (fraction * durSec * 1000).toInt()));
                                  },
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: durSec > 0 ? posSec / durSec : 0,
                                      backgroundColor: Colors.white24,
                                      valueColor: const AlwaysStoppedAnimation(
                                          ThemeConstants.primary),
                                      minHeight: 6,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showQualitySelector() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeConstants.surface,
        title: const Text('Selecionar Qualidade',
            style: TextStyle(color: Colors.white)),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            // B9: muitas resoluções estouravam o AlertDialog na TV (540dp).
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _sources.asMap().entries.map((e) {
            final idx = e.key;
            final src = e.value;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Semantics(
                button: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      _playSource(idx);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _selectedQualityIndex == idx
                            ? ThemeConstants.primary.withValues(alpha: 0.3)
                            : ThemeConstants.surfaceLight,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.high_quality,
                              color: _selectedQualityIndex == idx
                                  ? ThemeConstants.primary
                                  : Colors.white),
                          const SizedBox(width: 12),
                          Text(src.quality,
                              style: TextStyle(
                                  color: _selectedQualityIndex == idx
                                      ? ThemeConstants.primary
                                      : Colors.white,
                                  fontSize: 18)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
);
            }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNextOverlay() {
    return Positioned(
      bottom: 80,
      right: 24,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ThemeConstants.primary.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Próximo episódio',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Episódio ${widget.episodeIndex + 2}',
                style: const TextStyle(
                    color: ThemeConstants.primary, fontSize: 14)),
            const SizedBox(height: 8),
            Text('Em $_countdownSec segundos...',
                style: const TextStyle(
                    color: ThemeConstants.textSecondary, fontSize: 14)),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  button: true,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _playNextEpisode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: ThemeConstants.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('Pular',
                            style: TextStyle(
                                color: Colors.white, fontSize: 14)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Semantics(
                  button: true,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _cancelAutoNext,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: ThemeConstants.surfaceLight,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('Cancelar',
                            style: TextStyle(
                                color: Colors.white, fontSize: 14)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Handler do "Tentar novamente": força re-resolve das fontes e reinicia.
  // Não chama _initPlayer direto — precisa setar _forceReresolve p/ quebrar
  // o cache de widget.initialSources (que pode estar morto/expirado).
  void _retry() {
    if (!mounted) return;
    setState(() {
      _forceReresolve = true;
      _error = null;
      _isLoading = true;
    });
    _initPlayer();
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 64),
            const SizedBox(height: 16),
            Text(_error!,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            // ponytail: Focus + FocusKeyHandler — FireTV remote envia Select
            // seguido de ArrowRight (~7ms) e InkWell.onTap perde a race. Sem
            // isto, Select no botão sobe pro _onKeyEvent ancestral e vira
            // _togglePlayPause (vídeo pausa, overlay fica). autofocus puxa o
            // foco pro botão quando o overlay aparece. Padrão do resto da app.
            Focus(
              autofocus: true,
              onKeyEvent: (node, event) =>
                  FocusKeyHandler.handle(node, event, _retry),
              child: Semantics(
                button: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _retry,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 14),
                      decoration: BoxDecoration(
                        color: ThemeConstants.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Tentar novamente',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
