import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/dattebayo_br_adapter.dart';
import 'package:goanime_tv/core/sources/source_registry.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

const _base = 'https://www.dattebayo-br.com';

http.Response _ok(String body) =>
    http.Response(body, 200, headers: {'content-type': 'text/html'});

http.Response _probe() => http.Response(
      'x',
      206,
      headers: {'content-range': 'bytes 0-0/269115615'},
    );

void main() {
  String fx(String name) => File('test/fixtures/$name').readAsStringSync();

  test('search keeps series pages (legendado + dublado) and drops /videos/', () async {
    final adapter = DattebayoBrAdapter(
      client: MockClient((req) async {
        expect(req.url.path, '/busca');
        expect(req.url.queryParameters['busca'], 'Tensei Shitara Slime Datta Ken 4th Season');
        return _ok(fx('dattebayo_search.html'));
      }),
    );
    final result = await adapter.search('Tensei Shitara Slime Datta Ken 4th Season');
    expect(result, isA<Success<List<Anime>>>());
    final data = (result as Success<List<Anime>>).data;
    expect(data.length, 2);
    expect(data.first.url, '$_base/animes/tensei-shitara-slime-datta-ken-4th-season');
    expect(data.last.url, contains('/anime-dublado/'));
    // O card de vídeo não é uma página de série.
    expect(data.where((a) => a.url.contains('/videos/')), isEmpty);
  });

  test('getEpisodes parses div.ultimosEpisodiosHomeItem and skips page 2 when absent',
      () async {
    var page2Calls = 0;
    final adapter = DattebayoBrAdapter(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/page/2')) page2Calls++;
        return _ok(fx('dattebayo_anime.html'));
      }),
    );
    final result = await adapter.getEpisodes(
      Anime(name: 'Slime S4', url: '$_base/animes/tensei-shitara-slime-datta-ken-4th-season'),
    );
    expect(result, isA<Success<List<Episode>>>());
    final eps = (result as Success<List<Episode>>).data;
    expect(eps.map((e) => e.number).toList(), ['23', '24']);
    expect(eps.first.url, '$_base/videos/578742');
    // O HTML não aponta para /page/2: não paga o fetch extra.
    expect(page2Calls, 0);
  });

  test('getEpisodes follows /page/N only while the HTML announces a next page',
      () async {
    // Sem `.ultimosEpisodiosHomeItemInfosNum`: o número vem do nome, que tem
    // um "4th" antes do "ep 22" — não pode virar EP 4.
    const page2 = '''
<html><body>
<div class="ultimosEpisodiosHomeItem"><a href="/videos/570000"><img src="x"></a><div class="ultimosEpisodiosHomeItemInfosNome">Tensei shitara Slime Datta Ken 4th Season ep 22</div></div>
</body></html>''';
    final calls = <String>[];
    final adapter = DattebayoBrAdapter(
      client: MockClient((req) async {
        calls.add(req.url.path);
        if (req.url.path.endsWith('/page/2')) return _ok(page2);
        // Page 1 anuncia a página 2.
        return _ok('${fx('dattebayo_anime.html')}<a href="/animes/x/page/2">2</a>');
      }),
    );
    final result = await adapter.getEpisodes(
      Anime(name: 'Slime S4', url: '$_base/animes/x'),
    );
    final eps = (result as Success<List<Episode>>).data;
    expect(eps.map((e) => e.number).toList(), ['22', '23', '24']);
    expect(calls, ['/animes/x', '/animes/x/page/2']);
  });

  test('getVideoSources signs the R2 mp4, probes 206 and labels SD/HD/FULLHD',
      () async {
    final adapter = DattebayoBrAdapter(
      client: MockClient((req) async {
        if (req.url.host == 'ads.animeyabu.net') {
          expect(req.url.queryParameters['url'],
              contains('r2.cloudflarestorage.com'));
          return http.Response(
              '[{"ads":"OK","publicidade":"?sig=abc123"}]', 200);
        }
        if (req.url.path == '/videos/578742') {
          return _ok(fx('dattebayo_episode.html'));
        }
        if (req.url.host.endsWith('r2.cloudflarestorage.com')) {
          expect(req.url.query, 'sig=abc123');
          return _probe();
        }
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '23', url: '$_base/videos/578742'),
      anime: Anime(
        name: 'Slime S4',
        url: '$_base/animes/tensei-shitara-slime-datta-ken-4th-season',
      ),
    );
    expect(result, isA<Success<List<VideoSource>>>());
    final sources = (result as Success<List<VideoSource>>).data;
    expect(sources.map((s) => s.quality).toList(), ['SD', 'HD', 'FULLHD']);
    expect(sources.first.url, endsWith('.mp4?sig=abc123'));
    expect(sources.first.audio, 'legendado');
    expect(sources.first.headers['Referer'], '$_base/videos/578742');
  });

  test('dubbed page tags audio as dublado', () async {
    final adapter = DattebayoBrAdapter(
      client: MockClient((req) async {
        if (req.url.host == 'ads.animeyabu.net') {
          return http.Response('[{"publicidade":"?sig=x"}]', 200);
        }
        if (req.url.path == '/videos/578742') {
          return _ok(fx('dattebayo_episode.html'));
        }
        if (req.url.host.endsWith('r2.cloudflarestorage.com')) return _probe();
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '23', url: '$_base/videos/578742'),
      anime: Anime(
        name: 'Slime S4',
        url: '$_base/anime-dublado/tensei-shitara-slime-datta-ken-4th-season-dublado',
      ),
    );
    final sources = (result as Success<List<VideoSource>>).data;
    expect(sources.first.audio, 'dublado');
  });

  test('dead CDN (probe != 206) never reaches the picker', () async {
    final adapter = DattebayoBrAdapter(
      client: MockClient((req) async {
        if (req.url.host == 'ads.animeyabu.net') {
          return http.Response('[{"publicidade":"?sig=x"}]', 200);
        }
        if (req.url.path == '/videos/578742') {
          return _ok(fx('dattebayo_episode.html'));
        }
        return http.Response('nf', 404);
      }),
    );
    final result = await adapter.getVideoSources(
      Episode(number: '23', url: '$_base/videos/578742'),
    );
    expect(result, isA<Failure<List<VideoSource>>>());
  });

  test('videoVars maps container id → var vid', () {
    final vars = DattebayoBrAdapter.videoVars(
        html_parser.parse(fx('dattebayo_episode.html')));
    expect(vars.keys, ['0', '1', '2']);
    expect(vars['2'], contains('/zful/578742.mp4'));
  });

  test('registry routes the new source and keeps it in the PT-BR fan-out', () {
    final adapter = SourceRegistry.forSource(AnimeSource.dattebayoBr);
    expect(adapter, isA<DattebayoBrAdapter>());
    expect(adapter.implemented, isTrue);
    expect(AnimeSource.dattebayoBr.isPtBr, isTrue);
    expect(AnimeSource.dattebayoBr.language, SourceLanguage.portuguese);
    expect(SourceRegistry.fallbackOrder, contains(AnimeSource.dattebayoBr));
    expect(
      Anime(name: '', url: '', source: AnimeSource.dattebayoBr).sourceName,
      'Dattebayo BR',
    );
  });
}
