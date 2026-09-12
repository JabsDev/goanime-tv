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
import 'blogger_spa_resolver.dart';
import 'cdn_resolver.dart' show probeMediaUrl;
import 'dooplay_v2_extractor.dart' show DooPlayV2Extractor;

/// DooPlay provider (PT-BR): shared WordPress theme used by several Brazilian
/// anime sites (BetterAnime, AnimesRoll, AnimesOnline HDK, AnimesHD, Animes
/// Orion, among others). Search and episode listing are HTML scraping; video
/// resolves through the theme's player API:
///
///  - `wp_json`    → GET  <player_api><post>/<type>/<nume> (BetterAnime)
///  - `admin_ajax` → POST <url> action=doo_player_ajax&post=…&nume=…&type=…
///                    (AnimesHD, Animes Orion)
///
/// Both return the same JSON (`embed_url` + `type`); the embed is then probed
/// for a direct mp4/m3u8 or walked through the Blogger-jW player fallback.
///
/// Per-source differences (base URL, catalog path, episode path, transport)
/// are driven by [source] so one adapter covers the whole DooPlay family.
class DooPlayAdapter extends AnimeSourceAdapter {
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

  /// Base URL for the selected source. BetterAnime is the primary PT-BR
  /// DooPlay site; `animesRoll` is not fully wired via the old `anroll.plus`
  /// constant.
  static const Map<AnimeSource, String> baseUrls = {
    AnimeSource.dooPlay: 'https://betteranime.io',
    AnimeSource.betterAnime: 'https://betteranime.io',
    AnimeSource.animesRoll: 'https://anroll.tv',
    AnimeSource.animesOnlineHdk: 'https://animesonlinehdk.com',
    AnimeSource.animesHd: 'https://animeshd.to',
    AnimeSource.animesOrion: 'https://animesorion.cc',
  };

  String get baseUrl => baseUrls[_source] ?? 'https://betteranime.io';

  /// Catalog path of anime detail pages, used to filter search results. HDK
  /// exposes series under `/tvshows/`, the rest under `/animes/`.
  String get _searchPath => switch (_source) {
        AnimeSource.animesOnlineHdk => '/tvshows/',
        _ => '/animes/',
      };

