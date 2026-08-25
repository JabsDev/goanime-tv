import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/navigation/route_observer.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/storage/local_storage.dart';
import '../../core/storage/settings_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/utils/nsfw_filter.dart';
import '../../core/utils/quality_picker.dart';
import '../../core/utils/episode_airing.dart';
import '../../core/sources/source_ping_service.dart';
import '../../shared/widgets/cached_image.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../../shared/widgets/app_top_bar.dart';
import '../../shared/widgets/tv_button.dart';
import '../player/player_screen.dart';
import '../settings/settings_screen.dart';

class DetailScreen extends StatefulWidget {
  final Anime anime;

  const DetailScreen({super.key, required this.anime});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> with RouteAware {
  final AnimeRepository _repo = AnimeRepository();
  List<CatalogEpisode> _episodes = [];
  bool _isLoading = true;
  bool _isFavorite = false;
  // B8: UP na primeira linha do grid de episódios pousa no favorito, não na
  // seta voltar (topo-esquerda) — o scroll "passava pelo" coração.
  final FocusNode _favoriteFocus = FocusNode();

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
    _favoriteFocus.dispose();
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
    // BUGFIX (75%): localHigh reflete só o que REALMENTE foi assistido (gate de
    // 75% / reconcileWatched). Removido o fallback legado `episode+1`: abrir um
    // ep e sair gravava esse high-water e, via max-merge, marcava 0..N verdes
    // e empurrava progresso falso ao AniList.
    var localHigh = watched.isEmpty
        ? 0
        : watched.reduce((a, b) => a > b ? a : b) + 1;
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
      final episodes = await _repo.getCatalogEpisodes(widget.anime);
      if (!mounted) return;
      setState(() {
        _episodes = episodes;
        _isLoading = false;
      });

      debugPrint('[Detail] Loaded ${_episodes.length} canonical episodes');
      _reconcileWithAnilist();
    } catch (e) {
      debugPrint('[Detail] Load episodes error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
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

  void _playEpisode(int index) {
    debugPrint('[Detail] Tap EP index=$index num=${_episodes[index].number}');
    // BUGFIX (retomada): ep parado no meio (minutagem salva e não assistido)
    // pergunta se o usuário quer continuar de onde parou ou recomeçar.
    final progress = LocalStorage.getWatchProgress(widget.anime.name);
    final watchedSet =
        (progress?['watched'] as List?)?.cast<int>().toSet() ?? <int>{};
    final resume =
        LocalStorage.getResumePosition(widget.anime.name, index);
    final partial =
        !watchedSet.contains(index) &&
        resume != null &&
        resume.inMilliseconds > 5000;
    if (partial) {
      _showResumeChoiceDialog(index, resume);
    } else {
      _showEpisodeSourcePicker(index);
    }
  }

  /// BUGFIX (retomada): diálogo de escolha para episódio parado no meio.
  /// "Continuar" abre normal (o player restaura a minutagem); "Recomeçar"
  /// limpa a minutagem salva para o player abrir do zero.
  void _showResumeChoiceDialog(int index, Duration resume) {
    final d = resume;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final time = h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '$m:${s.toString().padLeft(2, '0')}';
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeConstants.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Continuar de onde parou?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'O episódio ${_episodes[index].number} parou em $time. '
          'Deseja continuar de onde parou ou recomeçar?',
          style: const TextStyle(
              color: ThemeConstants.textSecondary, fontSize: 16, height: 1.4),
        ),
        actions: [
          _DialogButton(
            label: 'Continuar',
            primary: true,
            autofocus: true,
            onTap: () {
              Navigator.pop(ctx);
              _showEpisodeSourcePicker(index);
            },
          ),
          _DialogButton(
            label: 'Recomeçar',
            onTap: () {
              Navigator.pop(ctx);
              LocalStorage.clearResumePosition(
                  animeKey: widget.anime.name, episodeIndex: index);
              _showEpisodeSourcePicker(index);
            },
          ),
        ],
      ),
    );
  }

  void _showEpisodeSourcePicker(int index) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ProviderQualityDialog(
        anime: widget.anime,
        episode: _episodes[index],
        episodeIndex: index,
        episodeList: _episodes,
      ),
    );
  }

  Widget _buildBlocked(NsfwFilterSetting setting) {
    final isStrict = setting == NsfwFilterSetting.strict;
    final label = isStrict
        ? 'Conteúdo oculto pelo filtro'
        : 'Conteúdo adulto oculto pelo filtro';
    final hint = isStrict
        ? 'Este anime é classificado como ecchi ou hentai. Ajuste o filtro '
            'de conteúdo nas configurações para exibi-lo.'
        : 'Este anime é classificado como hentai. Ajuste o filtro de '
            'conteúdo nas configurações para exibi-lo.';
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          AppTopBar(
            title: widget.anime.name,
            icon: Icons.visibility_off,
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.visibility_off,
                        color: ThemeConstants.textSecondary, size: 56),
                    const SizedBox(height: 16),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      hint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        color: ThemeConstants.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TVButton(
                      label: 'Ajustar filtro',
                      icon: Icons.settings,
                      isPrimary: false,
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                      },
                      width: 240,
                    ),
                  ],
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
    // ponytail: rede de segurança contra caminhos que contornam o filtro
    // (ex.: favoritos/histórico salvos antes do filtro existir). Caminhos
    // normais já filtram na origem (busca/home/favoritos).
    final setting = SettingsService.instance.nsfwFilterLevel;
    if (!NsfwFilter.shouldShow(widget.anime, setting)) {
      return _buildBlocked(setting);
    }
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
              focusNode: _favoriteFocus,
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

    final continueIndex = _continueIndex();
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
          if (continueIndex != null) _buildContinueCard(continueIndex),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: const Text(
              'Episódios',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: ThemeConstants.white,
              ),
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

  /// Índice do card "Continuar de onde parou".
  /// BUGFIX (retomada): se o último episódio tocado ainda NÃO foi concluído
  /// (parado no meio sem atingir o gate de 75%), o card aponta para ELE MESMO
  /// — retomar o episódio em andamento em vez de pular para o próximo.
  int? _continueIndex() {
    if (_episodes.isEmpty) return null;
    final progress = LocalStorage.getWatchProgress(widget.anime.name);
    if (progress == null) return null;
    final watchedSet =
        (progress['watched'] as List?)?.cast<int>().toSet() ?? <int>{};
    final epIndex = (progress['episode'] as int?) ?? -1;
    return LocalStorage.nextContinueIndex(
      episodeCount: _episodes.length,
      watched: watchedSet,
      lastPlayedIndex: epIndex,
    );
  }

  Widget _buildContinueCard(int index) {
    // BUGFIX (retomada): o card mostra o ponto de retomada quando o episódio
    // está parado no meio ("retomar de 14:23"). Continuar dependente da
    // escolha; sem minutagem salva mostra "a seguir".
    final resume = LocalStorage.getResumePosition(widget.anime.name, index);
    final resumeMs = (resume != null && resume.inMilliseconds > 5000)
        ? resume.inMilliseconds
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _ContinueWatchingCard(
        episode: _episodes[index],
        resumeMs: resumeMs,
        onPlay: () => _showEpisodeSourcePicker(index),
      ),
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
    // BUGFIX (75%): a cor verde reflete EXATAMENTE o conjunto 'watched'
    // (gate de 75% do player + reconcileWatched via AniList). Antes o
    // high-water 'episode' (previous last-played, gravado já nos primeiros
    // segundos de playback) era fundido aqui e abrir-e-sair pintava 0..N
    // como assistido — contradizendo o gate de 75% e o progresso AniList.
    final resumePositions = LocalStorage.getResumePositions(widget.anime.name);
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
          key: ValueKey(i),
          index: i,
          episode: _episodes[i],
          anime: widget.anime,
          isWatched: watchedSet.contains(i),
          resumeMs: !watchedSet.contains(i) ? resumePositions[i] : null,
          isFirstRow: i < crossAxisCount,
          // The continue card is the natural focus target when visible, so
          // the first grid card only autofocuses when there's no such card.
          autofocus: i == 0 && _continueIndex() == null,
          onUpFromFirstRow: i < crossAxisCount
              ? () => _favoriteFocus.requestFocus()
              : null,
          onPlay: () => _playEpisode(i),
        ),
      ),
    );
  }
}

