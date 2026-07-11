import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../data/models/anime.dart';
import '../../data/repositories/anime_repository.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/focusable_card.dart';
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

  @override
  void initState() {
    super.initState();
    _searchFocus.requestFocus();
  }

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final results = await _repo.searchAnime(q);
      setState(() {
        _results = results;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('[Search] Error: $e');
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
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 16,
              left: 24,
              right: 24,
              bottom: 16,
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
                const Expanded(
                  child: Text(
                    'Buscar Anime',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: ThemeConstants.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _buildSearchBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
          if (_searchController.text.isNotEmpty)
            Semantics(
              button: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    _searchController.clear();
                    _results = [];
                    setState(() {});
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.close,
                        color: ThemeConstants.textSecondary, size: 28),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
    final crossAxisCount = screenWidth > 900 ? 8 : screenWidth > 600 ? 6 : 4;
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.7,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _results.length,
      itemBuilder: (_, i) => FocusableCard(
        imageUrl: _results[i].imageUrl,
        title: _results[i].name,
        width: double.infinity,
        height: double.infinity,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DetailScreen(anime: _results[i]),
            ),
          );
        },
      ),
    );
  }
}
