import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/anilist/anilist_service.dart';
import '../../core/device/device_type.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/local_storage.dart';
import '../../core/utils/device_codecs.dart';
import '../../core/utils/quality_picker.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../data/repositories/anime_repository.dart';
import '../../shared/widgets/focus_key_handler.dart';
import 'dash_manifest_proxy.dart';
import 'player_screen.dart';

/// ExoPlayer screen, used exclusively for AnimeFire DASH streams.
///
/// Why a second player: the bundled mpv build rejects DASH manifests
/// (`Failed to recognize file format`, dur=0 — verified on x86_64 emulator
/// and ARM64 phone), while desktop mpv plays the same bytes. ExoPlayer
/// handles MPD natively (explicit `.mpd` URLs from [DashManifestProxy]),
/// so per-quality manifests ([VideoSource.dashHeight]) become real choices
/// instead of placebo buttons. Every other provider keeps [PlayerScreen].
///
/// Deliberately lean vs [PlayerScreen]: same navigation contract and progress
/// semantics (resume, throttled save, 75% watched + AniList push, auto-next),
/// but no AniSkip overlay (follow-up) and no mpv-specific guards.
class ExoDashPlayerScreen extends StatefulWidget {
  final Anime anime;
  final AnimeSource provider;
  final List<CatalogEpisode> episodeList;
  final int episodeIndex;
  final List<VideoSource>? initialSources;
  final int initialIndex;

  const ExoDashPlayerScreen({
    super.key,
    required this.anime,
    required this.provider,
    required this.episodeList,
    required this.episodeIndex,
    this.initialSources,
    this.initialIndex = 0,
  });

  @override
  State<ExoDashPlayerScreen> createState() => _ExoDashPlayerScreenState();
}

