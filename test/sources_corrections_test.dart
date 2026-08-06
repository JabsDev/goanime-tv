import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:goanime_tv/core/network/api_client.dart';
import 'package:goanime_tv/core/scraper/anime_scraper.dart';
import 'package:goanime_tv/core/sources/goyabu_adapter.dart';
import 'package:goanime_tv/core/utils/text_utils.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';

/// Regression tests for the source-correction plan (PLANO_ACAO_SOURCES.md):
/// clean search queries, HTTP 429 retry, and the AniList metadata-only merge.
void main() {
  tearDown(() {
    ApiClient.clientOverride = null;
    ApiClient.rateLimitBaseDelay = const Duration(milliseconds: 800);
  });

  test('cleanSearchQuery strips the rating/age badge (Naruto 7.93 A14)', () {
    expect(TextUtils.cleanSearchQuery('Naruto 7.93 A14'), 'Naruto');
    expect(TextUtils.cleanSearchQuery('One Piece 8.11 A12'), 'One Piece');
    expect(TextUtils.cleanSearchQuery('Dragon Ball Z'), 'Dragon Ball Z');
    expect(TextUtils.cleanSearchQuery('  Sword Art Online  '),
        'Sword Art Online');
  });

  test('Goyabu search cleans dirty query before hitting ?s=', () async {
    final adapter = GoyabuAdapter(client: MockClient((req) async {
      expect(req.url.queryParameters['s'], 'Naruto');
      return http.Response(
        '<article class="boxAN"><a href="/anime/naruto"><img class="cover" '
        'src="/cap.jpg" alt="Naruto"></a></article>',
        200,
      );
    }));
    final result = await adapter.search('Naruto 7.93 A14');
    expect(result, isA<Success<List<Anime>>>());
    expect((result as Success<List<Anime>>).data.single.name, 'Naruto');
  });

  test('ApiClient retries HTTP 429 with backoff until success', () async {
    var calls = 0;
    ApiClient.clientOverride = MockClient((req) async {
      calls++;
      return calls < 3
          ? http.Response('rate limited', 429)
          : http.Response('ok', 200);
    });
    ApiClient.rateLimitBaseDelay = Duration.zero;

    final res = await apiClient.get(Uri.parse('http://example.com/rate-limit'));
    expect(res.statusCode, 200);
    expect(calls, 3);
  });

  test('mergeEpisodes keeps video-source owner and drops AniList-only eps', () {
    final base = [
      Episode(
        number: '1',
        url: 'http://animefire/ep-1',
        source: AnimeSource.animeFire,
        owner: Anime(name: 'X', url: 'http://animefire/x'),
      ),
      Episode(
        number: '2',
        url: 'http://animefire/ep-2',
        source: AnimeSource.animeFire,
        owner: Anime(name: 'X', url: 'http://animefire/x'),
      ),
    ];
    final meta = [
      Episode(number: '1', url: '', title: 'Capítulo 1', thumbnail: 't1'),
      Episode(number: '99', url: '', title: 'sem stream'),
    ];
    final merged = AnimeScraper.mergeEpisodes(base, meta);
    expect(merged.length, 2, reason: 'AniList-only episode 99 must be dropped');
    expect(merged.first.title, 'Capítulo 1');
    expect(merged.first.thumbnail, 't1');
    expect(merged.first.url, 'http://animefire/ep-1');
    expect(merged.first.source, AnimeSource.animeFire);
    expect(merged.first.owner, isNotNull);
    expect(merged.map((e) => e.source).contains(AnimeSource.anilist), isFalse);
  });
}
