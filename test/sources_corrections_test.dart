import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:goanime_tv/core/network/api_client.dart';
import 'package:goanime_tv/core/sources/anime_source_adapter.dart';
import 'package:goanime_tv/core/sources/goyabu_adapter.dart';
import 'package:goanime_tv/core/utils/text_utils.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';

/// Regression tests for the source-correction plan (PLANO_ACAO_SOURCES.md):
/// clean search queries, HTTP 429 retry, and the adapter match contract.
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

  test('resolveAnime picks the best candidate by title match', () {
    // Regression for the old _findBySource/bestMatch flow, now living on the
    // adapter contract. Movies/spin-offs lose to the main series tie.
    final candidates = [
      Anime(name: 'One Piece Film: Red', url: '/filme-red', source: AnimeSource.animeFire),
      Anime(name: 'One Piece', url: '/one-piece/todos-os-episodios', source: AnimeSource.animeFire),
      Anime(name: 'One Piece', url: '/one-piece', source: AnimeSource.animeFire),
    ];
    final best = AnimeSourceAdapter.bestMatch(
        'One Piece', candidates, AnimeSource.animeFire);
    expect(best.url, '/one-piece/todos-os-episodios');
  });

  group('TextUtils.treatName', () {
    test('strips punctuation into a valid AnimeFire slug', () {
      expect(TextUtils.treatName('Naruto: Shippuuden'), 'naruto-shippuuden');
      expect(TextUtils.treatName('One Piece (dublado)'), 'one-piece-dublado');
      expect(TextUtils.treatName('Hunter × Hunter'), 'hunter-hunter');
      expect(TextUtils.treatName('One Piece'), 'one-piece');
      expect(TextUtils.treatName('  Double   Spaces  '), 'double-spaces');
    });
  });
}
