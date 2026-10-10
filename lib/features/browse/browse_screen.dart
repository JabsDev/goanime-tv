import 'package:flutter/material.dart';

import '../../core/catalog/catalog_browse_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../data/models/anime.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../../shared/widgets/focusable_card.dart';
import '../detail/detail_screen.dart';

/// **Explorar** — as duas formas de listar o acervo que não existiam:
///
///  1. **Categorias** (gêneros): grade de chips → grade de capas.
///  2. **Alfabeto**: A-Z + `#`, filtrando o índice local em memória.
///
/// Por que índice local e não "consultar a letra no catálogo": nenhum dos
/// dois provedores ordena alfabeticamente e a busca deles é difusa (medido:
/// AniList `search:"R"` devolve 40 itens e só 6 começam com R). Ver
/// `CatalogBrowseService`.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  /// 0 = categorias, 1 = alfabeto.
  int _tab = 0;

  List<BrowseCategory> _categories = const [];
  List<Anime> _index = const [];
  String? _selectedLetter;

  bool _loadingIndex = false;
  bool _loadingCategory = false;
  List<Anime> _categoryItems = const [];
  BrowseCategory? _activeCategory;

  @override
  void initState() {
    super.initState();
    CatalogBrowseService.warmUpInBackground();
    _load();
  }

  Future<void> _load() async {
    setState(() => _index = CatalogBrowseService.readIndex());
    final cats = await CatalogBrowseService.categories();
    if (!mounted) return;
    setState(() => _categories = cats);
  }

  Future<void> _openCategory(BrowseCategory c) async {
    setState(() {
      _activeCategory = c;
      _loadingCategory = true;
      _categoryItems = const [];
    });
    final items = await CatalogBrowseService.itemsOf(c);
    if (!mounted) return;
    setState(() {
      _categoryItems = items;
      _loadingCategory = false;
    });
  }

  Future<void> _openLetter(String letter) async {
    setState(() => _selectedLetter = letter);
    if (_index.length < CatalogBrowseService.minEntries) {
      setState(() => _loadingIndex = true);
      await CatalogBrowseService.sync();
      if (!mounted) return;
      setState(() {
        _index = CatalogBrowseService.readIndex();
        _loadingIndex = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            _tabs(),
            Expanded(child: _tab == 0 ? _categoriesTab() : _lettersTab()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 28, 32, 4),
      child: Row(
        children: [
          const Text('Explorar',
              style: TextStyle(
                  color: ThemeConstants.white,
                  fontSize: 34,
                  fontWeight: FontWeight.bold)),
          const Spacer(),
          _IconFocus(
            icon: Icons.arrow_back,
            tooltip: 'Voltar',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _tabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 8, 48, 16),
      child: Row(
        children: [
          _Chip(
            label: 'Categorias',
            selected: _tab == 0,
            onTap: () => setState(() => _tab = 0),
          ),
          const SizedBox(width: 12),
          _Chip(
            label: 'Alfabeto',
            selected: _tab == 1,
            onTap: () => setState(() => _tab = 1),
          ),
          if (_loadingIndex) ...[
            const SizedBox(width: 20),
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: ThemeConstants.primary)),
          ],
        ],
      ),
    );
  }

  // ─────────────────────────── aba categorias ──────────────────────────────

  Widget _categoriesTab() {
    if (_activeCategory != null) return _categoryGrid();
    return ListView(
      padding: const EdgeInsets.fromLTRB(48, 4, 48, 48),
      children: [
        const Text('Por gênero',
            style: TextStyle(
                color: ThemeConstants.textSecondary, fontSize: 20)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in _categories)
              _Chip(
                label: c.label,
                selected: false,
                badge: c.isTmdb ? 'TMDB' : null,
                onTap: () => _openCategory(c),
              ),
          ],
        ),
        const SizedBox(height: 36),
        const Text('Navegação',
            style: TextStyle(
                color: ThemeConstants.textSecondary, fontSize: 20)),
        const SizedBox(height: 12),
        _Chip(
          label: 'Ver por letra (A-Z)',
          selected: false,
          icon: Icons.abc,
          onTap: () => setState(() => _tab = 1),
        ),
      ],
    );
  }

  Widget _categoryGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 48, 12),
          child: Row(
            children: [
              _IconFocus(
                icon: Icons.arrow_back,
                tooltip: 'Voltar',
                onTap: () => setState(() => _activeCategory = null),
              ),
              const SizedBox(width: 12),
              Text(_activeCategory!.label,
                  style: const TextStyle(
                      color: ThemeConstants.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 14),
              Text('${_categoryItems.length} títulos',
                  style: const TextStyle(
                      color: ThemeConstants.textSecondary, fontSize: 16)),
            ],
          ),
        ),
        Expanded(
          child: _loadingCategory
              ? const Center(
                  child: CircularProgressIndicator(color: ThemeConstants.primary))
              : _categoryItems.isEmpty
                  ? const Center(
                      child: Text('Nada por aqui ainda',
                          style: TextStyle(
                              color: ThemeConstants.textSecondary,
                              fontSize: 18)))
                  : _posterGrid(_categoryItems),
        ),
      ],
    );
  }

  // ──────────────────────────── aba alfabeto ───────────────────────────────

  Widget _lettersTab() {
    final letters = CatalogBrowseService.lettersOf(_index);
    final items = _selectedLetter == null
        ? const <Anime>[]
        : CatalogBrowseService.byLetter(_index, _selectedLetter!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 0, 48, 10),
          child: Row(
            children: [
              Text(_selectedLetter ?? 'Escolha uma letra',
                  style: const TextStyle(
                      color: ThemeConstants.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 14),
              if (_selectedLetter != null)
                Text('${items.length} títulos',
                    style: const TextStyle(
                        color: ThemeConstants.textSecondary, fontSize: 16)),
              const Spacer(),
              if (_index.isEmpty && !_loadingIndex)
                _Chip(
                  label: 'Indexar acervo',
                  selected: false,
                  icon: Icons.sync,
                  onTap: () => _openLetter('A'),
                ),
            ],
          ),
        ),
        if (letters.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                _loadingIndex
                    ? 'Indexando o acervo… a primeira vez leva alguns minutos'
                    : 'Toque em "Indexar acervo" para montar a lista',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: ThemeConstants.textSecondary, fontSize: 18),
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final l in letters)
                  _LetterTile(
                    letter: l,
                    count: CatalogBrowseService.byLetter(_index, l).length,
                    selected: _selectedLetter == l,
                    onTap: () => _openLetter(l),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loadingIndex
                ? const Center(child: CircularProgressIndicator(
                    color: ThemeConstants.primary))
                : items.isEmpty
                    ? const Center(
                        child: Text('Nenhum título começa com essa letra',
                            style: TextStyle(
                                color: ThemeConstants.textSecondary,
                                fontSize: 18)))
                    : _posterGrid(items),
          ),
        ],
      ],
    );
  }

  Widget _posterGrid(List<Anime> items) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(48, 0, 48, 48),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        childAspectRatio: 0.62,
        crossAxisSpacing: 18,
        mainAxisSpacing: 18,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final a = items[i];
        return FocusableCard(
          title: a.name,
          subtitle: a.mediaType == 'movie' ? 'Filme' : null,
          imageUrl: a.imageUrl,
          width: double.infinity,
          height: double.infinity,
          onTap: () => _openDetail(a),
        );
      },
    );
  }

  /// Títulos só-TMDB não têm id do AniList: entram pelo detalhe, que resolve
  /// via as fontes de vídeo a partir do nome.
  void _openDetail(Anime a) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DetailScreen(anime: a)));
  }
}

// ────────────────────────────── componentes ───────────────────────────────

/// Chip focável por D-pad (o `FocusableCard` do app é só para posteres).
class _Chip extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? badge;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.badge,
  });

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, widget.onTap),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          decoration: BoxDecoration(
            color: widget.selected
                ? ThemeConstants.primary
                : ThemeConstants.surfaceLight,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _focused
                  ? ThemeConstants.primaryLight
                  : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon,
                    size: 18,
                    color: widget.selected
                        ? Colors.black
                        : ThemeConstants.white),
                const SizedBox(width: 8),
              ],
              Text(widget.label,
                  style: TextStyle(
                      color: widget.selected
                          ? Colors.black
                          : ThemeConstants.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              if (widget.badge != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: ThemeConstants.primary,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(widget.badge!,
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LetterTile extends StatelessWidget {
  final String letter;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _LetterTile({
    required this.letter,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _Chip(label: letter, selected: selected, onTap: onTap);
  }
}

class _IconFocus extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconFocus({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, onTap),
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          icon: Icon(icon, color: ThemeConstants.white, size: 30),
          onPressed: onTap,
        ),
      ),
    );
  }
}