import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// DonghuaNoSekai — **donghua chinês legendado em PT-BR**, a fonte que
/// preenche o buraco mais óbvio do app: nenhuma fonte PT-BR atual servia
/// animação chinesa, e o AniList quase não a cataloga.
///
/// Verificado ao vivo em 10/10/2026 (ver `relatorio-novas-fontes-asia-2026-10-10.md`):
///
///  - Busca: WordPress `/?s=<q>` — cards
///    `<li><a href="/<slug>" alt="Assistir <TÍTULO>">…<h4 class="title">…`.
///    Páginas de episódio (`…-episodio-N`) também aparecem nos resultados;
///    são filtradas para a busca devolver só séries.
///
///  - Episódios: página do título lista **todos** os episódios de uma vez
///    (`/<slug>-episodio-<n>`), sem paginação. A página também embute
///    links de outras séries (sidebar), então o parser ancora no próprio
///    slug e ignora o resto.
///
///  - Vídeo: página do episódio → `data-video-url="/player?file=<b64>&type=N"`
///    → `/player` devolve um `<iframe src="player-nativov2.php?v=<URL_HLS>">`
///    → o parâmetro `v` **é o `.m3u8` direto**.
///
/// Características que fazem desta a fonte mais scrapeável do catálogo:
/// zero anti-bot (sem Cloudflare, sem captcha, sem JS obrigatório no
/// caminho do vídeo), HLS nativo, 3 GETs por episódio.
///
/// O bloco anti-cópia do site (`Ctrl+S` → `window.location = facebook.com`)
/// é JS de cliente e **não** afeta requests HTTP — confirmado em probe.
class DonghuaNoSekaiAdapter extends AnimeSourceAdapter {
  static const _base = 'https://donghuanosekai.com';

  /// Tipo 0 é o player principal; o tipo 1 existe mas esvazia Frequently
  /// retorna "haha parece que não tem nada!" — por isso [parsePlayerUrls]
  /// ordena o tipo 0 para a frente e ele é tentado primeiro.
  static const _defaultPlayerType = 0;

  final http.Client? _client;

