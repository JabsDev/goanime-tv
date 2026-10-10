import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// Internet Archive — catálogo profundo de audiovisual, **sem anti-bot e sem
/// DRM**, com MP4 direto. É a rota mais "legal" de todas (domínio público /
/// licença livre) e já existia no app como estudo hardcoded (§Haibane).
/// Esta implementação **generaliza** aquele caso para o acervo inteiro.
///
/// API usada (verificada ao vivo em 10/10/2026):
///  - `GET /advancedsearch.php?q=…&fl[]=identifier&rows=&page=&output=json`
///    → `{response:{numFound, docs:[{identifier,title,year,collection}]}}`
///  - `GET /metadata/{identifier}`
///    → `{server, dir, files:[{name,format,size}]}` — **lista de arquivos com
///    formato e tamanho**, o que permite escolher o melhor `.mp4` sem
///    adivinhação.
///  - Vídeo: `GET https://archive.org/download/{identifier}/{arquivo}` → 302→200.
///
/// ⚠️ **Não existe HLS.** `…/arquivo.mp4.m3u8` responde `302 → text/html`
/// (página de erro), não um manifest. Por isso o app toca MP4 direto — que é
/// exatamente o caminho que o `media_kit` já usa aqui.
///
/// ⚠️ **O índice de busca é poluído.** O `q` textual varre espelhos do
/// YouTube (`youtube-*`) e VODs da Twitch (`TwitchVod-*`), não o acervo
/// curado — `mediatype:movies AND subject:"anime"` devolve 62.756 itens cujo
/// topo é reaction/vídeo aleatório. Por isso [search] **ancora em coleções**
/// (`opensource_movies`, `feature_films`) e descarta os prefixos de lixo
/// explicitamente. Buscar sem isso devolve lixo do mesmo tipo.
class ArchiveJpAdapter extends AnimeSourceAdapter {
  static const _apiBase = 'https://archive.org';
  static const _searchBase = '$_apiBase/advancedsearch.php';
  static const _metaBase = '$_apiBase/metadata';

  /// Coleções curadas — o acervo "de verdade", sem os espelhos do YouTube.
  static const _collections = ['opensource_movies', 'feature_films'];

  /// Prefixos de itens que são lixo indexado (espelhos de rede social).
  static const _junkPrefixes = ['youtube-', 'TwitchVod', 'vimeo-'];

  /// Formatos preferidos na escolha do arquivo de vídeo, em ordem. `h.264`
  /// é o que o player engole melhor (o `.mkv` Matroska também roda, mas
  /// ocupa o dobro).
  static const _preferredFormats = ['h.264', 'MPEG4', '512Kb MPEG4', 'Ogg Video'];

  final http.Client? _client;

  ArchiveJpAdapter({http.Client? client}) : _client = client;

  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  Map<String, String> get _headers => {'User-Agent': _userAgent};

  Future<http.Response> _get(Uri uri) {
    if (_client != null) return _client.get(uri, headers: _headers);
    return apiClient.get(uri, headers: _headers);
  }

  @override
  AnimeSource get source => AnimeSource.archiveJp;

  // ───────────────────────────── parse (público) ──────────────────────────

