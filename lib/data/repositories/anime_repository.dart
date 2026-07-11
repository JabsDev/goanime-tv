import 'package:flutter/foundation.dart';
import '../../core/scraper/anime_scraper.dart';
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
        return await a.getVideoSources(episode, anime: ctx);
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
      final results = await Future.wait(others.map((a) async {
        // Each fallback provider needs its own context (with the right ids).
        Anime? ctx = effectiveAnime;
        if (a.source == AnimeSource.superFlix) {
          ctx = await _superFlixContext(effectiveAnime);
        } else if (a.source == AnimeSource.allAnime) {
          ctx = await _contextForSource(effectiveAnime, AnimeSource.allAnime);
        } else if (a.source == AnimeSource.animeFire) {
          ctx = await _contextForSource(effectiveAnime, AnimeSource.animeFire);
        }
        return tryAdapter(a, ctx);
      }));
      for (final r in results) {
        collected.addAll(r);
      }
    }

    final seen = <String>{};
    return collected.where((s) => seen.add(s.url)).toList();
  }

  /// Resolves an anime context for [source] by (cached) search when the current
  /// context doesn't already carry the identifier that provider needs.
  Future<Anime?> _contextForSource(Anime? anime, AnimeSource source) async {
    if (anime == null) return null;
    if (source == AnimeSource.allAnime && anime.allAnimeId != null) return anime;
    if (source == AnimeSource.animeFire &&
        anime.source == AnimeSource.animeFire &&
        anime.url.isNotEmpty) {
      return anime;
    }
    try {
      final results = await SourceRegistry.forSource(source).search(anime.name);
      for (final r in results) {
        if (source == AnimeSource.allAnime && r.allAnimeId != null) return r;
        if (source == AnimeSource.animeFire && r.url.isNotEmpty) return r;
      }
    } catch (_) {}
    return anime;
  }

  /// Returns [anime] if it already carries a SuperFlix id, otherwise performs a
  /// (cached) SuperFlix search by name to obtain one so the SuperFlix provider
  /// can be used as a fallback source.
  Future<Anime?> _superFlixContext(Anime? anime) async {
    if (anime?.superFlixTmdbId != null) return anime;
    if (anime == null) return null;
    try {
      final results = await SourceRegistry.forSource(AnimeSource.superFlix)
          .search(anime.name);
      for (final r in results) {
        if (r.superFlixTmdbId != null) return r;
      }
    } catch (_) {
      // ignore – SuperFlix is only a fallback
    }
    return anime;
  }
}
