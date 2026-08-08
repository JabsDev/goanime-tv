import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';
import 'package:goanime_tv/core/cache/app_caches.dart';
import 'package:goanime_tv/data/models/anime.dart';

/// Fase 5/6 self-checks: rate-limit (pool de 6) e status categorizado.
/// Exercita o serviço via `httpOverride` (mock), sem rede.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Response okJson(String json) => http.Response.bytes(
        utf8.encode(json),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  String mediaJson({
    String romaji = 'Naruto',
    String? english,
    String? native,
  }) {
    return jsonEncode({
      'data': {
        'Media': {
          'id': 1,
          'title': {'romaji': romaji, 'english': english, 'native': native},
        },
      },
    });
  }

  setUp(() {
    AppCaches.clearAll();
    AniListService.lastErrorStatus = AniListStatus.ok;
    AniListService.anilistRequestGap = const Duration(milliseconds: 2);
  });

  tearDown(() {
    AniListService.httpOverride = null;
    AniListService.anilistRequestGap = const Duration(milliseconds: 800);
  });

  test('getTitleVariants retorna romaji/english/native e exclui a query', () async {
    AniListService.httpOverride = MockClient((req) async {
      return okJson(mediaJson(
        romaji: 'Kimetsu no Yaiba',
        english: 'Demon Slayer',
        native: '鬼滅の刃',
      ));
    });
    final variants = await AniListService.getTitleVariants('demon slayer');
    expect(variants, contains('Demon Slayer'));
    expect(variants, contains('Kimetsu no Yaiba'));
    expect(variants, isNot(contains('demon slayer'))); // query limpa removida
    expect(AniListService.lastErrorStatus, AniListStatus.ok);
  });

  test('429 mapeia para rateLimited e limpa com o próximo sucesso', () async {
    var calls = 0;
    AniListService.httpOverride = MockClient((req) async {
      calls++;
      if (calls == 1) return http.Response('rate limit', 429);
      return okJson(mediaJson());
    });
    final first = await AniListService.getTitleVariants('one piece');
    expect(first, isEmpty);
    expect(AniListService.lastErrorStatus, AniListStatus.rateLimited);

    // Próximo sucesso reseta o status (banner da Home some).
    await AniListService.getTitleVariants('one piece 2');
    expect(AniListService.lastErrorStatus, AniListStatus.ok);
  });

  test('enrichBatch limita concorrência ao pool de 6', () async {
    var active = 0;
    var maxActive = 0;
    AniListService.httpOverride = MockClient((req) async {
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      active--;
      return okJson(mediaJson());
    });

    final animes = [
      for (var i = 0; i < 12; i++)
        Anime(name: 'Anime $i', url: '', source: AnimeSource.animeFire),
    ];
    await AniListService.enrichBatch(animes);

    expect(maxActive, lessThanOrEqualTo(6), reason: 'pool deveria limitar');
    expect(animes.where((a) => a.anilistId != null).length, 12,
        reason: 'todos enriquecidos');
    expect(AniListService.lastErrorStatus, AniListStatus.ok);
  });

  test('getTitleVariants reusa detalhe já cacheado (sem rede)', () async {
    // Popula o cache de enrichment como `enrich` faria: o card do scraper vem
    // como romaji e o enriquecimento grava o englishName alternativo.
    final anime = Anime(
      name: 'Shingeki no Kyojin',
      url: '',
      source: AnimeSource.animeFire,
    );
    AniListService.httpOverride = MockClient((req) async {
      return okJson(mediaJson(
        romaji: 'Shingeki no Kyojin',
        english: 'Attack on Titan',
      ));
    });
    await AniListService.enrich(anime);

    var networkCalls = 0;
    AniListService.httpOverride = MockClient((req) async {
      networkCalls++;
      return okJson(mediaJson());
    });
    // Mesmo título já cacheado por `enrich` (mesmo cleanTitle preserva case) —
    // o lookup de variantes deve reusar o detalhe sem subir a rede.
    final variants = await AniListService.getTitleVariants('Shingeki no Kyojin');
    expect(networkCalls, 0, reason: 'deve vir do cache de enrichment');
    expect(variants, contains('Attack on Titan'));
  });
}
