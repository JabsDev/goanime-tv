import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/sources/donghua_no_sekai_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';

/// Fixtures capturadas ao vivo em 10/10/2026.
/// Ver `relatorio-novas-fontes-asia-2026-10-10.md` §2.
void main() {
  String fx(String name) => File('test/fixtures/$name').readAsStringSync();

  group('DonghuaNoSekai parse — busca', () {
    test('extrai séries com título, thumb e gêneros', () {
      final list = DonghuaNoSekaiAdapter.parseSearch(fx('dnsk_search.html'));
      expect(list, isNotEmpty);

      final curse = list.firstWhere((a) => a.url.endsWith('/golden-curse'));
      expect(curse.source, AnimeSource.donghuaNoSekai);
      expect(curse.name, isNotEmpty);
      expect(curse.url, 'https://donghuanosekai.com/golden-curse');
      expect(curse.genres, isNotEmpty);
    });

    test('descarta páginas de episódio dos resultados', () {
      final list = DonghuaNoSekaiAdapter.parseSearch(fx('dnsk_search.html'));
      // `golden-curse-episodio-06` aparece no HTML da busca mas é episódio.
      expect(list.any((a) => a.url.contains('episodio')), isFalse);
    });

    test('descarta rotas institucionais', () {
      final list = DonghuaNoSekaiAdapter.parseSearch(fx('dnsk_search.html'));
      for (final a in list) {
        expect(a.url, isNot(contains('/contato')));
        expect(a.url, isNot(contains('/feed')));
        expect(a.url, isNot(contains('/donghuas')));
      }
    });

    test('slugOf só aceita página de série', () {
      expect(DonghuaNoSekaiAdapter.slugOf('https://donghuanosekai.com/swallowed-star'),
          'swallowed-star');
      expect(DonghuaNoSekaiAdapter.slugOf(
          'https://donghuanosekai.com/swallowed-star-episodio-1'), isNull);
      expect(DonghuaNoSekaiAdapter.slugOf(''), isNull);
    });
  });

  group('DonghuaNoSekai parse — episódios', () {
    test('extrai os episódios da própria série', () {
      final eps = DonghuaNoSekaiAdapter.parseEpisodes(
          fx('dnsk_series.html'), 'swallowed-star');
      expect(eps, isNotEmpty);
      expect(eps.first.number, '1');
      expect(eps.first.url,
          startsWith('https://donghuanosekai.com/swallowed-star-episodio-'));
      expect(eps.first.source, AnimeSource.donghuaNoSekai);
    });

    test('ignora links de outras séries (sidebar)', () {
      final eps = DonghuaNoSekaiAdapter.parseEpisodes(
          fx('dnsk_series.html'), 'swallowed-star');
      for (final e in eps) {
        expect(e.url, startsWith('https://donghuanosekai.com/swallowed-star-episodio'));
      }
    });

    test('pares consecutivos viram alias do mesmo episódio', () {
      // `379-380` publica os dois de uma vez: ambos devem existir e
      // apontar para a MESMA página.
      final html =
          '<a href="https://donghuanosekai.com/x-episodio-379-380">a</a>'
          '<a href="https://donghuanosekai.com/x-episodio-5">b</a>';
      final eps = DonghuaNoSekaiAdapter.parseEpisodes(html, 'x');
      final byNum = {for (final e in eps) e.number: e.url};
      expect(byNum.keys.toSet(), {'5', '379', '380'});
      expect(byNum['379'], byNum['380']);
    });

    test('pares NÃO consecutivos não viram alias', () {
      final html = '<a href="https://donghuanosekai.com/x-episodio-13-178">a</a>';
      final eps = DonghuaNoSekaiAdapter.parseEpisodes(html, 'x');
      expect(eps.single.number, '178');
    });

    test('números ordenados', () {
      final html = '''
      <a href="https://donghuanosekai.com/x-episodio-10">c</a>
      <a href="https://donghuanosekai.com/x-episodio-2">a</a>
      <a href="https://donghuanosekai.com/x-episodio-1">b</a>
      ''';
      final eps = DonghuaNoSekaiAdapter.parseEpisodes(html, 'x');
      expect(eps.map((e) => e.number), ['1', '2', '10']);
    });
  });

  group('DonghuaNoSekai parse — player/HLS', () {
    test('lê os data-video-url e põe o tipo 0 na frente', () {
      final players = DonghuaNoSekaiAdapter.parsePlayerUrls(fx('dnsk_ep.html'));
      expect(players, isNotEmpty);
      expect(players.first, contains('type=0'));
      expect(players.first, contains('/player?file='));
    });

    test('extrai o HLS do iframe do /player (base64 decodificado)', () {
      final hls = DonghuaNoSekaiAdapter.parseHls(fx('dnsk_player.html'));
      expect(hls, isNotNull);
      expect(hls, contains('.m3u8'));
      expect(hls, startsWith('http'));
    });

    test('player vazio devolve null em vez de URL quebrada', () {
      expect(
        DonghuaNoSekaiAdapter.parseHls('haha parece que não tem nada!'),
        isNull,
      );
    });

    test('qualidade vem do nome do arquivo no CDN', () {
      expect(
        DonghuaNoSekaiAdapter.qualityOf(
            'https://cdn.example/stream/243_1080p_abc.mp4/index.m3u8'),
        '1080p',
      );
      expect(
        DonghuaNoSekaiAdapter.qualityOf('https://cdn.example/x/index.m3u8'),
        'Auto',
      );
    });
  });
}