import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';
import 'package:goanime_tv/core/sources/source_registry.dart';

/// On-device smoke test that exercises the real scrapers (AnimeFire, AllAnime,
/// SuperFlix) end-to-end: search -> episode listing -> video source (quality)
/// resolution. Run with:
///   flutter test integration_test/scraper_smoke_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final repo = AnimeRepository();

  Future<void> probe(String query) async {
    debugPrint('\n========== PROBE: "$query" ==========');
    final results = await repo.searchAnime(query);
    debugPrint('SEARCH: ${results.length} results');
    final bySource = <AnimeSource, int>{};
    for (final a in results) {
      bySource[a.source] = (bySource[a.source] ?? 0) + 1;
    }
    debugPrint('  by source: $bySource');
    if (results.isEmpty) {
      debugPrint('  !! no results');
      return;
    }

    final anime = results.first;
    debugPrint('PICK: "${anime.name}" [${anime.sourceName}]');

    final epResult = await repo.getEpisodes(anime);
    final epCount = epResult.episodes.length;
    final optionCount = epResult.sourceOptions.length;
    debugPrint('EPISODES: ${epCount} in main list, '
        '${optionCount} source options ${epResult.sourceOptions.keys.toList()}');

    final episodes = epResult.episodes.isNotEmpty
        ? epResult.episodes
        : (epResult.sourceOptions.isNotEmpty
            ? epResult.sourceOptions.values.first
            : <dynamic>[]);
    if (episodes.isEmpty) {
      debugPrint('  !! no episodes');
      return;
    }

    final firstEp = episodes.first;
    debugPrint('FIRST EP: number=${firstEp.number} url=${firstEp.url} '
        'source=${firstEp.source} '
        'owner.allAnimeId=${firstEp.owner?.allAnimeId} '
        'owner.tmdb=${firstEp.owner?.superFlixTmdbId}');
    final sources = await repo.getVideoSources(
      firstEp,
      anime.source,
      anime: anime,
    );
    debugPrint('VIDEO SOURCES: ${sources.length}');
    for (final s in sources) {
      final u = s.url.length > 80 ? '${s.url.substring(0, 80)}...' : s.url;
      debugPrint('  - [${s.quality}] $u');
    }
  }

  testWidgets('registry has 5 adapters', (tester) async {
    expect(SourceRegistry.adapters.length, 5);
  });

  testWidgets('AnimeFire: episodes + qualities', (tester) async {
    final results = await AnimeRepository().searchAnime('naruto');
    final af = results.where((a) => a.source == AnimeSource.animeFire).toList();
    debugPrint('AnimeFire results: ${af.length}');
    if (af.isNotEmpty) {
      final ep = await AnimeRepository().getEpisodes(af.first);
      debugPrint('AnimeFire episodes: ${ep.episodes.length}');
      expect(ep.episodes.isNotEmpty || ep.sourceOptions.isNotEmpty, true,
          reason: 'AnimeFire should list episodes');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('SuperFlix: direct search + episodes + multi-server stream',
      (tester) async {
    final sf = SourceRegistry.forSource(AnimeSource.superFlix);
    final results = await sf.search('the boys');
    debugPrint('SuperFlix search: ${results.length} results');
    expect(results.isNotEmpty, true, reason: 'SuperFlix search should work');
    final anime = results.firstWhere(
      (a) => a.superFlixTmdbId != null,
      orElse: () => results.first,
    );
    debugPrint('SuperFlix pick: "${anime.name}" tmdb=${anime.superFlixTmdbId}');

    // NOTE: as of 2026-07 SuperFlix content pages (superflixapi.pro) are gated
    // by a Cloudflare Turnstile challenge, so episode/stream extraction returns
    // empty without a browser-based clearance. Search still works. We assert
    // only search here and log the (likely gated) episode result.
    final eps = await sf.getEpisodes(anime);
    debugPrint('SuperFlix episodes: ${eps.episodes.length} '
        '(0 => Cloudflare Turnstile gated)');
    if (eps.episodes.isNotEmpty) {
      final firstEp = eps.episodes.first;
      final sources = await sf.getVideoSources(firstEp, anime: anime);
      debugPrint('SuperFlix video sources: ${sources.length}');
      for (final s in sources) {
        final u = s.url.length > 90 ? '${s.url.substring(0, 90)}...' : s.url;
        debugPrint('  - [${s.quality}] $u');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('AnimeFire: real series episodes + multi-quality stream',
      (tester) async {
    final af = SourceRegistry.forSource(AnimeSource.animeFire);
    final results = await af.search('kimetsu no yaiba');
    debugPrint('AnimeFire search: ${results.length}');
    expect(results.isNotEmpty, true);
    // Prefer a full series page (todos-os-episodios) over movies.
    final anime = results.firstWhere(
      (a) => a.url.contains('todos-os-episodios'),
      orElse: () => results.first,
    );
    debugPrint('AnimeFire pick: "${anime.name}" url=${anime.url}');
    final eps = await af.getEpisodes(anime);
    final list = eps.episodes.isNotEmpty
        ? eps.episodes
        : (eps.sourceOptions.isNotEmpty
            ? eps.sourceOptions.values.first
            : <Episode>[]);
    debugPrint('AnimeFire episodes: ${list.length}');
    expect(list.isNotEmpty, true, reason: 'AnimeFire should list episodes');

    final sources = await af.getVideoSources(list.first, anime: anime);
    debugPrint('AnimeFire video sources: ${sources.length}');
    for (final s in sources) {
      final u = s.url.length > 90 ? '${s.url.substring(0, 90)}...' : s.url;
      debugPrint('  - [${s.quality}] $u');
    }
    expect(sources.isNotEmpty, true,
        reason: 'AnimeFire should resolve a stream');
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('Goyabu: PT-BR search + episodes + multi-quality stream',
      (tester) async {
    final gy = SourceRegistry.forSource(AnimeSource.goyabu);
    final results = await gy.search('one piece');
    debugPrint('Goyabu search: ${results.length}');
    expect(results.isNotEmpty, true, reason: 'Goyabu search should work');
    // Pick the first result that actually lists episodes (spin-offs may be empty).
    Anime? anime;
    var eps = EpisodesResult([], {});
    for (final r in results) {
      final e = await gy.getEpisodes(r);
      debugPrint('  candidate "${r.name}" -> ${e.episodes.length} eps');
      if (e.episodes.isNotEmpty) {
        anime = r;
        eps = e;
        break;
      }
    }
    expect(anime != null, true, reason: 'Goyabu should have a series with episodes');
    debugPrint('Goyabu pick: "${anime!.name}" episodes=${eps.episodes.length}');
    final sources = await gy.getVideoSources(eps.episodes.first, anime: anime);
    debugPrint('Goyabu video sources: ${sources.length}');
    for (final s in sources) {
      final u = s.url.length > 90 ? '${s.url.substring(0, 90)}...' : s.url;
      debugPrint('  - [${s.quality}] $u');
    }
    expect(sources.isNotEmpty, true, reason: 'Goyabu should resolve a stream');
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('End-to-end probes', (tester) async {
    await probe('one piece');
    await probe('naruto');
    await probe('the boys');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
