import 'package:flutter/material.dart';
import '../../data/models/anime.dart';
import '../../data/models/anilist_models.dart';
import '../detail/detail_screen.dart';

/// Opens [DetailScreen] for an [Anime] obtained from the main catalog.
void openDetail(BuildContext context, Anime anime) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => DetailScreen(anime: anime)),
  );
}

/// Opens [DetailScreen] for an anime from the watch-history list.
void openFromHistory(BuildContext context, Map<String, dynamic> item) {
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

/// Opens [DetailScreen] for an anime from the favorites list.
void openFromFav(BuildContext context, Map<String, dynamic> item) {
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

/// Opens [DetailScreen] for an [AniListMedia] entry (from AniList user lists).
void openAnilistDetail(BuildContext context, AniListMedia media) {
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
