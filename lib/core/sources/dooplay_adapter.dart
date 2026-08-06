import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// DooPlay provider (PT-BR): shared WordPress theme used by several Brazilian
/// anime sites (BetterAnime, AnimesRoll, among others). Search and episode
/// listing are HTML scraping; video resolves through the site's `/wp-json/
/// dooplayer/v2/<post>/<type>/<nume>` player API which returns a Blogger-keyed
/// embed whose token is base64-decoded and reversed.
///
/// The [DooPlayAdapter.source] selects the base URL (see [baseUrl]).
class DooPlayAdapter implements AnimeSourceAdapter {
  final AnimeSource _source;
  final http.Client? _client;

  DooPlayAdapter({
    required AnimeSource source,
    http.Client? client,
  })  : _source = source,
        _client = client;

  @override
  AnimeSource get source => _source;

  @override
  bool get implemented => true;

  /// Base URL for the selected source. `animesRoll` is not fully wired via the
  /// old `anroll.plus` constant; BetterAnime is the primary PT-BR DooPlay site.
  static const Map<AnimeSource, String> baseUrls = {
    AnimeSource.dooPlay: 'https://betteranime.io',
    AnimeSource.betterAnime: 'https://betteranime.io',
    AnimeSource.animesRoll: 'https://anroll.tv',
  };

  String get baseUrl => baseUrls[_source] ?? 'https://betteranime.io';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) {
      return _client.get(uri, headers: headers);
    }
    return apiClient.get(uri, headers: headers);
  }

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    final url =
        Uri.parse('$baseUrl/?s=${Uri.encodeQueryComponent(query)}');
    try {
      http.Response res;
      try {
        res = await _httpGet(url, headers: {'User-Agent': _ua});
      } on TimeoutException {
        res = await _httpGet(url, headers: {'User-Agent': _ua});
      }
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final list = <Anime>[];
      // Dooplay results render as .result-item article cards.
      for (final item in doc.querySelectorAll('.result-item article')) {
        final a = item.querySelector('.image a') ?? item.querySelector('a');
        final href = a?.attributes['href'] ?? '';
        if (href.isEmpty || !href.contains('/animes/')) continue;
        final img = item.querySelector('img');
        final name = TextUtils.cleanTitle(
          img?.attributes['alt'] ?? a?.text.trim() ?? href.split('/').last,
        );
        if (name.isEmpty) continue;
        list.add(Anime(
          name: name,
          url: href,
          source: source,
          fallbackImageUrl: img?.attributes['src'],
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
      debugPrint('[DooPlay] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Unexpected error: $e',
        source: source,
      ));
    }
  }

  @override
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
    if (anime.url.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'No anime URL provided',
        source: source,
      ));
    }
    try {
      final res = await _httpGet(Uri.parse(anime.url), headers: {
        'User-Agent': _ua,
      });
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final hrefs = <String>{};
      for (final a in doc.querySelectorAll('a')) {
        final href = a.attributes['href'] ?? '';
        if (href.contains('/episodios/') && !href.endsWith('/episodios/')) {
          hrefs.add(href);
        }
      }
      if (hrefs.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episode URLs found in HTML',
          source: source,
        ));
      }
      final list = hrefs.toList()
        ..sort((a, b) {
          final na = _episodeNumber(a);
          final nb = _episodeNumber(b);
          if (na == null || nb == null) return 0;
          return na.compareTo(nb);
        });
      final episodes = list.map((url) {
        return Episode(
          number: (_episodeNumber(url) ?? 0).toString(),
          url: url,
          source: source,
          owner: anime,
        );
      }).toList();
      return ScraperResult.success(EpisodesResult(
        episodes,
        {source.toString(): episodes},
      ));
    } catch (e) {
      debugPrint('[DooPlay] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  int? _episodeNumber(String url) {
    final m = RegExp(r'episodio[\s-]*(\d+)').firstMatch(url);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final sources = await _extractFromDooPlay(episode.url);
      if (sources.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No video sources found',
          source: source,
        ));
      }
      return ScraperResult.success(sources);
    } catch (e) {
      debugPrint('[DooPlay] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  Future<List<VideoSource>> _extractFromDooPlay(String episodeUrl) async {
    final res = await _httpGet(Uri.parse(episodeUrl), headers: {
      'User-Agent': _ua,
      'Referer': '$baseUrl/',
    });
    if (res.statusCode != 200) return [];

    // The episode page embeds the player options: data-type / data-post /
    // data-nume on `li.player-option-N.dooplay_player_option`.
    final m = RegExp(
      r'''data-type='([\w-]+)' data-post='(\d+)' data-nume='([\d.]+)' ''',
    ).firstMatch(res.body);

    if (m == null) return [];

    final type = m.group(1)!;
    final post = m.group(2)!;
    final nume = m.group(3)!;

    final apiUrl =
        Uri.parse('$baseUrl/wp-json/dooplayer/v2/$post/$type/$nume');
    final apiRes = await _httpGet(apiUrl, headers: {
      'User-Agent': _ua,
      'Accept': 'application/json',
      'Referer': episodeUrl,
    });
    if (apiRes.statusCode != 200) return [];

    final decoded = jsonDecode(apiRes.body);
    if (decoded is! Map) return [];

    final embedUrl = decoded['embed_url']?.toString();
    if (embedUrl == null || embedUrl.isEmpty) return [];

    // The embed is a Blogger-jW player page whose token is base64(reversed).
    return _resolveJwplayerEmbed(embedUrl);
  }

  Future<List<VideoSource>> _resolveJwplayerEmbed(String embedUrl) async {
    try {
      final res = await _httpGet(Uri.parse(embedUrl), headers: {
        'User-Agent': _ua,
        'Referer': '$baseUrl/',
      });
      if (res.statusCode != 200) return [];

      // The amzn.jw file value is a base64 string that decodes to a reversed
      // Blogger token; the media URL is then resolved by the site's own
      // `decode_blogger_video` admin-ajax endpoint. Best-effort: if the Azure
      // token resolve isn't feasible here due to anti-bot/JS, we still surface
      // the direct mp4/m3u8 if present in the player page.
final direct = RegExp(
        r'''https?://[^"'\s<>]+(?:\.mp4|\.m3u8)''',
      ).firstMatch(res.body);
      if (direct != null) {
        return [
          VideoSource(
            url: direct.group(0)!,
            quality: 'Auto',
            headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'},
          )
        ];
      }
      return [];
    } catch (e) {
      debugPrint('[DooPlay] jwplayer resolve error: $e');
      return [];
    }
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
            return report;
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