  DonghuaNoSekaiAdapter({http.Client? client}) : _client = client;

  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  Map<String, String> get _headers => {
        'User-Agent': _userAgent,
        'Accept-Language': 'pt-BR,pt;q=0.9',
      };

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) {
    if (_client != null) return _client.get(uri, headers: headers);
    return apiClient.get(uri, headers: headers);
  }

  /// Card de resultado: âncora de série com o título no atributo `alt`
  /// (`alt="Assistir Zhen Dao Ge – 3ª Temporada"`). O `h4.title` é usado
  /// como fallback quando o `alt` não segue o prefixo "Assistir".
  static final _searchCard = RegExp(
    r'<li>\s*<a href="(https://donghuanosekai\.com/[^"#?]+)"[^>]*>(.*?)</a>',
    dotAll: true,
  );
  static final _titleAlt =
      RegExp(r'alt="Assistir\s+([^"]+)"', caseSensitive: false);
  static final _titleH4 = RegExp(
      r'<h4[^>]*class="title"[^>]*>([^<]+)</h4>', caseSensitive: false);
  static final _thumb = RegExp(
      r'<img[^>]+src="([^"]+)"', caseSensitive: false);
  static final _genres = RegExp(
      r'class="genere"[^>]*>(.*?)</div>', dotAll: true, caseSensitive: false);

  /// `data-video-url` dos players na página do episódio.
  static final _playerUrl =
      RegExp(r'data-video-url="([^"]+)"', caseSensitive: false);

  /// `<iframe src="…player-nativov2.php?v=<url>">` na página `/player`.
  static final _playerIframe =
      RegExp(r'<iframe[^>]+src="([^"]+)"', caseSensitive: false);

  /// Rótulo de qualidade embutido no nome do arquivo no CDN
  /// (ex.: `243_1080p_c9c70f13.mp4/index.m3u8`).
  static final _quality = RegExp(r'(\d{3,4})p');

  @override
  AnimeSource get source => AnimeSource.donghuaNoSekai;

  // ─────────────────────────── parse (público p/ teste) ──────────��────────

  /// Extrai as séries dos cards de busca. Descarta páginas de episódio,
  /// âncoras internas e imagens soltas.
  static List<Anime> parseSearch(String html) {
    final out = <Anime>[];
    final seen = <String>{};
    for (final m in _searchCard.allMatches(html)) {
      final url = m.group(1)!;
      final inner = m.group(2) ?? '';
      // Só páginas de série: o caminho precisa ter >1 segmento e não pode
      // ser um episódio (`…-episodio-…`) nem rota institucional.
      final path = Uri.tryParse(url)?.pathSegments ?? const [];
      if (path.length != 1 || path.first.isEmpty) continue;
      final slug = path.first;
      if (slug.contains('episodio')) continue;
      if (_institutionalSlugs.contains(slug)) continue;
      if (!seen.add(slug)) continue;

      final alt = _titleAlt.firstMatch(inner)?.group(1)?.trim();
      final h4 = _titleH4.firstMatch(inner)?.group(1)?.trim();
      final title = TextUtils.cleanTitle(
          (alt != null && alt.isNotEmpty) ? alt : (h4 ?? slug));
      if (title.isEmpty) continue;

      final genresRaw = _genres.firstMatch(inner)?.group(1) ?? '';
      final genres = genresRaw
          .replaceAll(RegExp(r'Gêneros?:', caseSensitive: false), '')
          .split(',')
          .map((g) => g.trim())
          .where((g) => g.isNotEmpty && g.length < 24)
          .toList();

      out.add(Anime(
        name: title,
        url: '$_base/$slug',
        source: AnimeSource.donghuaNoSekai,
        fallbackImageUrl: _abs(_thumb.firstMatch(inner)?.group(1)),
        genres: genres,
        description: genresRaw.trim().isEmpty ? null : genresRaw.trim(),
      ));
    }
    return out;
  }

  /// Extrai os episódios **da série [slug]**, ignorando os links de outras
  /// séries que a página embute na sidebar.
  ///
  /// Números: `-episodio-7`, `-episodio-07`, `-episodios-40-41`,
  /// `-episodio-379-380`. O canônico é sempre o ÚLTIMO número do slug;
  /// um par consecutivo (`N` e `N+1`, ex.: `379-380`, `40-41`) também
  /// registra o número inicial como alias — é o caso das páginas que
  /// pubblicam dois episódios de uma vez. Pares não consecutivos
  /// (ex.: `13-178`) ficam só pelo canônico, para não criar match errado.
  static List<Episode> parseEpisodes(String html, String slug, {Anime? owner}) {
    final out = <Episode>[];
    final byNumber = <String, String>{};
    final prefix = '$_base/$slug-episodio';

    for (final m in RegExp(r'href="([^"]*?-episodios?-[^"]+)"', caseSensitive: false)
        .allMatches(html)) {
      final url = m.group(1)!;
      if (!url.startsWith(prefix)) continue;
      final tail = url.substring(prefix.length);
      final nums = RegExp(r'\d+')
          .allMatches(tail)
          .map((x) => int.parse(x.group(0)!))
          .toList();
      if (nums.isEmpty) continue;
      final canonical = nums.last;
      final numbers = <int>{canonical};
      if (nums.length >= 2 && nums[0] + 1 == nums[1]) numbers.add(nums[0]);
      for (final n in numbers) {
        // O primeiro que ganha é o canônico (links duplicados no rodapé
        // de navegação podem repetir o mesmo episódio).
        byNumber.putIfAbsent('$n', () => url);
      }
    }

    final keys = byNumber.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    for (final k in keys) {
      out.add(Episode(
        number: k,
        url: byNumber[k]!,
        title: 'Episódio $k',
        source: AnimeSource.donghuaNoSekai,
        owner: owner,
      ));
    }
    return out;
  }

  /// URLs de player (`/player?file=…&type=N`) presentes na página do
  /// episódio, na ordem em que o site as lista. O tipo 0 vem primeiro.
  static List<String> parsePlayerUrls(String html) {
    final out = <String>[];
    for (final m in _playerUrl.allMatches(html)) {
      final raw = m.group(1)!;
      final url = raw.startsWith('http') ? raw : '$_base$raw';
      if (!out.contains(url)) out.add(url);
    }
    // Tipo 0 primeiro (o principal); os demais viram tentativa extra.
    out.sort((a, b) => _playerTypeOf(a).compareTo(_playerTypeOf(b)));
    return out;
  }

  /// Tipo declarado em `/player?file=…&type=N` (default 0).
  static int _playerTypeOf(String playerUrl) {
    final m = RegExp(r'[?&]type=(\d+)').firstMatch(playerUrl);
    return m == null ? _defaultPlayerType : int.parse(m.group(1)!);
  }

  /// HLS a partir do HTML de `/player`: extrai o `v` do iframe
  /// (`player-nativov2.php?v=<url>`) e decodifica. Null quando não há
  /// player (aí o site devolve a página "não tem nada").
  static String? parseHls(String playerHtml) {
    final iframe = _playerIframe.firstMatch(playerHtml)?.group(1);
    if (iframe == null) return null;
    final uri = Uri.tryParse(iframe);
    if (uri == null) return null;
    final v = uri.queryParameters['v'];
    if (v == null || v.isEmpty) return null;
    final decoded = Uri.decodeComponent(v);
    return decoded.contains('://') ? decoded : v;
  }

  /// Rótulo de qualidade a partir da URL do manifesto
  /// (`…/243_1080p_hash.mp4/index.m3u8` → `1080p`).
  static String qualityOf(String hlsUrl) {
    final m = _quality.firstMatch(hlsUrl);
    if (m == null) return 'Auto';
    return '${m.group(1)}p';
  }

  /// Slug da série a partir da URL persistida (`https://…/<slug>`).
  static String? slugOf(String url) {
    final segs = Uri.tryParse(url)?.pathSegments ?? const [];
    if (segs.length != 1 || segs.first.isEmpty) return null;
    if (segs.first.contains('episodio')) return null;
    return segs.first;
  }

  static String _abs(String? src) {
    if (src == null || src.isEmpty) return '';
    if (src.startsWith('http')) return src;
    return 'https:${src.startsWith('//') ? '' : '/'}$src';
  }

  /// Rotas institucionais que aparecem na navegação e nos widgets do rodapé
  /// e não são conteúdo. É uma BLOCKLIST: tudo que não estiver aqui e passar
  /// pelos filtros de slug é tratado como série.
  static const _institutionalSlugs = {
    'donghuas', 'feed', 'noticia', 'contato', 'politica-de-privacidade',
    'aviso-legal', 'politica-de-cookies', 'termos-e-condicoes', 'generos',
    'categorias', 'tags', 'search', 'page',
  };

  // ─────────────────────────────── rede ───────────────────────────────────

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    final q = Uri.encodeQueryComponent(TextUtils.cleanSearchQuery(animeName));
    if (q.isEmpty) return ScraperResult.success(const []);
    try {
      final res = await _get(Uri.parse('$_base/?s=$q'), headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final list = parseSearch(res.body);
      if (list.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No results for "$animeName"',
          source: source,
        ));
      }
      return ScraperResult.success(list);
    } catch (e) {
      debugPrint('[DonghuaNoSekai] search error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Search failed: $e',
        source: source,
        originalError: e,
      ));
    }
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    final slug = slugOf(anime.url);
    if (slug == null) {
      return ScraperResult.failure(EmptyResultError(
        message: 'Not a DonghuaNoSekai series URL: ${anime.url}',
        source: source,
      ));
    }
    try {
      final res = await _get(Uri.parse('$_base/$slug'), headers: _headers);
      if (res.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200: ${res.statusCode}',
          source: source,
        ));
      }
      final eps = parseEpisodes(res.body, slug, owner: anime);
      if (eps.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No episodes parsed for $slug',
          source: source,
        ));
      }
      return ScraperResult.success(eps);
    } catch (e) {
      debugPrint('[DonghuaNoSekai] getEpisodes error: $e');
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
    try {
      // 1) página do episódio → /player?file=…
      final epRes = await _get(Uri.parse(episode.url), headers: _headers);
      if (epRes.statusCode != 200) {
        return ScraperResult.failure(EmptyResultError(
          message: 'Non-200 on episode: ${epRes.statusCode}',
          source: source,
        ));
      }
      final players = parsePlayerUrls(epRes.body);
      if (players.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No player in episode page',
          source: source,
        ));
      }

      // 2) cada player → HLS. O tipo 0 resolve de cara; os demais só
      //    entram se o principal falhar (alguns eps trazem player extra).
      final sources = <VideoSource>[];
      final seen = <String>{};
      for (final player in players) {
        final res = await _get(Uri.parse(player), headers: _headers);
        if (res.statusCode != 200) continue;
        final hls = parseHls(res.body);
        if (hls == null || !hls.contains('.m3u8')) continue;
        if (!seen.add(hls)) continue;
        sources.add(VideoSource(
          url: hls,
          quality: qualityOf(hls),
          headers: _headers,
          // Donghua = áudio original chinês com legenda PT-BR embutida na
          // encode; não há trilha dublada separada para escolher.
          audio: null,
        ));
      }

      if (sources.isEmpty) {
        return ScraperResult.failure(EmptyResultError(
          message: 'No HLS resolved from ${players.length} player(s)',
          source: source,
        ));
      }
      return ScraperResult.success(sources);
    } catch (e) {
      debugPrint('[DonghuaNoSekai] getVideoSources error: $e');
      return ScraperResult.failure(UnknownError(
        message: 'Video resolution failed: $e',
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
          if (animes.isEmpty) {
            report.status = AvailabilityStatus.notFound;
            report.reason = 'Not in DonghuaNoSekai catalog';
          } else {
            report.status = AvailabilityStatus.available;
            final eps = await getEpisodes(animes.first);
            if (eps is Success<List<Episode>>) {
              report.episodeCount = eps.data.length;
            }
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