  /// Documentos do `advancedsearch` → [Anime]. Filtra os prefixos de lixo.
  static List<Anime> parseSearch(String body) {
    Map<String, dynamic>? doc;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['response'] is Map) {
        doc = Map<String, dynamic>.from(decoded['response'] as Map);
      }
    } catch (_) {
      return const [];
    }
    final docs = doc?['docs'];
    if (docs is! List) return const [];
    final out = <Anime>[];
    for (final raw in docs) {
      if (raw is! Map) continue;
      final id = raw['identifier']?.toString() ?? '';
      final title = TextUtils.cleanTitle(raw['title']?.toString() ?? '');
      if (id.isEmpty || title.isEmpty) continue;
      if (_junkPrefixes.any(id.startsWith)) continue;
      final year = raw['year'];
      out.add(Anime(
        name: year == null ? title : '$title ($year)',
        url: '$_apiBase/details/$id',
        source: AnimeSource.archiveJp,
      ));
    }
    return out;
  }

  /// Escolhe os arquivos de vídeo de um item via `/metadata`.
  ///
  /// Só aceita nomes com extensão de vídeo known (`.mp4`, `.m4v`, `.webm`,
  /// `.ogv`, `.mkv`) e **ignora** derivados que não são vídeo (`.xml`,
  /// `_meta.xml`, `.txt`, thumbnails `.jpg`, `.gif`, `.png`). O critério de
  /// qualidade é: extensão de vídeo primeiro, depois o `format` preferido
  /// (`h.264`), depois o **maior tamanho** (melhor encode do mesmo item).
  static List<String> pickVideoFiles(String body, {String? contains}) {
    Map<String, dynamic>? meta;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) meta = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return const [];
    }
    final files = meta?['files'];
    if (files is! List) return const [];

    final videoExt = RegExp(r'\.(mp4|m4v|webm|ogv|mkv)$', caseSensitive: false);
    final candidates = <Map>[];
    for (final f in files) {
      if (f is! Map) continue;
      final name = f['name']?.toString() ?? '';
      if (!videoExt.hasMatch(name)) continue;
      // Derivados do player do IA (`_512kb.mp4`, `_meta.mp4`) e arte.
      final base = name.split('.').first.toLowerCase();
      if (base.endsWith('_meta') || base.endsWith('_512kb') || base.endsWith('_ia')) {
        continue;
      }
      if (contains != null && contains.isNotEmpty && !name.contains(contains)) {
        continue;
      }
      final size = int.tryParse(f['size']?.toString() ?? '') ?? 0;
      final fmt = f['format']?.toString() ?? '';
      var rank = _preferredFormats.indexOf(fmt);
      if (rank < 0) rank = _preferredFormats.length;
      candidates.add({'name': name, 'size': size, 'rank': rank});
    }
    if (candidates.isEmpty) return const [];
    candidates.sort((a, b) {
      final r = (a['rank']! as int).compareTo(b['rank']! as int);
      if (r != 0) return r;
      return (b['size']! as int).compareTo(a['size']! as int);
    });
    return candidates.map((c) => c['name']! as String).toList();
  }

  /// Deduz o rótulo de qualidade pelo nome do arquivo
  /// (`…_1080p…` / `…_512kb…` / `…_720p…`). "Auto" quando não há sinal.
  static String qualityOf(String fileName) {
    final p = RegExp(r'(\d{3,4})p').firstMatch(fileName);
    if (p != null) return '${p.group(1)}p';
    final kb = RegExp(r'(\d{3,4})kb', caseSensitive: false).firstMatch(fileName);
    if (kb != null) return '${kb.group(1)}kb';
    return 'Auto';
  }

  /// URL de download direta. Arquivos com espaço precisam de encode.
  static String downloadUrl(String identifier, String fileName) {
    final encoded = Uri.encodeComponent(fileName).replaceAll('%2F', '/');
    return '$_apiBase/download/$identifier/$encoded';
  }

  static String? identifierOf(String url) {
    final segs = Uri.tryParse(url)?.pathSegments ?? const [];
    if (segs.length < 2 || segs.first != 'details') return null;
    return segs[1];
  }

  // ─────────────────────────────── rede ───────────────────────────────────

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final q = TextUtils.cleanSearchQuery(animeName);
    if (q.isEmpty) return ScraperResult.success(const []);
    // Ancora em coleção E em título: sem o `collection:` o topo do índice
    // é espelho de YouTube (ver doc do adapter).
    final coll = _collections.map((c) => 'collection:($c)').join(' OR ');
    final query =
        'mediatype:movies AND ($coll) AND title:(${jsonEncode(q)})';
    try {
      // `fl[]` é repetido — `Uri.replace(queryParameters:)` não aceita
      // chaves duplicadas, então a query é montada à mão (mesmo formato
      // que o site envia: `fl%5B%5D=`).
      final queryString = Uri.encodeQueryComponent(query) +
          '&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=year' +
          '&rows=40&page=1&output=json';
      final uri = Uri.parse('$_searchBase?$queryString');
      final res = await _get(uri);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final list = parseSearch(res.body);
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No curated results for "$animeName"',
          source: source,
        ));
      }
      return ScraperResult.success(list);
    } catch (e) {
      debugPrint('[Archive] search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Search failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    final id = identifierOf(anime.url);
    if (id == null) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Not an Internet Archive item URL: ${anime.url}',
        source: source,
      ));
    }
    try {
      final res = await _get(Uri.parse('$_metaBase/$id'));
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200 on metadata: ${res.statusCode}',
          source: source,
        ));
      }
      final files = pickVideoFiles(res.body);
      if (files.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No video files in $id',
          source: source,
        ));
      }
      // Deduplica por número de episódio quando o nome permitir
      // (`Haibane Renmei - S01E01.mp4`); sem sinal, cai para a ordem do
      // próprio item (que já vem em ordem de carga).
      final eps = <Episode>[];
      final seen = <String>{};
      for (final f in files) {
        final num = _episodeNumberOf(f);
        final key = num ?? f;
        if (!seen.add(key)) continue;
        eps.add(Episode(
          number: num ?? '${eps.length + 1}',
          url: downloadUrl(id, f),
          title: f,
          source: AnimeSource.archiveJp,
          owner: anime,
        ));
      }
      eps.sort((a, b) =>
          (int.tryParse(a.number) ?? 0).compareTo(int.tryParse(b.number) ?? 0));
      if (eps.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed for $id',
          source: source,
        ));
      }
      return ScraperResult.success(eps);
    } catch (e) {
      debugPrint('[Archive] getEpisodes error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'getEpisodes failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  /// Número de episódio a partir de nomes padronizados
  /// (`S01E07`, `E07`, `- 07 -`, `ep07`). Null quando o item não segue
  /// convenção (filme único, por exemplo) — aí o índice serve de número.
  static String? _episodeNumberOf(String fileName) {
    final base = fileName.split('.').first;
    final m = RegExp(r'[Ss](\d{1,2})[Ee](\d{1,3})').firstMatch(base) ??
        RegExp(r'\b[Ee](\d{1,3})\b').firstMatch(base) ??
        RegExp(r'\b[Ee]p?\.?\s?(\d{1,3})\b', caseSensitive: false).firstMatch(base);
    if (m == null) return null;
    return m.group(m.groupCount)!;
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    // O IA não tem HLS: o único caminho é o MP4 direto que já vem pronto
    // na URL do episódio (montada em [getEpisodes]).
    if (episode.url.isEmpty) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Episode carries no archive file URL',
        source: source,
      ));
    }
    final fileName = Uri.tryParse(episode.url)?.pathSegments.last ?? '';
    return ScraperResult.success([
      VideoSource(
        url: episode.url,
        quality: qualityOf(fileName.isEmpty ? episode.url : fileName),
        headers: _headers,
        // Acervo em geral é JA/EN cru sem legenda baked — cai no
        // transcribe L1 do LegendAI quando o usuário pede.
        audio: null,
      ),
    ]);
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
            report.reason = 'Not in curated Internet Archive collections';
          } else {
            report.status = AvailabilityStatus.available;
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