import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../data/models/anime.dart';
import '../../data/models/anilist_models.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/storage/local_storage.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/focusable_card.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/cached_image.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../search/search_screen.dart';
import 'anilist_banner.dart';
import 'home_navigation.dart';
import 'anilist_login_dialog.dart';
import 'favorites_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AnimeRepository _repo = AnimeRepository();
  List<Anime> _trending = [];
  List<Anime> _recent = [];
  bool _isLoading = true;
  bool _anilistLoggedIn = false;
  AniListUser? _anilistUser;
  List<AniListGroup> _anilistLists = [];

  static const _defaultQueries = [
    'one piece',
    'attack on titan',
    'jujutsu kaisen',
    'demon slayer',
    'naruto',
    'dragon ball',
    'death note',
    'fullmetal',
    'sword art online',
    'my hero academia',
  ];

  @override
  void initState() {
    super.initState();
    // pintar cache do AniList instantaneamente (lista vinda da última sessão)
    _anilistLists = AniListService.getCachedAnimeLists();
    _loadDataWithTimeout();
  }

  Future<void> _loadDataWithTimeout() async {
    setState(() => _isLoading = true);
    // ponytail: _checkAnilist() fora do timeout de 12s. Validação de token +
    // fetch de listas pode levar mais que catálogo; home pinta o catálogo
    // primeiro e atualiza listas/user incrementalmente via setState.
    _checkAnilist();
    try {
      await _loadAnimeLists().timeout(const Duration(seconds: 12));
    } catch (_) {
      // Timeout or error – show whatever we have
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _checkAnilist() async {
    final loggedIn = await AniListService.isLoggedIn();
    if (!mounted) return;
    if (!loggedIn) return;
    // cache local pinta instantâneo caso exista; senão refreshUser busca na rede.
    AniListUser? user = await AniListService.getUser();
    if (user == null) {
      user = await AniListService.refreshUser();
      if (!mounted) return;
      if (user == null) {
        // Token inválido/expirado — refreshUser já fez logout. Limpa UI.
        setState(() {
          _anilistLoggedIn = false;
          _anilistUser = null;
          _anilistLists = [];
        });
        return;
      }
    }
    final cached = AniListService.getCachedAnimeLists();
    setState(() {
      _anilistLoggedIn = true;
      _anilistUser = user;
      _anilistLists = cached;
    });
    final lists = await AniListService.getUserAnimeList();
    if (!mounted) return;
    setState(() => _anilistLists = lists);
  }

  Future<void> _loadAnimeLists() async {
    try {
      final results = await Future.wait([
        AniListService.getTrending(),
        AniListService.getPopularThisSeason(),
      ]);
      var trending = results[0];
      var season = results[1];
      if (trending.isNotEmpty || season.isNotEmpty) {
        final names = trending.map((a) => a.name.toLowerCase()).toSet();
        season = season.where((a) => !names.contains(a.name.toLowerCase())).toList();
        setState(() { _trending = trending; _recent = season; });
        return;
      }
    } catch (e) {
      debugPrint('[Home] AniList catalog error: $e');
    }
    await _loadAnimeListsFromScrapers();
  }

  Future<void> _loadAnimeListsFromScrapers() async {
    try {
      final results = await Future.wait(_defaultQueries.map((q) => _repo.searchAnime(q)));
      final all = results.fold<List<Anime>>([], (a, b) => a..addAll(b));
      final seen = <String>{};
      final unique = all.where((a) => seen.add(a.url.isNotEmpty ? a.url : a.name.toLowerCase())).toList();
      final mid = unique.length ~/ 2;
      setState(() { _trending = unique.take(mid).toList(); _recent = unique.skip(mid).toList(); });
    } catch (e) {
      debugPrint('[Home] Load error: $e');
    }
  }

  void _showAnilistLogin() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const AnilistLoginDialog(),
    );
    if (!mounted) return;
    if (result == true) {
      await _checkAnilist();
      if (!mounted) return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: ThemeConstants.primary,
                    ),
                  )
                : _buildContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final top = MediaQuery.of(context).padding.top + 16;
    return Container(
      padding: EdgeInsets.only(left: 32, right: 32, top: top, bottom: 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ThemeConstants.surface, ThemeConstants.background],
          stops: [0, 1],
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ThemeConstants.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.play_circle_filled,
                color: ThemeConstants.primary, size: 32),
          ),
          const SizedBox(width: 12),
          const Text(
            'GoAnime TV',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: ThemeConstants.white,
            ),
          ),
          const Spacer(),
          _navItem(
            Icons.search,
            'Buscar',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SearchScreen()),
            ),
          ),
          const SizedBox(width: 24),
          // ponytail: botão único de perfil — fundiu avatar AniList + nav Perfil.
          // Dropdown cobre conectar/desconectar, atualizar, favoritos. Tudo num só.
          _ProfileButton(
            loggedIn: _anilistLoggedIn,
            user: _anilistUser,
            onTap: _showProfileMenu,
          ),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, String label, VoidCallback onTap) {
    return _FocusableNavItem(icon: icon, label: label, onTap: onTap);
  }

  void _showProfileMenu() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeConstants.surface,
        title: Row(
          children: [
            if (_anilistUser?.avatar != null)
              CircleAvatar(
                radius: 22,
                backgroundImage:
                    CachedNetworkImageProvider(_anilistUser!.avatar!),
              )
            else
              const CircleAvatar(
                radius: 22,
                child: Icon(Icons.person, color: Colors.white),
              ),
            const SizedBox(width: 12),
            Text(
              _anilistUser?.name ?? 'Visitante',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_anilistLoggedIn)
              _menuEntry(
                icon: Icons.login,
                label: 'Logar',
                onTap: () {
                  Navigator.pop(ctx);
                  _showAnilistLogin();
                },
              )
            else ...[
              _menuEntry(
                icon: Icons.refresh,
                label: 'Atualizar listas',
                onTap: () {
                  Navigator.pop(ctx);
                  _loadDataWithTimeout();
                },
              ),
              _menuEntry(
                icon: Icons.favorite,
                label: 'Favoritos',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const FavoritesScreen()),
                  );
                },
              ),
              _menuEntry(
                icon: Icons.logout,
                label: 'Deslogar',
                color: Colors.red,
                onTap: () async {
                  Navigator.pop(ctx);
                  await AniListService.logout();
                  if (!mounted) return;
                  setState(() {
                    _anilistLoggedIn = false;
                    _anilistUser = null;
                    _anilistLists = [];
                  });
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _menuEntry({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return Semantics(
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 12),
                Text(label,
                    style: TextStyle(color: color, fontSize: 18)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final history = LocalStorage.getHistory();
    final favorites = LocalStorage.getFavorites();
    final screenWidth = MediaQuery.of(context).size.width;
    final isTv = screenWidth > 600;
    final cardWidth = isTv ? ThemeConstants.cardWidthTv : ThemeConstants.cardWidthMobile;
    final cardHeight = cardWidth * 1.38;
    final bannerWidth = isTv ? ThemeConstants.bannerWidthTv : 260.0;
    final bannerHeight = bannerWidth * 0.55;

    final watching = _anilistLists
        .expand((g) => g.entries
            .where((e) => e.status == 'CURRENT' || e.status == 'REPEATING'))
        .toList();

    final otherGroups = _anilistLists
        .where((g) => g.entries.isNotEmpty &&
            g.entries.every((e) =>
                e.status != 'CURRENT' && e.status != 'REPEATING'))
        .toList();

    List<Widget> section(
        String title, List<dynamic> items, double h, Widget Function(dynamic) cardBuilder,
        {String? subtitle, double buffer = 48}) {
      if (items.isEmpty) return const [];
      return [
        SectionHeader(title: title, subtitle: subtitle),
        SizedBox(
          // ponytail: buffer vertical p/ AnimatedScale + boxShadow não
          // cliparem no focus. Cards: 48 (blur 15), banners: 80 (blur 20 +
          // spread 2 + scale 1.05 sobre h≈198 ≈ 27px/lado exigem 54+).
          height: h + buffer,
          child: ListView.builder(
            clipBehavior: Clip.none,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(32, buffer / 2, 32, buffer / 2),
            itemCount: items.length > 20 ? 20 : items.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(right: 18),
              child: cardBuilder(items[i]),
            ),
          ),
        ),
      ];
    }

    return ListView(
      clipBehavior: Clip.none,
      children: [
        if (!_anilistLoggedIn)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            child: AnilistBanner(onTap: _showAnilistLogin),
          ),
        if (_anilistLoggedIn && _anilistUser != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
            child: Row(
              children: [
                if (_anilistUser!.avatar != null)
                  CircleAvatar(
                    radius: 28,
                    backgroundImage:
                        CachedNetworkImageProvider(_anilistUser!.avatar!),
                  )
                else
                  const CircleAvatar(
                    radius: 28,
                    child: Icon(Icons.person, color: Colors.white),
                  ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Olá, ${_anilistUser!.name}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_anilistLists.fold(0, (sum, l) => sum + l.entries.length)} animes em suas listas',
                      style: const TextStyle(
                        color: ThemeConstants.textSecondary,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        // Continue assistindo — AniList quando logado; histórico local offline.
        if (_anilistLoggedIn && watching.isNotEmpty)
          ..._buildWatchingSection(watching, screenWidth)
        else if (!_anilistLoggedIn && history.isNotEmpty)
          ...section('Continue assistindo', history.take(10).toList(), cardHeight,
              (item) {
            final m = item as Map<String, dynamic>;
            return FocusableCard(
              imageUrl: m['image']?.toString() ?? '',
              title: m['title']?.toString() ?? '',
              width: cardWidth,
              height: cardHeight,
              onTap: () => openFromMap(context, m),
            );
          }, subtitle: '${history.length} no histórico'),
        if (_trending.isNotEmpty)
          ...section('Em Alta', _trending.take(10).toList(), bannerHeight,
              (item) => FocusableBannerCard(
                    imageUrl: (item as Anime).imageUrl,
                    title: item.name,
                    width: bannerWidth,
                    height: bannerHeight,
                    onTap: () => openDetail(context, item),
                  ),
              buffer: 80),
        if (_recent.isNotEmpty)
          ...section('Populares da Temporada', _recent.take(20).toList(), cardHeight,
              (item) => FocusableCard(
                    imageUrl: (item as Anime).imageUrl,
                    title: item.name,
                    width: cardWidth,
                    height: cardHeight,
                    onTap: () => openDetail(context, item),
                  )),
        if (_anilistLoggedIn)
          for (final g in otherGroups)
            if (g.entries.isNotEmpty) _buildAnilistGroup(g, screenWidth),
        if (favorites.isNotEmpty)
          ...section('Favoritos', favorites.take(10).toList(), cardHeight,
              (item) {
            final m = item as Map<String, dynamic>;
            return FocusableCard(
              imageUrl: m['image']?.toString() ?? '',
              title: m['title']?.toString() ?? '',
              width: cardWidth,
              height: cardHeight,
              onTap: () => openFromMap(context, m),
            );
          }),
        const SizedBox(height: 48),
      ],
    );
  }

  // ponytail: seção dedicada "Continue assistindo" — banner largo com pôster,
  // título, progresso "Ep X/Y" e countdown do próximo ep. Mais legível no
  // projetor que o card vertical genérico. Fonte: lista AniList do usuário.
  List<Widget> _buildWatchingSection(List<AniListEntry> entries, double screenWidth) {
    if (entries.isEmpty) return const [];
    final bannerWidth = screenWidth > 600 ? ThemeConstants.bannerWidthTv : 260.0;
    final bannerHeight = bannerWidth * 0.62;

    return [
      SectionHeader(
        title: 'Continue assistindo',
        subtitle: '${entries.length} na fila',
      ),
      SizedBox(
        height: bannerHeight + 80,
        child: ListView.builder(
          clipBehavior: Clip.none,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 40),
          itemCount: entries.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(right: 24),
            child: _WatchingBanner(
              entry: entries[i],
              width: bannerWidth,
              height: bannerHeight,
              onTap: () => openAnilistDetail(context, entries[i].media),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _buildAnilistGroup(AniListGroup group, double screenWidth) {
    if (group.entries.isEmpty) return const SizedBox.shrink();
    final w = screenWidth > 600 ? ThemeConstants.cardWidthTv : 120.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'AniList: ${group.name}', subtitle: '${group.entries.length} animes'),
        SizedBox(
          height: w * 1.4 + 48,
          child: ListView.builder(
            clipBehavior: Clip.none,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            itemCount: group.entries.length > 20 ? 20 : group.entries.length,
            itemBuilder: (_, i) {
              final entry = group.entries[i];
              return Padding(
                padding: const EdgeInsets.only(right: 18),
                child: FocusableCard(
                  imageUrl: entry.media.coverImage,
                  title: entry.media.title,
                  width: w,
                  height: w * 1.4,
                  onTap: () => openAnilistDetail(context, entry.media),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ponytail: nav item sem Focus invisível (igual ao QualityDialog bug). Herda o
// padrão AnimatedContainer do FocusableCard para battlefield consistency.
class _FocusableNavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _FocusableNavItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_FocusableNavItem> createState() => _FocusableNavItemState();
}

class _FocusableNavItemState extends State<_FocusableNavItem> {
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
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : Colors.transparent,
                  width: ThemeConstants.focusBorderWidth,
                ),
                boxShadow: _isFocused
                    ? [
                        BoxShadow(
                          color:
                              ThemeConstants.primary.withValues(alpha: 0.4),
                          blurRadius: ThemeConstants.focusGlowBlur,
                        ),
                      ]
                    : [],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    color: _isFocused
                        ? ThemeConstants.primary
                        : ThemeConstants.white,
                    size: 30,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: _isFocused
                          ? ThemeConstants.primary
                          : ThemeConstants.white,
                      fontSize: 16,
                      fontWeight:
                          _isFocused ? FontWeight.bold : FontWeight.normal,
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

class _ProfileButton extends StatefulWidget {
  final bool loggedIn;
  final AniListUser? user;
  final VoidCallback onTap;

  const _ProfileButton({
    required this.loggedIn,
    required this.user,
    required this.onTap,
  });

  @override
  State<_ProfileButton> createState() => _ProfileButtonState();
}

class _ProfileButtonState extends State<_ProfileButton> {
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
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : Colors.transparent,
                  width: ThemeConstants.focusBorderWidth,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundImage: widget.loggedIn &&
                            widget.user?.avatar != null
                        ? CachedNetworkImageProvider(widget.user!.avatar!)
                        : null,
                    child: !(widget.loggedIn &&
                            widget.user?.avatar != null)
                        ? const Icon(Icons.person,
                            size: 20, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.loggedIn ? (widget.user?.name ?? '') : 'Perfil',
                    style: TextStyle(
                      color: _isFocused
                          ? ThemeConstants.primary
                          : ThemeConstants.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
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

// ponytail: banner focável para "Assistindo agora". Mistura pôster lateral +
// progresso + countdown do próximo ep. Adiciona-se aqui em vez de virar
// widget compartilhado porque é caso único (Watching).
class _WatchingBanner extends StatefulWidget {
  final AniListEntry entry;
  final double width;
  final double height;
  final VoidCallback onTap;

  const _WatchingBanner({
    required this.entry,
    required this.width,
    required this.height,
    required this.onTap,
  });

  @override
  State<_WatchingBanner> createState() => _WatchingBannerState();
}

class _WatchingBannerState extends State<_WatchingBanner> {
  bool _isFocused = false;

  String _progressLabel() {
    final p = widget.entry.progress ?? 0;
    final total = widget.entry.media.episodes;
    if (total != null && total > 0) {
      return 'Ep $p de $total';
    }
    return 'Ep $p';
  }

  String _nextEpLabel() {
    final next = widget.entry.nextEpisode;
    final sec = widget.entry.timeUntilAiring;
    if (next == null || sec == null) return '';
    final days = (sec / 86400).floor();
    final hours = ((sec % 86400) / 3600).floor();
    if (days > 0) return 'Próx. ep $next em $days d';
    if (hours > 0) return 'Próx. ep $next em ${hours}h';
    return 'Próx. ep $next em breve';
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.entry.media;
    final banner = media.bannerImage ?? media.coverImageExtra ?? media.coverImage;
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _isFocused ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isFocused
                        ? ThemeConstants.primary
                        : ThemeConstants.surfaceLight,
                    width: _isFocused
                        ? ThemeConstants.focusBorderWidth
                        : 1,
                  ),
                  boxShadow: _isFocused
                      ? [
                          BoxShadow(
                            color:
                                ThemeConstants.primary.withValues(alpha: 0.5),
                            blurRadius: ThemeConstants.focusGlowBlur,
                            spreadRadius: 1,
                          ),
                        ]
                      : [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (banner != null && banner.isNotEmpty)
                        CachedImage(
                          url: banner,
                          width: widget.width,
                          height: widget.height,
                          fit: BoxFit.cover,
                          fallback: _buildPosterFallback(),
                        )
                      else
                        _buildPosterFallback(),
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Color(0xCC0A0A0F),
                              Color(0x660A0A0F),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              media.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: ThemeConstants.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _progressLabel(),
                              style: const TextStyle(
                                color: ThemeConstants.primary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_nextEpLabel().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                _nextEpLabel(),
                                style: const TextStyle(
                                  color: ThemeConstants.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPosterFallback() {
    return Container(
      color: ThemeConstants.surfaceLight,
      child: const Center(
        child: Icon(Icons.movie, color: ThemeConstants.textMuted, size: 48),
      ),
    );
  }
}