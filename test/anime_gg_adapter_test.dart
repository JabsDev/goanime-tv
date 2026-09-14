import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/sources/anime_gg_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';

const _searchHtml = '''
<a href="/series/haibane-renmei" class="mse"><div class="media searchre">
<div class="media-body"><div class="first"><h2>Haibane Renmei</h2>
<p class="infoami"><div>Episodes: 13</div></p></div></div></div></a>
<a href="/series/haibane-renmei-dub" class="mse"><div class="media searchre">
<div class="media-body"><div class="first"><h2>Haibane Renmei Dub</h2>
<p class="infoami"><div>Episodes: 13</div></p></div></div></div></a>
''';

const _epHtml = '''
<a href="/haibane-renmei-episode-13">Episode 13</a>
<a href="/haibane-renmei-episode-1">Episode 1</a>
<a href="/haibane-renmei-episode-2">Episode 2</a>
<a href="/haibane-renmei-episode-1">Episode 1</a>
<a href="/haibane-renmei-dub-episode-1">Episode 1</a>
''';

const _embedHtml = '''
<div id="subbed-Animegg" class="tab-pane">
<iframe src="/embed/26743"></iframe></div>
<div id="dubbed-Animegg"><iframe src="/embed/26744"></iframe></div>
''';

const _playerHtml = '''
var videoSources = [{file: "/play/54112/video.mp4?for=1", label: "360p"},
{file: "/play/213281/video.mp4?for=1", label: "480p"}];
''';

void main() {
  group('AnimeGgAdapter parse', () {
    test('search extrai slug + título + eps', () {
      final res = AnimeGgAdapter.parseSearch(_searchHtml);
      expect(res, hasLength(2));
      expect(res.first.url,
          'https://www.animegg.org/series/haibane-renmei');
      expect(res.first.episodes, 13);
      expect(res.first.source, AnimeSource.animeGg);
    });

    test('episódios únicos do slug, ordenados', () {
      final eps =
          AnimeGgAdapter.parseEpisodes('haibane-renmei', _epHtml);
      expect(eps, hasLength(3)); // dub excluído, dup removido
      expect(eps.first.$2, 1);
      expect(eps.last.$2, 13);
    });

    test('embed pega a aba SUB', () {
      expect(AnimeGgAdapter.parseSubEmbed(_embedHtml), '/embed/26743');
      expect(AnimeGgAdapter.parseSubEmbed('<html></html>'), isNull);
    });

    test('player extrai mp4 absoluto + qualidade + referer', () {
      final vids = AnimeGgAdapter.parseEmbed(
          'https://www.animegg.org/embed/26743', _playerHtml);
      expect(vids, hasLength(2));
      expect(vids.first.url,
          'https://www.animegg.org/play/54112/video.mp4?for=1');
      expect(vids.first.quality, '360p');
      expect(vids.first.headers['Referer'],
          'https://www.animegg.org/embed/26743');
      expect(vids.first.subtitleCandidates, isEmpty);
    });
  });
}
