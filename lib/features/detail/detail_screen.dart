import 'package:flutter/material.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/navigation/route_observer.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/storage/local_storage.dart';
import '../../core/storage/settings_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/cached_image.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../player/player_screen.dart';

class DetailScreen extends StatefulWidget {
  final Anime anime;

  const DetailScreen({super.key, required this.anime});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> with RouteAware {
  final AnimeRepository _repo = AnimeRepository();
  List<Episode> _episodes = [];
  bool _isLoading = true;
  bool _isFavorite = false;
  Map<String, List<Episode>> _sourceOptions = {};
  String? _selectedSource;

  @override
  void initState() {
    super.initState();
    debugPrint('[Detail] initState name=${widget.anime.name} source=${widget.anime.source}');
    _isFavorite = LocalStorage.isFavorite(widget.anime.name);
    // B4: resultado vindo da busca traz só dados do scraper. Se não há
    // metadata e não veio do catálogo AniList (que já é rico), enriquece
    // aqui p/ paridade com a Home (sinopse/backdrop/gêneros/capa).
    if ((widget.anime.description == null ||
            widget.anime.description!.isEmpty ||
            widget.anime.genres.isEmpty) &&
        widget.anime.anilistId == null) {
      AniListService.enrich(widget.anime).then((_) {
        if (mounted) setState(() {});
      });
    }
    _loadEpisodes();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    // Voltou do player (ou outra rota empilhada). Re-casa local × AniList e
    // repinta a grade p/ refletir eps marcados assistidos durante o playback.
    debugPrint('[Detail] didPopNext — re-casando com AniList');
    _reconcileWithAnilist();
  }

  /// Backsync cross-device: busca o status+progresso do entry no AniList,
  /// funde com o high-water local (max-merge p/ não perder progresso offline),
  /// marca o conjunto assistido CONTÍGUO 0..N-1, e back-push se local à frente.
  /// AniList prevalece (Q5); local à frente sobe p/ AniList. (Regra Q4: 1..N.)
  Future<void> _reconcileWithAnilist() async {
    final id = widget.anime.anilistId;
    if (id == null) return;
    final entry = await AniListService.getMediaListEntry(id);
    if (!mounted) return;
    final localProg = LocalStorage.getWatchProgress(widget.anime.name);
    final watched =
        (localProg?['watched'] as List?)?.cast<int>().toSet() ?? <int>{};
    // legacy fallback (pré-migração, sem chave 'watched'): high-water do
    // último episode INDEX jogado.
    final legacyEp = localProg?['episode'] as int? ?? -1;
    int localHigh;
    if (watched.isEmpty) {
      localHigh = legacyEp + 1;
    } else {
      localHigh = watched.reduce((a, b) => a > b ? a : b) + 1;
    }
    if (localHigh < 0) localHigh = 0;
    final anilistProgress = entry?.progress ?? 0;
    final effective = anilistProgress > localHigh ? anilistProgress : localHigh;
    if (effective > 0) {
      await LocalStorage.reconcileWatched(
          animeKey: widget.anime.name, progress: effective);
    }
    if (mounted) setState(() {});
    // back-push: local à frente do AniList (offline / push anterior falhou).
    if (entry != null && entry.progress != null && localHigh > entry.progress!) {
      final total = widget.anime.episodes ?? _episodes.length;
      final status =
          (total > 0 && localHigh >= total) ? 'COMPLETED' : 'CURRENT';
      AniListService.updateProgress(
              mediaId: id, progress: localHigh, status: status)
          .then((ok) => debugPrint(
              '[Detail] back-push local=$localHigh > anilist=${entry.progress} status=$status ok=$ok'))
          .catchError((e) => debugPrint('[Detail] back-push error: $e'));
    }
  }

  Future<void> _loadEpisodes() async {
    debugPrint('[Detail] _loadEpisodes start');
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

      // Log the result for debugging
      debugPrint('[Detail] Loaded ${_episodes.length} episodes from ${result.sourceOptions.length} sources');
      debugPrint('[Detail] _loadEpisodes end eps=${result.episodes.length} sources=${result.sourceOptions.length}');
      _reconcileWithAnilist();
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
      anilistId: widget.anime.anilistId,
    );
    setState(() => _isFavorite = !_isFavorite);
  }

