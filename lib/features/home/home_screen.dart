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
import '../../shared/widgets/play_icon.dart';
import '../search/search_screen.dart';
import 'anilist_banner.dart';
import 'home_navigation.dart';
import 'anilist_login_dialog.dart';
import 'profile_screen.dart';

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
    _loadDataWithTimeout();
  }

  Future<void> _loadDataWithTimeout() async {
    setState(() => _isLoading = true);
    try {
      await Future.wait([
        _loadAnimeLists(),
        _checkAnilist(),
      ]).timeout(const Duration(seconds: 12));
    } catch (_) {
      // Timeout or error – show whatever we have
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _checkAnilist() async {
    final loggedIn = await AniListService.isLoggedIn();
    if (!mounted) return;
    if (!loggedIn) return;
    final user = await AniListService.getUser();
    if (!mounted) return;
    final lists = await AniListService.getUserAnimeList();
    if (!mounted) return;
    setState(() {
      _anilistLoggedIn = true;
      _anilistUser = user;
      _anilistLists = lists;
    });
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
      body: Stack(
        children: [
          Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildContent(),
              ),
            ],
          ),
          _buildPlayButton(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    final top = MediaQuery.of(context).padding.top + 12;
    return Container(
      padding: EdgeInsets.only(left: 16, right: 16, top: top, bottom: 12),
      child: Row(children: [
        const Icon(Icons.play_circle_filled, color: ThemeConstants.primary, size: 32),
        const SizedBox(width: 8),
        const Text('GoAnime TV', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: ThemeConstants.white)),
        const Spacer(),
        _navItem(Icons.search, 'Buscar', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()))),
        const SizedBox(width: 24),
        _navItem(Icons.person, 'Perfil', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()))),
        if (!_anilistLoggedIn) ...[
          const SizedBox(width: 24),
          _navItem(Icons.login, 'AniList', _showAnilistLogin),
        ] else ...[
          const SizedBox(width: 24),
          Semantics(button: true,
            child: Material(color: Colors.transparent,
              child: InkWell(onTap: () => _showAnilistMenu(),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  CircleAvatar(radius: 16,
                    backgroundImage: _anilistUser?.avatar != null ? CachedNetworkImageProvider(_anilistUser!.avatar!) : null,
                    child: _anilistUser?.avatar == null ? const Icon(Icons.person, size: 18, color: Colors.white) : null,
                  ),
                  const SizedBox(width: 8),
                  Text(_anilistUser?.name ?? '', style: const TextStyle(color: Colors.white, fontSize: 14)),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  void _showAnilistMenu() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: ThemeConstants.surface,
      title: Text(_anilistUser?.name ?? 'AniList', style: const TextStyle(color: Colors.white)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Semantics(button: true, child: Material(color: Colors.transparent, child: InkWell(
          onTap: () { Navigator.pop(ctx); _loadDataWithTimeout(); },
          child: const Padding(padding: EdgeInsets.all(12), child: Row(children: [
            Icon(Icons.refresh, color: Colors.white), SizedBox(width: 12),
            Text('Atualizar listas', style: TextStyle(color: Colors.white, fontSize: 18)),
          ])),
        ))),
        Semantics(button: true, child: Material(color: Colors.transparent, child: InkWell(
          onTap: () async { Navigator.pop(ctx); await AniListService.logout(); if (!mounted) return; setState(() { _anilistLoggedIn = false; _anilistUser = null; _anilistLists = []; }); },
          child: const Padding(padding: EdgeInsets.all(12), child: Row(children: [
            Icon(Icons.logout, color: Colors.red), SizedBox(width: 12),
            Text('Desconectar', style: TextStyle(color: Colors.red, fontSize: 18)),
          ])),
        ))),
      ]),
    ));
  }

  Widget _navItem(IconData icon, String label, VoidCallback onTap) {
    return Semantics(
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 28),
              const SizedBox(height: 4),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayButton() {
    return Positioned(
      bottom: 100,
      right: 24,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            _searchAnime('one piece');
          },
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: ThemeConstants.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: ThemeConstants.primary.withValues(alpha: 0.5),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: const PlayIcon(size: 36),
          ),
        ),
      ),
    );
  }

  void _searchAnime(String query) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen()),
    );
  }

  Widget _buildContent() {
    final history = LocalStorage.getHistory();
    final favorites = LocalStorage.getFavorites();
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth > 600 ? 150.0 : 130.0;
    final cardHeight = cardWidth * 1.38;
    final bannerWidth = screenWidth > 600 ? 320.0 : 260.0;
    final bannerHeight = bannerWidth * 0.55;

    List<Widget> section(String title, List<dynamic> items, double h, Widget Function(dynamic) cardBuilder) {
      if (items.isEmpty) return const [];
      return [
        SectionHeader(title: title),
        SizedBox(height: h + 20, child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: items.length > 20 ? 20 : items.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(right: 10),
            child: cardBuilder(items[i]),
          ),
        )),
      ];
    }

    return ListView(children: [
      if (!_anilistLoggedIn)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: AnilistBanner(onTap: _showAnilistLogin),
        ),
      if (_anilistLoggedIn && _anilistUser != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(children: [
            if (_anilistUser!.avatar != null)
              CircleAvatar(radius: 24, backgroundImage: CachedNetworkImageProvider(_anilistUser!.avatar!))
            else
              const CircleAvatar(radius: 24, child: Icon(Icons.person, color: Colors.white)),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_anilistUser!.name, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              Text('${_anilistLists.fold(0, (sum, l) => sum + l.entries.length)} animes nas listas',
                  style: const TextStyle(color: ThemeConstants.textSecondary, fontSize: 14)),
            ]),
          ]),
        ),
      if (_anilistLoggedIn)
        ..._anilistLists.map((g) => _buildAnilistGroup(g, screenWidth)),
      if (_trending.isNotEmpty)
        ...section('Em Alta', _trending.take(10).toList(), bannerHeight,
          (item) => FocusableBannerCard(
            imageUrl: (item as Anime).imageUrl, title: item.name,
            width: bannerWidth, height: bannerHeight,
            onTap: () => openDetail(context, item),
          )),
      if (_recent.isNotEmpty)
        ...section('Populares da Temporada', _recent.take(20).toList(), cardHeight,
          (item) => FocusableCard(
            imageUrl: (item as Anime).imageUrl, title: item.name,
            width: cardWidth, height: cardHeight,
            onTap: () => openDetail(context, item),
          )),
      if (history.isNotEmpty)
        ...section('Continuar Assistindo', history.take(10).toList(), cardHeight,
          (item) {
            final m = item as Map<String, dynamic>;
            return FocusableCard(
              imageUrl: m['image']?.toString() ?? '', title: m['title']?.toString() ?? '',
              width: cardWidth, height: cardHeight,
              onTap: () => openFromHistory(context, m),
            );
          }),
      if (favorites.isNotEmpty)
        ...section('Favoritos', favorites.take(10).toList(), cardHeight,
          (item) {
            final m = item as Map<String, dynamic>;
            return FocusableCard(
              imageUrl: m['image']?.toString() ?? '', title: m['title']?.toString() ?? '',
              width: cardWidth, height: cardHeight,
              onTap: () => openFromFav(context, m),
            );
          }),
      const SizedBox(height: 32),
    ]);
  }

  Widget _buildAnilistGroup(AniListGroup group, double screenWidth) {
    if (group.entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'AniList: ${group.name}'),
        SizedBox(
          height: 180,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            itemCount: group.entries.length > 20 ? 20 : group.entries.length,
            itemBuilder: (_, i) {
              final entry = group.entries[i];
              final w = screenWidth > 600 ? 140.0 : 120.0;
              return Padding(
                padding: const EdgeInsets.only(right: 10),
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