class _EpisodeCard extends StatefulWidget {
  final int index;
  final CatalogEpisode episode;
  final Anime anime;
  final bool isWatched;
  final int? resumeMs;
  final bool isFirstRow;
  final bool autofocus;
  final VoidCallback? onUpFromFirstRow;
  final VoidCallback onPlay;

  const _EpisodeCard({
    super.key,
    required this.index,
    required this.episode,
    required this.anime,
    required this.isWatched,
    required this.onPlay,
    this.resumeMs,
    this.isFirstRow = false,
    this.autofocus = false,
    this.onUpFromFirstRow,
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

  // BUGFIX (75%): minutagem salva de retomada do ep (não-assistido). Mostra
  // onde o usuário parou; abrir o ep retoma daqui (player lê getResumePosition).
  Widget _buildResumeBadge() {
    final ms = widget.resumeMs ?? 0;
    final show = !widget.isWatched && ms >= 5000;
    if (!show) return const SizedBox.shrink();
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final time = h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '$m:${s.toString().padLeft(2, '0')}';
    return Positioned(
      left: 4,
      right: 4,
      bottom: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow, color: ThemeConstants.primaryLight, size: 12),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                // "Retomar" colide com o badge EP; só a minutagem resolve melhor
                // em card ~300lp.
                time,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: ThemeConstants.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
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
          _buildResumeBadge(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // B5: foco inicial pousa no primeiro episódio (sempre visível no grid
      // da TV) em vez de em nó fora do viewport/header colapsado.
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _isFocused = focused);
      },
      onKeyEvent: (node, event) {
        // B8: sair do topo do grid com UP pousa no coração (ação mais próxima
        // da expectativa do usuário ao rolar pra cima), não na seta voltar.
        if (widget.isFirstRow &&
            widget.onUpFromFirstRow != null &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          debugPrint(
              '[Detail] B8 intercept UP from first-row card idx=${widget.index}');
          widget.onUpFromFirstRow!();
          return KeyEventResult.handled;
        }
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

/// TV-focusable card shown above the episode grid: "Continue de onde parou"
/// with the next episode. Same focus mechanics as [_EpisodeCard].
class _ContinueWatchingCard extends StatefulWidget {
  final CatalogEpisode episode;
  final int? resumeMs;
  final VoidCallback onPlay;

  const _ContinueWatchingCard({
    required this.episode,
    required this.onPlay,
    this.resumeMs,
  });

  @override
  State<_ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<_ContinueWatchingCard> {
  bool _isFocused = false;

  String _formatResume(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) =>
          FocusKeyHandler.handle(node, event, widget.onPlay),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPlay,
          child: AnimatedContainer(
            duration: SettingsService.instance.animDuration,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  ThemeConstants.primary.withValues(alpha: 0.22),
                  ThemeConstants.surfaceLight.withValues(alpha: 0.9),
                ],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isFocused
                    ? ThemeConstants.primary
                    : ThemeConstants.primary.withValues(alpha: 0.35),
                width: _isFocused ? ThemeConstants.focusBorderWidth : 1,
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
                  Icons.play_circle_fill,
                  color: _isFocused
                      ? ThemeConstants.primary
                      : ThemeConstants.white,
                  size: 36,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Continuar de onde parou',
                        style: TextStyle(
                          color: _isFocused
                              ? ThemeConstants.primary
                              : ThemeConstants.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.resumeMs != null
                            ? 'Episódio ${widget.episode.number} · '
                                'retomar de ${_formatResume(widget.resumeMs!)}'
                            : 'Episódio ${widget.episode.number} a seguir',
                        style: const TextStyle(
                          color: ThemeConstants.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: _isFocused
                      ? ThemeConstants.primary
                      : ThemeConstants.white,
                  size: 30,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Replaces the old _QualityDialog. Instead of resolving ONE provider's
// qualities, it resolves the episode across ALL providers on tap and shows a
// two-level picker in a single dialog: Provider → Quality. The provider with
// the best priority that has the episode is auto-selected (fewer taps on TV).
//
// ponytail: `initialSources` per provider passed straight to the player; the
//     player keeps its own dead-source fallback across the provider's qualities.
class _ProviderQualityDialog extends StatefulWidget {
  final Anime anime;
  final CatalogEpisode episode;
  final int episodeIndex;
  final List<CatalogEpisode> episodeList;

  const _ProviderQualityDialog({
    required this.anime,
    required this.episode,
    required this.episodeIndex,
    required this.episodeList,
  });

  @override
  State<_ProviderQualityDialog> createState() => _ProviderQualityDialogState();
}

class _ProviderQualityDialogState extends State<_ProviderQualityDialog> {
  final AnimeRepository _repo = AnimeRepository();
  bool _loading = true;
  String? _error;
  Map<AnimeSource, List<VideoSource>>? _providers;
  Set<AnimeSource> _matchedUnavailable = {};
  AnimeSource? _selectedProvider;

  /// Latency (ms) per resolved provider. Absent = still measuring; -1 = timeout.
  final Map<AnimeSource, int> _pings = {};

  @override
  void initState() {
    super.initState();
    _resolveProviders();
    // Best-effort backfill: if the anime never got enriched (no airing info),
    // fetch it in background so the "ainda não lançado" state can show the
    // predicted date. Enrichment is session-cached, so repeats are cheap.
    if (widget.anime.nextAiringEpisode == null) {
      AniListService.enrich(widget.anime).then((_) {
        if (mounted && widget.anime.nextAiringEpisode != null) {
          setState(() {});
        }
      });
    }
  }

  Future<void> _resolveProviders() async {
    debugPrint(
        '[ProviderDialog] resolve ep ${widget.episode.number} anime=${widget.anime.name}');
    try {
      // partial: o picker abre assim que a melhor fonte resolve, sem esperar a
      // mais lenta — as demais fontes chegam via onUpdate progressivamente.
      await _repo.resolveProvidersForEpisode(
        widget.anime,
        widget.episode.number,
        partial: true,
        onUpdate: _applyResolution,
      );
    } catch (e) {
      if (!mounted) return;
      debugPrint('[ProviderDialog] resolve error: $e');
      setState(() {
        _error = 'Fonte indisponível. Tente novamente.';
        _loading = false;
      });
    }
  }

  /// Incremental application of a (possibly partial) resolution, fired by the
  /// repo as each provider lands. Keeps loading while nothing resolved yet and
  /// providers are still on their way; renders the picker as soon as there's at
  /// least one. The auto-selection re-evaluates so a higher-priority provider
  /// arriving later claims the best slot.
  void _applyResolution(EpisodeResolution resolution) {
    if (!mounted) return;
    final nextBest =
        resolution.providers.isEmpty ? null : resolution.providers.keys.first;
    debugPrint('[ProviderDialog] partial ${resolution.providers.length} '
        'providers best=$nextBest complete=${resolution.complete} '
        'matchedUnavailable=${resolution.matchedUnavailable}');
    setState(() {
      _error = null;
      _matchedUnavailable = resolution.matchedUnavailable;
      if (resolution.providers.isNotEmpty) {
        _providers = resolution.providers;
        _selectedProvider = nextBest;
        _loading = false;
      } else if (resolution.complete) {
        _loading = false;
      }
    });
    if (resolution.providers.isNotEmpty) {
      _probeLatency(resolution.providers.keys);
    }
  }

  String _sourceName(AnimeSource s) => s.name;

  /// Probes latency for the resolved providers in parallel. Updates [_pings]
  /// as each measurement lands so the label appears without blocking the picker.
  void _probeLatency(Iterable<AnimeSource> sources) {
    for (final source in sources) {
      SourcePingService.instance.ping(source).then((ms) {
        if (!mounted) return;
        setState(() => _pings[source] = ms ?? -1);
      });
    }
  }

  /// Label for the provider row: `"42 ms"` when measured, `"--"` on timeout,
  /// `null` (nothing rendered) while still measuring.
  String? _pingLabel(AnimeSource source) {
    final ms = _pings[source];
    if (ms == null) return null;
    return ms < 0 ? SourcePingService.unknownPing : '$ms ms';
  }

  void _navigateToPlayer(AnimeSource provider, int qualityIndex) {
    final sources = _providers?[provider] ?? const <VideoSource>[];
    if (sources.isEmpty) return;
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          anime: widget.anime,
          provider: provider,
          episodeIndex: widget.episodeIndex,
          episodeList: widget.episodeList,
          initialSources: sources,
          initialIndex: qualityIndex,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.all(32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 520,
          // B9: muitos providers × qualidades estouravam a altura do dialog
          // na TV (960x540 log.) e cortavam os itens na borda inferior.
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        padding: const EdgeInsets.all(28),
        child: SingleChildScrollView(
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
                        'Reproduzir EP',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Episódio ${widget.episode.number}',
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
                        'Procurando fontes de vídeo...',
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
                    const Icon(Icons.error_outline,
                        color: Colors.red, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Não foi possível carregar o vídeo',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'As fontes podem estar temporariamente indisponíveis. '
                      'Tente novamente.',
                      style: TextStyle(
                        color: ThemeConstants.textSecondary,
                        fontSize: 14,
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
                            setState(() {
                              _error = null;
                              _loading = true;
                              _providers = null;
                              _selectedProvider = null;
                            });
                            _resolveProviders();
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
            else if (_providers == null || _providers!.isEmpty)
              _buildEmptyProviders()
            else
              _buildProviderSelector(),
          ],
          ),
        ),
      ),
    );
  }

  /// No provider delivered a stream. Three honest states:
  ///  - the tapped episode hasn't aired yet (currently airing anime + AniList
  ///    airing info) → "ainda não lançado" with the predicted date;
  ///  - at least one page matched but its extractor failed (e.g. Blogger SPA)
  ///    → the episode exists, the video just isn't supported;
  ///  - no page matched at all → generic not found.
  Widget _buildEmptyProviders() {
    final notAired = notAiredMessage(
      tappedEpisode: widget.episode.number,
      anime: widget.anime,
    );
    final unavailable = _matchedUnavailable.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Icon(
            notAired != null
                ? Icons.schedule
                : Icons.videocam_off,
            color: notAired != null
                ? const Color(0xFF4FC3F7)
                : Colors.orange,
            size: 48,
          ),
          const SizedBox(height: 12),
          Text(
            notAired != null
                ? 'Episódio ainda não lançado'
                : unavailable
                    ? 'Episódio sem vídeo disponível'
                    : 'Nenhuma fonte disponível',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            notAired ??
                (unavailable
                    ? 'O Ep ${widget.episode.number} existe na fonte, mas o '
                        'vídeo não é suportado por ela neste momento (player '
                        'de vídeo sem stream recuperável). Pode ser que outra '
                        'fonte sirva o episódio.'
                    : 'Nenhuma fonte resolveu um stream para o Ep '
                        '${widget.episode.number} deste anime agora. '
                        'Possíveis motivos: Cloudflare, fonte fora do ar ou o '
                        'episódio ainda não foi indexado.'),
            style: const TextStyle(
              color: ThemeConstants.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          if (notAired != null) ...[
            const SizedBox(height: 4),
            const Text(
              'Assista aos episódios anteriores enquanto isso!',
              style: TextStyle(
                color: ThemeConstants.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DialogButton(
                label: 'Tentar novamente',
                primary: true,
                onTap: () {
                  setState(() {
                    _loading = true;
                    _providers = null;
                    _matchedUnavailable = {};
                  });
                  _resolveProviders();
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
    );
  }

  /// Level 1 of the picker: the available providers. When a provider is
  /// selected (default = best priority), show its qualities directly.
  Widget _buildProviderSelector() {
    final providers = _providers!;
    final selected = _selectedProvider;

    final providerList = providers.entries.map((e) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: _ProviderItem(
          label: _sourceName(e.key),
          ping: _pingLabel(e.key),
          isSelected: selected == e.key,
          onTap: () {
            setState(() => _selectedProvider = e.key);
          },
        ),
      );
    }).toList();

    final qualityList = selected == null
        ? const <Widget>[]
        : <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: _QualityItem(
                quality: 'Melhor qualidade',
                // Fase 3: atalho que abre direto na melhor — evita o 2º tap
                // quando o usuário só quer assistir.
                onTap: () => _navigateToPlayer(
                  selected,
                  bestQualityIndex(providers[selected]!),
                ),
              ),
            ),
            ...providers[selected]!.asMap().entries.map((q) {
              final idx = q.key;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: _QualityItem(
                  quality: q.value.quality,
                  onTap: () => _navigateToPlayer(selected, idx),
                ),
              );
            }),
          ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Fonte',
          style: TextStyle(
            color: ThemeConstants.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (selected == null)
          ...providerList
        else ...[
          ...providerList,
          const Divider(color: ThemeConstants.surfaceLight),
          const Text(
            'Qualidade',
            style: TextStyle(
              color: ThemeConstants.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          ...qualityList,
        ],
      ],
    );
  }
}

// ponytail: itens do dialog eram InkWell sem Focus → D-pad andava
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

// ponytail: linha de provider focável no dialog — mesma mecânica de
// _QualityItem, com check de seleção no lado direito.
class _ProviderItem extends StatefulWidget {
  final String label;
  final String? ping;
  final bool isSelected;
  final VoidCallback onTap;

  const _ProviderItem({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.ping,
  });

  @override
  State<_ProviderItem> createState() => _ProviderItemState();
}

class _ProviderItemState extends State<_ProviderItem> {
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
                  width: _isFocused ? ThemeConstants.focusBorderWidth : 1,
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
                    Icons.source,
                    color: _isFocused
                        ? ThemeConstants.primary
                        : ThemeConstants.white,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      widget.label,
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
                  if (widget.ping != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        widget.ping!,
                        style: TextStyle(
                          color: _isFocused
                              ? ThemeConstants.primary
                              : ThemeConstants.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (widget.isSelected)
                    const Icon(
                      Icons.check_circle,
                      color: ThemeConstants.primary,
                      size: 22,
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
  final bool autofocus;
  final VoidCallback onTap;

  const _DialogButton({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.autofocus = false,
  });

  @override
  State<_DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<_DialogButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
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
  final FocusNode? focusNode;

  const _FavoriteButton({
    required this.isFavorite,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<_FavoriteButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) {
        debugPrint('[Detail] FAVORITE focused=$f');
        setState(() => _isFocused = f);
      },
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
      onFocusChange: (f) {
        debugPrint('[Detail] BACK focused=$f');
        setState(() => _isFocused = f);
      },
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