  Future<void> _playEpisode(int index) async {
    debugPrint('[Detail] Tap EP index=$index num=${_episodes[index].number} source=${_episodes[index].source} owner=${_episodes[index].owner?.source}');
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

  void _showEpisodeDescription(BuildContext context, Episode episode) {
    if (episode.description == null || episode.description!.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(episode.title ?? 'Episódio ${episode.number}'),
        content: SingleChildScrollView(
          child: Text(
            episode.description ?? '',
            style: const TextStyle(fontSize: 14),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fechar'),
          ),
        ],
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
          // ponytail: grid virtualizado como sliver sibling. Antes era
          // GridView.count shrinkWrap com List.generate — long shows instanciavam
          // 1000+ _EpisodeCard Statefuls upfront.
          if (!_isLoading && _episodes.isNotEmpty) _buildSliverEpisodeGrid(),
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
                                (widget.anime.averageScore! / 10).toStringAsFixed(1),
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
                  if (widget.anime.status != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
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
            ),
          ],
        ),
      ),
      // B2: o coração fica na barra PINNED (actions), não no FlexibleSpaceBar
      // que colapsa ao scrollar — antes ele saía do viewport e ficava
      // inacessível por D-pad. Aqui permanece visível junto do voltar.
      leading: _BackButton(onTap: () => Navigator.pop(context)),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Center(
            child: _FavoriteButton(
              isFavorite: _isFavorite,
              onTap: _toggleFavorite,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSliverBody() {
    if (_isLoading) {
      // ponytail: cosmetic — spinner sem identificação causa percepção de "nada aconteceu" em TV lenta
      return SliverFillRemaining(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: ThemeConstants.primary),
              const SizedBox(height: 16),
              Text(
                'Carregando episódios de ${widget.anime.name}...',
                style: const TextStyle(
                  color: ThemeConstants.textSecondary,
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
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
              Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sentiment_dissatisfied, color: Colors.white24, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'Nada por aqui',
                        style: TextStyle(
                          fontSize: 22,
                          color: ThemeConstants.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Não conseguimos achar episódios para este anime '
                        'em nenhuma das fontes (AnimeFire, Goyabu, '
                        'BetterAnime, AnimesROLL, DooPlay, AnimePlayer). '
                        'Pode ser que o título não esteja '
                        'indexado ou todas as fontes estejam indisponíveis no momento.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: ThemeConstants.textSecondary,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                     _DialogButton(
                       label: 'Tentar novamente',
                       primary: true,
                       onTap: _loadEpisodes,
                     ),
                   ],
                 ),
               ),
             )
           // else: episodes grid rendered as a separate sliver sibling (see build()).
         ]),
       ),
     );
   }

  Widget _buildSourceSelector() {
    return _SourceSelector(
      selectedSource: _selectedSource,
      options: _sourceOptions,
      onChanged: _onSourceChanged,
    );
  }

  Widget _buildSliverEpisodeGrid() {
    final width = MediaQuery.sizeOf(context).width;
    // ponytail: FireTV reporta density 320 (dpr 2.0) → logical width = 960.
    // 3 colunas nessa faixa dão card ~300lp p/ título de 3 linhas caber.
    final crossAxisCount = width > 1400 ? 5 : width > 900 ? 3 : width > 600 ? 2 : 1;
    final progress = LocalStorage.getWatchProgress(widget.anime.name);
    final watchedSet =
        (progress?['watched'] as List?)?.cast<int>().toSet() ?? <int>{};
    // ponytail: pinta prefixo contíguo 0..maxWatchedIdx. Combina high-water do
    // último ep tocado (progress['episode']) com o maior índice no conjunto
    // 'watched' (preenchido pelo gate de 75% do player e pelo reconcileWatched
    // quando o AniList reporta progress N). Garante que TODOS os eps até o
    // último assistido fiquem verdes, mesmo em fluxos não-contíguos.
    final epIndex = (progress?['episode'] as int?) ?? -1;
    final maxWatchedIdx = [
      if (watchedSet.isNotEmpty) watchedSet.reduce((a, b) => a > b ? a : b),
      epIndex,
    ].fold<int>(-1, (a, b) => a > b ? a : b);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: 2.2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: _episodes.length,
        itemBuilder: (context, i) => _EpisodeCard(
          key: ValueKey('${_selectedSource}_$i'),
          index: i,
          episode: _episodes[i],
          anime: widget.anime,
          isWatched: i <= maxWatchedIdx,
          onPlay: () => _playEpisode(i),
        ),
      ),
    );
  }
}

