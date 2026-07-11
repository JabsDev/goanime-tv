import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/storage/local_storage.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/constants/app_constants.dart';

class PlayerScreen extends StatefulWidget {
  final Anime anime;
  final Episode episode;
  final List<Episode> episodeList;
  final int episodeIndex;
  final List<VideoSource>? initialSources;
  final int initialIndex;

  const PlayerScreen({
    super.key,
    required this.anime,
    required this.episode,
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
      if (widget.initialSources != null) {
        sources = widget.initialSources!;
        debugPrint('[Player] Using ${sources.length} pre-selected sources');
      } else {
        sources = await _repo.getVideoSources(
          widget.episode,
          widget.anime.source,
          anime: widget.anime,
        );
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
      setState(() => _sources = sources);
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
    setState(() {
      _selectedQualityIndex = index;
      _isLoading = true;
      _error = null;
      _videoReady = false;
    });
    _loadTimeout?.cancel();
    _loadTimeout = Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      debugPrint('[Player] Loading timeout for source $index');
      setState(() {
        _error = 'O servidor não está respondendo. Tente novamente.';
        _isLoading = false;
      });
    });
    try {
      await _player.stop();
      final headers = <String, String>{
        'User-Agent': AppConstants.userAgent,
        'Referer': widget.episode.url.contains('animefire.io')
            ? 'https://animefire.io/'
            : 'https://animefire.plus/',
      };
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
      setState(() {});
      if (_videoReady) _saveProgress();
    });
    _durationSub = _player.stream.duration.listen((d) {
      if (!mounted) return;
      _durationSec = d.inMilliseconds / 1000.0;
      setState(() {});
      debugPrint('[Player] Duration: ${_durationSec}s');
      if (_durationSec >= 10 && !_videoReady) {
        _loadTimeout?.cancel();
        _videoReady = true;
        _showControls();
        debugPrint('[Player] Video is ready, duration: ${_durationSec}s');
      }
    });
    _completedSub = _player.stream.completed.listen((_) {
      if (!mounted) return;
      debugPrint('[Player] Completed event (ready: $_videoReady, dur: ${_durationSec}s, pos: ${_positionSec}s)');
      if (!_videoReady) return;
      if (_positionSec / _durationSec > 0.8) {
        _triggerAutoNext();
      }
    });
    _errorSub = _player.stream.error.listen((e) {
      if (!mounted) return;
      debugPrint('[Player] Error event: $e');
      setState(() {
        _error = 'Erro de reprodução: Verifique o vídeo.';
        _isLoading = false;
      });
    });
  }

  void _saveProgress() {
    if (_durationSec < 10) return;
    final posMs = (_positionSec * 1000).toInt();
    LocalStorage.saveWatchProgress(
      animeKey: widget.anime.name,
      episodeNumber: widget.episodeIndex,
      position: Duration(milliseconds: posMs),
      totalEpisodes: widget.episodeList.length,
    );
    LocalStorage.addToHistory(
      animeKey: widget.anime.name,
      title: widget.anime.name,
      imageUrl: widget.anime.imageUrl,
      lastEpisode: widget.episodeIndex,
      totalEpisodes: widget.episodeList.length,
    );
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
      final next = widget.episodeList[widget.episodeIndex + 1];
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            anime: widget.anime,
            episode: next,
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
    if (h > 0) return '${h}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m}:${s.toString().padLeft(2, '0')}';
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
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Video(controller: _videoController),
          if (_isLoading)
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
                    Semantics(
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
                    const Spacer(),
                    Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _sources.length > 1 ? _showQualitySelector : null,
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
                        ),
                      ),
                  ],
                ),
              ),
              const Spacer(),
              Semantics(
                button: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _togglePlayPause,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      child: Icon(
                        _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                        color: Colors.white70,
                        size: 72,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 24, bottom: 16),
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
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _durationSec > 0 ? _positionSec / _durationSec : 0,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation(
                            ThemeConstants.primary),
                        minHeight: 6,
                      ),
                    ),
                  ],
                ),
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
        content: Column(
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
            Semantics(
              button: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _initPlayer,
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
          ],
        ),
      ),
    );
  }
}
