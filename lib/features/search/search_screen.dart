import 'package:flutter/material.dart';
import '../../data/models/anime.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/utils/nsfw_filter.dart';
import '../../shared/widgets/app_top_bar.dart';
import '../../shared/widgets/focusable_card.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../detail/detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final AnimeRepository _repo = AnimeRepository();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<Anime> _results = [];
  bool _isLoading = false;
  bool _hasQuery = false;

  @override
  void initState() {
    super.initState();
    _searchFocus.requestFocus();
    _searchController.addListener(() {
      final has = _searchController.text.isNotEmpty;
      if (has != _hasQuery) setState(() => _hasQuery = has);
    });
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final results = await _repo.searchAnime(q);
      if (!mounted) return;
      setState(() {
        _results = NsfwFilter.filter(
            results, SettingsService.instance.nsfwFilterLevel);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[Search] Error: $e');
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          AppTopBar(
            title: 'Buscar Anime',
            icon: Icons.search,
            onBack: () => Navigator.pop(context),
          ),
          _buildSearchBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      decoration: BoxDecoration(
        color: ThemeConstants.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ThemeConstants.primary.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 20),
            child: Icon(Icons.search, color: ThemeConstants.primary, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              style: const TextStyle(fontSize: 22, color: ThemeConstants.white),
              decoration: const InputDecoration.collapsed(
                hintText: 'Digite o nome do anime...',
                hintStyle: TextStyle(color: ThemeConstants.textSecondary),
              ),
              onSubmitted: _performSearch,
              textInputAction: TextInputAction.search,
            ),
          ),
          if (_hasQuery)
            _ClearButton(onTap: () {
              _searchController.clear();
              setState(() => _results = []);
            }),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: ThemeConstants.primary),
      );
    }
    if (_results.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
            child: Text(
              '${_results.length} resultado(s) encontrado(s)',
              style: const TextStyle(
                fontSize: 18,
                color: ThemeConstants.textSecondary,
              ),
            ),
          ),
          Expanded(child: _buildResultsGrid()),
        ],
      );
    }
    return const Center(
      child: Text(
        'Use o teclado para buscar animes',
        style: TextStyle(fontSize: 18, color: ThemeConstants.textSecondary),
      ),
    );
  }

  Widget _buildResultsGrid() {
    final screenWidth = MediaQuery.of(context).size.width;
    // ponytail: 8 colunas na TV (960 log.) deixava cards ~100px e títulos
    // truncados/ilegíveis (C3). Facilita um pouco: menos colunas em telas
    // largas dá cards mais legíveis mantendo densidade razoável.
    final crossAxisCount = screenWidth > 900 ? 6 : screenWidth > 600 ? 5 : 4;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.7,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _results.length,
      // ponytail: LayoutBuilder entrega width/height finite do GridView cell
      // para o FocusableCard. Antes passávamos double.infinity → cached_image
      // chamava .toInt() em Infinity → UnsupportedError/NaN crash na busca.
      itemBuilder: (_, i) => LayoutBuilder(
        builder: (context, c) => FocusableCard(
          imageUrl: _results[i].imageUrl,
          title: _results[i].name,
          width: c.maxWidth,
          height: c.maxHeight,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DetailScreen(anime: _results[i]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ClearButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ClearButton({required this.onTap});

  @override
  State<_ClearButton> createState() => _ClearButtonState();
}

class _ClearButtonState extends State<_ClearButton> {
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
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isFocused
                    ? ThemeConstants.primary.withValues(alpha: 0.15)
                    : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isFocused ? ThemeConstants.primary : Colors.transparent,
                  width: ThemeConstants.focusBorderWidth,
                ),
              ),
              child: const Icon(
                Icons.close,
                color: ThemeConstants.textSecondary,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}