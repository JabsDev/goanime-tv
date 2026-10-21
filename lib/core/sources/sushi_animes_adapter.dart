import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../constants/app_constants.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// Sushi Animes (PT-BR), `sushianimes.com.br`.
///
/// Catálogo dublado + legendado, antigo e atual (Bleach 2004, One Piece,
/// Naruto, JJK, Frieren…). Diferente do cluster AnimesOnline, o player tem
/// duas opções por episódio: a primeira é um embed do Blogger (morto desde
/// que o Blogger fechou o hosting público — `video.g` responde, mas o
/// `googlevideo` devolve 403), e a segunda é o **CDN próprio** que responde
/// HLS ou mp4 direto. O adapter tenta todas as opções e só aceita a que
/// entrega bytes.
///
/// Superfície usada (verificada ao vivo 21/10/2026):
///  - `GET /` → `_TOKEN` (CSRF) + cookie de sessão PHP;
///  - `POST /search` (`_ACTION=search&_TOKEN=…&q=…`) → página de resultados
///    com cards `.list-movie` (`a.list-title` / `a.list-media`);
///  - `GET /anime/<slug>-<id>` → cards `.epx-card` com a URL
///    `/anime/<slug>-<id>-<season>-season-<n>-episode`;
///  - `GET` da página do episódio → botões `data-embed`;
///  - `POST /ajax/embed` (`id=<data-embed>`) → HTML com
///    `var playerEmbed="<m3u8|mp4>"` (o player Blogger vem como iframe e é
///    descartado).
///
/// Numeração: o número do episódio na URL é o que o site usa — absoluto em
/// séries como One Piece (S23E25 = 1180) e reiniciado por temporada em
/// outras (Bleach S2E1 = 1). Por isso [resolveVideo] usa o mesmo mapa do
/// AnimeFire: quando o catálogo nomeia a temporada, casa por
/// temporada + número relativo; sem nome, casa pelo número cru.
class SushiAnimesAdapter extends AnimeSourceAdapter {
  static const _base = 'https://sushianimes.com.br';

  final http.Client? _client;

  SushiAnimesAdapter({http.Client? client}) : _client = client;

  static const _ua = AppConstants.userAgent;

  static const _headers = {
    'User-Agent': _ua,
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Referer': '$_base/',
  };