  /// URL segment that episode pages live under: HDK uses `/episodes/`, the
  /// other DooPlay sites `/episodios/`.
  String get _episodePath => switch (_source) {
        AnimeSource.animesOnlineHdk => '/episodes/',
        _ => '/episodios/',
      };

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
        if (href.isEmpty || !href.contains(_searchPath)) continue;
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
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
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
        if (href.contains(_episodePath) && !href.endsWith(_episodePath)) {
          hrefs.add(href);
        }
      }
      if (hrefs.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episode URLs found in HTML',
          source: source,
        ));
      }
      final list = hrefs.toList()..sort(_compareEpisodeUrls);
      final episodes = list.map((url) {
        final sn = seasonEpisode(url);
        return Episode(
          number: (sn.$2 ?? 0).toString(),
          url: url,
          source: source,
          owner: anime,
          season: sn.$1,
        );
      }).toList();
      return ScraperResult.success(episodes);
    } catch (e) {
      debugPrint('[DooPlay] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Total comparator for episode URLs: (season nulls-last, number,
  /// url-tiebreak). Never returns 0 for distinct URLs — the old
  /// `return 0 on null` violated the comparator contract and made multi-season
  /// order non-deterministic. `null` season sorts LAST (unknown ≠ S1).
  static int _compareEpisodeUrls(String a, String b) {
    final sa = seasonEpisode(a);
    final sb = seasonEpisode(b);
    if (sa.$1 == null && sb.$1 != null) return 1;
    if (sa.$1 != null && sb.$1 == null) return -1;
    if (sa.$1 != null && sb.$1 != null && sa.$1 != sb.$1) {
      return sa.$1!.compareTo(sb.$1!);
    }
    if (sa.$2 != sb.$2) return (sa.$2 ?? 0).compareTo(sb.$2 ?? 0);
    return a.compareTo(b);
  }

  /// (season, number) from an episode URL. Precedence is fixed (first match
  /// wins); the path is matched case-insensitively with `/`, `?`, `#`
  /// suffixes stripped before matching:
  ///
  ///  1. `…-<S>-<M>-episodio-<N>` (e.g. Temporada 2.5 slug `…-2-5-episodio-N`)
  ///     → `(null, N)` + log. Specials `x.5` can't be expressed as an int
  ///     season, so they stay out of season-aware resolve by design.
  ///  2. `…-<S>-episodio-<N>` (BetterAnime combined page) → `(S, N)`.
  ///  3. `…-<S>x<N>` (HDK/Orion) → `(S, N)`.
  ///  4. `…-episodio-<N>` without prefix → `(null, N)` (S1/single season).
  ///
  /// `episodio-<N>-parte-<P>` keeps the FIRST number (N); the `parte` suffix
  /// is logged as ambiguous, never used as the episode number.
  /// Never matches: pure IDs (`/15859/`), resolutions (`-720p`), years.
  @visibleForTesting
  static (int?, int?) seasonEpisode(String url) {
    var path = url.split('?').first.split('#').first;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final lower = path.toLowerCase();
    if (RegExp(r'-(\d+)-(\d+)-episodio-(\d+)$').firstMatch(lower)
        case final m?) {
      debugPrint('[SeasonResolve] DooPlay special x.5 slug (season=null): $url');
      return (null, int.tryParse(m.group(3)!));
    }
    if (RegExp(r'-(\d{1,2})-episodio-(\d+)(?:-parte-\d+)?$').firstMatch(lower)
        case final m?) {
      return (int.tryParse(m.group(1)!), int.tryParse(m.group(2)!));
    }
    if (RegExp(r'-(\d{1,2})x(\d{1,4})$').firstMatch(lower) case final m?) {
      return (int.tryParse(m.group(1)!), int.tryParse(m.group(2)!));
    }
    final classic =
        RegExp(r'episodio[\s-]*(\d+)', caseSensitive: false).firstMatch(path);
    if (classic != null) {
      if (lower.contains('-parte-')) {
        debugPrint('[SeasonResolve] DooPlay parte-suffix, keeping N: $url');
      }
      return (null, int.tryParse(classic.group(1)!));
    }
    return (null, null);
  }

  /// Season-aware resolve: when [catalog] names a season (AniList splits
  /// seasons into entries, e.g. "…4th Season") and the page holds that
  /// season, the number is season-relative — match by number-IN-season via
  /// [firstWhere], never by position. When the hint points at a season but
  /// the page is COMBINED (≥2 distinct seasons) and the episode isn't in the
  /// hinted season, return [] instead of silently falling back to S1 (that
  /// fallback WAS the bug: S4E21 → S1E21). Absolute fallback only for
  /// season-unknown catalogs or single-season pages, with a tagged log.
  @override
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber,
      {Anime? catalog}) async {
    final eps = await getEpisodes(match);
    Episode? target;
    switch (eps) {
      case Success(:final data):
        final hint =
            catalog == null ? null : TextUtils.seasonOf(catalog.name);
        if (hint != null) {
          final inSeason = data
              .where((e) => e.season == hint)
              .toList()
            ..sort((a, b) =>
                (int.tryParse(a.number) ?? 0)
                    .compareTo(int.tryParse(b.number) ?? 0));
          for (final e in inSeason) {
            if (int.tryParse(e.number) == episodeNumber) {
              target = e;
              break;
            }
          }
          if (target == null) {
            final seasons =
                data.map((e) => e.season).whereType<int>().toSet();
            if (seasons.length >= 2) return const [];
            debugPrint('[SeasonResolve] DooPlay fallback absoluto '
                'ep=$episodeNumber hint=$hint url=${match.url}');
          }
        }
        target ??= () {
          for (final e in data) {
            if (int.tryParse(e.number) == episodeNumber) return e;
          }
          return null;
        }();
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
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final result = await _extractFromDooPlay(episode.url);
      if (result.sources.isEmpty) {
        // Blogger SPA: the episode page matched and the player answered with a
        // Blogger embed, but the token is dead / the SPA has no recoverable
        // stream. Distinct from "not found" so the UI can explain it.
        if (result.bloggerSpa) {
          return ScraperResult.failure(BloggerUnsupportedError(
            message: 'Blogger SPA embed without a recoverable stream',
            source: source,
          ));
        }
        return ScraperResult.failure(EmptyResultError(
          message: 'No video sources found',
          source: source,
        ));
      }
      return ScraperResult.success(result.sources);
    } catch (e) {
      debugPrint('[DooPlay] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  Future<({List<VideoSource> sources, bool bloggerSpa})> _extractFromDooPlay(
      String episodeUrl) async {
    final res = await _httpGet(Uri.parse(episodeUrl), headers: {
      'User-Agent': _ua,
      'Referer': '$baseUrl/',
    });
    if (res.statusCode != 200) return (sources: const <VideoSource>[], bloggerSpa: false);

    // The episode page embeds the player options: data-type / data-post /
    // data-nume on `li.player-option-N.dooplay_player_option`. No trailing
    // space — real pages end the tag with `'` + newline or `>`.
    final m = RegExp(
      r'''data-type='([\w-]+)' data-post='(\d+)' data-nume='([\d.]+)''',
    ).firstMatch(res.body);

    if (m == null) return (sources: const <VideoSource>[], bloggerSpa: false);

    final type = m.group(1)!;
    final post = m.group(2)!;
    final nume = m.group(3)!;

    // Transport is theme-dependent (`dtAjax.play_method`); when the page
    // carries no `dtAjax`, try the classic wp-json route first and fall back to
    // admin_ajax (AnimesHD serves no dtAjax but only answers admin_ajax).
    final method = _playMethod(res.body);
    Map<String, dynamic>? payload;
    if (method == 'admin_ajax') {
      payload = await _adminAjaxPayload(post, nume, type, episodeUrl);
      payload ??= await _wpJsonPayload(res.body, post, type, nume, episodeUrl);
    } else {
      payload = await _wpJsonPayload(res.body, post, type, nume, episodeUrl);
      payload ??= await _adminAjaxPayload(post, nume, type, episodeUrl);
    }

    final embedUrl = payload?['embed_url']?.toString();
    if (embedUrl == null || embedUrl.isEmpty) {
      return (sources: const <VideoSource>[], bloggerSpa: false);
    }

    // Direct mp4/m3u8 source → probe and offer; otherwise walk the Blogger
    // SPA resolution chain. An embed that points at a Blogger player marks the
    // outcome as `bloggerSpa` so a dead token classifies as BloggerUnsupported
    // instead of a plain empty result.
    final isBlogger =
        embedUrl.contains('blogger.com') || embedUrl.contains('type=blogger');
    final direct = DooPlayV2Extractor.mp4FromEmbed(embedUrl);
    if (direct != null &&
        await probeMediaUrl(Uri.parse(direct),
                client: _client,
                headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'}) >=
            0) {
      return (
        sources: [
          VideoSource(
            url: direct,
            quality: 'Auto',
            headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'},
          ),
        ],
        bloggerSpa: isBlogger,
      );
    }

    final resolved = await BloggerSpaResolver(client: _client)
        .resolve(embedUrl: embedUrl, referer: '$baseUrl/');
    return (sources: resolved, bloggerSpa: isBlogger);
  }

  static final RegExp _dtAjaxRe = RegExp(
    r'dtAjax\s*=\s*(\{.*?\})\s*;?',
    dotAll: true,
  );
  static final RegExp _playMethodRe = RegExp(r'"play_method"\s*:\s*"([^"]*)"');
  static final RegExp _playerApiRe = RegExp(r'"player_api"\s*:\s*"([^"]*)"');

  /// `wp_json`/`admin_ajax` from the page's `dtAjax` blob, or null when the
  /// theme doesn't expose it.
  String? _playMethod(String body) {
    final blob = _dtAjaxRe.firstMatch(body)?.group(1);
    if (blob == null) return null;
    return _playMethodRe.firstMatch(blob)?.group(1);
  }

  Future<Map<String, dynamic>?> _wpJsonPayload(
    String pageBody,
    String post,
    String type,
    String nume,
    String episodeUrl,
  ) async {
    try {
      final blob = _dtAjaxRe.firstMatch(pageBody)?.group(1);
      var api = _playerApiRe.firstMatch(blob ?? '')?.group(1);
      if (api == null || api.isEmpty) {
        api = '$baseUrl/wp-json/dooplayer/v2/';
      } else {
        // O blob é JSON cru: `player_api` vem com escapes (`\/`). Sem
        // unescape, o `\` vira `/` no Uri.parse e o host esvazia
        // (`https:////host//wp-json...` → "No host specified"). Visto ao
        // vivo no animesonlinehdk.
        api = api.replaceAll(r'\/', '/');
      }
      final apiBase = api.startsWith('http') ? api : '$baseUrl$api';
      final apiUrl = Uri.parse('$apiBase$post/$type/$nume');
      final apiRes = await _httpGet(apiUrl, headers: {
        'User-Agent': _ua,
        'Accept': 'application/json',
        'Referer': episodeUrl,
      });
      if (apiRes.statusCode != 200) return null;
      return _decode(apiRes.body);
    } catch (e) {
      debugPrint('[DooPlay] wp-json player API error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _adminAjaxPayload(
    String post,
    String nume,
    String type,
    String episodeUrl,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/wp-admin/admin-ajax.php');
      final headers = {
        'User-Agent': _ua,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Referer': episodeUrl,
      };
      final body = 'action=doo_player_ajax&post=$post&nume=$nume&type=$type';
      final apiRes = _client != null
          ? await _client.post(uri, headers: headers, body: body)
          : await apiClient.post(uri, headers: headers, body: body);
      if (apiRes.statusCode != 200) return null;
      return _decode(apiRes.body);
    } catch (e) {
      debugPrint('[DooPlay] admin-ajax player API error: $e');
      return null;
    }
  }

  Map<String, dynamic>? _decode(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
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