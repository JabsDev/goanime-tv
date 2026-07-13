import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../constants/app_constants.dart';
import '../ffi/superflix_bridge.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// SuperFlix provider: native FFI bridge (preferred) with an HTTP/HTML fallback.
class SuperFlixAdapter implements AnimeSourceAdapter {
  const SuperFlixAdapter();

  static const _sfUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  @override
  AnimeSource get source => AnimeSource.superFlix;

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final stopwatch = Stopwatch()..start();
    try {
      final normalized = animeName.trim().replaceAll('-', ' ').replaceAll('_', ' ');

      SuperFlixFFI.instance.load();
      if (SuperFlixFFI.instance.loaded) {
        final results = SuperFlixFFI.instance.search(normalized);
        if (results != null && results.isNotEmpty) {
          return ScraperResult.success(results.map((r) => Anime(
                name: r['title']?.toString() ?? '',
                url: '${AppConstants.superFlixBase}/serie/${r['tmdbId']}',
                source: AnimeSource.superFlix,
                superFlixTmdbId: r['tmdbId']?.toString(),
                fallbackImageUrl: r['imageUrl']?.toString(),
              )).toList());
        }
        debugPrint('[SuperFlixFFI] Search returned empty, falling back to HTTP');
      }

      final url =
          '${AppConstants.superFlixBase}/pesquisar?s=${Uri.encodeQueryComponent(normalized)}';
      final res = await apiClient.get(
        Uri.parse(url),
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': AppConstants.superFlixReferer,
        },
      );
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }

      // Cloudflare check (D-08)
      if (isCloudflareChallenge(res.body, res.headers)) {
        return ScraperResult.failure(CloudflareError(
          message: 'Cloudflare challenge detected on search page',
          source: source,
          operationDuration: stopwatch.elapsed,
          detectionPattern: 'isCloudflareChallenge',
        ));
      }

      final doc = html_parser.parse(res.body);
      final cards = doc.querySelectorAll('.group\\/card');
      final list = <Anime>[];
      for (final card in cards) {
        final img = card.querySelector('img');
        final name = img?.attributes['alt']?.trim() ?? '';
        if (name.isEmpty) continue;
        var imageUrl =
            img?.attributes['data-src'] ?? img?.attributes['src'] ?? '';
        imageUrl = _normalizeSuperFlixImage(imageUrl);
        String? tmdbId;
        for (final btn in card.querySelectorAll('button')) {
          final msg = btn.attributes['data-msg'] ?? '';
          final copy = btn.attributes['data-copy'] ?? '';
          if (msg.contains('TMDB') && copy.isNotEmpty) tmdbId = copy;
        }
        if (tmdbId == null) continue;
        final mediaUrl = '${AppConstants.superFlixBase}/serie/$tmdbId';
        list.add(Anime(
          name: name,
          url: mediaUrl,
          source: AnimeSource.superFlix,
          superFlixTmdbId: tmdbId,
          fallbackImageUrl: imageUrl.isNotEmpty ? imageUrl : null,
        ));
      }
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No search results found',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }
      return ScraperResult.success(list);
    } catch (e) {
      debugPrint('[SuperFlix] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Search error: $e',
        source: source,
        operationDuration: stopwatch.elapsed,
        originalError: e,
      ));
    }
  }

  @override
  Future<ScraperResult<EpisodesResult>> getEpisodes(Anime anime) async {
    final tmdbId = anime.superFlixTmdbId;
    if (tmdbId == null) {
      return ScraperResult.failure(EmptyResultError(
        message: 'No TMDB ID',
        source: source,
        operationDuration: Duration.zero,
      ));
    }
    return _getSuperFlixEpisodes(tmdbId);
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    final tmdbId = anime?.superFlixTmdbId;
    final season = TextUtils.extractSuperFlixSeason(
      episode.url,
      tmdbId,
    );
    if (tmdbId == null || season == null) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Missing tmdbId/season for stream extraction',
        source: source,
        operationDuration: Duration.zero,
      ));
    }
    final stopwatch = Stopwatch()..start();
    try {
      final sources = await _extractFromSuperFlix(tmdbId, season, episode.number);
      if (sources.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No video sources resolved',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }
      return ScraperResult.success(sources);
    } catch (e) {
      debugPrint('[SuperFlix] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source error: $e',
        source: source,
        operationDuration: stopwatch.elapsed,
        originalError: e,
      ));
    }
  }

  Future<ScraperResult<EpisodesResult>> _getSuperFlixEpisodes(String tmdbId) async {
    final stopwatch = Stopwatch()..start();

    // FFI path (preferred)
    SuperFlixFFI.instance.load();
    if (SuperFlixFFI.instance.loaded) {
      final result = SuperFlixFFI.instance.getEpisodes(tmdbId);
      if (result != null) {
        if (result.containsKey('error')) {
          debugPrint('[SuperFlixFFI] Episodes error: ${result['error']}');
        } else {
          final seasons = result['seasons'] as Map<String, dynamic>?;
          if (seasons != null && seasons.isNotEmpty) {
            final episodes = <Episode>[];
            for (final sEntry in seasons.entries) {
              final seasonNum = sEntry.key;
              final epList = sEntry.value as List;
              for (final ep in epList) {
                final epMap = ep as Map;
                final epNum = epMap['number']?.toString() ?? '';
                if (epNum.isEmpty) continue;
                final title = epMap['title']?.toString();
                episodes.add(Episode(
                  number: epNum,
                  url:
                      '${AppConstants.superFlixBase}/serie/$tmdbId/$seasonNum/$epNum',
                  title: title,
                ));
              }
            }
            episodes.sort(
              (a, b) => (double.tryParse(a.number) ?? double.infinity).compareTo(double.tryParse(b.number) ?? double.infinity),
            );
            return ScraperResult.success(EpisodesResult(episodes, {}));
          }
        }
      }
      debugPrint('[SuperFlixFFI] Episodes empty, falling back to HTTP');
    }

    // HTTP fallback path
    try {
      final url = '${AppConstants.superFlixBase}/serie/$tmdbId';
      final res = await apiClient.get(
        Uri.parse(url),
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': AppConstants.superFlixReferer,
        },
      );
      final html = res.body;

      // Cloudflare check (D-08) — BEFORE status guard (Cloudflare can return
      // 200 with a challenge page or 403/503). Headers checked in
      // isCloudflareChallenge catch CF-Ray/CF-Challenge.
      if (isCloudflareChallenge(html, res.headers)) {
        debugPrint('[SuperFlix] Cloudflare challenge on episodes page');
        return ScraperResult.failure(CloudflareError(
          message: 'Cloudflare challenge detected on episodes page',
          source: source,
          operationDuration: stopwatch.elapsed,
          detectionPattern: 'isCloudflareChallenge',
        ));
      }
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }

      final allEpisodesMatch = RegExp(
        r'var ALL_EPISODES\s*=\s*(\{.+?\});',
        dotAll: true,
      ).firstMatch(html);
      if (allEpisodesMatch == null) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No ALL_EPISODES data found',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }

      final data = jsonDecode(allEpisodesMatch.group(1)!);
      final episodes = <Episode>[];
      for (final seasonEntry in (data as Map).entries) {
        final epList = seasonEntry.value as List;
        for (final ep in epList) {
          final epMap = ep as Map;
          final airDate = epMap['air_date']?.toString() ?? '';
          if (airDate.isEmpty || airDate == 'null') continue;
          final epNum = epMap['epi_num']?.toString() ?? '';
          if (epNum.isEmpty) continue;
          final title = epMap['title']?.toString();
          episodes.add(Episode(
            number: epNum,
            url:
                '${AppConstants.superFlixBase}/serie/$tmdbId/${seasonEntry.key}/$epNum',
            title: title,
          ));
        }
      }
      if (episodes.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed',
          source: source,
          operationDuration: stopwatch.elapsed,
        ));
      }
      episodes.sort(
        (a, b) => (double.tryParse(a.number) ?? double.infinity).compareTo(double.tryParse(b.number) ?? double.infinity),
      );
      return ScraperResult.success(EpisodesResult(episodes, {}));
    } catch (e) {
      debugPrint('[SuperFlix] Episodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Episodes HTTP error: $e',
        source: source,
        operationDuration: stopwatch.elapsed,
        originalError: e,
      ));
    }
  }

  Future<List<VideoSource>> _extractFromSuperFlix(
    String tmdbId,
    String season,
    String episodeNumber,
  ) async {
    SuperFlixFFI.instance.load();
    if (SuperFlixFFI.instance.loaded) {
      final servers =
          SuperFlixFFI.instance.getServers(tmdbId, season, episodeNumber);
      if (servers != null && servers.isNotEmpty) {
        final sources = <VideoSource>[];
        final seen = <String>{};
        for (final s in servers) {
          final streamUrl = s['streamUrl']?.toString() ?? '';
          if (streamUrl.isEmpty || !seen.add(streamUrl)) continue;
          final headers = <String, String>{};
          final referer = s['referer']?.toString();
          if (referer != null && referer.isNotEmpty) {
            headers['Referer'] = referer;
          }
          sources.add(VideoSource(
            url: streamUrl,
            quality: s['name']?.toString().isNotEmpty == true
                ? s['name'].toString()
                : 'Auto',
            headers: headers,
          ));
        }
        if (sources.isNotEmpty) return sources;
      }
    }

    debugPrint('[SuperFlix] FFI unavailable, trying HTTP stream fallback');
    return _extractFromSuperFlixHttp(tmdbId, season, episodeNumber);
  }

  /// Pure-Dart fallback that mirrors the Go bridge's stream resolution so
  /// SuperFlix keeps working even when the native library cannot be loaded
  /// (e.g. 32-bit devices where only arm64/x86_64 .so files are bundled).
  /// Returns one [VideoSource] per available server.
  Future<List<VideoSource>> _extractFromSuperFlixHttp(
    String tmdbId,
    String season,
    String episodeNumber,
  ) async {
    try {
      final base = AppConstants.superFlixBase;
      final pageRes = await apiClient.get(
        Uri.parse('$base/serie/$tmdbId/$season/$episodeNumber'),
        headers: {
          'User-Agent': _sfUserAgent,
          'Referer': '$base/',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      );
      final html = pageRes.body;

      // Cloudflare check (D-08) — multi-pattern, BEFORE status guard
      if (isCloudflareChallenge(html, pageRes.headers)) {
        debugPrint('[SuperFlix] Cloudflare challenge on player page');
        return [];
      }
      if (pageRes.statusCode != 200) return [];


      final csrf = _firstGroup(html, r'var CSRF_TOKEN\s*=\s*"([^"]+)"');
      final pageToken = _firstGroup(html, r'var PAGE_TOKEN\s*=\s*"([^"]+)"');
      final contentId =
          _firstGroup(html, r'var INITIAL_CONTENT_ID\s*=\s*(\d+)');
      final contentType =
          _firstGroup(html, r'var CONTENT_TYPE\s*=\s*"([^"]+)"');
      if (csrf == null || pageToken == null) {
        debugPrint('[SuperFlix] Missing player tokens');
        return [];
      }

      final bootstrapRes = await apiClient.post(
        Uri.parse('$base/player/bootstrap'),
        headers: {
          'User-Agent': _sfUserAgent,
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': '$base/',
          'X-Page-Token': pageToken,
          'X-Requested-With': 'XMLHttpRequest',
          'Origin': base,
        },
        body:
            'contentid=$contentId&type=$contentType&_token=$csrf&page_token=$pageToken&pageToken=$pageToken',
      );
      if (bootstrapRes.statusCode != 200) return [];
      final bbody = bootstrapRes.body;
      if (bbody.trim().startsWith('<')) return [];
      final options =
          (jsonDecode(bbody) as Map)['data']?['options'] as List? ?? [];
      if (options.isEmpty) return [];

      final sources = <VideoSource>[];
      final seen = <String>{};

      String? parseId(dynamic idRaw) {
        final raw = idRaw is String ? idRaw : idRaw?.toString() ?? '';
        if (raw.startsWith('fallback')) return null;
        return raw;
      }

      for (final opt in options) {
        final videoID = parseId(opt['ID']);
        if (videoID == null) continue;
        final name = opt['name']?.toString() ?? 'Auto';

        final sourceRes = await apiClient.post(
          Uri.parse('$base/player/source'),
          headers: {
            'User-Agent': _sfUserAgent,
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': '$base/',
            'X-Page-Token': pageToken,
            'X-Requested-With': 'XMLHttpRequest',
            'Origin': base,
          },
          body: 'video_id=$videoID&page_token=$pageToken&host=&site=&_token=$csrf',
        );
        if (sourceRes.statusCode != 200) continue;
        final sbody = sourceRes.body;
        if (sbody.trim().startsWith('<')) continue;
        final videoUrl = (jsonDecode(sbody)
            as Map)['data']?['video_url']?.toString();
        if (videoUrl == null || videoUrl.isEmpty) continue;

        final resolved = await _resolveSuperFlixRedirect(videoUrl);
        if (resolved == null) continue;
        final apiRes = await apiClient.post(
          Uri.parse(
              '${resolved.baseURL}/player/index.php?data=${resolved.videoHash}&do=getVideo'),
          headers: {
            'User-Agent': _sfUserAgent,
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': resolved.referer,
            'X-Requested-With': 'XMLHttpRequest',
          },
          body: 'hash=${resolved.videoHash}&r=$base/',
        );
        if (apiRes.statusCode != 200) continue;
        final abody = apiRes.body;
        if (abody.trim().startsWith('<')) continue;
        final apiJson = jsonDecode(abody) as Map;
        final secured = apiJson['securedLink']?.toString() ??
            apiJson['videoSource']?.toString();
        if (secured == null || secured.isEmpty) continue;
        if (!seen.add(secured)) continue;
        sources.add(VideoSource(
          url: secured,
          quality: name,
          headers: {
            'Referer': resolved.referer,
            'User-Agent': _sfUserAgent,
          },
        ));
      }

      return sources;
    } catch (e) {
      debugPrint('[SuperFlix] HTTP stream error: $e');
      return [];
    }
  }

  /// Resolves a SuperFlix `video_url` (obtained via the WebView Turnstile
  /// bypass) into a final playable [VideoSource]. The redirect target and the
  /// external player's getVideo API are not Cloudflare-gated, so plain HTTP
  /// works here once we have the video_url from the (gated) player page.
  Future<VideoSource?> resolveExternalServer(String videoUrl, String name) async {
    try {
      final base = AppConstants.superFlixBase;
      final resolved = await _resolveSuperFlixRedirect(videoUrl);
      if (resolved == null) return null;
      final apiRes = await apiClient.post(
        Uri.parse(
            '${resolved.baseURL}/player/index.php?data=${resolved.videoHash}&do=getVideo'),
        headers: {
          'User-Agent': _sfUserAgent,
          'Content-Type': 'application/x-www-form-urlencoded',
          'Referer': resolved.referer,
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: 'hash=${resolved.videoHash}&r=$base/',
      );
      if (apiRes.statusCode != 200) return null;
      final abody = apiRes.body;
      if (abody.trim().startsWith('<')) return null;
      final apiJson = jsonDecode(abody) as Map;
      final secured = apiJson['securedLink']?.toString() ??
          apiJson['videoSource']?.toString();
      if (secured == null || secured.isEmpty) return null;
      return VideoSource(
        url: secured,
        quality: name.isNotEmpty ? name : 'Auto',
        headers: {
          'Referer': resolved.referer,
          'User-Agent': _sfUserAgent,
        },
      );
    } catch (e) {
      debugPrint('[SuperFlix] resolveExternalServer error: $e');
      return null;
    }
  }

  String? _firstGroup(String html, String pattern) {
    final m = RegExp(pattern).firstMatch(html);
    return m?.group(1);
  }

  Future<_ResolvedInfo?> _resolveSuperFlixRedirect(String redirectURL) async {
    try {
      final res = await apiClient.get(
        Uri.parse(redirectURL),
        headers: {
          'User-Agent': _sfUserAgent,
          'Referer': '${AppConstants.superFlixBase}/',
          'Accept': '*/*',
        },
      );
      if (res.statusCode != 200) return null;
      final finalURL = res.request?.url.toString() ?? redirectURL;
      String baseURL;
      String videoHash;
      if (finalURL.contains('/video/')) {
        final parts = finalURL.split('/video/');
        baseURL = parts[0];
        videoHash = parts[1].split('?').first.split('#').first;
      } else {
        final idx = finalURL.lastIndexOf('/');
        if (idx <= 0) return null;
        baseURL = finalURL.substring(0, idx);
        videoHash = finalURL.substring(idx + 1).split('?').first;
      }
      return _ResolvedInfo(
        baseURL: baseURL,
        videoHash: videoHash,
        referer: '$baseURL/video/$videoHash',
      );
    } catch (e) {
      debugPrint('[SuperFlix] Redirect resolve error: $e');
      return null;
    }
  }

  static String _normalizeSuperFlixImage(String url) {
    const tmdbPrefix = 'https://image.tmdb.org/t/p/';
    final idx = url.indexOf(tmdbPrefix);
    if (idx > 0) {
      var direct = url.substring(idx);
      direct = direct.replaceAll('/w342/', '/w500/');
      direct = direct.replaceAll('/w185/', '/w500/');
      direct = direct.replaceAll('/w154/', '/w500/');
      return direct;
    }
    return url;
  }
}

class _ResolvedInfo {
  final String baseURL;
  final String videoHash;
  final String referer;

  _ResolvedInfo({
    required this.baseURL,
    required this.videoHash,
    required this.referer,
  });
}