  @override
  AnimeSource get source => AnimeSource.sushiAnimes;

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) return _client.get(uri, headers: headers);
    return apiClient.get(uri, headers: headers);
  }

  Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    if (_client != null) {
      return _client.post(uri, headers: headers, body: body);
    }
    return apiClient.post(uri, headers: headers, body: body);
  }

  Future<http.Response?> _head(Uri uri,
      {Map<String, String>? headers}) async {
    final client = _client ?? http.Client();
    try {
      return await client
          .head(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[Sushi] HEAD failed $uri: $e');
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final q = TextUtils.cleanSearchQuery(animeName);
    if (q.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Empty query',
        source: source,
      ));
    }
    try {
      // `GET /search/<q>` devolve o resultado sem sessão (verificado ao vivo
      // 21/10/2026). O POST do formulário exige `_TOKEN` + cookie e responde
      // 302; o GET direto evita as duas idas e o cookie jar.
      final res = await _get(
        Uri.parse('$_base/search/${Uri.encodeComponent(q)}'),
        headers: _headers,
      );
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final list = <Anime>[];
      final seen = <String>{};
      for (final card in doc.querySelectorAll('.list-movie')) {
        final titleLink = card.querySelector('a.list-title');
        final media = card.querySelector('a.list-media') ?? titleLink;
        final href = media?.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        // Só séries: as páginas `/assistir/<slug>` de filmes não expõem player
        // no HTML (verificado em Promare/21/10/2026), então não entram no
        // catálogo para não oferecer um card que nunca toca.
        if (!href.contains('/anime/')) continue;
        final raw = (titleLink?.text ?? media?.text ?? '').trim();
        final name = _displayTitle(raw.isEmpty ? href.split('/').last : raw);
        if (name.isEmpty || !seen.add(href)) continue;
        final cover = card.querySelector('.media[data-src]')?.attributes['data-src'] ??
            card.querySelector('img')?.attributes['src'];
        list.add(Anime(
          name: name,
          url: href,
          source: source,
          fallbackImageUrl: cover,
        ));
      }
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No results found',
          source: source,
        ));
      }
      return ScraperResult.success(list);
    } on TimeoutException {
      return ScraperResult.failure(TimeoutError(
        message: 'Search timed out',
        source: source,
      ));
    } catch (e) {
      debugPrint('[Sushi] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Unexpected error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Título de exibição. Mantém o áudio no fim ("Bleach (Dublado)") para o
  /// usuário distinguir as duas páginas na busca; [TextUtils.cleanTitle] e
  /// [AnimeSourceAdapter.normalize] já removem o marcador na hora de casar.
  static String _displayTitle(String raw) {
    final lower = raw.toLowerCase();
    final cleaned = TextUtils.cleanTitle(raw);
    if (cleaned.isEmpty) return cleaned;
    if (lower.contains('dublado')) return '$cleaned (Dublado)';
    if (lower.contains('legendado')) return '$cleaned (Legendado)';
    return cleaned;
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    if (anime.url.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'No anime URL provided',
        source: source,
      ));
    }
    try {
      final res = await _get(Uri.parse(anime.url), headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final list = <Episode>[];

      // Filme: a página `/assistir/<slug>` é o próprio player (sem grade).
      if (anime.url.contains('/assistir/')) {
        list.add(Episode(
          number: '1',
          url: anime.url,
          title: anime.name,
          owner: anime,
          source: source,
        ));
        return ScraperResult.success(list);
      }

      for (final card in doc.querySelectorAll('.epx-card')) {
        final href = card.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        final m = RegExp(r'-(\d+)-season-(\d+)-episode$').firstMatch(href);
        if (m == null) continue;
        final season = int.tryParse(m.group(1)!);
        final number = m.group(2)!;
        final title = card.querySelector('.epx-desc')?.text.trim().isNotEmpty == true
            ? card.querySelector('.epx-desc')!.text.trim()
            : card.querySelector('.epx-title')?.text.trim();
        final thumb = card.querySelector('.epx-thumb')?.attributes['data-src'];
        list.add(Episode(
          number: number,
          url: href,
          title: title,
          thumbnail: thumb,
          season: season,
          owner: anime,
          source: source,
        ));
      }
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes found in HTML',
          source: source,
        ));
      }
      // Ordena por temporada e, dentro dela, pelo número do site.
      list.sort((a, b) {
        final sa = a.season ?? 0;
        final sb = b.season ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        final na = int.tryParse(a.number) ?? 0;
        final nb = int.tryParse(b.number) ?? 0;
        return na.compareTo(nb);
      });
      return ScraperResult.success(list);
    } catch (e, st) {
      debugPrint('[Sushi] getEpisodes error: $e\n$st');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final page = await _get(Uri.parse(episode.url), headers: _headers);
      if (page.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${page.statusCode}',
          source: source,
        ));
      }
      final ids = <String>[];
      for (final m in RegExp(r'data-embed="(\d+)"').allMatches(page.body)) {
        final id = m.group(1)!;
        if (!ids.contains(id)) ids.add(id);
      }
      if (ids.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No player options in episode page',
          source: source,
        ));
      }

      final audio = _audioOf(anime?.name ?? episode.owner?.name ?? '');
      var sawBlogger = false;
      for (final id in ids) {
        final emb = await _post(
          Uri.parse('$_base/ajax/embed'),
          headers: {
            ..._headers,
            'X-Requested-With': 'XMLHttpRequest',
            'Referer': episode.url,
          },
          body: {'id': id},
        );
        if (emb.statusCode != 200) continue;
        final doc = html_parser.parse(emb.body);
        final srcdoc = doc.querySelector('iframe')?.attributes['srcdoc'] ?? '';
        final m = RegExp(r'var playerEmbed="([^"]+)"').firstMatch(srcdoc);
        if (m == null) {
          // Player Blogger (iframe externo) — morto hoje, tenta o próximo.
          if (emb.body.contains('blogger.com') ||
              emb.body.contains('playsus.online')) {
            sawBlogger = true;
          }
          continue;
        }
        final url = m.group(1)!;
        if (!await _alive(url)) {
          debugPrint('[Sushi] dead stream for ${episode.url}: $url');
          continue;
        }
        return ScraperResult.success([
          VideoSource(
            url: url,
            quality: 'Auto',
            headers: {
              'User-Agent': _ua,
              'Referer': '$_base/',
            },
            audio: audio,
          ),
        ]);
      }
      return ScraperResult.failure(sawBlogger
          ? BloggerUnsupportedError(
              message: 'Only Blogger players available (dead)',
              source: source,
            )
          : EmptyResultError(
              message: 'No playable stream found',
              source: source,
            ));
    } catch (e) {
      debugPrint('[Sushi] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// "Dublado"/"Legendado" a partir do nome da página (o site separa as duas
  /// em entradas diferentes). Null quando não há marcador.
  static String? _audioOf(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('dublado')) return 'Dublado';
    if (lower.contains('legendado')) return 'Legendado';
    return null;
  }

  /// Confere que a URL entrega bytes de verdade. O CDN do Sushi ignora
  /// `Range` e devolve o segmento inteiro, então usamos HEAD (barato) em vez
  /// do probe 206 usado no cluster AnimesOnline. Para HLS, valida o master e
  /// o primeiro segmento — um master 200 com segmento 404 foi exatamente o
  /// sintoma dos clones mortos do AnimeFire.
  Future<bool> _alive(String url) async {
    final headers = {..._headers, 'Referer': '$_base/'};
    try {
      if (url.contains('.m3u8')) {
        final res = await _get(Uri.parse(url), headers: headers);
        if (res.statusCode != 200 || !res.body.contains('#EXTM3U')) {
          return false;
        }
        String? segment;
        for (final line in res.body.split('\n')) {
          final t = line.trim();
          if (t.isEmpty || t.startsWith('#')) continue;
          segment = t;
          break;
        }
        if (segment == null) return false;
        final segUrl = Uri.parse(url).resolve(segment);
        final head = await _head(segUrl, headers: headers);
        return head != null && head.statusCode >= 200 && head.statusCode < 300;
      }
      final head = await _head(Uri.parse(url), headers: headers);
      return head != null && head.statusCode >= 200 && head.statusCode < 400;
    } catch (e) {
      debugPrint('[Sushi] probe error $url: $e');
      return false;
    }
  }

  /// Mesmo mapa de temporada do AnimeFire: com dica de temporada no catálogo,
  /// o número do episódio é relativo à temporada do site (Bleach S2E1 = 1).
  /// Sem dica, casa o número cru — absoluto em One Piece e relativo na S1.
  Episode? _pickEpisode(List<Episode> data, int episodeNumber, Anime match,
      Anime? catalog) {
    // Só a dica do catálogo: a URL do Sushi termina no ID numérico do site
    // (`/anime/bleach-1105`), que [seasonOfCandidateUrl] leria como temporada
    // quando o ID tem 1–2 dígitos.
    final hint = catalog == null ? null : TextUtils.seasonOf(catalog.name);
    if (hint != null) {
      final inSeason = data.where((e) => e.season == hint).toList()
        ..sort((a, b) => (int.tryParse(a.number) ?? 0)
            .compareTo(int.tryParse(b.number) ?? 0));
      final start =
          inSeason.isEmpty ? null : int.tryParse(inSeason.first.number);
      if (start != null) {
        for (final e in inSeason) {
          final n = int.tryParse(e.number);
          if (n != null && n - start + 1 == episodeNumber) return e;
        }
      }
      // Página combinada com 2+ temporadas: nunca cair no número absoluto —
      // é exatamente o bug S4E21→S1E21.
      final seasons = data.map((e) => e.season).whereType<int>().toSet();
      if (seasons.length >= 2) return null;
    }
    for (final e in data) {
      if (int.tryParse(e.number) == episodeNumber) return e;
    }
    return null;
  }

  @override
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber,
      {Anime? catalog}) async {
    final eps = await getEpisodes(match);
    Episode? target;
    switch (eps) {
      case Success(:final data):
        target = _pickEpisode(data, episodeNumber, match, catalog);
      case Failure():
      case Loading():
        return const [];
    }
    if (target == null) return const [];

    final vs = await getVideoSources(target, anime: match);
    switch (vs) {
      case Success(:final data):
        return data;
      case Failure():
      case Loading():
        return const [];
    }
  }

  @override
  Future<String?> watchUrlForMatched(Anime match, int episodeNumber) async {
    final eps = await getEpisodes(match);
    if (eps is! Success<List<Episode>>) return null;
    final target = _pickEpisode(eps.data, episodeNumber, match, null) ??
        (eps.data.isNotEmpty ? eps.data.first : null);
    return target?.url;
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    final report = AvailabilityReport(
      source: source,
      animeName: animeName,
    );
    try {
      final result = await search(animeName);
      switch (result) {
        case Success(data: final animes):
          if (animes.isNotEmpty) {
            report.status = AvailabilityStatus.available;
            report.episodeCount = animes.first.episodes ?? 0;
          }
        case Failure(error: final err):
          if (err is EmptyResultError) {
            report.status = AvailabilityStatus.notFound;
            report.reason = 'Anime not found in catalog';
          } else if (err is UnknownError) {
            report.status = AvailabilityStatus.error;
            report.reason = 'Unknown error: ${err.message}';
          } else if (err is TimeoutError) {
            report.status = AvailabilityStatus.timeout;
            report.reason = 'Request timed out';
          }
        case Loading():
          break;
      }
    } on Exception catch (e) {
      report.status = AvailabilityStatus.exception;
      report.reason = 'Exception: $e';
    }
    return report;
  }
}
