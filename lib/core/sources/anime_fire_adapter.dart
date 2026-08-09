import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient;
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../constants/app_constants.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/episode_number.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// AnimeFire provider: HTML scraping for search, episode listing and video
/// extraction (multiple qualities via `data-video-src` + Blogger fallback).
class AnimeFireAdapter extends AnimeSourceAdapter {
  final http.Client? _client;

  AnimeFireAdapter({http.Client? client}) : _client = client;

  /// Dispatches to [http.Client.get] when a mock client is injected, otherwise
  /// falls back to the app's global [apiClient] singleton. Before the real
  /// network call, serializes AnimeFire requests (min 250ms gap) — the site
  /// rate-limits (HTTP 429) under bursts of concurrent requests.
  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) {
      return _client.get(uri, headers: headers);
    }
    await _throttle();
    return apiClient.get(uri, headers: headers);
  }

  // ponytail: global last-request timestamp — good enough for serialization;
  // switch to per-endpoint queues if throughput ever matters.
  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _throttle() async {
    final now = DateTime.now();
    final since = now.difference(_lastRequest).inMilliseconds;
    const minGap = 250;
    if (since < minGap) {
      await Future.delayed(Duration(milliseconds: minGap - since));
    }
    _lastRequest = DateTime.now();
  }

  static final RegExp _mp4Re =
      RegExp(r"""https?://[^"\'<>]+\.mp4(?:\?[^"\'<>]*)?""");
  static final RegExp _m3u8Re =
      RegExp(r"""https?://[^"\'<>]+\.m3u8(?:\?[^"\'<>]*)?""");
  static final RegExp _bloggerRe = RegExp(
      r"""https://www\.blogger\.com/video\.g\?token=([A-Za-z0-9_-]+)""");
  static final RegExp _videoApiRe =
      RegExp(r"""https://animefire\.(?:plus|io)/video/[^"'\s<>]+""");

  @override
  AnimeSource get source => AnimeSource.animeFire;

  // B11: busca funcional (única implementada de fato).
  @override
  bool get implemented => true;

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final url =
        '${AppConstants.baseSiteUrl}/pesquisar/${TextUtils.treatName(animeName)}';
    try {
      // HTTP call with timeout retry (D-04: retry once on TimeoutException)
      http.Response res;
      try {
        res = await _httpGet(Uri.parse(url), headers: {'User-Agent': AppConstants.userAgent});
      } on TimeoutException {
        debugPrint('[AnimeFire] Search timeout, retrying once...');
        res = await _httpGet(Uri.parse(url), headers: {'User-Agent': AppConstants.userAgent});
      }

      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final elements = doc.querySelectorAll('.row.ml-1.mr-1 a');
      final list = <Anime>[];
      for (final el in elements) {
        // B1: el.text concatena badges de nota/faixa etária dos filhos do <a>.
        final name = TextUtils.cleanTitle(el.text.trim());
        final href = el.attributes['href'] ?? '';
        String? thumb;
        final img = el.querySelector('img.imgAnimes');
        if (img != null) {
          // B3: data-src costuma ser caminho relativo e src um gif de
          // placeholder. Normaliza para URL absoluta e descarta placeholders.
          thumb = _normalizeThumb(
            img.attributes['data-src'] ?? img.attributes['src'],
          );
        }
        if (name.isNotEmpty && href.isNotEmpty) {
          list.add(Anime(
            name: name,
            url: _resolveUrl(href),
            source: AnimeSource.animeFire,
            fallbackImageUrl: thumb,
          ));
        }
      }
      if (list.isNotEmpty) {
        return ScraperResult.success(list);
      }

      // Fallback selector used by newer AnimeFire markup.
      final cards = doc.querySelectorAll('.card_ani');
      for (final card in cards) {
        final titleElem = card.querySelector('.ani_name a');
        final title = TextUtils.cleanTitle(titleElem?.text.trim() ?? '');
        final href = titleElem?.attributes['href'] ?? '';
        if (title.isEmpty || href.isEmpty) continue;
        final img = card.querySelector('.div_img img');
        final thumb = _normalizeThumb(img?.attributes['src']);
        list.add(Anime(
          name: title,
          url: _resolveUrl(href),
          source: AnimeSource.animeFire,
          fallbackImageUrl: thumb,
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
      // Second retry also timed out — return typed error
      return ScraperResult.failure(TimeoutError(
        message: 'Search timed out after retry',
        source: source,
      ));
    } on FormatException {
      return ScraperResult.failure(ParseFailureError(
        message: 'HTML parse failure',
        source: source,
      ));
    } catch (e) {
      debugPrint('[AnimeFire] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Unexpected error: $e',
        source: source,
      ));
    }
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    debugPrint('[AnimeFireAdapter] getEpisodes START anime=${anime.name}');
    debugPrint('[AnimeFireAdapter] anime.url=${anime.url}');

    try {
      if (anime.url.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No anime URL provided',
          source: source,
        ));
      }
      final uri = Uri.parse(anime.url);
      debugPrint('[AnimeFireAdapter] Fetching episodes from: $uri');

      final res = await _httpGet(uri, headers: {
        'User-Agent': AppConstants.userAgent,
      });

      debugPrint('[AnimeFireAdapter] Response status: ${res.statusCode}');

      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }

      final doc = html_parser.parse(res.body);
      debugPrint('[AnimeFireAdapter] Parsed HTML, looking for episodes');

      final episodeUrls = _extractEpisodeUrls(doc, anime);
      debugPrint('[AnimeFireAdapter] Found ${episodeUrls.length} episode URLs');

      if (episodeUrls.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episode URLs found in HTML',
          source: source,
        ));
      }

      final episodes = episodeUrls.asMap().entries.map((entry) {
        // Número real da URL (/animes/x/130) em vez de posição no array —
        // defesa contra páginas fora de ordem (bug 1 na camada de provider).
        final num = episodeNumberFromUrl(entry.value) ?? (entry.key + 1);
        return Episode(
          number: '$num',
          url: entry.value,
          title: 'Episódio $num',
          owner: anime,
        );
      }).toList();

      return ScraperResult.success(episodes);
    } catch (e, stackTrace) {
      debugPrint('[AnimeFireAdapter] getEpisodes ERROR: $e\n$stackTrace');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Extracts episode URLs from HTML document
  List<String> _extractEpisodeUrls(dynamic doc, Anime anime) {
    final episodeUrls = <String>[];

    final episodeElements = doc.querySelectorAll('a.lEp.epT.divNumEp.smallbox.px-2.mx-1.text-left.d-flex');

    debugPrint('[AnimeFireAdapter] Found ${episodeElements.length} episode elements');

    for (final element in episodeElements) {
      final href = element.attributes['href'];
      if (href != null && href.isNotEmpty) {
        final episodeUrl = Uri.parse(href).replace(
          scheme: 'https',
          host: 'animefire.io',
        );
        episodeUrls.add(episodeUrl.toString());
      }
    }

    return episodeUrls;
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      return _extractFromAnimeFire(episode.url);
    } catch (e) {
      debugPrint('[AnimeFire] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Extracts all available video qualities from an AnimeFire episode page.
  /// Returns one [VideoSource] per quality found (highest priority first).
  ///
  /// Empty result is typed: pages that only embed the Blogger SPA player
  /// (`/_/BloggerVideoPlayerUi` — anti-bot, no recoverable stream) fail with
  /// [BloggerUnsupportedError] so the caller can say "episódio existe mas o
  /// vídeo não abre" instead of a generic "não encontrado".
  Future<ScraperResult<List<VideoSource>>> _extractFromAnimeFire(
      String episodeUrl) async {
    try {
      debugPrint('[AnimeFire] Extracting: $episodeUrl');
      final res = await _httpGet(
        Uri.parse(episodeUrl),
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': '${AppConstants.baseSiteUrl}/',
        },
      );
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }

      final doc = html_parser.parse(res.body);
      final sources = <VideoSource>[];
      final seen = <String>{};

      void add(String url, String quality) {
        if (url.isEmpty || !seen.add(url)) return;
        sources.add(VideoSource(
          url: url,
          quality: quality,
          headers: {
            'User-Agent': AppConstants.userAgent,
            'Referer': '${AppConstants.baseSiteUrl}/',
          },
        ));
      }

      // Method 0 (primary): AnimeFire video API endpoint that returns a JSON
      // list of qualities: {"data":[{"src":...,"label":"720p"}, ...]}.
      final apiMatch = _videoApiRe.firstMatch(res.body);
      if (apiMatch != null) {
        final apiSources = await _resolveVideoApi(apiMatch.group(0)!);
        if (apiSources.isNotEmpty) return ScraperResult.success(apiSources);
      }

      // Method 1: data-video-src attributes with data-quality labels.
      doc.querySelectorAll('[data-video-src]').forEach((el) {
        final src = el.attributes['data-video-src'] ?? '';
        if (src.isEmpty) return;
        final label = el.attributes['data-quality'] ?? '';
        add(src, label.isNotEmpty ? label : 'Auto');
      });
      if (sources.isNotEmpty) return ScraperResult.success(sources);

      // Method 2: <video><source src>.
      final videoSrc = doc.querySelector('video source')?.attributes['src'] ??
          doc.querySelector('video')?.attributes['src'];
      if (videoSrc != null && videoSrc.isNotEmpty) {
        add(videoSrc, 'Auto');
        return ScraperResult.success(sources);
      }

      // Method 3: Blogger iframe.
      String? iframeSrc;
      for (final el in doc.querySelectorAll('iframe')) {
        final src = el.attributes['src'] ?? '';
        if (src.contains('blogger.com') || src.contains('blogspot.com')) {
          iframeSrc = src;
          break;
        }
      }
      if (iframeSrc != null) {
        final blogger = await _extractFromBlogger(iframeSrc);
        if (blogger.isNotEmpty) return ScraperResult.success(blogger);
      }

      // Method 4: generic data attributes.
      for (final entry in const [
        ('div[data-video]', 'data-video'),
        ('div[data-src]', 'data-src'),
        ('div[data-url]', 'data-url'),
        ('[data-player]', 'data-player'),
      ]) {
        final elem = doc.querySelector(entry.$1);
        final val = elem?.attributes[entry.$2];
        if (val != null && val.isNotEmpty) {
          add(val, 'Auto');
          return ScraperResult.success(sources);
        }
      }

      // Method 5: regex search in raw HTML.
      final html = res.body;
      final bloggerMatch = _bloggerRe.firstMatch(html);
      if (bloggerMatch != null) {
        final blogger = await _extractFromBlogger(bloggerMatch.group(0)!);
        if (blogger.isNotEmpty) return ScraperResult.success(blogger);
      }
      final mp4 = _mp4Re.firstMatch(html);
      if (mp4 != null) {
        add(mp4.group(0)!, 'Auto');
        return ScraperResult.success(sources);
      }
      final m3u8 = _m3u8Re.firstMatch(html);
      if (m3u8 != null) {
        add(m3u8.group(0)!, 'Auto');
      }
      if (sources.isNotEmpty) return ScraperResult.success(sources);

      // Nada extraído. Distingue o player SPA do Blogger (episódio existe,
      // vídeo não suportado) de um episódio que realmente não está na fonte.
      final sawBlogger = html.contains('/_/BloggerVideoPlayer') ||
          html.contains('BloggerVideoPlayerUi') ||
          html.contains('blogger.com/video.g') ||
          html.contains('blogspot.com/video.g');
      if (sawBlogger) {
        return ScraperResult.failure(BloggerUnsupportedError(
          message: 'Blogger SPA player (vídeo não suportado)',
          source: source,
        ));
      }
      return ScraperResult.failure(EmptyResultError(
        message: 'No video sources found',
        source: source,
      ));
    } catch (e) {
      debugPrint('[AnimeFire] Extract error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Extraction error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Fetches the AnimeFire `/video/...` JSON API and returns one [VideoSource]
  /// per available quality. Falls back to Blogger when the API returns a token.
  Future<List<VideoSource>> _resolveVideoApi(String videoApiUrl) async {
    try {
      final res = await _httpGet(
        Uri.parse(videoApiUrl),
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': '${AppConstants.baseSiteUrl}/',
        },
      );
      if (res.statusCode != 200) return [];

      try {
        final jsonData = jsonDecode(res.body);
        final dataList = jsonData['data'] as List?;
        if (dataList != null && dataList.isNotEmpty) {
          final result = <VideoSource>[];
          final seen = <String>{};
          for (final item in dataList) {
            final src = item['src']?.toString() ?? '';
            final label = item['label']?.toString() ?? 'Auto';
            if (src.isEmpty || !seen.add(src)) continue;
            result.add(VideoSource(
              url: src,
              quality: label,
              headers: {
                'User-Agent': AppConstants.userAgent,
                'Referer': '${AppConstants.baseSiteUrl}/',
              },
            ));
          }
          if (result.isNotEmpty) return result;
        }
        final token = jsonData['token']?.toString();
        if (token != null && token.isNotEmpty) {
          return _extractFromBlogger(
            'https://www.blogger.com/video.g?token=$token',
          );
        }
      } catch (_) {}

      // Raw fallbacks on the API body.
      final direct = _mp4Re.firstMatch(res.body) ?? _m3u8Re.firstMatch(res.body);
      if (direct != null) {
        return [
          VideoSource(
            url: direct.group(0)!,
            quality: 'Auto',
            headers: {
              'User-Agent': AppConstants.userAgent,
              'Referer': '${AppConstants.baseSiteUrl}/',
            },
          )
        ];
      }
      return [];
    } catch (e) {
      debugPrint('[AnimeFire] Video API error: $e');
      return [];
    }
  }

  Future<List<VideoSource>> _extractFromBlogger(String bloggerUrl,
      {int hop = 0}) async {
    // ponytail: hop ceiling on redirect recursion, no visited-set.
    if (hop > 5) return <VideoSource>[];
    debugPrint('[AnimeFire] Blogger: $bloggerUrl');
    final client = HttpClient();
    client.autoUncompress = false;
    client.userAgent =
        'Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36';

    try {
      final request = await client.getUrl(Uri.parse(bloggerUrl));
      request.headers.set('Referer', '${AppConstants.baseSiteUrl}/');
      request.followRedirects = false;

      final response =
          await request.close().timeout(AppConstants.requestTimeout);
      final statusCode = response.statusCode;

      if (statusCode >= 300 && statusCode < 400) {
        final location = response.headers.value('location');
        if (location != null &&
            (location.contains('.mp4') ||
                location.contains('googlevideo.com') ||
                location.contains('googleusercontent.com') ||
                location.contains('redirector.googlevideo.com') ||
                location.contains('videoplayback'))) {
          return [
            VideoSource(
              url: location.startsWith('//') ? 'https:$location' : location,
              quality: 'Auto',
              headers: {
                'User-Agent': AppConstants.userAgent,
                'Referer': '${AppConstants.baseSiteUrl}/',
              },
            )
          ];
        }
        if (location != null) {
          return _extractFromBlogger(location, hop: hop + 1);
        }
      }

      final bytes =
          await response.toList().timeout(AppConstants.requestTimeout);
      final body =
          utf8.decode(bytes.expand((x) => x).toList(), allowMalformed: true);

      final patterns = [
        RegExp(r'https://[^"\s<>]+googlevideo\.com[^"\s<>]*'),
        RegExp(r'https://[^"\s<>]+redirector\.googlevideo[^"\s<>]*'),
        RegExp(r'https://[^"\s<>]+googleusercontent\.com[^"\s<>]*'),
        RegExp(r'https://[^"\s<>]+\.mp4[^"\s<>]*'),
        RegExp(r'https://[^"\s<>]+videoplayback[^"\s<>]*'),
      ];
      for (final p in patterns) {
        final m = p.firstMatch(body);
        if (m != null) {
          return [
            VideoSource(
              url: m.group(0)!,
              quality: 'Auto',
              headers: {
                'User-Agent': AppConstants.userAgent,
                'Referer': '${AppConstants.baseSiteUrl}/',
              },
            )
          ];
        }
      }

      final configStart = body.indexOf('VIDEO_CONFIG = ');
      if (configStart != -1) {
        final jsonStart = body.indexOf('{', configStart);
        if (jsonStart != -1) {
          int braceCount = 0, jsonEnd = jsonStart;
          for (int i = jsonStart; i < body.length; i++) {
            if (body[i] == '{') {
              braceCount++;
            } else if (body[i] == '}') {
              braceCount--;
              if (braceCount == 0) {
                jsonEnd = i;
                break;
              }
            }
          }
          if (jsonEnd > jsonStart) {
            final configStr = body.substring(jsonStart, jsonEnd + 1);
            try {
              final config = jsonDecode(configStr);
              if (config is Map && config['streams'] is List) {
                final streams = config['streams'] as List;
                final result = <VideoSource>[];
                for (final s in streams) {
                  final sMap = s as Map;
                  final url = sMap['play_url']?.toString() ??
                      sMap['url']?.toString() ??
                      '';
                  final label = sMap['label']?.toString() ?? 'Auto';
                  if (url.isNotEmpty) {
                    result.add(VideoSource(
                      url: url,
                      quality: label,
                      headers: {
                        'User-Agent': AppConstants.userAgent,
                        'Referer': '${AppConstants.baseSiteUrl}/',
                      },
                    ));
                  }
                }
                if (result.isNotEmpty) return result;
              }
            } catch (_) {
              final playUrlMatch =
                  RegExp(r'"play_url"\s*:\s*"([^"]+)"').firstMatch(configStr);
              if (playUrlMatch != null) {
                return [
                  VideoSource(
                    url: playUrlMatch.group(1)!,
                    quality: 'Auto',
                    headers: {
                      'User-Agent': AppConstants.userAgent,
                      'Referer': '${AppConstants.baseSiteUrl}/',
                    },
                  )
                ];
              }
            }
          }
        }
      }

      final mp4Links = _mp4Re.allMatches(body);
      if (mp4Links.isNotEmpty) {
        final result = <VideoSource>[];
        final seen = <String>{};
        for (final m in mp4Links) {
          final url = m.group(0)!;
          if (seen.add(url)) {
            result.add(VideoSource(
              url: url,
              quality: 'Auto',
              headers: {
                'User-Agent': AppConstants.userAgent,
                'Referer': '${AppConstants.baseSiteUrl}/',
              },
            ));
          }
        }
        if (result.isNotEmpty) return result;
      }

      return [];
    } catch (e) {
      debugPrint('[AnimeFire] Blogger error: $e');
      return [];
    } finally {
      // Fase D: always release the HttpClient — previously only closed on the
      // success branches, leaking the connection on timeout/error paths.
      client.close(force: true);
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

  String _resolveUrl(String ref) {
    if (ref.startsWith('http')) return ref;
    if (ref.startsWith('/')) return '${AppConstants.baseSiteUrl}$ref';
    return '${AppConstants.baseSiteUrl}/$ref';
  }

  /// B3: normalizes a scraped image URL. Relative paths get the site origin
  /// (AnimeFire serves posters under `/uploads/...`); data-URIs/placeholder
  /// gifs are dropped so `fallbackImageUrl` stays null and the AniList cover
  /// fills in via enrich instead of issuing a broken request.
  String? _normalizeThumb(String? thumb) {
    if (thumb == null || thumb.isEmpty) return null;
    if (thumb.startsWith('data:')) return null;
    if (thumb.endsWith('.gif') || thumb.contains('placeholder')) return null;
    return _resolveUrl(thumb);
  }
}
