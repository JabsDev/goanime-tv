import 'package:http/http.dart' as http;

import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import 'anime_source_adapter.dart';

/// AnimeGG (EN, rápido): search/episódios em HTML server-side + mp4 direto
/// por qualidade no `/embed` (aba SUB = áudio JA). Sem legenda separada —
/// entra no workflow como fonte de TRANSCRIÇÃO (rápida) ou fallback.
/// Verificado em 14/09/2026: search `/search/?q=`, cards
/// `<a href="/series/x" class="mse">…<h2>Título</h2>…Episodes: N`,
/// episódios `/{slug}-episode-{n}`, vídeo `file/label` no embed SUB.
class AnimeGgAdapter extends AnimeSourceAdapter {
  final http.Client? _client;

  AnimeGgAdapter({http.Client? client}) : _client = client;

  static const _base = 'https://www.animegg.org';
  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  static final _searchCard = RegExp(
      r'<a href="(/series/[^"]+)" class="mse">.*?<h2>([^<]+)</h2>.*?<div>Episodes:\s*(\d+)</div>',
      dotAll: true);
  static final _epLink =
      RegExp(r'/([a-z0-9-]+)-episode-(\d+)', caseSensitive: false);
  static final _subEmbed = RegExp(
      r'id="subbed-[^"]*"[\s\S]*?<iframe src="([^"]+)"');
  static final _fileLabel = RegExp(
      r'file:\s*"([^"]+)"[^}]*?label:\s*"([^"]+)"', dotAll: true);

  @override
  AnimeSource get source => AnimeSource.animeGg;

  Map<String, String> get _headers => {
        'User-Agent': _userAgent,
        'Accept-Language': 'en-US,en;q=0.9',
      };

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) {
    if (_client != null) return _client.get(uri, headers: headers);
    return apiClient.get(uri, headers: headers);
  }

  /// Parse puro p/ teste (sem rede).
  static List<Anime> parseSearch(String html) {
    final out = <Anime>[];
    for (final m in _searchCard.allMatches(html)) {
      out.add(Anime(
        name: m.group(2)!.trim(),
        url: '$_base${m.group(1)!}',
        source: AnimeSource.animeGg,
        episodes: int.tryParse(m.group(3)!),
      ));
    }
    return out;
  }

  /// `(slug, ep)` únicos ordenados p/ teste.
  static List<(String, int)> parseEpisodes(String seriesSlug, String html) {
    final seen = <String>{};
    for (final m in _epLink.allMatches(html)) {
      if (m.group(1)!.toLowerCase() != seriesSlug.toLowerCase()) continue;
      final n = int.tryParse(m.group(2)!);
      if (n != null && n > 0) seen.add('$n');
    }
    final nums = seen.map(int.parse).toList()..sort();
    return [for (final n in nums) (seriesSlug, n)];
  }

  static String? parseSubEmbed(String html) =>
      _subEmbed.firstMatch(html)?.group(1);

  static List<VideoSource> parseEmbed(String embedUrl, String html) {
    final out = <VideoSource>[];
    for (final m in _fileLabel.allMatches(html)) {
      final file = m.group(1)!;
      if (!file.contains('.mp4')) continue;
      final abs = file.startsWith('http')
          ? file
          : '$_base${file.startsWith('/') ? file : '/$file'}';
      out.add(VideoSource(
        url: abs,
        quality: m.group(2)!.trim(),
        headers: {'User-Agent': _userAgent, 'Referer': embedUrl},
        audio: 'japonês',
      ));
    }
    return out;
  }

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    try {
      final uri = Uri.parse('$_base/search/').replace(queryParameters: {
        'q': query,
      });
      final res = await _get(uri, headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
            message: 'HTTP ${res.statusCode}', source: source));
      }
      return ScraperResult.success(parseSearch(res.body));
    } catch (e) {
      return ScraperResult.failure(
          EmptyResultError(message: '$e', source: source));
    }
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    try {
      final slug = anime.url.split('/').where((s) => s.isNotEmpty).last;
      final res = await _get(Uri.parse(anime.url), headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
            message: 'HTTP ${res.statusCode}', source: source));
      }
      final eps = parseEpisodes(slug, res.body);
      return ScraperResult.success([
        for (final (_, n) in eps)
          Episode(
            number: '$n',
            url: '$_base/$slug-episode-$n',
            title: '${anime.name} EP$n',
            source: source,
            owner: anime,
          ),
      ]);
    } catch (e) {
      return ScraperResult.failure(
          EmptyResultError(message: '$e', source: source));
    }
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    try {
      final epRes = await _get(Uri.parse(episode.url), headers: _headers);
      if (epRes.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
            message: 'HTTP ${epRes.statusCode}', source: source));
      }
      final embedRel = parseSubEmbed(epRes.body);
      if (embedRel == null) {
        return ScraperResult.failure(EmptyResultError(
            message: 'aba SUB sem embed', source: source));
      }
      final embedUrl = embedRel.startsWith('http')
          ? embedRel
          : '$_base${embedRel.startsWith('/') ? embedRel : '/$embedRel'}';
      final emRes = await _get(Uri.parse(embedUrl), headers: {
        ..._headers,
        'Referer': episode.url,
      });
      if (emRes.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
            message: 'HTTP ${emRes.statusCode} no embed', source: source));
      }
      final vids = parseEmbed(embedUrl, emRes.body);
      if (vids.isEmpty) {
        return ScraperResult.failure(
            EmptyResultError(message: 'sem mp4 no embed', source: source));
      }
      return ScraperResult.success(vids);
    } catch (e) {
      return ScraperResult.failure(
          EmptyResultError(message: '$e', source: source));
    }
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    final report = AvailabilityReport(
      source: source,
      animeName: animeName,
    );
    final result = await search(animeName);
    switch (result) {
      case Success(data: final animes):
        if (animes.isNotEmpty) {
          report.status = AvailabilityStatus.available;
          report.episodeCount = animes.first.episodes ?? 0;
        } else {
          report.status = AvailabilityStatus.notFound;
        }
      case Failure():
      case Loading():
        report.status = AvailabilityStatus.error;
    }
    return report;
  }
}
