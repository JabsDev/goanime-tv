import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import 'ai_subtitle_card.dart';

// ponytail: fallback temporário — a decisão completa agora vive no
// AiSubtitleCard (inline no picker); remover esta tela após QA do card.
/// Tela dedicada da legenda IA (D-pad navegável): mesmo card do picker,
/// empilhada como rota própria.
class AiSubtitleScreen extends StatelessWidget {
  final Anime anime;
  final CatalogEpisode episode;
  final int episodeIndex;
  final List<CatalogEpisode> episodeList;
  final AnimeSource provider;
  final List<VideoSource> sources;

  const AiSubtitleScreen({
    super.key,
    required this.anime,
    required this.episode,
    required this.episodeIndex,
    required this.episodeList,
    required this.provider,
    required this.sources,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      appBar: AppBar(
        backgroundColor: ThemeConstants.surface,
        title: Text('Legenda IA · EP${episode.number}',
            style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
        children: [
          AiSubtitleCard(
            anime: anime,
            episode: episode,
            episodeIndex: episodeIndex,
            episodeList: episodeList,
            provider: provider,
            sources: sources,
          ),
        ],
      ),
    );
  }
}
