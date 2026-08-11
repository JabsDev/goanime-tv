import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/animesonline_adapter.dart';
import 'package:goanime_tv/core/sources/dooplay_v2_extractor.dart';
import 'package:goanime_tv/core/sources/source_registry.dart';

const _cloud = 'https://animesonline.cloud';
const _soloSource =
    'https%3A%2F%2Fmangas.cloud%2FAnimes%2FLetra-S%2FSolo%2520Leveling%2F01.mp4';
const _mangas =
    'https://mangas.cloud/Animes/Letra-S/Solo%20Leveling/01.mp4';

http.Response _ok(String body, {int status = 200}) =>
    http.Response(body, status, headers: {'content-type': 'text/html'});

http.Response _json(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

http.Response _mp4Payload([String source = _soloSource]) => _json(
    '{"embed_url":"https://animesonline.cloud/jwplayer?source=$source&id=1559&type=mp4","type":"mp4"}');
http.Response _iframe(String u) => _json('{"embed_url":"$u","type":"iframe"}');

/// 206 range probe response; path must match the second segment exactly.
http.Response _probe(String path) => http.Response(
    'x',
    206,
    headers: {'content-range': 'bytes 0-0/125505938'});

void main() {
  String fx(String name) => File('test/fixtures/$name').readAsStringSync();

  test('mp4FromEmbed decodes source exactly once (P4), rejects b64 (P8)', () {
    expect(
      DooPlayV2Extractor.mp4FromEmbed(
          '$_cloud/jwplayer?source=$_soloSource&id=1559&type=mp4'),
      _mangas,
    );
    // Double-encoded colon: single decode keeps `%3A` visible to the player.
    expect(
      DooPlayV2Extractor.mp4FromEmbed(
          '$_cloud/jwplayer?source=https%3A%2F%2Fmangas.cloud%2FAnimes%2FKimetsu%2520no%2520Yaiba%253A%2520Hashira%2520Geiko-hen%2F01-sd.mp4'),
      'https://mangas.cloud/Animes/Kimetsu%20no%20Yaiba%3A%20Hashira%20Geiko-hen/01-sd.mp4',
    );
    // Blogger/blogger SPA → not a direct stream.
    expect(DooPlayV2Extractor.mp4FromEmbed('https://www.blogger.com/video.g?token=AD6v5'),
        isNull);
    // base64 obfuscated source → legacy resolver, not a direct mp4.
    expect(
        DooPlayV2Extractor.mp4FromEmbed(
            'https://betteranime.io/jwplayer?source=abc%2Bdef%3D%3D&type=mp4'),
        isNull);
  });

  test('search filters /anime/ results (P9) and parses .result-item', () async {
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animesOnlineCloud,
      client: MockClient((req) async => _ok(fx('animesonline_search.html'))),
    );
    final result = await adapter.search('solo leveling');
    expect(result, isA<Success<List<Anime>>>());
    final data = (result as Success<List<Anime>>).data;
    // The /filme/ card is excluded; the two /anime/ cards survive.
    expect(data.length, 2);
    for (final a in data) {
      expect(a.url, contains('/anime/'));
    }
    expect(data.map((a) => a.name), everyElement('Solo Leveling'));
  });

  test('getEpisodes parses .episode-card ordered by data-episode-number', () async {
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animesOnlineCloud,
      client: MockClient((req) async => _ok(fx('animesonline_anime.html'))),
    );
    final result = await adapter.getEpisodes(
      Anime(name: 'Solo Leveling', url: '$_cloud/anime/solo-leveling'),
    );
    expect(result, isA<Success<List<Episode>>>());
    final eps = (result as Success<List<Episode>>).data;
    expect(eps.map((e) => int.parse(e.number)).toList(), [1, 2, 10]);
    expect(eps.first.url, '$_cloud/episodio/solo-leveling-episodio-01');
  });

  test('getVideoSources wp_json: mp4 in 2nd option wins (P1), all 206-checked (P6)',
      () async {
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animesOnlineCloud,
      client: MockClient((req) async {
        if (req.url.path == '/episodio/solo-leveling-episodio-01') {
          return _ok(fx('animesonline_episode.html'));
        }
        if (req.url.path.startsWith('/wp-json/dooplayer/v2/1559/tv/')) {
          final n = req.url.path.split('/').last;
          switch (n) {
            case '1':
              return _iframe('https://www.blogger.com/video.g?token=AD6v5');
            case '2':
              return _mp4Payload();
            case '3':
              return _iframe('https://animeshd.cloud/#e9ntgf');
            case '4':
              return _iframe('https://animes.strp2p.com/#osl9to');
          }
        }
        if (req.url.path.endsWith('.mp4')) return _probe(req.url.path);
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '1', url: '$_cloud/episodio/solo-leveling-episodio-01'),
      anime: Anime(name: 'Solo Leveling', url: '$_cloud/anime/solo-leveling'),
    );
    expect(result, isA<Success<List<VideoSource>>>());
    final sources = (result as Success<List<VideoSource>>).data;
    expect(sources.single.url, _mangas); // decoded once, never literal space
    expect(sources.single.headers['Referer'], '$_cloud/');
  });

  test('getVideoSources admin_ajax (animeplay.cloud) resolves same JSON (P3)',
      () async {
    const base = 'https://animeplay.cloud';
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animePlay,
      client: MockClient((req) async {
        if (req.url.host == 'animeplay.cloud' &&
            req.url.path == '/episodio/solo-leveling-episodio-01') {
          return _ok(fx('animesonline_episode_adminajax.html'));
        }
        if (req.url.host == 'animeplay.cloud' &&
            req.url.path == '/wp-admin/admin-ajax.php') {
          expect(req.body, contains('action=doo_player_ajax'));
          expect(req.body, contains('post=1559'));
          expect(req.body, contains('nume=2'));
          return _mp4Payload(
              'https%3A%2F%2Fmangas.cloud%2FAnimes%2FLetra-S%2FSolo%2520Leveling%2F01.mp4');
        }
        if (req.url.path.endsWith('.mp4')) return _probe(req.url.path);
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '1', url: '$base/episodio/solo-leveling-episodio-01'),
    );
    expect(result, isA<Success<List<VideoSource>>>());
    expect((result as Success<List<VideoSource>>).data.single.url, _mangas);
  });

  test('all options iframe → Failure (no 404 video is ever offered)', () async {
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animesOnlineCloud,
      client: MockClient((req) async {
        if (req.url.path == '/episodio/x-episodio-01') {
          return _ok(fx('animesonline_episode.html'));
        }
        if (req.url.path.startsWith('/wp-json/dooplayer/v2/')) {
          return _iframe('https://www.blogger.com/video.g?token=X');
        }
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '1', url: '$_cloud/episodio/x-episodio-01'),
      anime: Anime(name: 'X', url: '$_cloud/anime/x'),
    );
    expect(result, isA<Failure<List<VideoSource>>>());
  });

  test('Layer B CDN fallback when Layer A has no playable option (P7)', () async {
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animesOnlineCloud,
      client: MockClient((req) async {
        // Empty episode page → no player options → extractor throws.
        if (req.url.path == '/episodio/solo-leveling-episodio-01') {
          return _ok('<html><body>nada</body></html>');
        }
        // CDN probe: only the exact Solo Leveling path answers 206.
        if (req.url.path.endsWith('Solo%20Leveling/01.mp4')) {
          return _probe(req.url.path);
        }
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '1', url: '$_cloud/episodio/solo-leveling-episodio-01'),
      anime: Anime(name: 'Solo Leveling', url: '$_cloud/anime/solo-leveling'),
    );
    expect(result, isA<Success<List<VideoSource>>>());
    expect((result as Success<List<VideoSource>>).data.single.url,
        'https://mangas.cloud/Animes/Letra-S/Solo Leveling/01.mp4');
  });

  test('resolveAnime prefers English title to beat S2/spin-off ordering (P12)',
      () async {
    // Mirrors the site's real result order for a romaji query: S2 first.
    String card(String slug, String title) =>
        '<div class="result-item"><article><div class="image">'
        '<a href="$_cloud/anime/$slug"><img alt="$title" src="https://x/f.jpg">'
        '</a></div></article></div>';
    final html = '<html><body>${[
      card('solo-leveling-2-arise-from-the-shadow-dublado',
          'Solo Leveling 2: Arise from the Shadow Dublado'),
      card('solo-leveling-2-arise-from-the-shadow',
          'Solo Leveling 2: Arise from the Shadow'),
      card('solo-leveling-dublado', 'Solo Leveling Dublado'),
      card('solo-leveling', 'Solo Leveling'),
    ].join()}</body></html>';
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animesOnlineCloud,
      client: MockClient((req) async => _ok(html)),
    );
    final match = await adapter.resolveAnime(Anime(
      name: 'Ore dake Level Up na Ken',
      englishName: 'Solo Leveling',
      url: '',
      source: AnimeSource.animesOnlineCloud,
    ));
    expect(match, isNotNull);
    expect(match!.url, '$_cloud/anime/solo-leveling');
    expect(match.url, isNot(contains('solo-leveling-2')));
  });

  test('registry: 4 cluster sources registered and routable', () {
    for (final s in [
      AnimeSource.animesOnlineCloud,
      AnimeSource.animesDrive,
      AnimeSource.animeQ,
      AnimeSource.animePlay,
    ]) {
      final adapter = SourceRegistry.forSource(s);
      expect(adapter, isA<AnimesOnlineAdapter>());
      expect(adapter.implemented, isTrue);
      expect(adapter.source, s);
      expect(
        AnimesOnlineAdapter.baseUrls[s]!.contains('animesonline.cloud') ||
            AnimesOnlineAdapter.baseUrls[s]!.contains('animesdrive.online') ||
            AnimesOnlineAdapter.baseUrls[s]!.contains('animeq.blog') ||
            AnimesOnlineAdapter.baseUrls[s]!.contains('animeplay.cloud'),
        isTrue,
      );
    }
    expect(Anime(name: '', url: '', source: AnimeSource.animesOnlineCloud).sourceName,
        'Animes Online');
    expect(Anime(name: '', url: '', source: AnimeSource.animePlay).sourceName,
        'Anime Play');
    expect(AnimeSource.animeQ.isPtBr, isTrue);
    // Cluster sits between DooPlay (5) and AnimePlayer (10) in display order.
    expect(AnimeSource.animesOnlineCloud.priority, greaterThan(AnimeSource.dooPlay.priority));
    expect(AnimeSource.animePlay.priority, lessThan(AnimeSource.animePlayer.priority));
  });
}