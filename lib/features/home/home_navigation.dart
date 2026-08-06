import 'package:flutter/material.dart';
import '../../core/anilist/anilist_service.dart';
import '../../data/models/anime.dart';
import '../../data/models/anilist_models.dart';
import '../detail/detail_screen.dart';

/// Opens [DetailScreen] for an [Anime] obtained from the main catalog.
void openDetail(BuildContext context, Anime anime) {
  debugPrint('[Nav] openDetail name=${anime.name} source=${anime.source} url=${anime.url}');
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

/// Opens [DetailScreen] for an anime from a stored item map (history or favorites).
Future<void> openFromMap(BuildContext context, Map<String, dynamic> item) async {
  final anime = Anime(
    name: item['title']?.toString() ?? '',
    url: '',
    fallbackImageUrl: item['image']?.toString(),
    anilistId: item['anilistId'] as int?,
  );
  debugPrint('[Nav] openFromMap name=${anime.name}');
  await AniListService.enrich(anime);
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

/// Opens [DetailScreen] for an [AniListMedia] entry (from AniList user lists).
Future<void> openAnilistDetail(BuildContext context, AniListMedia media) async {
  final anime = Anime(
    name: media.title,
    url: '',
    fallbackImageUrl: media.coverImage,
    anilistId: media.id,
  );
  debugPrint('[Nav] openAnilistDetail name=${anime.name}');
  await AniListService.enrich(anime);
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}
