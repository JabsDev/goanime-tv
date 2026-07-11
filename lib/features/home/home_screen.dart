import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../data/models/anime.dart';
import '../../data/models/anilist_models.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/storage/local_storage.dart';
import '../../core/anilist/anilist_service.dart';
import '../../core/anilist/anilist_pairing_server.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/focusable_card.dart';
import '../../shared/widgets/cached_image.dart';
import '../../shared/widgets/section_header.dart';
import '../../shared/widgets/play_icon.dart';
import '../search/search_screen.dart';
import '../detail/detail_screen.dart';

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
    if (!loggedIn) return;
    final user = await AniListService.getUser();
    final lists = await AniListService.getUserAnimeList();
    if (!mounted) return;
    setState(() {
      _anilistLoggedIn = true;
      _anilistUser = user;
      _anilistLists = lists;
    });
  }

  Future<void> _loadAnimeLists() async {
    // Primary: AniList curated catalog (trending + popular this season). Opening
    // a title resolves episodes by name across the PT-BR providers.
    try {
      final results = await Future.wait([
        AniListService.getTrending(),
        AniListService.getPopularThisSeason(),
      ]);
      final trending = results[0];
      var season = results[1];
      if (trending.isNotEmpty || season.isNotEmpty) {
        // Avoid showing the same title in both rows.
        final trendingNames =
            trending.map((a) => a.name.toLowerCase()).toSet();
        season = season
            .where((a) => !trendingNames.contains(a.name.toLowerCase()))
            .toList();
        setState(() {
          _trending = trending;
          _recent = season;
        });
        return;
      }
    } catch (e) {
      debugPrint('[Home] AniList catalog error: $e');
    }
    // Fallback: legacy scraping of default queries.
    await _loadAnimeListsFromScrapers();
  }

  Future<void> _loadAnimeListsFromScrapers() async {
    List<Anime> all = [];
    try {
      final futures = _defaultQueries.map((q) => _repo.searchAnime(q));
      final results = await Future.wait(futures);
      for (final r in results) {
        all.addAll(r);
      }
      final seen = <String>{};
      final unique = <Anime>[];
      for (final a in all) {
        final key = a.url.isNotEmpty ? a.url : a.name.toLowerCase();
        if (seen.add(key)) unique.add(a);
      }
      final mid = unique.length ~/ 2;
      setState(() {
        _trending = unique.take(mid).toList();
        _recent = unique.skip(mid).toList();
      });
    } catch (e) {
      debugPrint('[Home] Load error: $e');
    }
  }

  void _showAnilistLogin() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const _AnilistLoginDialog(),
    );
    if (result == true) {
      await _checkAnilist();
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
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: MediaQuery.of(context).padding.top + 12,
        bottom: 12,
      ),
      child: Row(
        children: [
          const Icon(Icons.play_circle_filled,
              color: ThemeConstants.primary, size: 32),
          const SizedBox(width: 8),
          const Text(
            'GoAnime TV',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: ThemeConstants.white,
            ),
          ),
          const Spacer(),
          _navItem(Icons.search, 'Buscar', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SearchScreen()),
            );
          }),
          const SizedBox(width: 24),
          _navItem(Icons.person, 'Perfil', () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            );
          }),
          if (!_anilistLoggedIn) ...[
            const SizedBox(width: 24),
            _navItem(Icons.login, 'AniList', _showAnilistLogin),
          ] else ...[
            const SizedBox(width: 24),
            Semantics(
              button: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _showAnilistMenu(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundImage: _anilistUser?.avatar != null
                            ? CachedNetworkImageProvider(_anilistUser!.avatar!)
                            : null,
                        child: _anilistUser?.avatar == null
                            ? const Icon(Icons.person, size: 18, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _anilistUser?.name ?? '',
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showAnilistMenu() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ThemeConstants.surface,
        title: Text(
          _anilistUser?.name ?? 'AniList',
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    Navigator.pop(ctx);
                    _loadDataWithTimeout();
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.refresh, color: Colors.white),
                        SizedBox(width: 12),
                        Text('Atualizar listas',
                            style: TextStyle(color: Colors.white, fontSize: 18)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              button: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
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
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.logout, color: Colors.red),
                        SizedBox(width: 12),
                        Text('Desconectar',
                            style: TextStyle(color: Colors.red, fontSize: 18)),
                      ],
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

    return ListView(
      children: [
        if (!_anilistLoggedIn)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: _FocusableAnilistBanner(onTap: _showAnilistLogin),
          ),
        if (_anilistLoggedIn && _anilistUser != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Row(
              children: [
                if (_anilistUser!.avatar != null)
                  CircleAvatar(
                    radius: 24,
                    backgroundImage:
                        CachedNetworkImageProvider(_anilistUser!.avatar!),
                  )
                else
                  const CircleAvatar(
                    radius: 24,
                    child: Icon(Icons.person, color: Colors.white),
                  ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _anilistUser!.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${_anilistLists.fold(0, (sum, l) => sum + l.entries.length)} animes nas listas',
                      style: const TextStyle(
                        color: ThemeConstants.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (_anilistLoggedIn)
          ..._anilistLists.map((group) => _buildAnilistGroup(group, screenWidth)),
        if (_trending.isNotEmpty) ...[
          const SectionHeader(title: 'Em Alta'),
          SizedBox(
            height: bannerHeight + 20,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: _trending.length > 10 ? 10 : _trending.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FocusableBannerCard(
                  imageUrl: _trending[i].imageUrl,
                  title: _trending[i].name,
                  width: bannerWidth,
                  height: bannerHeight,
                  onTap: () => _openDetail(_trending[i]),
                ),
              ),
            ),
          ),
        ],
        if (_recent.isNotEmpty) ...[
          const SectionHeader(title: 'Populares da Temporada'),
          SizedBox(
            height: cardHeight + 20,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: _recent.length > 20 ? 20 : _recent.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(right: 10),
                child: FocusableCard(
                  imageUrl: _recent[i].imageUrl,
                  title: _recent[i].name,
                  width: cardWidth,
                  height: cardHeight,
                  onTap: () => _openDetail(_recent[i]),
                ),
              ),
            ),
          ),
        ],
        if (history.isNotEmpty) ...[
          const SectionHeader(title: 'Continuar Assistindo'),
          SizedBox(
            height: cardHeight + 20,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: history.length > 10 ? 10 : history.length,
              itemBuilder: (_, i) {
                final item = history[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: FocusableCard(
                    imageUrl: item['image']?.toString() ?? '',
                    title: item['title']?.toString() ?? '',
                    width: cardWidth,
                    height: cardHeight,
                    onTap: () => _openFromHistory(item),
                  ),
                );
              },
            ),
          ),
        ],
        if (favorites.isNotEmpty) ...[
          const SectionHeader(title: 'Favoritos'),
          SizedBox(
            height: cardHeight + 20,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              itemCount: favorites.length > 10 ? 10 : favorites.length,
              itemBuilder: (_, i) {
                final item = favorites[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: FocusableCard(
                    imageUrl: item['image']?.toString() ?? '',
                    title: item['title']?.toString() ?? '',
                    width: cardWidth,
                    height: cardHeight,
                    onTap: () => _openFromFav(item),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 32),
      ],
    );
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
                  onTap: () => _openAnilistDetail(entry.media),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _openDetail(Anime anime) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
    );
  }

  void _openAnilistDetail(AniListMedia media) {
    final anime = Anime(
      name: media.title,
      url: '',
      fallbackImageUrl: media.coverImage,
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
    );
  }

  void _openFromHistory(Map<String, dynamic> item) {
    final anime = Anime(
      name: item['title']?.toString() ?? '',
      url: '',
      fallbackImageUrl: item['image']?.toString(),
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
    );
  }

  void _openFromFav(Map<String, dynamic> item) {
    final anime = Anime(
      name: item['title']?.toString() ?? '',
      url: '',
      fallbackImageUrl: item['image']?.toString(),
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
    );
  }
}

class _AnilistLoginDialog extends StatefulWidget {
  const _AnilistLoginDialog();

  @override
  State<_AnilistLoginDialog> createState() => _AnilistLoginDialogState();
}

class _AnilistLoginDialogState extends State<_AnilistLoginDialog> {
  WebViewController? _controller;
  bool _isLoading = true;
  bool _showManual = false;
  final _tokenController = TextEditingController();
  bool _saving = false;
  String? _error;

  AniListPairingServer? _pairing;
  bool _pairingStarting = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _pairing?.dispose();
    super.dispose();
  }

  Future<void> _startPairing() async {
    setState(() {
      _showManual = true;
      _pairingStarting = true;
      _error = null;
    });
    final server = AniListPairingServer();
    final ok = await server.start();
    if (!mounted) {
      await server.dispose();
      return;
    }
    if (!ok) {
      // No LAN available – fall back to manual token entry.
      setState(() => _pairingStarting = false);
      return;
    }
    setState(() {
      _pairing = server;
      _pairingStarting = false;
    });
    // Wait until the phone completes login, then close.
    server.onLoggedIn.then((loggedIn) {
      if (loggedIn && mounted) Navigator.pop(context, true);
    });
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) async {
          if (!mounted) return;
          setState(() => _isLoading = false);
          await _checkTokenFromWebView();
        },
        onNavigationRequest: (request) {
          if (request.url.contains('access_token')) {
            _checkTokenFromUrl(request.url);
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(AniListService.authUrl));
  }

  Future<String?> _getCurrentUrl() async {
    try {
      final result = await _controller!
          .runJavaScriptReturningResult('window.location.href');
      if (result is String) {
        // result may be JSON-encoded "..." or raw
        if (result.length >= 2 &&
            result.startsWith('"') &&
            result.endsWith('"')) {
          return result.substring(1, result.length - 1);
        }
        return result;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _checkTokenFromWebView() async {
    final url = await _getCurrentUrl();
    if (url != null) _checkTokenFromUrl(url);
  }

  void _checkTokenFromUrl(String url) {
    final match = RegExp(r'access_token=([^&]+)').firstMatch(url);
    if (match != null) {
      _handleToken(match.group(1)!);
    }
  }

  Future<void> _handleToken(String token) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await AniListService.saveToken(token);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Token inválido. Tente novamente.';
        _showManual = true;
      });
    }
  }

  Future<void> _doLogin() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Insira o token do AniList');
      return;
    }
    if (!token.startsWith('eyJ')) {
      setState(() => _error = 'Token inválido. Deve começar com "eyJ..."');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await AniListService.saveToken(token);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = 'Token inválido ou expirado. Tente novamente.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authUrl = AniListService.authUrl;
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CachedImage(
                  url: 'https://anilist.co/img/icons/icon.svg',
                  width: 32,
                  height: 32,
                  fallback: const Icon(
                    Icons.bookmark,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Conectar AniList',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (!_showManual) ...[
              const Text(
                'Faça login no AniList usando o controle remoto',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 4),
              const Text(
                'Depois de autorizar, o login será feito automaticamente',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: ThemeConstants.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      if (_controller != null)
                        WebViewWidget(controller: _controller!),
                      if (_isLoading)
                        const Center(
                          child: CircularProgressIndicator(
                            color: ThemeConstants.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Semantics(
                    button: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _startPairing,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          child: Text(
                            'Usar celular',
                            style: TextStyle(
                              color: ThemeConstants.primary,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Semantics(
                        button: true,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => Navigator.pop(context, false),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              child: const Text(
                                'Cancelar',
                                style: TextStyle(
                                  color: ThemeConstants.textSecondary,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
            if (_showManual) ...[
              if (_pairingStarting)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                            color: ThemeConstants.primary),
                        SizedBox(height: 16),
                        Text('Preparando pareamento...',
                            style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                )
              else if (_pairing?.pairUrl != null) ...[
                const Text(
                  '1. Escaneie o QR code com a câmera do celular',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 4),
                const Text(
                  '2. Toque em "Entrar com AniList" e autorize',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 4),
                const Text(
                  '3. O login na TV acontece sozinho — sem digitar nada',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: _pairing!.pairUrl!,
                      version: QrVersions.auto,
                      size: 200,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: ThemeConstants.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Aguardando login no celular...',
                      style: TextStyle(
                        color: ThemeConstants.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _pairing!.pairUrl!,
                    style: const TextStyle(
                        color: ThemeConstants.textSecondary, fontSize: 12),
                  ),
                ),
              ] else ...[
                // Fallback: no LAN — QR of the AniList auth + paste token.
                const Text(
                  'Escaneie o QR, autorize e cole o token abaixo:',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: authUrl,
                      version: QrVersions.auto,
                      size: 180,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: ThemeConstants.background,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _error != null
                          ? Colors.red
                          : ThemeConstants.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: TextField(
                    controller: _tokenController,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration.collapsed(
                      hintText: 'Token (começa com eyJ...)',
                      hintStyle: TextStyle(
                        color: ThemeConstants.textSecondary
                            .withValues(alpha: 0.5),
                      ),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 14),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Semantics(
                    button: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => Navigator.pop(context, false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          child: const Text(
                            'Cancelar',
                            style: TextStyle(
                              color: ThemeConstants.textSecondary,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // "Conectar" only in the paste-token fallback mode.
                  if (_pairing?.pairUrl == null && !_pairingStarting) ...[
                    const SizedBox(width: 12),
                    Semantics(
                      button: true,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _saving ? null : _doLogin,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            decoration: BoxDecoration(
                              color: _saving
                                  ? ThemeConstants.primary
                                      .withValues(alpha: 0.5)
                                  : ThemeConstants.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Conectar',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FocusableAnilistBanner extends StatefulWidget {
  final VoidCallback onTap;

  const _FocusableAnilistBanner({required this.onTap});

  @override
  State<_FocusableAnilistBanner> createState() => _FocusableAnilistBannerState();
}

class _FocusableAnilistBannerState extends State<_FocusableAnilistBanner> {
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
            onTap: widget.onTap,
            onHover: (_) {},
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: _isFocused
                    ? const LinearGradient(
                        colors: [Color(0xFF7B73FF), Color(0xFF5C51E0)],
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF6C63FF), Color(0xFF3F51B5)],
                      ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _isFocused ? ThemeConstants.primary : Colors.transparent,
                  width: 2,
                ),
                boxShadow: _isFocused
                    ? [
                        BoxShadow(
                          color: ThemeConstants.primary.withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 1,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                children: [
                  CachedImage(
                    url: 'https://anilist.co/img/icons/icon.svg',
                    width: 36,
                    height: 36,
                    fallback: const Icon(
                      Icons.bookmark,
                      color: Colors.white, size: 36,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Conectar com AniList',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Veja suas listas de animes aqui',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios,
                      color: Colors.white, size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  @override
  Widget build(BuildContext context) {
    final history = LocalStorage.getHistory();
    final favorites = LocalStorage.getFavorites();

    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 16,
              left: 24, right: 24, bottom: 16,
            ),
            child: Row(
              children: [
                Semantics(
                  button: true,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => Navigator.pop(context),
                      child: const Icon(Icons.arrow_back,
                          color: Colors.white, size: 32),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                const Text(
                  'Meu Perfil',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: ThemeConstants.white,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                const SectionHeader(title: 'Assistidos'),
                if (history.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nenhum anime assistido ainda',
                      style: TextStyle(
                          fontSize: 18,
                          color: ThemeConstants.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  SizedBox(
                    height: 210,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: history.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: FocusableCard(
                          imageUrl: history[i]['image']?.toString() ?? '',
                          title: history[i]['title']?.toString() ?? '',
                          width: 140,
                          height: 200,
                          onTap: () => _open(context, history[i]),
                        ),
                      ),
                    ),
                  ),
                const SectionHeader(title: 'Favoritos'),
                if (favorites.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nenhum favorito adicionado',
                      style: TextStyle(
                          fontSize: 18,
                          color: ThemeConstants.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  SizedBox(
                    height: 210,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: favorites.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: FocusableCard(
                          imageUrl: favorites[i]['image']?.toString() ?? '',
                          title: favorites[i]['title']?.toString() ?? '',
                          width: 140,
                          height: 200,
                          onTap: () => _open(context, favorites[i]),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, Map<String, dynamic> item) {
    final anime = Anime(
      name: item['title']?.toString() ?? '',
      url: '',
      fallbackImageUrl: item['image']?.toString(),
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
    );
  }
}
