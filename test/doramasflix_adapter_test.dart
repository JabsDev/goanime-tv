import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/doramasflix_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

/// Fixtures da GraphQL pública do Doramasflix capturadas em 10/10/2026.
void main() {
  String fx(String name) => File('test/fixtures/$name').readAsStringSync();

  group('DoramasflixAdapter parse — catálogo', () {
    test('searchDorama vira Anime com poster TMDB e gêneros', () {
      final list = DoramasflixAdapter.parseDoramas(fx('df_search.json'));
      expect(list, isNotEmpty);
      final goblin = list.first;
      expect(goblin.source, AnimeSource.doramasflix);
      expect(goblin.name, isNotEmpty);
      expect(goblin.fallbackImageUrl, startsWith('https://image.tmdb.org/t/p/w500/'));
      expect(goblin.genres, isNotEmpty);
      expect(goblin.episodes, isNotNull);
    });

    test('URL carrega o id do GraphQL (abre a lista de episódios)', () {
      final list = DoramasflixAdapter.parseDoramas(fx('df_search.json'));
      expect(list.first.url, startsWith('https://doramasflix.in/dorama/'));
    });

    test('aceita listDoramas também', () {
      final body = jsonEncode({
        'data': {
          'listDoramas': [
            {'_id': 'abc', 'name': 'C Drama X', 'poster_path': '/p.jpg'}
          ]
        }
      });
      final list = DoramasflixAdapter.parseDoramas(body);
      expect(list.single.name, 'C Drama X');
    });

    test('envelope com errors devolve vazio (a API responde 200 em erro)', () {
      final body = jsonEncode({
        'errors': [
          {'message': 'Cannot query field "country" on type "Serie".'}
        ],
        'data': null,
      });
      expect(DoramasflixAdapter.parseDoramas(body), isEmpty);
      expect(DoramasflixAdapter.parseEpisodes(body), isEmpty);
    });
  });

  group('DoramasflixAdapter parse — episódios', () {
    test('extrai episódios ordenados com página de vídeo', () {
      final eps = DoramasflixAdapter.parseEpisodes(fx('df_episodes.json'));
      expect(eps, isNotEmpty);
      expect(eps.first.url, startsWith('http'));
      expect(eps.first.source, AnimeSource.doramasflix);
      final nums = eps.map((e) => int.parse(e.number)).toList();
      expect(nums, [...nums]..sort());
    });

    test('prefere doramasyt e o idioma de menor código', () {
      const ep = {
        'episode_number': 1,
        'urls': [
          {'page': 'desconhecido', 'url': 'https://x.com/a', 'lang': '1'},
          {'page': 'doramasmp4', 'url': 'https://www25.doramasmp4.com/b/', 'lang': '13109'},
          {'page': 'doramasyt', 'url': 'https://www.doramasyt.com/c', 'lang': '13109'},
          {'page': 'doramasyt', 'url': 'https://www.doramasyt.com/d', 'lang': '38'},
        ]
      };
      final pick = DoramasflixAdapter.pickEpisodePage(ep);
      expect(pick!.url, 'https://www.doramasyt.com/d'); // tipo 38 > 13109
      expect(pick.lang, 'Latino');
    });

    test('hoster desconhecido nunca ganha de um conhecido', () {
      const ep = {
        'episode_number': 1,
        'urls': [
          {'page': 'zzz', 'url': 'https://a.com/1', 'lang': '38'},
          {'page': 'doramasyt', 'url': 'https://b.com/2', 'lang': '13109'},
        ]
      };
      expect(DoramasflixAdapter.pickEpisodePage(ep)!.url, 'https://b.com/2');
    });

    test('episódio sem urls fica sem URL em vez de sumir', () {
      final body = jsonEncode({
        'data': {
          'listEpisodes': [
            {'_id': 'e1', 'episode_number': 1, 'urls': []},
            {'_id': 'e2', 'episode_number': 2,
             'urls': [
               {'page': 'doramasyt', 'url': 'https://www.doramasyt.com/x', 'lang': '13109'}
             ]},
          ]
        }
      });
      final eps = DoramasflixAdapter.parseEpisodes(body);
      expect(eps, hasLength(2));
      expect(eps.first.url, isEmpty);
      expect(eps.last.url, isNotEmpty);
    });
  });

  group('DoramasflixAdapter — vídeo', () {
    test('getVideoSources devolve failure → app cai no WebView', () async {
      final adapter = DoramasflixAdapter();
      final res = await adapter.getVideoSources(
          Episode(number: '1', url: 'https://www.doramasyt.com/x'));
      expect(res, isA<Failure>());
    });

    test('watchUrlForMatched devolve a página do hoster', () async {
      final adapter = DoramasflixAdapter(
        client: MockClient((_) async => http.Response(
              File('test/fixtures/df_episodes.json').readAsStringSync(),
              200,
            )),
      );
      final url = await adapter.watchUrlForMatched(
        Anime(
            name: 'Goblin',
            url: 'https://doramasflix.in/dorama/5f2c3daaca7ff72d546e4982',
            source: AnimeSource.doramasflix),
        1,
      );
      expect(url, isNotNull);
      expect(url, startsWith('https://www.doramasyt.com/'));
    });
  });
}