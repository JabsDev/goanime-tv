/// On-device integration test covering the full user flow:
/// search → detail (episode listing) → playback (video source resolution).
/// Run with:
///   flutter test integration_test/search_detail_playback_test.dart -d emulator-5554
///
/// Follows the established probe() pattern from scraper_smoke_test.dart.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final repo = AnimeRepository();

  testWidgets('search → detail → playback flow', (tester) async {
    // ============================== SEARCH ==============================
    debugPrint('\n===== SEARCH =====');
    final results = await repo.searchAnime('naruto');
    debugPrint('Results: ${results.length} hits');
    expect(results.isNotEmpty, true, reason: 'Search should return results');

    final bySource = <AnimeSource, int>{};
    for (final a in results) {
      bySource[a.source] = (bySource[a.source] ?? 0) + 1;
    }
    debugPrint('By source: $bySource');

    // ============================== SELECT ==============================
    debugPrint('\n===== SELECT =====');
    // Find the first anime with resolvable episode identifiers.
    Anime selected = results.firstWhere(
      (a) => a.url.isNotEmpty || a.allAnimeId != null || a.superFlixTmdbId != null,
      orElse: () => results.first,
    );
    debugPrint('Selected: "${selected.name}" [${selected.sourceName}]'
        ' url=${selected.url.isNotEmpty}'
        ' allAnimeId=${selected.allAnimeId}'
        ' superFlixTmdbId=${selected.superFlixTmdbId}');

    // ============================== EPISODES ==============================
    debugPrint('\n===== EPISODES =====');
    final epResult = await repo.getEpisodes(selected);
    final episodes = epResult.episodes.isNotEmpty
        ? epResult.episodes
        : (epResult.sourceOptions.isNotEmpty
            ? epResult.sourceOptions.values.first
            : <dynamic>[]);
    debugPrint('Episodes: ${episodes.length} in main list'
        ', ${epResult.sourceOptions.length} source options'
        ' ${epResult.sourceOptions.keys.toList()}');
    expect(episodes.isNotEmpty, true,
        reason: 'Should list episodes for the selected anime');

    // ============================== PLAYBACK ==============================
    debugPrint('\n===== PLAYBACK =====');
    final firstEp = episodes.first;
    debugPrint('First episode: number=${firstEp.number}'
        ' url=${firstEp.url}'
        ' source=${firstEp.source}'
        ' owner.allAnimeId=${firstEp.owner?.allAnimeId}'
        ' owner.tmdb=${firstEp.owner?.superFlixTmdbId}');
    final sources = await repo.getVideoSources(
      firstEp,
      selected.source,
      anime: selected,
    );
    debugPrint('Video sources: ${sources.length}');
    for (final s in sources) {
      final u = s.url.length > 80 ? '${s.url.substring(0, 80)}...' : s.url;
      debugPrint('  - [${s.quality}] $u');
    }
    expect(sources.isNotEmpty, true,
        reason: 'Should resolve at least one video source for playback');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
