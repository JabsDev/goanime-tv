import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/catalog/catalog_browse_service.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/tmdb/tmdb_service.dart';
import 'package:goanime_tv/data/models/anime.dart';

Anime _a(String name, {String? type, int? tmdb, int? al}) => Anime(
      name: name,
      url: 'https://x/$name',
      source: AnimeSource.anilist,
      mediaType: type,
      tmdbId: tmdb,
      anilistId: al,
    );

void main() {
  group('Chave TMDB — validação', () {
    test('rejeita vazio', () {
      expect(SettingsService.validateTmdbKey('  '), isNotNull);
    });

    test('rejeita tamanho/formato errado', () {
      expect(SettingsService.validateTmdbKey('abc'), isNotNull);
      expect(
        SettingsService.validateTmdbKey('z' * 32), // não é hex
        isNotNull,
      );
      expect(SettingsService.validateTmdbKey('a' * 31), isNotNull);
    });

    test('aceita hex de 32, com ou sem maiúsculas/espaços', () {
      final hex32 = '0123456789abcdef0123456789abcdef';
      expect(SettingsService.validateTmdbKey(hex32), isNull);
      expect(SettingsService.validateTmdbKey('  $hex32  '), isNull);
      expect(
        SettingsService.validateTmdbKey(hex32.toUpperCase()),
        isNull,
      );
    });
  });

  group('TMDB parse', () {
    test('search/multi mantém tv/movie e descarta person', () {
      final body = jsonEncode({
        'results': [
          {
            'id': 1396,
            'name': 'Breaking Bad',
            'media_type': 'tv',
            'poster_path': '/p.jpg',
            'overview': 'Químico.',
            'first_air_date': '2008-01-20',
            'genre_ids': [18, 80],
            'vote_average': 9.5,
          },
          {
            'id': 550,
            'title': 'Fight Club',
            'media_type': 'movie',
            'poster_path': null,
          },
          {'id': 1, 'name': 'Actor', 'media_type': 'person'},
        ]
      });
      final list = TmdbService.parseSearchMulti(body);
      expect(list, hasLength(2));
      expect(list[0].tmdbId, 1396);
      expect(list[0].mediaType, 'tv');
      expect(list[0].fallbackImageUrl, contains('/w342/p.jpg'));
      expect(list[1].mediaType, 'movie');
      // sem poster_path → sem imagem, e não deve quebrar
      expect(list[1].fallbackImageUrl, isNull);
    });

    test('descarta entrada sem id ou sem título', () {
      final body = jsonEncode({
        'results': [
          {'name': 'Sem id', 'media_type': 'tv'},
          {'id': 7, 'media_type': 'tv'},
        ]
      });
      expect(TmdbService.parseSearchMulti(body), isEmpty);
    });

    test('discover mapeia mediaType do parâmetro', () {
      final body = jsonEncode({
        'results': [
          {'id': 1, 'name': 'K drama', 'poster_path': '/a.jpg'}
        ]
      });
      final list = TmdbService.parseDiscover(body, 'tv');
      expect(list.single.mediaType, 'tv');
    });

    test('parseGenres devolve id → nome', () {
      final body = jsonEncode({
        'genres': [
          {'id': 18, 'name': 'Drama'},
          {'id': 10765, 'name': 'Sci-Fi & Fantasy'},
        ]
      });
      final g = TmdbService.parseGenres(body);
      expect(g[18], 'Drama');
      expect(g[10765], 'Sci-Fi & Fantasy');
    });

    test('nameGenres troca id numérico por nome', () {
      final items = [_a('X', type: 'tv')..genres = ['18', '80']];
      final out =
          TmdbService.nameGenres(items, {18: 'Drama', 80: 'Crime'});
      expect(out.single.genres, ['Drama', 'Crime']);
    });

    test('payload de erro não vira lista', () {
      expect(TmdbService.parseSearchMulti('{"status_code":7}'), isEmpty);
      expect(TmdbService.parseSearchMulti('nao json'), isEmpty);
    });
  });

  group('Letra — letterOf', () {
    test('letra simples', () {
      expect(CatalogBrowseService.letterOf('Naruto'), 'n');
      expect(CatalogBrowseService.letterOf('Bleach'), 'b');
    });

    test('artigos iniciais não viram a letra', () {
      expect(CatalogBrowseService.letterOf('The Godfather'), 'g');
      expect(CatalogBrowseService.letterOf('A Quiet Place'), 'q');
      expect(CatalogBrowseService.letterOf('An Attack on Titan'), 'a');
    });

    test('símbolo inicial não rouba a letra real', () {
      // `°Celsius` indexa em C (o `°` é decoração), não em '#'.
      expect(CatalogBrowseService.letterOf('°Celsius'), 'c');
      // número de verdade é '#'
      expect(CatalogBrowseService.letterOf('86'), '#');
      expect(CatalogBrowseService.letterOf('1 Piece'), '#');
    });

    test('acento não quebra a letra', () {
      expect(CatalogBrowseService.letterOf('Átama no Doubt'), 'a');
    });

    test('título vazio não estoura', () {
      expect(CatalogBrowseService.letterOf(''), '#');
    });
  });

  group('Alfabeto — índice', () {
    final items = [
      _a('Naruto'),
      _a('Naruto Shippuden'),
      _a('Bleach'),
      _a('86'),
      _a('Átama'),
      _a('The Walking Dead'),
    ];

    test('lettersOf ordena A-Z e # no fim', () {
      // "The Walking Dead" indexa em W (artigo removido), senão o índice
      // vira um bloco enorme de "The…".
      final letters = CatalogBrowseService.lettersOf(items);
      expect(letters, ['a', 'b', 'n', 'w', '#']);
      expect(letters.last, '#');
    });

    test('byLetter filtra e ordena alfabeticamente', () {
      final n = CatalogBrowseService.byLetter(items, 'n');
      expect(n.map((a) => a.name), ['Naruto', 'Naruto Shippuden']);
      expect(CatalogBrowseService.byLetter(items, 'b').single.name, 'Bleach');
    });

    test('byLetter com letra vazia devolve vazio', () {
      expect(CatalogBrowseService.byLetter(items, 'z'), isEmpty);
    });
  });

  group('Dedup entre catálogos', () {
    test('mesma série com sufixo colapsa num card', () {
      final a = _a('Goblin', type: 'tv', tmdb: 1);
      final b = _a('Goblin (Korean Drama)', type: 'anime', al: 2);
      expect(CatalogBrowseService.dedupKey(a),
          CatalogBrowseService.dedupKey(b));
      expect(CatalogBrowseService.merge([a], [b]), hasLength(1));
    });

    test('títulos diferentes não colapsam', () {
      final merged = CatalogBrowseService.merge(
          [_a('Dune', type: 'movie', tmdb: 1)],
          [_a('Dune: Part Two', type: 'movie', tmdb: 2)]);
      expect(merged, hasLength(2));
    });

    test('merge mantém a ordem do primário', () {
      final merged = CatalogBrowseService.merge(
          [_a('B', al: 1), _a('A', al: 2)],
          [_a('C', tmdb: 3)]);
      expect(merged.map((x) => x.name), ['B', 'A', 'C']);
    });

    test('merge descarta título vazio', () {
      expect(CatalogBrowseService.merge([_a('')], [_a('X')]), hasLength(1));
    });
  });

  group('Índice — serialização', () {
    test('encode/decode preserva id, tipo e imagem', () {
      final raw = CatalogBrowseService.encodeIndex([
        _a('Goblin', type: 'tv', tmdb: 99)..fallbackImageUrl = 'http://i/p.jpg',
        _a('Naruto', type: 'anime', al: 21),
      ]);
      final back = CatalogBrowseService.decodeIndex(raw);
      expect(back, hasLength(2));
      expect(back[0].tmdbId, 99);
      expect(back[0].mediaType, 'tv');
      expect(back[0].fallbackImageUrl, 'http://i/p.jpg');
      expect(back[1].anilistId, 21);
    });

    test('lixo serializado devolve lista vazia, não exceção', () {
      expect(CatalogBrowseService.decodeIndex('nao json'), isEmpty);
    });

    test('entrada sem nome é filtrada na volta', () {
      final raw = jsonEncode([
        {'name': 'Ok', 'tmdb': '1'},
        {'name': '', 'tmdb': '2'},
      ]);
      expect(CatalogBrowseService.decodeIndex(raw), hasLength(1));
    });
  });

  group('Categorias', () {
    test('AniList sempre; TMDB aparece porque há chave padrão', () async {
      // A chave padrão está embutida no app, então as categorias TMDB
      // existem mesmo sem o usuário configurar nada.
      final cats = await CatalogBrowseService.categories();
      expect(cats, isNotEmpty);
      expect(cats.any((c) => c.anilistGenre != null), isTrue);
      expect(cats.any((c) => c.isTmdb), isTrue);
    });

    test('categorias AniList têm rótulo legível e único', () async {
      final cats = await CatalogBrowseService.categories();
      final ids = cats.map((c) => c.id).toSet();
      expect(ids.length, cats.length, reason: 'ids duplicados quebram o Wrap');
      for (final c in cats.where((c) => c.anilistGenre != null)) {
        expect(c.label, isNotEmpty);
        expect(c.anilistGenre, isNotEmpty);
      }
    });

    // Live: valida a query GraphQL de gênero ponta a ponta. O resto do
    // arquivo é puro, mas uma query com nome de variável errado voltaria
    // vazia sem erro visível — foi exatamente o modo de falha que derrubou
    // o TMDB na v1.5.0.
    test('itemsOf devolve títulos reais para uma categoria AniList', () async {
      const drama = BrowseCategory(
          id: 'anilist:Drama', label: 'Drama', anilistGenre: 'Drama');
      final items = await CatalogBrowseService.itemsOf(drama);
      expect(items, isNotEmpty, reason: 'categoria AniList voltou vazia');
      expect(items.length, greaterThan(5));
      // Todo item tem id do AniList (é o que abre o detalhe).
      expect(items.every((a) => a.anilistId != null), isTrue,
          reason: 'sem anilistId o card não abre detalhe');
      // E todos são de verdade do gênero pedido.
      expect(items.every((a) => a.genres.contains('Drama')), isTrue,
          reason: 'filtro de gênero não aplicado');
      expect(items.first.name, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('itemsOf de categoria TMDB sem chave devolve só o que houver', () async {
      const cat = BrowseCategory(
        id: 'tmdb:tv:18',
        label: 'Drama',
        tmdbGenre: 18,
        mediaType: 'tv',
      );
      // Sem chave configurada, o TMDB é ignorado silenciosamente: não pode
      // lançar nem estourar a tela.
      final items = await CatalogBrowseService.itemsOf(cat);
      expect(items, isNotNull);
    });
  });
}