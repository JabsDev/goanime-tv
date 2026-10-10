import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// Doramasflix — **catálogo de K-drama / C-drama / dorama japonês** via uma
/// API GraphQL pública e sem autenticação (`sv1.fluxcedene.net/api/gql`).
///
/// O site `doramasflix.in` é só um cliente dessa API: toda a lógica (busca,
/// detalhes, episódios, links) vive no GraphQL, com introspection aberta.
/// Isso faz desta fonte a melhor candidata para resolver o **maior gap de
/// produto do app**: hoje não existe NENHUM catálogo de drama — o AniList é
/// exclusivamente anime.
///
/// ⚠️ Idioma — leitura honesta do acervo (auditoria de 10/10/2026):
/// `listLanguagees` declara 12 idiomas, **incluindo Português**, mas o
/// acervo real é **Latino/Espanhol**. Amostra de 800 dramas via
/// `listDoramas(limit:200, skip:0|200|400|600)` deu apenas os códigos
/// `13109` (534), `13111` (223), `38` (118), `13112` (39), `13110` (22),
/// `13114` (3), `13113` (1) — **zero** itens com o id de Português
/// (`64bad14b3cdb8dd0a7032619`), e `filter:{bylanguage:"Portugués"}`
/// retorna `[]`. Por isso esta fonte é marcada como **espanhola** em
/// [AnimeSourceLanguage], não como PT-BR.
///
/// ⚠️ Vídeo — a API é índice, não host. `listEpisodes` devolve `urls[]`
/// apontando para `doramasyt.com` e `doramasmp4.com`. O `doramasyt` embute o
/// vídeo em `data-player` (base64 de `{iv,value,mac}` = AES-CBC com MAC,
/// mesmo esquema `Protector` do AnimesDigital) — **não implementamos o
/// decifrador**. O adapter entrega o catálogo e deixa a reprodução com o
/// **fallback por WebView** que o app já tem (`watchUrl` → `WebViewPlayerScreen`),
/// que é o caminho honesto para esse hoster.
class DoramasflixAdapter extends AnimeSourceAdapter {
  static const _apiBase = 'https://sv1.fluxcedene.net/api/gql';
  static const _siteBase = 'https://doramasflix.in';

  /// Base de imagens do TMDB — `poster_path` vem no formato `/xxxx.jpg`.
  static const _tmdbImage = 'https://image.tmdb.org/t/p/w500';

  /// Idiomas do acervo, na ordem em que `listLanguagees` os devolve.
  /// Usados só para rotular o que o app mostra.
  static const _languageLabels = {
    '38': 'Latino',
    '13109': 'Subtitulado',
    '13110': 'Subtitulado',
    '13111': 'Subtitulado',
    '13112': 'Subtitulado',
    '13113': 'Subtitulado',
    '13114': 'Subtitulado',
    '37': 'Latino',
  };

  /// Hosters preferidos na escolha do link de um episódio, na ordem.
  /// `doramasyt` é o que responde; `doramasmp4` apareceu como DNS morto.
  static const _preferredPages = ['doramasyt', 'doramasmp4'];

  final http.Client? _client;

  DoramasflixAdapter({http.Client? client}) : _client = client;

  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  Map<String, String> get _headers => {
        'User-Agent': _userAgent,
        'Origin': _siteBase,
        'Referer': '$_siteBase/',
      };

  Future<http.Response> _post(String query) async {
    final uri = Uri.parse(_apiBase);
    final body = jsonEncode({'query': query});
    if (_client != null) {
      return _client.post(uri, headers: {..._headers, 'Content-Type': 'application/json'}, body: body);
    }
    return apiClient.postJson(uri, json: {'query': query}, headers: _headers);
  }

  @override
  AnimeSource get source => AnimeSource.doramasflix;

  // ───────────────────────────── parse (público) ──────────────────────────

