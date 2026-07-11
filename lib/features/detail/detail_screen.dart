import 'package:flutter/material.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/storage/local_storage.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/cached_image.dart';
import '../player/player_screen.dart';
import '../superflix/superflix_web_screen.dart';

class DetailScreen extends StatefulWidget {
  final Anime anime;

  const DetailScreen({super.key, required this.anime});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final AnimeRepository _repo = AnimeRepository();
  List<Episode> _episodes = [];
  bool _isLoading = true;
  bool _isFavorite = false;
  Map<String, List<Episode>> _sourceOptions = {};
  String? _selectedSource;

  @override
  void initState() {
    super.initState();
    _isFavorite = LocalStorage.isFavorite(widget.anime.name);
    _loadEpisodes();
  }

  Future<void> _loadEpisodes() async {
    setState(() => _isLoading = true);
    try {
      final result = await _repo.getEpisodes(widget.anime);
      if (!mounted) return;
      if (result.sourceOptions.isNotEmpty) {
        final first = result.sourceOptions.entries.first;
        setState(() {
          _sourceOptions = result.sourceOptions;
          _selectedSource = first.key;
          _episodes = first.value;
          _isLoading = false;
        });
      } else {
        setState(() {
          _episodes = result.episodes;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[Detail] Load episodes error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onSourceChanged(String? key) {
    if (key == null || key == _selectedSource) return;
    final episodes = _sourceOptions[key];
    if (episodes == null) return;
    setState(() {
      _selectedSource = key;
      _episodes = episodes;
    });
  }

  void _toggleFavorite() {
    LocalStorage.toggleFavorite(
      animeKey: widget.anime.name,
      title: widget.anime.name,
      imageUrl: widget.anime.imageUrl,
    );
    setState(() => _isFavorite = !_isFavorite);
  }

  Future<void> _playEpisode(int index) async {
    _showQualityPicker(_episodes[index], index);
  }

  void _showQualityPicker(Episode episode, int index) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _QualityDialog(
        anime: widget.anime,
        episode: episode,
        episodeList: _episodes,
        episodeIndex: index,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: CustomScrollView(
        slivers: [
          _buildSliverHeader(),
          _buildSliverBody(),
        ],
      ),
    );
  }

  Widget _buildSliverHeader() {
    final topPad = MediaQuery.of(context).padding.top;
    final expandedHeight = 300.0;
    final collapsedHeight = topPad + kToolbarHeight + 8;

    return SliverAppBar(
      pinned: true,
      expandedHeight: expandedHeight,
      collapsedHeight: collapsedHeight,
      backgroundColor: ThemeConstants.background,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.anime.bannerImage != null &&
                widget.anime.bannerImage!.isNotEmpty)
              CachedImage(
                url: widget.anime.bannerImage,
                fit: BoxFit.cover,
                fallback: Container(color: ThemeConstants.surfaceLight),
              )
            else
              Container(
                color: ThemeConstants.surfaceLight,
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    ThemeConstants.background,
                    Colors.transparent,
                    ThemeConstants.background.withValues(alpha: 0.3),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: widget.anime.imageUrl.isNotEmpty
                        ? CachedImage(
                            url: widget.anime.imageUrl,
                            width: 90,
                            height: 130,
                            fit: BoxFit.cover,
                            fallback: Container(
                              width: 90,
                              height: 130,
                              color: ThemeConstants.surfaceLight,
                              child: const Icon(Icons.movie,
                                  color: ThemeConstants.textSecondary),
                            ),
                          )
                        : Container(
                            width: 90,
                            height: 130,
                            color: ThemeConstants.surfaceLight,
                            child: const Icon(Icons.movie,
                                color: ThemeConstants.textSecondary),
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.anime.name,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: ThemeConstants.white,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (widget.anime.averageScore != null) ...[
                              const Icon(Icons.star,
                                  color: Colors.amber, size: 18),
                              const SizedBox(width: 4),
                              Text(
                                '${(widget.anime.averageScore! / 10).toStringAsFixed(1)}',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.amber,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            if (widget.anime.episodes != null)
                              Text(
                                '${widget.anime.episodes} eps',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: ThemeConstants.textSecondary,
                                ),
                              ),
                            if (widget.anime.episodes != null) const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: ThemeConstants.primary
                                    .withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                widget.anime.sourceName,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: ThemeConstants.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        button: true,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _toggleFavorite,
                            customBorder: const CircleBorder(),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: _isFavorite
                                    ? ThemeConstants.accent.withValues(alpha: 0.3)
                                    : ThemeConstants.surfaceLight,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: _isFavorite
                                    ? ThemeConstants.accent
                                    : Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.anime.status != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            widget.anime.status!.replaceAll('_', ' '),
                            style: TextStyle(
                              fontSize: 11,
                              color: widget.anime.status == 'FINISHED'
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      leading: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => Navigator.pop(context),
            customBorder: const CircleBorder(),
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.arrow_back,
                  color: Colors.white, size: 24),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSliverBody() {
    if (_isLoading) {
      return const SliverFillRemaining(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          if (widget.anime.description != null &&
              widget.anime.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                widget.anime.description!.replaceAll(RegExp(r'<[^>]*>'), ''),
                style: const TextStyle(
                  fontSize: 15,
                  color: ThemeConstants.textSecondary,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (widget.anime.genres.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: widget.anime.genres.map((g) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: ThemeConstants.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: ThemeConstants.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      g,
                      style: const TextStyle(
                        fontSize: 13,
                        color: ThemeConstants.primary,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const Text(
                  'Episódios',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: ThemeConstants.white,
                  ),
                ),
                if (_sourceOptions.length > 1) ...[
                  const Spacer(),
                  _buildSourceSelector(),
                ],
              ],
            ),
          ),
          if (_episodes.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text(
                  'Nenhum episódio encontrado',
                  style: TextStyle(
                    fontSize: 16,
                    color: ThemeConstants.textSecondary,
                  ),
                ),
              ),
            )
          else
            _buildEpisodeGrid(),
        ]),
      ),
    );
  }

  Widget _buildSourceSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: ThemeConstants.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ThemeConstants.primary.withValues(alpha: 0.4)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedSource,
          dropdownColor: ThemeConstants.surface,
          style: const TextStyle(
            color: ThemeConstants.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          icon: const Icon(Icons.source, color: ThemeConstants.primary, size: 20),
          items: _sourceOptions.entries.map((e) {
            return DropdownMenuItem<String>(
              value: e.key,
              child: Text('${e.key} (${e.value.length})'),
            );
          }).toList(),
          onChanged: _onSourceChanged,
        ),
      ),
    );
  }

  Widget _buildEpisodeGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 900 ? 5 : constraints.maxWidth > 600 ? 4 : 2;
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          childAspectRatio: 2.8,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          children: List.generate(_episodes.length, (i) => _EpisodeCard(
            episode: _episodes[i],
            anime: widget.anime,
            onPlay: () => _playEpisode(i),
          )),
        );
      },
    );
  }
}

