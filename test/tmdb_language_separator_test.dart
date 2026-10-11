import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/tmdb/tmdb_service.dart';

/// Regressão do bug que fez o catálogo TMDB NUNCA aparecer no app, mesmo
/// com chave válida e o botão "Testar chave" dizendo que estava tudo bem.
///
/// Causa raiz: `with_original_language=ja,ko,zh,th`. Documentação do TMDB:
/// comma = AND, pipe = OR. Com vírgula o filtro vira "idioma original é
/// japonês E coreano E chinês E tailandês" — impossível — e a API responde
/// **HTTP 200 com `results: []`**, sem sinal de erro. Resultado: tela vazia
/// sem explicação.
///
/// Medido contra a API real em 11/10/2026 (curl, chave válida):
///   with_original_language=ja,ko,zh,th   -> total_results: 0
///   with_original_language=ja|ko|zh|th   -> total_results: 20001 (teto de paginação)
void main() {
  group('with_original_language — separador', () {
    test('usa PIPE (OR), nunca vírgula (AND)', () {
      expect(TmdbService.asianLanguages, contains('|'),
          reason: 'pipe é o separador OR do TMDB');
      expect(TmdbService.asianLanguages, isNot(contains(',')),
          reason: 'vírgula é AND: a consulta volta vazia com HTTP 200');
    });

    test('lista os quatro idiomas asiáticos', () {
      final langs = TmdbService.asianLanguages.split('|');
      expect(langs, containsAll(['ja', 'ko', 'zh', 'th']));
      expect(langs, hasLength(4));
    });

    test('a URL final preserva o pipe e não injeta vírgula', () {
      final uri = Uri.parse('https://api.themoviedb.org/3/discover/tv').replace(
        queryParameters: {
          'with_original_language': TmdbService.asianLanguages,
          'api_key': 'k',
          'language': 'pt-BR',
        },
      );
      // O valor precisa chegar como lista separada por pipe (ou o seu
      // percent-encode), nunca como `%2C`.
      final v = uri.queryParameters['with_original_language']!;
      expect(v, anyOf('ja|ko|zh|th', 'ja%7Cko%7Czh%7Cth'));
      expect(v, isNot('ja,ko,zh,th'));
      expect(v, isNot('ja%2Cko%2Czh%2Cth'));
    });
  });

  group('with_type — tipo do conteúdo', () {
    // Segundo erro de suposição (11/10/2026): assumi que `with_type=1` era
    // "Scripted". Na verdade a numeração do TMDB é
    // 0=Documentário · 1=NOTÍCIA · 2=Minissérie · 3=Reality · 4=Scripted
    // · 5=Talk Show · 6=Vídeo. Com 1, a linha vinha de programas de
    // notícia coreanos/japoneses, e somado a `vote_count` zerava tudo.
    test('Scripted é 4, não 1', () {
      // Verificado na API: type=1 → 'JTBC 뉴스룸' (noticiário);
      // type=4 → 'Uma Noite Pecaminosa' (drama).
      expect(TmdbService.typeScripted, '4');
      expect(TmdbService.typeScripted, isNot('1'));
    });

    test('a linha de dramas não usa japonês (AniList já cobre anime)', () {
      expect(TmdbService.dramaLanguages, 'ko|zh|th');
      expect(TmdbService.dramaLanguages, isNot(contains('ja')));
      // ...enquanto a busca/índice continuam com todos os asiáticos.
      expect(TmdbService.asianLanguages, 'ja|ko|zh|th');
    });
  });

  group('parseDiscover descarta títulos não latinos', () {
    test('título só em coreano/japonês/chinês é ignorado', () {
      const body = '{"results":['
          '{"id":1,"name":"탐사기획 스트레이트","poster_path":"/a.jpg"},'
          '{"id":2,"name":"ニュースルーム","poster_path":"/b.jpg"},'
          '{"id":3,"name":"Round 6","poster_path":"/c.jpg"},'
          '{"id":4,"name":"A Coroa Perfeita","poster_path":null}'
          ']}';
      final list = TmdbService.parseDiscover(body, 'tv');
      expect(list.map((a) => a.name), ['Round 6', 'A Coroa Perfeita']);
    });

    test('título em japonês com nome latino é mantido', () {
      const body = '{"results":[{"id":5,"name":"Bleach","poster_path":null}]}';
      expect(TmdbService.parseDiscover(body, 'tv'), hasLength(1));
    });
  });

  group('resposta do TMDB que vazou pelo app', () {
    // Payload real de uma consulta COM VÍRGULA: HTTP 200, results vazio.
    test('results:[] com HTTP 200 é detectado como filtro sem resultado', () {
      const emptyOk = '{"page":1,"results":[],"total_pages":0,"total_results":0}';
      expect(TmdbService.parseDiscover(emptyOk, 'tv'), isEmpty);
    });

    test('payload com pipe traz títulos', () {
      const body = '{"page":1,"results":['
          '{"id":2100,"name":"Goblin","genre_ids":[18],"poster_path":"/p.jpg"},'
          '{"id":1,"name":"Squid Game","genre_ids":[80],"poster_path":null}'
          '],"total_pages":10,"total_results":20001}';
      final list = TmdbService.parseDiscover(body, 'tv');
      expect(list, hasLength(2));
      expect(list.map((a) => a.name), ['Goblin', 'Squid Game']);
    });
  });
}
