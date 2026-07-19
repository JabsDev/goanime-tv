import 'package:flutter/material.dart';
import '../../core/storage/local_storage.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/app_top_bar.dart';
import '../../shared/widgets/focusable_card.dart';
import 'home_navigation.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final favorites = LocalStorage.getFavorites();

    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          AppTopBar(
            title: 'Favoritos',
            icon: Icons.favorite,
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: favorites.isEmpty
                ? const Center(
                    child: Text(
                      'Nenhum favorito adicionado',
                      style: TextStyle(
                        fontSize: 18,
                        color: ThemeConstants.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 6,
                      childAspectRatio: 0.7,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: favorites.length,
                    itemBuilder: (_, i) => LayoutBuilder(
                      builder: (context, c) => FocusableCard(
                        imageUrl: favorites[i]['image']?.toString() ?? '',
                        title: favorites[i]['title']?.toString() ?? '',
                        width: c.maxWidth,
                        height: c.maxHeight,
                        onTap: () => openFromMap(context, favorites[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}