class _EpisodeCard extends StatefulWidget {
  final Episode episode;
  final Anime anime;
  final VoidCallback onPlay;

  const _EpisodeCard({
    required this.episode,
    required this.anime,
    required this.onPlay,
  });

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : ThemeConstants.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : ThemeConstants.surfaceLight,
                  width: _isFocused ? 2 : 1,
                ),
                boxShadow: _isFocused
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.3),
                          blurRadius: 12,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                children: [
                  Container(
                    width: 72,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: _isFocused
                          ? ThemeConstants.primaryDark
                          : ThemeConstants.surfaceLight,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(7),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'EP ${widget.episode.number}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _isFocused
                              ? Colors.white
                              : ThemeConstants.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.episode.title ?? 'Episódio ${widget.episode.number}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: ThemeConstants.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.play_circle_filled,
                      color: _isFocused
                          ? ThemeConstants.primary
                          : ThemeConstants.textSecondary,
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityDialog extends StatefulWidget {
  final Anime anime;
  final Episode episode;
  final List<Episode> episodeList;
  final int episodeIndex;

  const _QualityDialog({
    required this.anime,
    required this.episode,
    required this.episodeList,
    required this.episodeIndex,
  });

  @override
  State<_QualityDialog> createState() => _QualityDialogState();
}

class _QualityDialogState extends State<_QualityDialog> {
  final AnimeRepository _repo = AnimeRepository();
  List<VideoSource>? _sources;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    try {
      var sources = await _repo.getVideoSources(
        widget.episode,
        widget.anime.source,
        anime: widget.anime,
      );

      // SuperFlix player pages are gated by Cloudflare Turnstile; when HTTP
      // extraction comes back empty, fall back to the WebView resolver which
      // renders the page and passes the challenge.
      final effectiveSource = widget.episode.source ?? widget.anime.source;
      final sfAnime = widget.episode.owner ?? widget.anime;
      if (sources.isEmpty &&
          effectiveSource == AnimeSource.superFlix &&
          sfAnime.superFlixTmdbId != null &&
          mounted) {
        sources = await SuperFlixWebScreen.resolve(
          context,
          anime: sfAnime,
          episode: widget.episode,
        );
      }

      if (!mounted) return;
      setState(() {
        _sources = sources;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Erro ao carregar: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.all(24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Selecionar Qualidade',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                          color: ThemeConstants.primary),
                      SizedBox(height: 16),
                      Text(
                        'Buscando fontes de vídeo...',
                        style: TextStyle(
                          color: ThemeConstants.textSecondary,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(_error!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 16)),
                    const SizedBox(height: 16),
                    Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            decoration: BoxDecoration(
                              color: ThemeConstants.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Fechar',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 18)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (_sources != null && _sources!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Nenhum vídeo disponível.',
                    style: TextStyle(
                        color: ThemeConstants.textSecondary, fontSize: 16)),
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: _sources!.asMap().entries.map((e) {
                  final idx = e.key;
                  final src = e.value;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _navigateToPlayer(idx),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: ThemeConstants.surfaceLight,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: ThemeConstants.primary
                                    .withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.high_quality,
                                    color: Colors.white),
                                const SizedBox(width: 12),
                                Text(
                                  src.quality,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                  ),
                                ),
                                const Spacer(),
                                const Icon(Icons.play_arrow,
                                    color: ThemeConstants.primary),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  void _navigateToPlayer(int qualityIndex) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          anime: widget.anime,
          episode: widget.episode,
          episodeList: widget.episodeList,
          episodeIndex: widget.episodeIndex,
          initialSources: _sources,
          initialIndex: qualityIndex,
        ),
      ),
    );
  }
}