  /// Extrai os dramas de uma resposta `searchDorama` / `listDoramas`.
  static List<Anime> parseDoramas(String body) {
    final rows = _dataList(body, 'searchDorama') ?? _dataList(body, 'listDoramas');
    if (rows == null) return const [];
    final out = <Anime>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final id = raw['_id']?.toString() ?? '';
      final name = TextUtils.cleanTitle(raw['name']?.toString() ?? '');
      if (id.isEmpty || name.isEmpty) continue;
      final posterPath = raw['poster_path']?.toString() ?? '';
      out.add(Anime(
        name: name,
        // O id do GraphQL é o que abre a lista de episódios; a página web
        // correspondente é usada só como "onde assistir" no WebView.
        url: '$_siteBase/dorama/$id',
        source: AnimeSource.doramasflix,
        fallbackImageUrl:
            posterPath.isEmpty ? null : '$_tmdbImage$posterPath',
        description: TextUtils.cleanTitle(raw['overview']?.toString() ?? ''),
        episodes: _asInt(raw['number_of_episodes']),
        status: raw['status']?.toString(),
        genres: (raw['genres'] is List)
            ? (raw['genres'] as List)
                .whereType<Map>()
                .map((g) => g['name']?.toString() ?? '')
                .where((g) => g.isNotEmpty)
                .toList()
            : const [],
      ));
    }
    return out;
  }

  /// Escolhe a página de vídeo de um episódio entre os `urls[]` da API,
  /// respeitando a preferência de host e devolvendo (url, idioma).
  ///
  /// A API devolve o mesmo episódio em vários idiomas (ex.: `13109`
  ///=subtitulado, `38`=latino). Preferimos o primeiro hoster conhecido e,
  /// empatado, o idioma mais baixo do acervo (`38` = Latino vem antes de
  /// `13109` no dicionário acima, mas comparamos numericamente).
  static ({String url, String? lang})? pickEpisodePage(Map episode) {
    final urls = episode['urls'];
    if (urls is! List || urls.isEmpty) return null;
    final candidates = <Map>[];
    for (final u in urls) {
      if (u is! Map) continue;
      final url = u['url']?.toString() ?? '';
      if (url.isEmpty) continue;
      candidates.add(u);
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final pa = _preferredPages.indexOf(a['page']?.toString() ?? '');
      final pb = _preferredPages.indexOf(b['page']?.toString() ?? '');
      // Hoster desconhecido vai para o fim.
      final ra = pa < 0 ? 99 : pa;
      final rb = pb < 0 ? 99 : pb;
      if (ra != rb) return ra.compareTo(rb);
      final la = int.tryParse(a['lang']?.toString() ?? '') ?? 9999;
      final lb = int.tryParse(b['lang']?.toString() ?? '') ?? 9999;
      return la.compareTo(lb);
    });
    final best = candidates.first;
    return (
      url: best['url']!.toString(),
      lang: _languageLabels[best['lang']?.toString() ?? ''],
    );
  }

  /// Converte `listEpisodes` em [Episode]. Episódios sem página de vídeo
  /// (a maioria está como "commingSoon") são mantidos, mas sem URL — o app
  /// os mostra como indisponíveis em vez de sumir com o episódio da grade.
  static List<Episode> parseEpisodes(String body, {Anime? owner}) {
    final rows = _dataList(body, 'listEpisodes');
    if (rows == null) return const [];
    final out = <Episode>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final n = _asInt(raw['episode_number']);
      if (n == null) continue;
      final pick = pickEpisodePage(raw);
      final season = _asInt(raw['season_number']);
      out.add(Episode(
        number: '$n',
        url: pick?.url ?? '',
        title: raw['name']?.toString(),
        season: season,
        source: AnimeSource.doramasflix,
        owner: owner,
      ));
    }
    out.sort((a, b) =>
        (int.tryParse(a.number) ?? 0).compareTo(int.tryParse(b.number) ?? 0));
    return out;
  }

  /// `data` do envelope GraphQL como lista, ou null quando o payload veio
  /// com `errors` (a API devolve 200 mesmo em erro de GraphQL).
  static List? _dataList(String body, String key) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      if (decoded['errors'] is List && decoded['errors'].isNotEmpty) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final list = data[key];
      return list is List ? list : null;
    } catch (_) {
      return null;
    }
  }

  static int? _asInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  static String? _idOf(String url) {
    final segs = Uri.tryParse(url)?.pathSegments ?? const [];
    if (segs.length < 2) return null;
    return segs.last;
  }

  // ─────────────────────────────── rede ───────────────────────────────────

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final q = TextUtils.cleanSearchQuery(animeName);
    if (q.isEmpty) return ScraperResult.success(const []);
    try {
      final res = await _post('query { searchDorama(input: '
          '${jsonEncode(q)}, limit: 20) { _id name overview country '
          'poster_path languages genres { name } status '
          'number_of_episodes first_air_date } }');
      final list = parseDoramas(res.body);
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No results for "$animeName"',
          source: source,
        ));
      }
      return ScraperResult.success(list);
    } catch (e) {
      debugPrint('[Doramasflix] search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Search failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    final id = _idOf(anime.url);
    if (id == null) {
      return ScraperResult.failure(EmptyResultError(
        message: 'No Doramasflix id in URL: ${anime.url}',
        source: source,
      ));
    }
    try {
      final res = await _post('query { listEpisodes(limit: 400, '
          'filter: { serie_id: ${jsonEncode(id)} }) { _id name '
          'episode_number season_number air_date commingSoon '
          'urls { page url lang } } }');
      final eps = parseEpisodes(res.body, owner: anime);
      if (eps.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed for $id',
          source: source,
        ));
      }
      return ScraperResult.success(eps);
    } catch (e) {
      debugPrint('[Doramasflix] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes failed: $e',
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
    // Catálogo-first: o vídeo do `doramasyt` vive num `data-player`
    // criptografado (AES-CBC + MAC) que não implementamos. Devolvendo
    // `EmptyResultError` o app cai no fallback por WebView (ver [watchUrl]),
    // que é o caminho honesto — melhor que oferecer um link quebrado.
    return ScraperResult.failure(EmptyResultError(
      message: 'Native stream not available — use WebView fallback',
      source: source,
    ));
  }

  /// Página do episódio no hoster, para o fallback por WebView.
  @override
  Future<String?> watchUrlForMatched(Anime match, int episodeNumber) async {
    final eps = await getEpisodes(match);
    if (eps is! Success<List<Episode>>) return null;
    for (final e in eps.data) {
      if (int.tryParse(e.number) == episodeNumber && e.url.isNotEmpty) {
        return e.url;
      }
    }
    return null;
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    final report = AvailabilityReport(source: source, animeName: animeName);
    try {
      final result = await search(animeName);
      switch (result) {
        case Success(data: final animes):
          if (animes.isEmpty) {
            report.status = AvailabilityStatus.notFound;
            report.reason = 'Not in Doramasflix catalog';
          } else {
            report.status = AvailabilityStatus.available;
            report.episodeCount = animes.first.episodes;
          }
        case Failure(error: final err):
          report.status = err is EmptyResultError
              ? AvailabilityStatus.notFound
              : AvailabilityStatus.error;
          report.reason = err.message;
        case Loading():
          report.status = AvailabilityStatus.error;
      }
    } catch (e) {
      report.status = AvailabilityStatus.exception;
      report.reason = '$e';
    }
    return report;
  }
}