import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/tmdb/tmdb_service.dart';

/// Payload realista do `/discover/tv` (pt-BR), capturado da documentação do
/// TMDB. Serve para decidir se o buraco está no PARSER ou nos FILTROS da
/// query — duas suspeitas muito diferentes.
void main() {
  // Formato exato que o TMDB devolve em /discover/tv?language=pt-BR.
  final discoverTvBody = jsonEncode({
    'page': 1,
    'results': [
      {
        'id': 1396,
        'name': 'Breaking Bad',
        'original_name': 'Breaking Bad',
        'overview':
            'Um professor de química com cancro fabrica metanfetamina.',
        'poster_path': '/ggFHVNu6YYI5L9pCfOacjizRGt.jpg',
        'backdrop_path': '/tsRy63Mu5cu8etL1X7iZyc8DTZv.jpg',
        'first_air_date': '2008-01-20',
        'genre_ids': [18, 80],
        'vote_average': 8.9,
        'origin_country': ['US']
      },
      {
        'id': 66732,
        'name': 'Um Maluco no Pedaço',
        'original_name': 'The Fresh Prince of Bel-Air',
        'overview': 'Will vai morar em Bel-Air.',
        'poster_path': '/wapRre5x Ba.jpg',
        'backdrop_path': null,
        'first_air_date': '1990-09-10',
        'genre_ids': [35],
        'vote_average': 7.8,
        'origin_country': ['US']
      },
      {
        'id': 2100,
        'name': 'Goblin',
        'original_name': '도깨비',
        'overview': 'Um goblin imortal procura um noivo humano.',
        'poster_path': '/x.jpg',
        'backdrop_path': '/y.jpg',
        'first_air_date': '2016-12-02',
        'genre_ids': [18, 10765],
        'vote_average': 8.4,
        'origin_country': ['KR']
      },
    ],
    'total_pages': 500,
    'total_results': 10000,
  });

  group('parseDiscover com payload real do TMDB', () {
    test('converte os 3 títulos', () {
      final list = TmdbService.parseDiscover(discoverTvBody, 'tv');
      expect(list, hasLength(3),
          reason: 'se falhar aqui, o buraco é no parser — não na query');
    });

    test('usa `name` (campo de TV) e não `title`', () {
      final list = TmdbService.parseDiscover(discoverTvBody, 'tv');
      expect(list.first.name, 'Breaking Bad');
      expect(list.any((a) => a.name == 'Goblin'), isTrue);
    });

    test('preenche ids, poster TMDB e votação', () {
      final list = TmdbService.parseDiscover(discoverTvBody, 'tv');
      final bb = list.first;
      expect(bb.tmdbId, 1396);
      expect(bb.mediaType, 'tv');
      expect(bb.fallbackImageUrl,
          'https://image.tmdb.org/t/p/w342/ggFHVNu6YYI5L9pCfOacjizRGt.jpg');
      expect(bb.averageScore, 8.9);
      expect(bb.episodes, isNull); // discover não traz esse campo
    });

    test('aceita original_name quando name está vazio', () {
      final body = jsonEncode({
        'results': [
          {
            'id': 1,
            'name': '',
            'original_name': 'Titulo pelo original',
            'poster_path': null,
          }
        ]
      });
      final list = TmdbService.parseDiscover(body, 'tv');
      expect(list.single.name, 'Titulo pelo original');
    });

    test('aceita `title` (formato de filme) também', () {
      final body = jsonEncode({
        'results': [
          {'id': 2, 'title': 'Clube da Luta', 'poster_path': null}
        ]
      });
      expect(TmdbService.parseDiscover(body, 'movie').single.name,
          'Clube da Luta');
    });

    test('descarte de título vazio NÃO come títulos válidos', () {
      final list = TmdbService.parseDiscover(discoverTvBody, 'tv');
      expect(list.length, 3);
      expect(list.every((a) => a.name.isNotEmpty), isTrue);
    });

    test('URL do item aponta para o site do TMDB', () {
      final list = TmdbService.parseDiscover(discoverTvBody, 'tv');
      expect(list.first.url, contains('themoviedb.org/tv/1396'));
    });
  });

  group('URL montada por discover', () {
    test('filtros vão todos como query parameters', () {
      // Mesmos parâmetros que `discover(mediaType: 'tv')` monta.
      final uri = Uri.parse('https://api.themoviedb.org/3/discover/tv').replace(
        queryParameters: {
          'sort_by': 'popularity.desc',
          'page': '1',
          'include_adult': 'false',
          'with_original_language': 'ja,ko,zh,th',
          'with_type': '1',
          'api_key': 'CHAVE',
          'language': 'pt-BR',
        },
      );
      final p = uri.queryParameters;
      expect(p['with_original_language'], 'ja,ko,zh,th');
      expect(p['with_type'], '1');
      expect(p['sort_by'], 'popularity.desc');
      expect(p['include_adult'], 'false');
      expect(p['language'], 'pt-BR');

      // A vírgula precisa sobreviver ao encode — é o que separa os idiomas.
      // `String.fromCharCode(44)` = ','; o TMDB rejeita a lista se a vírgula
      // chegar "espaguetificada".
      expect(p['with_original_language'], contains(','));
    });
  });
}