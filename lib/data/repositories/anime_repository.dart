import 'package:flutter/foundation.dart';
import '../../core/scraper/anime_scraper.dart';
import '../../core/scraper/scraper_result.dart';
import '../../core/sources/anime_source_adapter.dart';
import '../../core/sources/source_registry.dart';
import '../models/anime.dart';
import '../models/episode.dart';

class AnimeRepository {
  Future<List<Anime>> searchAnime(String query) async {
    return AnimeScraper.searchAnime(query);
  }

  Future<EpisodesResult> getEpisodes(Anime anime) async {
    return AnimeScraper.getEpisodes(anime);
  }

  /// Resolves playable sources. The episode's own source is tried first; if it
  /// yields nothing (site down, HTML changed, Cloudflare, source mismatch, etc.)
  /// the remaining providers are attempted as a fallback so the quality picker
  /// always shows the best available option. Results are de-duplicated by URL.
  Future<List<VideoSource>> getVideoSources(
    Episode episode,
    AnimeSource source, {
    Anime? anime,
  }) async {
    // Prefer the episode's own source/owner (episodes can be merged from a
    // provider that differs from the parent anime's source). Fall back to the
    // passed-in source/anime otherwise.
    final effectiveSource = episode.source ?? source;
    final effectiveAnime = episode.owner ?? anime;
    final primary = SourceRegistry.forSource(effectiveSource);

    Future<List<VideoSource>> tryAdapter(
        AnimeSourceAdapter a, Anime? ctx) async {
      try {
        final result = await a.getVideoSources(episode, anime: ctx);
        switch (result) {
          case Success(data: final sources):
            return sources;
          case Failure(error: final err):
            debugPrint('[Repo] Source ${a.source} failed: ${err.message}');
            return <VideoSource>[];
          case Loading():
            return <VideoSource>[];
        }
      } catch (e) {
        debugPrint('[Repo] Source ${a.source} failed: $e');
        return <VideoSource>[];
      }
    }

    final collected = <VideoSource>[];
    collected.addAll(await tryAdapter(primary, effectiveAnime));

    if (collected.isEmpty) {
      final others =
          SourceRegistry.adapters.where((a) => a.source != effectiveSource);
      final results = await Future.wait(
          others.map((a) => tryAdapter(a, effectiveAnime)));
      for (final r in results) {
        collected.addAll(r);
      }
    }

    final seen = <String>{};
    return collected.where((s) => seen.add(s.url)).toList();
  }
}
