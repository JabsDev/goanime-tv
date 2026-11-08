import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' show Document, Element;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';
import 'blogger_spa_resolver.dart';
import 'cdn_resolver.dart';
import 'dooplay_v2_extractor.dart';

/// AnimesOnline-cluster provider (PT-BR): `animesonline.cloud`, its clones
/// `animesdrive.cloud` and `animeq.cloud` (same database, `wp_json` transport)
/// and `animeplay.cloud` (`admin_ajax` transport). `animesonlinecc.to` é o
/// tema antigo do cluster, mantido como espelho desligado (player Blogger).
/// Search and episode listing are HTML scraping; video resolves through
/// [DooPlayV2Extractor] (Layer A) with the CDN probe fallback (Layer B) as
/// last resort.
///
/// Domain note (06/10/2026): `animesdrive.online` → 301 → `animesdrive.cloud`
/// and `animeq.blog` → 301 → `animeq.cloud`; the constants below point
/// straight at the canonical hosts to skip the redirect hop.
///
/// Season layout (probe 12/09/2026, Slime S4): SPLIT pages — one URL per
/// season (`…/anime/…-4th-season`, block `se-t se-o'>4`), episodes numbered
/// in-season via `data-episode-number`. No combined-page season collapse, so
/// the default number match is correct once [AnimeSourceAdapter.bestMatch]
/// pins the season page (season bonus). The EN-first [resolveAnime] searches
/// by English title, but [resolveVideo] keeps using `catalog.name` (romaji
/// with "Season") as the season hint — search language never leaks into it.
class AnimesOnlineAdapter extends AnimeSourceAdapter {
  final AnimeSource _source;
  final http.Client? _client;

  AnimesOnlineAdapter({
    required AnimeSource source,
    http.Client? client,
  })  : _source = source,
        _client = client;

  static const Map<AnimeSource, String> baseUrls = {
    AnimeSource.animesOnlineCloud: 'https://animesonline.cloud',
    AnimeSource.animesOnlineCc: 'https://animesonlinecc.to',
    AnimeSource.animesDrive: 'https://animesdrive.cloud',
    AnimeSource.animeQ: 'https://animeq.cloud',
    AnimeSource.animePlay: 'https://animeplay.cloud',
  };

  String get baseUrl => baseUrls[_source] ?? 'https://animesonline.cloud';

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  Future<http.Response> _httpGet(Uri uri, {Map<String, String>? headers}) async {
    if (_client != null) return _client.get(uri, headers: headers);
    return apiClient.get(uri, headers: headers);
  }

  @override
  AnimeSource get source => _source;

  /// animeplay.cloud devolve 403 em todas as rotas (verificado 09/09/2026) —
  /// fica fora do fan-out até voltar. Os outros 3 do cluster respondem 200.
  ///
  /// `animesonlinecc.to` é o tema antigo do cluster: catálogo e listagem
  /// funcionam, mas o player é um iframe do Blogger e o `googlevideo` devolve
  /// 403 (token sem `pot`), o mesmo sintoma do Meus Animes/anroll.cc em
  /// 21/10/2026. Fica como espelho DESLIGADO do fan-out até o player voltar —
  /// aí basta remover a condição abaixo.
  @override
  bool get implemented =>
      _source != AnimeSource.animePlay &&
      _source != AnimeSource.animesOnlineCc;

  @override
  Future<Anime?> resolveAnime(Anime animeRef) async {
    // Cluster catalogs index series by English (PT-BR) title; a romaji name
    // ("Ore dake Level Up na Ken") leaves bestMatch with no title signal, so
    // the site's own ordering wins and S2/spin-offs beat the main series.
    // Search the English title first, fall back to the given name.
    final queries = <String>{
      if (animeRef.englishName != null && animeRef.englishName!.isNotEmpty)
        animeRef.englishName!,
      animeRef.name,
    };
    for (final q in queries) {
      final result = await search(TextUtils.cleanSearchQuery(q));
      switch (result) {
        case Success(data: final candidates):
          final valid = candidates
              .where((a) => a.url.isNotEmpty && _overlaps(q, a.name))
              .toList();
          if (valid.isEmpty) continue;
          // Same-season pinning when the entry URL carries a season
          // (`…-4th-season` split pages); otherwise plain bestMatch.
          return AnimeSourceAdapter.pinSeasonPage(
              q, valid, source, animeRef.url);
        case Failure():
        case Loading():
          continue;
      }
    }
    return null;
  }