class _EpisodeCard extends StatefulWidget {
  final int index;
  final Episode episode;
  final Anime anime;
  final bool isWatched;
  final VoidCallback onPlay;

  const _EpisodeCard({
    super.key,
    required this.index,
    required this.episode,
    required this.anime,
    required this.isWatched,
    required this.onPlay,
  });

  @override
  State<_EpisodeCard> createState() => _EpisodeCardState();
}

class _EpisodeCardState extends State<_EpisodeCard> {
  bool _isFocused = false;

  // B6: a fonte fabrica "Episódio N"; repetir como texto trunca feio
  // ("Epis…"). Para títulos estúrgicos (só "Episódio N"), mostra o número em
  // destaque no lugar do título — evita o card vazio e reforça o número.
  Widget _buildTitle() {
    final t = widget.episode.title;
    final generic = t == null ||
        t.isEmpty ||
        RegExp(r'^epis[oó]dio\s+\d+$', caseSensitive: false).hasMatch(t);
    if (generic) {
      return Text(
        'Episódio ${widget.episode.number}',
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: ThemeConstants.white,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text(
      t,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: ThemeConstants.white,
        height: 1.25,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildCover() {
    final thumb = widget.episode.thumbnail;
    final poster = widget.anime.imageUrl;
    final hasThumb = thumb != null && thumb.isNotEmpty;
    final hasPoster = poster.isNotEmpty;
    return Container(
      width: 120,
      height: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ThemeConstants.surfaceLight,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasThumb || hasPoster)
            CachedImage(
              url: hasThumb ? thumb : poster,
              fit: BoxFit.cover,
              fallback: Container(color: ThemeConstants.surfaceLight),
            ),
          if (!hasThumb && !hasPoster)
            Center(
              child: Text(
                'EP ${widget.episode.number}',
                style: const TextStyle(
                  color: ThemeConstants.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          Positioned(
            left: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'EP ${widget.episode.number}',
                style: const TextStyle(
                  color: ThemeConstants.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // B5: foco inicial pousa no primeiro episódio (sempre visível no grid
      // da TV) em vez de em nó fora do viewport/header colapsado.
      autofocus: widget.index == 0,
      onFocusChange: (focused) {
        setState(() => _isFocused = focused);
      },
      onKeyEvent: (node, event) {
        // ponytail: FireTV remote envia Select logo seguido de ArrowRight (~7ms).
        // InkWell.onTap perde a race c/ a trava de foco do ArrowRight. Helper
        // FocusKeyHandler intercepta Select/Enter/Space e chama onPlay direto.
        return FocusKeyHandler.handle(node, event, widget.onPlay);
      },
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPlay,
            child: AnimatedContainer(
              duration: SettingsService.instance.animDuration,
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : (widget.isWatched
                        ? ThemeConstants.watched
                        : ThemeConstants.surface),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : ThemeConstants.surfaceLight,
                  width: _isFocused ? 2 : 1,
                ),
                boxShadow: (_isFocused && SettingsService.instance.shadowsEnabled)
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
                  _buildCover(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildTitle(),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
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
    debugPrint('[QualityDialog] loadSources start ep=${widget.episode.number} source=${widget.episode.source ?? widget.anime.source} anime=${widget.anime.name}');
    try {
      var sources = await _repo.getVideoSources(
        widget.episode,
        widget.anime.source,
        anime: widget.anime,
      );
      debugPrint('[QualityDialog] primary sources count=${sources.length}');

      final effectiveSource = widget.episode.source ?? widget.anime.source;
      // If the primary source fails, try the episode's own owner source when
      // it differs (episodes can be merged from another provider).
      if (sources.isEmpty &&
          mounted &&
          effectiveSource == AnimeSource.animeFire &&
          widget.episode.owner != null &&
          widget.episode.owner!.source != AnimeSource.animeFire) {
        debugPrint('[QualityDialog] Falling back to ${widget.episode.owner!.source}');
        sources = await _repo.getVideoSources(
          widget.episode,
          widget.episode.owner!.source,
          anime: widget.episode.owner ?? widget.anime,
        );
      }

      if (!mounted) return;
      debugPrint('[QualityDialog] loadSources done count=${sources.length}');
      setState(() {
        _sources = sources;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('[QualityDialog] Load sources error: $e');
      setState(() {
        _error = 'Fonte indisponível. Tente novamente ou escolha outra fonte.';
        _loading = false;
      });
    }
  }

  String _effectiveSourceName() {
    final src = widget.episode.source ?? widget.anime.source;
    switch (src) {
      case AnimeSource.animeFire:
        return 'AnimeFire';
      case AnimeSource.anilist:
        return 'AniList';
      case AnimeSource.goyabu:
        return 'Goyabu';
      case AnimeSource.allAnime:
        return 'AllAnime';
      case AnimeSource.betterAnime:
        return 'BetterAnime';
      case AnimeSource.animesRoll:
        return 'AnimesROLL';
      case AnimeSource.dooPlay:
        return 'DooPlay';
      case AnimeSource.animePlayer:
        return 'Anime Player';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.all(32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 6,
                  height: 28,
                  decoration: BoxDecoration(
                    color: ThemeConstants.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
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
                      const SizedBox(height: 2),
                      Text(
                        'Ep ${widget.episode.number} · ${_effectiveSourceName()}',
                        style: const TextStyle(
                          color: ThemeConstants.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
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
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Não foi possível carregar o vídeo',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'O servidor pode estar temporariamente indisponível. Tente novamente ou escolha outra fonte.',
                      style: TextStyle(color: ThemeConstants.textSecondary, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _DialogButton(
                          label: 'Tentar novamente',
                          primary: true,
                          onTap: () {
                            setState(() { _error = null; _loading = true; });
                            _loadSources();
                          },
                        ),
                        const SizedBox(width: 12),
                        _DialogButton(
                          label: 'Fechar',
                          onTap: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else if (_sources == null || _sources!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    const Icon(Icons.videocam_off, color: Colors.orange, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Nenhuma resolução disponível',
                      style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Tentamos AnimeFire, Goyabu, BetterAnime e AnimePlayer '
                      'para o Ep ${widget.episode.number} deste anime, '
                      'mas nenhuma fonte resolveu um stream jogável agora. '
                      'Possíveis motivos: Cloudflare, fonte fora do ar ou o '
                      'anime ainda não foi indexado por essas fontes.',
                      style: const TextStyle(
                        color: ThemeConstants.textSecondary,
                        fontSize: 14,
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _DialogButton(
                          label: 'Tentar novamente',
                          primary: true,
                          onTap: () {
                            setState(() { _loading = true; _sources = null; });
                            _loadSources();
                          },
                        ),
                        const SizedBox(width: 12),
                        _DialogButton(
                          label: 'Voltar',
                          onTap: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: _sources!.asMap().entries.map((e) {
                  final idx = e.key;
                  final src = e.value;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: _QualityItem(
                      quality: src.quality,
                      onTap: () => _navigateToPlayer(idx),
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
    debugPrint('[QualityDialog] navigate idx=$qualityIndex');
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

// ponytail: antes, itens do dialog eram InkWell sem Focus → D-pad andava
// invisível. Aproveita o padrão AnimatedContainer com border/shadow primary
// usado em FocusableCard/EpisodeCard para foco visível no controle.
class _QualityItem extends StatefulWidget {
  final String quality;
  final VoidCallback onTap;

  const _QualityItem({required this.quality, required this.onTap});

  @override
  State<_QualityItem> createState() => _QualityItemState();
}

class _QualityItemState extends State<_QualityItem> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: SettingsService.instance.animDuration,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : ThemeConstants.surfaceLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : ThemeConstants.surfaceLight,
                  width: _isFocused
                      ? ThemeConstants.focusBorderWidth
                      : 1,
                ),
                boxShadow: (_isFocused && SettingsService.instance.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.4),
                          blurRadius: ThemeConstants.focusGlowBlur,
                          spreadRadius: 1,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.high_quality,
                    color: _isFocused
                        ? ThemeConstants.primary
                        : ThemeConstants.white,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.quality,
                      style: TextStyle(
                        color: _isFocused
                            ? ThemeConstants.primary
                            : ThemeConstants.white,
                        fontSize: 18,
                        fontWeight: _isFocused
                            ? FontWeight.bold
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.play_arrow,
                    color: _isFocused
                        ? ThemeConstants.primary
                        : ThemeConstants.textSecondary,
                    size: 26,
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

class _DialogButton extends StatefulWidget {
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const _DialogButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  State<_DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<_DialogButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: SettingsService.instance.animDuration,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: widget.primary
                    ? (_isFocused
                        ? ThemeConstants.primary
                        : ThemeConstants.primaryDark)
                    : (_isFocused
                        ? ThemeConstants.surfaceLight
                        : ThemeConstants.surface),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : (widget.primary
                          ? ThemeConstants.primary
                          : ThemeConstants.surfaceLight),
                  width: _isFocused
                      ? ThemeConstants.focusBorderWidth
                      : 1,
                ),
                boxShadow: (_isFocused && SettingsService.instance.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.5),
                          blurRadius: ThemeConstants.focusGlowBlur,
                        ),
                      ]
                    : [],
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: widget.primary
                      ? Colors.white
                      : (_isFocused
                          ? ThemeConstants.primary
                          : ThemeConstants.white),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ponytail: botão favorito focável — antes InkWell sem Focus invisível no remote.
class _FavoriteButton extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onTap;

  const _FavoriteButton({required this.isFavorite, required this.onTap});

  @override
  State<_FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<_FavoriteButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: SettingsService.instance.animDuration,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.isFavorite
                    ? ThemeConstants.accent.withValues(alpha: 0.3)
                    : ThemeConstants.surfaceLight,
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : Colors.transparent,
                  width: ThemeConstants.focusBorderWidth,
                ),
                boxShadow: (_isFocused && SettingsService.instance.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.5),
                          blurRadius: ThemeConstants.focusGlowBlur,
                        ),
                      ]
                    : [],
              ),
              child: Icon(
                widget.isFavorite ? Icons.favorite : Icons.favorite_border,
                color: widget.isFavorite ? ThemeConstants.accent : Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackButton extends StatefulWidget {
  final VoidCallback onTap;

  const _BackButton({required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: SettingsService.instance.animDuration,
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : Colors.transparent,
                  width: ThemeConstants.focusBorderWidth,
                ),
                boxShadow: (_isFocused && SettingsService.instance.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.5),
                          blurRadius: ThemeConstants.focusGlowBlur,
                        ),
                      ]
                    : [],
              ),
              child: Icon(
                Icons.arrow_back,
                color: _isFocused ? ThemeConstants.primary : Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ponytail: antes DropdownButton sem Focus → D-pod pousava invisível no seletor
// de fontes. DropdownButton não é ativável por Select no remote (mobile-first),
// então troquei por InkWell + showMenu. Mesmo padrão AnimatedContainer de
// _QualityItem/_DialogButton: border + glow primary ao focar, FocusKeyHandler
// despacha Select/Enter/Space para abrir o menu nativo.
class _SourceSelector extends StatefulWidget {
  final String? selectedSource;
  final Map<String, List<Episode>> options;
  final ValueChanged<String?> onChanged;

  const _SourceSelector({
    required this.selectedSource,
    required this.options,
    required this.onChanged,
  });

  @override
  State<_SourceSelector> createState() => _SourceSelectorState();
}

class _SourceSelectorState extends State<_SourceSelector> {
  bool _isFocused = false;

  Future<void> _openMenu() async {
    final renderBox = context.findRenderObject() as RenderBox?;
    final offset = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final size = renderBox?.size ?? Size.zero;
    final key = await showMenu<String>(
      context: context,
      color: ThemeConstants.surface,
      initialValue: widget.selectedSource,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height + 4,
        offset.dx + size.width + 200,
        offset.dy + size.height + 4,
      ),
      items: widget.options.entries.map((e) {
        return PopupMenuItem<String>(
          value: e.key,
          child: Text(
            e.key,
            style: const TextStyle(
              color: ThemeConstants.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      }).toList(),
    );
    if (key != null) widget.onChanged(key);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, _openMenu),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _openMenu,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: SettingsService.instance.animDuration,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : ThemeConstants.surfaceLight,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : ThemeConstants.primary.withValues(alpha: 0.4),
                  width: _isFocused ? ThemeConstants.focusBorderWidth : 1,
                ),
                boxShadow: (_isFocused && SettingsService.instance.shadowsEnabled)
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.4),
                          blurRadius: ThemeConstants.focusGlowBlur,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.selectedSource ?? '',
                    style: TextStyle(
                      color: _isFocused
                          ? ThemeConstants.primary
                          : ThemeConstants.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.source,
                    color: ThemeConstants.primary,
                    size: 20,
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
