import 'package:flutter/material.dart';
import '../../core/storage/local_storage.dart';
import '../../core/constants/theme_constants.dart';
import '../../shared/widgets/focusable_card.dart';
import '../../shared/widgets/section_header.dart';
import '../../data/models/anime.dart';
import 'home_navigation.dart';

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
                          onTap: () => openFromHistory(context, history[i]),
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
                          onTap: () => openFromFav(context, favorites[i]),
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
}
