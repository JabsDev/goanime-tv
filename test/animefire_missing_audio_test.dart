import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/sources/anime_fire_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';

/// Regressão do relato "o app não me deu opção de dublado ou legendado e
/// tocou dublado" (Slime S4E23).
///
/// A API do AnimeFire anuncia `"audio": "Dublado & Legendado"` com
/// `is_offline: false` nos DOIS streams, mas o manifesto do legendado responde
/// 404 enquanto o do dublado responde 200. O adapter descartava o morto
/// (correto), sobrava um `audio` só, e o passo de áudio — que exige
/// `_audiosFor(sources).length > 1` — desaparecia. O app tocava o dublado sem
/// dizer que a escolha existia e havia sumido.
///
/// Aqui travamos a parte do adapter: o áudio perdido é carimbado em
/// `VideoSource.unavailableAudios`, que é o que a UI usa para avisar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Payload no formato real da API: 2 streams, um com o manifesto 404.
  String payload({
    required String dubbedUrl,
    required String subbedUrl,
    bool dubbedOffline = false,
    bool subbedOffline = false,
  }) =>
      jsonEncode({
        'data': {
          'id': 'VNt1hrYY199',
          'title': 'A esperança de Granville',
          'audio': 'Dublado & Legendado',
          'season': 4,
          'number': 23,
          'streams': [
            {
              'audio': 'dublado',
              'is_offline': dubbedOffline,
              'url': dubbedUrl,
              'qualities': ['480p', '720p'],
            },
            {
              'audio': 'legendado',
              'is_offline': subbedOffline,
              'url': subbedUrl,
              'qualities': ['480p', '720p'],
            },
          ],
        }
      });

  /// Mock: a API responde o payload; o manifesto responde 200 (#EXTM3U) ou
  /// 404 conforme a URL — é esse o mecanismo real de descarte.
  MockClient clientFor(String body, Set<String> deadManifests) => MockClient((
        req,
      ) async {
        final u = req.url.toString();
        if (u.contains('/episode/')) return http.Response(body, 200);
        if (deadManifests.any((d) => u.contains(d))) {
          return http.Response('<html>404</html>', 404);
        }
        return http.Response('#EXTM3U\n#EXT-X-VERSION:6\n', 200);
      });

  Future<List<VideoSource>> resolve(
      Future<ScraperResult<List<VideoSource>>> pending) async {
    final r = await pending;
    switch (r) {
      case Success(:final data):
        return data;
      case Failure(:final error):
        fail('unexpected failure: ${error.message}');
      case Loading():
        return const [];
    }
  }

  final episode = Episode(
    number: '23',
    url: 'https://api.animefire.one/episode/VNt1hrYY199',
    source: AnimeSource.animeFire,
  );

  test('legendado 404 + dublado vivo → marca o legendado como indisponível',
      () async {
    final adapter = AnimeFireAdapter(
      client: clientFor(
        payload(
          dubbedUrl: 'https://cdn.test/DUB.m3u8',
          subbedUrl: 'https://cdn.test/SUB.m3u8',
        ),
        {'SUB.m3u8'},
      ),
    );

    final sources = await resolve(adapter.getVideoSources(episode));

    // Só o dublado sobrevive — o comportamento que produziu o bug.
    expect(sources.map((s) => s.audio).toSet(), {'dublado'});
    // Mas agora o app SABE que o legendado foi anunciado e não veio.
    expect(sources, isNotEmpty);
    for (final s in sources) {
      expect(s.unavailableAudios, ['legendado']);
    }
  });

  test('os dois vivos → nenhum áudio marcado como indisponível', () async {
    final adapter = AnimeFireAdapter(
      client: clientFor(
        payload(
          dubbedUrl: 'https://cdn.test/DUB.m3u8',
          subbedUrl: 'https://cdn.test/SUB.m3u8',
        ),
        const {},
      ),
    );

    final sources = await resolve(adapter.getVideoSources(episode));

    // Este é o caminho saudável: 2 áudios → o passo de áudio aparece.
    expect(sources.map((s) => s.audio).toSet(), {'dublado', 'legendado'});
    expect(sources.every((s) => s.unavailableAudios.isEmpty), isTrue);
  });

  test('um áudio só anunciado e morto → não avisa (não havia escolha)',
      () async {
    // Só existe legendado na fonte e ele morre: o app não tem o episódio. Não
    // faz sentido dizer "legendado indisponível" — nada tocaria de qualquer
    // forma, e o erro de "no sources" já cobre o caso.
    final adapter = AnimeFireAdapter(
      client: clientFor(
        jsonEncode({
          'data': {
            'id': 'x',
            'streams': [
              {
                'audio': 'legendado',
                'is_offline': false,
                'url': 'https://cdn.test/ONLYSUB.m3u8',
                'qualities': ['720p'],
              }
            ],
          }
        }),
        {'ONLYSUB.m3u8'},
      ),
    );

    final result = await adapter.getVideoSources(episode);
    expect(result, isA<Failure<List<VideoSource>>>());
  });

  test('URL vazia (is_offline) não conta como áudio perdido', () async {
    // `url: ""` = stream marcado offline pela fonte. Não chegou a ser
    // prometido com manifesto, então não deve gerar aviso: o caso real de
    // "só havia um áudio" continua sendo o do teste acima.
    final adapter = AnimeFireAdapter(
      client: clientFor(
        jsonEncode({
          'data': {
            'id': 'x',
            'streams': [
              {
                'audio': 'dublado',
                'is_offline': true,
                'url': '',
                'qualities': ['720p'],
              },
              {
                'audio': 'legendado',
                'is_offline': false,
                'url': 'https://cdn.test/SUB.m3u8',
                'qualities': ['720p'],
              },
            ],
          }
        }),
        const {},
      ),
    );

    final sources = await resolve(adapter.getVideoSources(episode));
    expect(sources.map((s) => s.audio).toSet(), {'legendado'});
    expect(sources.every((s) => s.unavailableAudios.isEmpty), isTrue);
  });
}