  static bool _overlaps(String query, String candidate) {
    final q = AnimeSourceAdapter.normalize(query);
    final c = AnimeSourceAdapter.normalize(candidate);
    if (q == c || q.contains(c) || c.contains(q)) return true;
    return q.split(' ').any(c.split(' ').contains);
  }

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    final url = Uri.parse('$baseUrl/?s=${Uri.encodeQueryComponent(query)}');
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
      for (final item in doc.querySelectorAll('.result-item article')) {
        final a = item.querySelector('.image a') ?? item.querySelector('a');
        final href = a?.attributes['href'] ?? '';
        // P9: the catalog serves films under `/filme/`; the video addresses are
        // under `/anime/` (TV) only.
        if (href.isEmpty || !href.contains('/anime/')) continue;
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
      debugPrint('[AnimesOnline] Search error: $e');
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
      final res = await _httpGet(Uri.parse(anime.url), headers: {'User-Agent': _ua});
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final doc = html_parser.parse(res.body);
      final list = _episodesFromTheme(doc, anime);
      _sortEpisodes(list);
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes found in HTML',
          source: source,
        ));
      }
      return ScraperResult.success(list);
} catch (e, st) {
      debugPrint('[AnimesOnline] Search stack: $st');
      debugPrint('[AnimesOnline] Search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Unexpected error: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Grade do tema DooPlay atual. Duas variantes convivem no cluster:
  ///
  ///  - `#seasons .se-c` agrupa uma temporada e dentro dela os episódios são
  ///    `div.episode-card[data-episode-number]` (`animesdrive.cloud`,
  ///    `animeq.cloud`) **ou** `ul.episodios li a[href*="/episodio/"]`
  ///    (`animesonline.cloud` e o tema antigo `animesonlinecc.to`; o
  ///    `animesonline.cloud` deixou de emitir `.episode-card` — era por isso
  ///    que o EP 23 do Slime S4 só voltava pelo AnimeFire).
  ///  - Documento sem `#seasons`: `.episode-card` solto (fixtures/páginas
  ///    antigas).
  ///
  /// Número: `data-episode-number` > `-episodio-<N>` no href. Temporada:
  /// `.se-t` ("4") > `.numerando` ("4 - 23"). O mesmo link aparece duas vezes
  /// (capa + título), então dedupe por href.
  List<Episode> _episodesFromTheme(Document doc, Anime anime) {
    final list = <Episode>[];
    final seen = <String>{};

    void addCard(Element card, int? season) {
      final numAttr = card.attributes['data-episode-number']?.toString();
      final a = card.querySelector('a[href*="/episodio/"]') ??
          card.querySelector('a[href]');
      final href = _absolute(a?.attributes['href']);
      if (href.isEmpty || !seen.add(href)) return;
      final number = numAttr ?? _episodeNumber(href)?.toString() ?? '';
      if (number.isEmpty) return;
      final attrTitle = card.attributes['data-episode-title']?.trim() ?? '';
      final anchorTitle = a?.text.trim() ?? '';
      list.add(Episode(
        number: number,
        url: href,
        title: attrTitle.isNotEmpty
            ? attrTitle
            : anchorTitle.isNotEmpty
                ? anchorTitle
                : null,
        thumbnail: card.querySelector('img')?.attributes['src'],
        season: season,
        owner: anime,
        source: source,
      ));
    }

    void addAnchor(Element a, int? season) {
      final href = _absolute(a.attributes['href']);
      if (href.isEmpty || !seen.add(href)) return;
      final m = RegExp(r'episodio[^/]*?[-]?(\d+)/?$').firstMatch(href);
      final number = m?.group(1) ?? _episodeNumber(href)?.toString();
      if (number == null || number.isEmpty) return;
      final li = a.parent?.parent;
      // Sem bloco `#seasons` reconhecido, o `.numerando` do próprio item
      // ("4 - 23") ainda entrega a temporada.
      var seasonOfItem = season;
      if (seasonOfItem == null) {
        final num = li?.querySelector('.numerando')?.text.trim() ?? '';
        final sm = RegExp(r'^\s*(\d{1,2})\s*[-x]').firstMatch(num);
        seasonOfItem = sm == null ? null : int.tryParse(sm.group(1)!);
      }
      list.add(Episode(
        number: number,
        url: href,
        title: a.text.trim().isEmpty ? null : a.text.trim(),
        thumbnail: li?.querySelector('img')?.attributes['src'],
        season: seasonOfItem,
        owner: anime,
        source: source,
      ));
    }

    for (final block in doc.querySelectorAll('#seasons .se-c')) {
      final season = _seasonOfBlock(block);
      for (final card in block.querySelectorAll('.episode-card')) {
        addCard(card, season);
      }
      for (final a in block.querySelectorAll('ul.episodios li a[href*="/episodio/"]')) {
        addAnchor(a, season);
      }
    }
    if (list.isEmpty) {
      for (final card in doc.querySelectorAll('.episode-card')) {
        addCard(card, _seasonOfBlock(card.parent));
      }
      // Variante sem `#seasons .se-c` (alguns espelhos): a lista antiga ainda
      // aparece solta no documento.
      for (final a in doc.querySelectorAll('ul.episodios li a[href*="/episodio/"]')) {
        addAnchor(a, null);
      }
    }
    return list;
  }

  /// Season number of a `#seasons .se-c` block: header `.se-t` or the first
  /// episode's `.numerando` ("4 - 23" → 4). Null when the page carries none.
  int? _seasonOfBlock(Element? block) {
    if (block == null) return null;
    final header = int.tryParse(
        block.querySelector('.se-t')?.text.trim() ?? '');
    if (header != null && header > 0) return header;
    final numerando = block.querySelector('.numerando')?.text.trim() ?? '';
    final m = RegExp(r'^\s*(\d{1,2})\s*[-x]').firstMatch(numerando);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  String _absolute(String? href) {
    final h = href?.trim() ?? '';
    if (h.isEmpty) return '';
    if (h.startsWith('http')) return h;
    if (h.startsWith('/')) return '$baseUrl$h';
    return '$baseUrl/$h';
  }

  void _sortEpisodes(List<Episode> list) {
    list.sort((a, b) {
      final sa = a.season ?? 0;
      final sb = b.season ?? 0;
      if (sa != sb) return sa.compareTo(sb);
      final na = int.tryParse(a.number);
      final nb = int.tryParse(b.number);
      if (na == null && nb == null) return a.url.compareTo(b.url);
      if (na == null) return 1;
      if (nb == null) return -1;
      if (na != nb) return na.compareTo(nb);
      return a.url.compareTo(b.url);
    });
  }

  /// Player do tema antigo: iframes diretos do Blogger. Passa pelo
  /// [BloggerSpaResolver] (o mesmo dos outros DooPlay) e, se nada responder,
  /// cai no CDN por título+episódio (Layer B).
  Future<ScraperResult<List<VideoSource>>> _videoFromOldTheme(
      Episode episode, Anime? anime) async {
    try {
      final res = await _httpGet(Uri.parse(episode.url), headers: {'User-Agent': _ua});
      if (res.statusCode == 200) {
        final doc = html_parser.parse(res.body);
        final resolver = BloggerSpaResolver(client: _client);
        for (final iframe in doc.querySelectorAll('iframe[src]')) {
          final src = iframe.attributes['src'] ?? '';
          if (!src.contains('blogger.com')) continue;
          final sources =
              await resolver.resolve(embedUrl: src, referer: episode.url);
          if (sources.isNotEmpty) return ScraperResult.success(sources);
        }
      }
      final ctx = anime ?? episode.owner;
      final title = ctx?.name ?? '';
      final ep = int.tryParse(episode.number);
      if (title.isNotEmpty && ep != null) {
        final url = await CdnResolver(client: _client)
            .resolve(title, ep, englishName: ctx?.englishName);
        if (url != null) {
          return ScraperResult.success([
            VideoSource(
              url: url,
              quality: 'Auto',
              headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'},
            ),
          ]);
        }
      }
      return ScraperResult.failure(BloggerUnsupportedError(
        message: 'Blogger-only player (googlevideo 403)',
        source: source,
      ));
    } catch (e) {
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  int? _episodeNumber(String url) {
    final m = RegExp(r'episodio[^/]*?[-]?(\d+)\s*/?$').firstMatch(url);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Áudio que a página do provedor entrega. O cluster separa as variantes em
  /// páginas distintas (`…-4th-season` = legendado, `…-dublado` = dublado) e o
  /// NOME das duas é idêntico (o `normalize` remove "dublado"), então a URL é
  /// a única fonte de verdade.
  String _audioTag(Anime? anime, Episode episode) {
    final url = '${anime?.url ?? ''} ${episode.url}'.toLowerCase();
    return url.contains('dublado') ? 'dublado' : 'legendado';
  }

  /// Season-aware resolve: o catálogo AniList divide temporadas em entradas
  /// ("… 4th Season") e a página do cluster é uma temporada por URL, então o
  /// número do episódio é relativo à temporada. Páginas combinadas (raro no
  /// cluster) caem no absoluto; página com ≥2 temporadas e sem hit na
  /// temporada pedida devolve vazio (nunca S4E23 → S1E23).
  @override
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber,
      {Anime? catalog}) async {
    final eps = await getEpisodes(match);
    Episode? target;
    switch (eps) {
      case Success(:final data):
        final hint =
            (catalog == null ? null : TextUtils.seasonOf(catalog.name)) ??
                AnimeSourceAdapter.seasonOfCandidateUrl(match.url);
        if (hint != null) {
          final inSeason = data
              .where((e) => e.season == hint)
              .toList()
            ..sort((a, b) => (int.tryParse(a.number) ?? 0)
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
            debugPrint('[SeasonResolve] AnimesOnline fallback absoluto '
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
    final audio = _audioTag(anime, episode);
    if (_source == AnimeSource.animesOnlineCc) {
      final result = await _videoFromOldTheme(episode, anime);
      if (result is Success<List<VideoSource>>) {
        return ScraperResult.success(
            result.data.map((s) => s.withAudio(audio)).toList());
      }
      return result;
    }
    try {
      final extractor = DooPlayV2Extractor(baseUrl: baseUrl, client: _client);
      final sources = await extractor.extractPlayable(episode.url);
      return ScraperResult.success(
          sources.map((s) => s.withAudio(audio)).toList());
    } on NoPlayableOption catch (e) {
      // Layer B (last resort): probe the CDN directly by title + episode.
      final ctx = anime ?? episode.owner;
      final title = ctx?.name ?? '';
      final ep = int.tryParse(episode.number);
      if (title.isNotEmpty && ep != null) {
        try {
          final url = await CdnResolver(client: _client).resolve(title, ep,
              englishName: ctx?.englishName);
          if (url != null) {
            return ScraperResult.success([
              VideoSource(
                url: url,
                quality: 'Auto',
                headers: {'User-Agent': _ua, 'Referer': '$baseUrl/'},
                audio: audio,
              ),
            ]);
          }
        } catch (e2) {
          debugPrint('[AnimesOnline] CDN fallback error: $e2');
        }
      }
      return ScraperResult.failure(EmptyResultError(
        message: 'No playable option: ${e.message}',
        source: source,
      ));
    } catch (e) {
      debugPrint('[AnimesOnline] Video sources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video source extraction failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    final report = AvailabilityReport(source: source, animeName: animeName);
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