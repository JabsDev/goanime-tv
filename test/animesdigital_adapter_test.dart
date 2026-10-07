import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/sources/animesdigital_adapter.dart';
import 'package:goanime_tv/core/sources/anime_source_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

/// Fixture HTML mínimo do animesdigital.org (recortado do site real 07/10/2026;
/// classes/chaves exatamente como o tema rende).
String searchHtml() => '''
<html><body>
<div class="itemA"><a href="https://animesdigital.org/anime/a/one-piece" title="Assistir One Piece Online em HD">
<div class="thumb"><img src="x.jpg" alt="Assistir One Piece Online em HD" title="Assistir One Piece Online em HD"></div>
<div class="title"><span class="title_anime">One Piece</span></div></a></div>
<div class="itemA"><a href="https://animesdigital.org/anime/a/one-piece-dublado" title="Assistir One Piece Dublado Online em HD">
<div class="title"><span class="title_anime">One Piece Dublado</span></div></a></div>
<div class="itemA"><a href="https://animesdigital.org/anime/a/black-clover-2" title="Assistir Black Clover Dublado Online em HD">
<div class="title"><span class="title_anime">Black Clover Dublado</span></div></a></div>
</body></html>''';

String animePageHtml({required List<String> eps, String? nextPage}) =>
    '''
<div class="lista_episodes" data-nosnippet>
<div class="itens_ep">
${eps.map((t) => '''
<div class="item_ep b_flex"><a href="https://animesdigital.org/video/a/${_epId(t)}" class="b_flex">
<div class="thumb"><img src="t.jpg" alt="$t" title="$t"></div>
<div class="dados b_flex"><div class="left"><div class="title_anime">$t</div><div class="date">3 anos atrás</div></div></div></a></div>''').join()}
</div>
</div>
${nextPage != null ? '<a href="https://animesdigital.org/anime/a/one-piece-dublado/page/$nextPage/">Próxima</a>' : ''}
</div>''';

String _epId(String title) {
  // resolves 'One Piece Dublado Episódio 877' → id; estabilidade p/ testes:
  final n = RegExp(r'Epis[óo]dio\s+(\d+)').firstMatch(title)?.group(1) ?? '1';
  const letters = 'abcdefghijklmnopqrstuvwxyz0123456789';
  var sum = 0;
  for (var i = 0; i < n.length; i++) {
    sum = sum * 10 + int.parse(n[i]);
  }
  return 'v$sum';
}

String videoPageHtml(int postId,
        {required String? p1token, required String? p2token}) =>
    '''
<div id="player1" class="tab-video" data-id="$postId" data-video="1">
${p1token == null ? '' : '<a class="ad-protected-cover" href="https://investcentro.com/campaign.php?token=$p1token&amp;x=1" target="_blank"></a>'}
</div>
<div id="player2" class="tab-video" data-id="$postId" data-video="2">
${p2token == null ? '' : '<a class="ad-protected-cover" href="https://investcentro.com/campaign.php?token=$p2token&amp;x=2" target="_blank"></a>'}
</div>''';

String stCodePage(String m3u8) => '''
<script>jwplayer.key="k";</script>
<div id="video-player"></div>
<script>
var player = jwplayer('video-player');
const playerInstance = jwplayer('video-player').setup({
    playlist: [{
        sources: [{
            type: "video/mp4",
            label: "720p HD",
            file: '$m3u8'
        }]
    }]
});
</script>''';

const cdnM3u8 = 'https://cdn-sv01.maximaimg.online/stream/o/x/08.mp4/index.m3u8';

http.Response _html(String body, {int code = 200}) =>
    http.Response(body, code, headers: {'content-type': 'text/html'});

MockClient _clientWith(Map<String, http.Response Function(http.Request)> map) {
  return MockClient((req) async {
    final key = req.url.toString();
    for (final pattern in map.keys) {
      if (key.contains(pattern)) return map[pattern]!(req);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseSearch', () {
    test('extrai título PT do card e deduplica por url', () {
      final list = AnimesDigitalAdapter.parseSearch(searchHtml());
      expect(list, hasLength(3));
      expect(list[0].name, 'One Piece');
      expect(list[0].url,
          'https://animesdigital.org/anime/a/one-piece');
      expect(list[0].source, AnimeSource.animesDigital);
      expect(list[1].name, 'One Piece Dublado');
      // A variante mantém o "Dublado" (sinal de áudio da fonte).
      expect(list[2].name, 'Black Clover Dublado');
    });
  });

  group('parseEpisodePage', () {
    test('numera pelo "Episódio N" do título e ignora template de load', () {
      final items = AnimesDigitalAdapter.parseEpisodePage(animePageHtml(
        eps: [
          'One Piece Dublado Episódio 877',
          'One Piece Dublado Episódio 876',
        ],
      ));
      expect(items, hasLength(2));
      expect(items[0].$2, '877');
      expect(items[1].$2, '876');
      // Áudio: "Dublado" no título cru.
      expect(items[0].$3.toLowerCase(), contains('dublado'));
    });

    test('item sem "Episódio" (filme) → número 1', () {
      final items = AnimesDigitalAdapter.parseEpisodePage(
          animePageHtml(eps: ['Black Clover: Mahou Tei no Ken Movie']));
      expect(items.single.$2, '1');
    });

    test('página sem .itens_ep devolve vazio (não explode)', () {
      expect(AnimesDigitalAdapter.parseEpisodePage('<html></html>'), isEmpty);
    });
  });

  group('parece título limpo (search)', () {
    test('limpa o wrapper do site', () {
      expect(AnimesDigitalAdapter.cleanCardTitle('Assistir X Online em HD'),
          'X');
      expect(
          AnimesDigitalAdapter.cleanCardTitle(
              'Assistir X Todos os Episodios Online HD'),
          'X');
    });
  });

  group('cobertura de áudio', () {
    test('audioOf marca dublado/legendado pelo nome', () {
      expect(AnimesDigitalAdapter.audioOf('One Piece Dublado'), 'dublado');
      expect(
          AnimesDigitalAdapter.audioOf('Nia Liston: The Merciless Maiden'),
          isNull);
    });
  });
}