class _ExoDashPlayerScreenState extends State<ExoDashPlayerScreen>
    with WidgetsBindingObserver {
  final AnimeRepository _repo = AnimeRepository();
  final DashManifestProxy _dashProxy = DashManifestProxy();

  VideoPlayerController? _controller;
  Timer? _pollTimer;
  Timer? _controlsTimer;
  Timer? _loadTimeout;
  Timer? _countdownTimer;

  List<VideoSource> _sources = [];
  int _selectedQualityIndex = 0;

  bool _isLoading = true;
  bool _isPlaying = false;
  String? _error;
  bool _controlsVisible = true;
  double _positionSec = 0;
  double _durationSec = 0;
  bool _videoReady = false;
  bool _restoreAttempted = false;
  bool _anilistPushedForThisEp = false;
  bool _forceReresolve = false;
  bool _autoAdvancing = false;
  DateTime? _lastProgressSave;

  bool _showNextOverlay = false;
  int _countdownSec = 10;

  late final FocusNode _backNode = FocusNode();
  late final FocusNode _qualityNode = FocusNode();
  late final FocusNode _replayNode = FocusNode();
  late final FocusNode _playNode = FocusNode();
  late final FocusNode _forwardNode = FocusNode();
  List<FocusNode> get _controlNodes =>
      [_backNode, _qualityNode, _replayNode, _playNode, _forwardNode];
  bool get _aControlIsFocused =>
      _controlNodes.any((n) => n.hasPrimaryFocus);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DeviceType.lockLandscapeForPlayer();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initPlayer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) &&
        _videoReady &&
        _durationSec >= 10) {
      _writeProgress();
    }
  }

  Future<void> _initPlayer() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      List<VideoSource> sources;
      int startIndex = widget.initialIndex;
      if (widget.initialSources != null && !_forceReresolve) {
        sources = widget.initialSources!;
        debugPrint('[ExoDash] Using ${sources.length} pre-selected sources');
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
    debugPrint('[ExoDash] Attempting source $index: ${src.url} (${src.quality})');
    _autoAdvancing = false;
    await _disposeController();
    if (!mounted) return;
    setState(() {
      _selectedQualityIndex = index;
      _isLoading = true;
      _error = null;
      _videoReady = false;
      _anilistPushedForThisEp = false;
      _restoreAttempted = false;
      _positionSec = 0;
      _durationSec = 0;
    });
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      debugPrint('[ExoDash] Loading timeout for source $index');
      if (_selectedQualityIndex < _sources.length - 1) {
        _advanceSource();
      } else if (mounted) {
        setState(() {
          _error = 'O servidor não está respondendo. Tente novamente.';
          _isLoading = false;
        });
      }
    });
    try {
      var playUrl = src.url;
      try {
        playUrl = (await _dashProxy.serveManifest(
          manifestUrl: src.url,
          height: src.dashHeight,
          headers: src.headers,
        ))
            .toString();
        debugPrint('[ExoDash] Dash proxy: ${src.quality} -> $playUrl');
      } catch (e) {
        debugPrint('[ExoDash] Dash proxy failed, direct fallback: $e');
      }
      // AV1-only num aparelho sem decoder de hardware = som sobre tela
      // preta no ExoPlayer. Fallback automático e silencioso via software
      // (mpv/dav1d, parte na fixa mais baixa): o usuário só vê o loading.
      if (DashManifestProxy.isAv1Only(_dashProxy.lastVideoCodecs) &&
          !await DeviceCodecs.supportsAv1()) {
        _loadTimeout?.cancel();
        if (!mounted) return;
        debugPrint('[ExoDash] AV1-only sem HW — fallback software automático');
        _openSoftwareFallback();
        return;
      }
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(playUrl),
        httpHeaders: src.headers,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted) return;
      final durMs = controller.value.duration.inMilliseconds;
      _durationSec = durMs / 1000.0;
      _restoreProgress();
      await controller.play();
      _loadTimeout?.cancel();
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isPlaying = true;
        _videoReady = _durationSec >= 10;
      });
      _startPolling();
      _showControls();
      _prefetchNextEpisode();
      debugPrint('[ExoDash] Playing ${src.quality}, duration=${_durationSec}s');
    } catch (e) {
      _loadTimeout?.cancel();
      debugPrint('[ExoDash] Error source $index: $e');
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

  void _advanceSource() {
    if (_autoAdvancing) return;
    if (_selectedQualityIndex >= _sources.length - 1) return;
    _autoAdvancing = true;
    _playSource(_selectedQualityIndex + 1);
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      final c = _controller;
      if (!mounted || c == null || !c.value.isInitialized) return;
      if (c.value.hasError) {
        debugPrint('[ExoDash] Controller error: ${c.value.errorDescription}');
        _pollTimer?.cancel();
        if (!_videoReady) {
          _advanceSource();
          if (_autoAdvancing == false && _selectedQualityIndex >= _sources.length - 1) {
            setState(() {
              _error = 'Não foi possível reproduzir esta fonte. Tente outra.';
              _isLoading = false;
            });
          }
        }
        return;
      }
      final pos = c.value.position.inMilliseconds / 1000.0;
      final dur = c.value.duration.inMilliseconds / 1000.0;
      setState(() {
        _positionSec = pos;
        _durationSec = dur;
        _isPlaying = c.value.isPlaying;
        if (dur >= 10 && !_videoReady) {
          _videoReady = true;
          _loadTimeout?.cancel();
          _prefetchNextEpisode();
        }
      });
      if (_videoReady) {
        _saveProgress();
        if (dur > 10 && pos / dur > 0.8) _triggerAutoNext();
      }
    });
  }

  Future<void> _disposeController() async {
    _pollTimer?.cancel();
    final c = _controller;
    _controller = null;
    try {
      await c?.pause();
      await c?.dispose();
    } catch (_) {}
  }

  void _restoreProgress() {
    if (_restoreAttempted) return;
    _restoreAttempted = true;
    final progress = LocalStorage.getWatchProgress(widget.anime.name);
    final watchedSet =
        (progress?['watched'] as List?)?.cast<int>().toSet() ?? <int>{};
    if (watchedSet.contains(widget.episodeIndex)) return;
    final resume = LocalStorage.getResumePosition(
        widget.anime.name, widget.episodeIndex);
    if (resume == null || resume.inMilliseconds <= 5000) return;
    _controller?.seekTo(resume);
    debugPrint('[ExoDash] Resume seek -> ${resume.inSeconds}s');
  }

  void _saveProgress() {
    if (_durationSec < 10) return;
    final now = DateTime.now();
    if (_lastProgressSave != null &&
        now.difference(_lastProgressSave!).inSeconds < 8) {
      return;
    }
    _lastProgressSave = now;
    _writeProgress();
    _maybePushAnilistProgress();
  }

  void _writeProgress() {
    LocalStorage.saveWatchProgress(
      animeKey: widget.anime.name,
      episodeNumber: widget.episodeIndex,
      position: Duration(milliseconds: (_positionSec * 1000).toInt()),
      totalEpisodes: widget.episodeList.length,
    );
    LocalStorage.addToHistory(
      animeKey: widget.anime.name,
      title: widget.anime.name,
      imageUrl: widget.anime.imageUrl,
      lastEpisode: widget.episodeIndex,
      totalEpisodes: widget.episodeList.length,
      anilistId: widget.anime.anilistId,
    );
  }

  Future<void> _maybePushAnilistProgress() async {
    if (_anilistPushedForThisEp) return;
    if (_positionSec / _durationSec < 0.75) return;
    _anilistPushedForThisEp = true;
    LocalStorage.markEpisodeWatched(
      animeKey: widget.anime.name,
      episodeIndex: widget.episodeIndex,
    );
    final id = widget.anime.anilistId;
    if (id == null) return;
    final newProgress = widget.episodeIndex + 1;
    final cached = await AniListService.getCachedProgress(id);
    if (cached != null && newProgress <= cached) return;
    final total = widget.anime.episodes ?? widget.episodeList.length;
    final status = (total > 0 && newProgress >= total) ? 'COMPLETED' : 'CURRENT';
    AniListService.updateProgress(
            mediaId: id, progress: newProgress, status: status)
        .then((ok) => debugPrint(
            '[ExoDash] AniList push ep $newProgress/$id status=$status ok=$ok'))
        .catchError((e) => debugPrint('[ExoDash] AniList push error: $e'));
  }

  void _prefetchNextEpisode() {
    if (widget.episodeIndex >= widget.episodeList.length - 1) return;
    final next = widget.episodeIndex + 2;
    _repo
        .resolveProvidersForEpisode(widget.anime, next)
        .then((_) {}, onError: (e) =>
            debugPrint('[ExoDash] Prefetch next ep $next failed: $e'));
  }

  void _triggerAutoNext() {
    if (_showNextOverlay) return;
    if (widget.episodeIndex >= widget.episodeList.length - 1) return;
    setState(() {
      _showNextOverlay = true;
      _countdownSec = 10;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
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
          builder: (_) => ExoDashPlayerScreen(
            anime: widget.anime,
            provider: widget.provider,
            episodeList: widget.episodeList,
            episodeIndex: widget.episodeIndex + 1,
          ),
        ),
      );
    }
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() => _isPlaying = c.value.isPlaying);
    _showControls();
  }

  void _seekRelative(double seconds) {
    final c = _controller;
    if (c == null) return;
    final pos = _positionSec + seconds;
    final clamped = pos.clamp(0.0, _durationSec);
    c.seekTo(Duration(milliseconds: (clamped * 1000).toInt()));
    _showControls();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (_error != null) return KeyEventResult.ignored;
    if (_showNextOverlay) return KeyEventResult.ignored;
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
    switch (k) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.mediaRewind:
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
        if (_aControlIsFocused) return KeyEventResult.ignored;
        _togglePlayPause();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  String _formatTime(double sec) {
    if (sec.isNaN || sec.isInfinite || sec < 0) return '0:00';
    final d = Duration(milliseconds: (sec * 1000).toInt());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _showQualitySelector() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeConstants.surface,
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: const Text('Selecionar Qualidade',
            style: TextStyle(color: Colors.white),
            overflow: TextOverflow.ellipsis),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
            maxWidth: 512,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _sources.asMap().entries.map((e) {
                final idx = e.key;
                final src = e.value;
                final selected = _selectedQualityIndex == idx;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Focus(
                    onKeyEvent: (n, ev) => FocusKeyHandler.handle(n, ev, () {
                      Navigator.pop(ctx);
                      _playSource(idx);
                    }),
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
                            color: selected
                                ? ThemeConstants.primary.withValues(alpha: 0.3)
                                : ThemeConstants.surfaceLight,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.high_quality,
                                  color: selected
                                      ? ThemeConstants.primary
                                      : Colors.white),
                              const SizedBox(width: 12),
                              Text(src.quality,
                                  style: TextStyle(
                                      color: selected
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DeviceType.restoreAfterPlayer();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pollTimer?.cancel();
    _controlsTimer?.cancel();
    _loadTimeout?.cancel();
    _countdownTimer?.cancel();
    for (final n in _controlNodes) {
      n.dispose();
    }
    if (_videoReady && _durationSec >= 10) _writeProgress();
    _dashProxy.close();
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready =
        controller != null && controller.value.isInitialized && _error == null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Stack(
          children: [
            if (ready)
              Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio == 0
                      ? 16 / 9
                      : controller.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
            if (_isLoading && _error == null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                        color: ThemeConstants.primary),
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
            if (_error != null) _buildErrorState(),
            // Toque fora dos botões com controles ocultos reexibe o overlay.
            // Sem isto, no touch não há como chamar a UI de volta (no D-pad
            // as setas acordam via _onKeyEvent). Abaixo do overlay para não
            // roubar taps dos botões quando visível.
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
            if (_controlsVisible && ready) _buildControlsOverlay(),
            if (_showNextOverlay) _buildNextOverlay(),
          ],
        ),
      ),
    );
  }

  /// Fallback AV1 via software: reabre as mesmas fontes no PlayerScreen
  /// (mpv/ffmpeg+dav1d decodifica sem hardware) na qualidade que o usuário
  /// escolheu — sem trocar para 480p por conta própria.
  void _openSoftwareFallback() {
    if (_sources.isEmpty) return;
    final start = _selectedQualityIndex < _sources.length
        ? _selectedQualityIndex
        : 0;
    debugPrint('[ExoDash] Fallback software via mpv em '
        '${_sources[start].quality}');
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          anime: widget.anime,
          provider: widget.provider,
          episodeList: widget.episodeList,
          episodeIndex: widget.episodeIndex,
          initialSources: _sources,
          initialIndex: start,
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Text(_error ?? 'Erro desconhecido',
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  autofocus: true,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: ThemeConstants.primary),
                  onPressed: () {
                    _forceReresolve = true;
                    _initPlayer();
                  },
                  child: const Text('Tentar novamente'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Voltar',
                      style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlButton({
    required FocusNode node,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Focus(
      focusNode: node,
      onKeyEvent: (n, e) => FocusKeyHandler.handle(n, e, onTap),
      onFocusChange: (_) {
        _controlsTimer?.cancel();
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
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(onTap: onTap, child: child),
            ),
          );
        },
      ),
    );
  }

  Widget _buildControlsOverlay() {
    return Positioned.fill(
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
                left: 16,
                right: 16,
              ),
              child: Row(
                children: [
                  _controlButton(
                    node: _backNode,
                    onTap: () => Navigator.pop(context),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.arrow_back,
                          color: Colors.white, size: 28),
                    ),
                  ),
                  const Spacer(),
                  _controlButton(
                    node: _qualityNode,
                    onTap: _showQualitySelector,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: ThemeConstants.primary.withValues(alpha: 0.8),
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
                ],
              ),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _controlButton(
                  node: _replayNode,
                  onTap: () => _seekRelative(-10),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.replay_10,
                        color: Colors.white70, size: 48),
                  ),
                ),
                const SizedBox(width: 16),
                _controlButton(
                  node: _playNode,
                  onTap: _togglePlayPause,
                  child: Padding(
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
                const SizedBox(width: 16),
                _controlButton(
                  node: _forwardNode,
                  onTap: () => _seekRelative(10),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.forward_10,
                        color: Colors.white70, size: 48),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Padding(
              padding:
                  const EdgeInsets.only(left: 24, right: 24, bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(_formatTime(_positionSec),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14)),
                      const Spacer(),
                      Text(_formatTime(_durationSec),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: _durationSec > 0 ? _positionSec / _durationSec : 0,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(
                        ThemeConstants.primary),
                    minHeight: 6,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNextOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.8),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Próximo episódio em...',
                  style: TextStyle(color: Colors.white, fontSize: 20)),
              Text('$_countdownSec',
                  style: const TextStyle(
                      color: ThemeConstants.primary,
                      fontSize: 48,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    autofocus: true,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: ThemeConstants.primary),
                    onPressed: _playNextEpisode,
                    child: const Text('Pular agora'),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () {
                      _countdownTimer?.cancel();
                      setState(() => _showNextOverlay = false);
                    },
                    child: const Text('Cancelar',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
