import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/data/repositories/anime_repository.dart';

/// Verifies the AniList catalog powers discovery and that opening a catalog
/// title resolves episodes via the PT-BR scrapers.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AniList catalog + episode resolution by title', (tester) async {
    final trending = await AniListService.getTrending(perPage: 15);
    final season = await AniListService.getPopularThisSeason(perPage: 15);
    debugPrint('Trending: ${trending.length}, Season: ${season.length}');
    expect(trending.isNotEmpty, true, reason: 'AniList trending should return');
    for (final a in trending.take(5)) {
      debugPrint('  - ${a.name} (score=${a.averageScore}, eps=${a.episodes})');
    }

    // Open a trending title and resolve episodes across providers by name.
    final repo = AnimeRepository();
    var resolved = 0;
    for (final a in trending.take(6)) {
      final eps = await repo.getEpisodes(a);
      final list = eps.episodes.isNotEmpty
          ? eps.episodes
          : (eps.sourceOptions.isNotEmpty
              ? eps.sourceOptions.values.first
              : []);
      debugPrint('  "${a.name}" -> ${list.length} eps '
          '(options: ${eps.sourceOptions.keys.toList()})');
      if (list.isNotEmpty) resolved++;
    }
    debugPrint('Resolved episodes for $resolved/6 trending titles');
    expect(resolved > 0, true,
        reason: 'At least one trending title should resolve episodes');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
