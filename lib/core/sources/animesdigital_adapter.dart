import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../network/api_client.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';
import 'anime_source_adapter.dart';

/// Animes Digital (`https://animesdigital.org`) — PT-BR, WordPress com tema
/// próprio ("Animes Online"), HTML server-side (sem SPA/Cloudflare challenge na
/// leitura). Fluxo de vídeo decodificado do tema (STCode/jwplayer) e validado
/// ao vivo em 07/10/2026.
///
/// Caminho do vídeo:
///
/// ```
/// GET /anime/a/<slug>         lista `.itens_ep` (50/pág) → /video/a/<postId>
/// GET /video/a/<postId>       abas Player FHD (player1) / Player 2 (player2),
///                             ambas cobertas por `a.ad-protected-cover`
/// GET capa (investcentro…)    200 + `window.location.replace("mixumenu…")`
/// GET mixumenu campaign       302 → artigo; Set-Cookie `token`/`post_data`
/// GET artigo [cookies]        `#media-display data-url`:
///   (a) `https://api.anivideo.net/videohls.php?d=<m3u8>&nocache=<ts>`
///   (b) `https://animesdigital.org/<b64>/<n>/bg.mp4?…` (espelho Blogger,
///       morto no catálogo antigo — descartado se não virar HLS)
/// GET (a) [Referer animesdigital.org] → página STCode com `file:'<m3u8>'`
/// m3u8                        HLS VOD (`.webp` = MPEG-TS), jogável nativo.
/// ```
///
/// Headers confirmados ao vivo (07/10/2026):
///  - `api.anivideo.net/videohls.php` **exige Referer de `animesdigital.org`**
///    (sem referer/referer estranho → 302 `/404`, mesmo com nocache);
///  - o CDN final (`cdn-sv0*.maximaimg.online`, `cdn-s01.mywallpaper…`)
///    responde 200 sem Referer (m3u8 e segmentos MP2T);
///  - o artigo do mixumenu só entrega `media-display` com os cookies que o
///    próprio 302 do mixumenu seta — jarra mínima aqui.
///
/// O `resolveVideo` devolve um `VideoSource` por qualidade do jwplayer (label
/// "720p HD" → qualidade "720p" + `dashHeight`), todos .m3u8 HLS — o
/// [PlayerScreen] (mpv) já toca HLS de outras fontes.
///
/// Cobertura PT-BR confirmada: One Piece (dublado/legendado, série completa),
/// Black Clover, Slime T1..T4, Kimi ga Shinu made Koi wo Shitai, Nia Liston,
/// Sato-san (só legendado).
class AnimesDigitalAdapter extends AnimeSourceAdapter {
  static const _base = 'https://animesdigital.org';
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.6099.230 Safari/537.36';

  /// Referer aceito pelo `videohls.php`.
  static const _videoReferer = '$_base/';

  static Map<String, String> get _headers => {
    'User-Agent': _userAgent,
    'Accept-Language': 'pt-BR',
  };

  final http.Client? _client;

  AnimesDigitalAdapter({http.Client? client}) : _client = client;

  @override
  AnimeSource get source => AnimeSource.animesDigital;

  @override
  bool get implemented => true;

  /// GET de catálogo (search/anime page): quando não há client injetado, usa o
  /// [apiClient] (cache + backoff de 429). A cadeia de vídeo NÃO passa aqui —
  /// os tokens rotam e a jarra de cookie é local (ver [CookieJar]).
  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) {
    final hs = {..._headers, ...?headers};
    if (_client != null) return _client.get(uri, headers: hs);
    return apiClient.get(uri, headers: hs);
  }

  // --------------------------------------------------------------------------
  // Parse (puro — testável sem rede)
  // --------------------------------------------------------------------------

  /// Card de resultado: `<div class="itemA">…<a href="/anime/a/X"
  /// title="Assistir Y Online em HD">…`. O `title` do link está todo unificado
  /// no sentido PT ("Assistir X Online em HD").
  static final _searchCard = RegExp(
    r'<div class="itemA">.*?href="(https://animesdigital\.org/anime/a/[^"]+)"'
    r'.*?title="([^"]*)"',
    dotAll: true,
  );

  /// Item de episódio: `/video/a/…` + `title_anime">…Episódio N`.
  static final _epItem = RegExp(
    r'href="(https://animesdigital\.org/video/a/[^"]+)"[^>]*>.*?'
    r'title_anime">([^<]+)<',
    dotAll: true,
  );

  static final _episodeNumber = RegExp(r'Epis[óo]dio\s*([\d,.]+)');

  /// Capa/iframe de cada aba (`player1`/`player2`/…). A fonte rende DOIS
  /// formatos ao vivo (07/10/2026):
  ///  - formato antigo: `<a class="ad-protected-cover" href="…campaign.php?token=…">`
  ///  - formato novo: `<iframe class="metaframe…" src="https://api.anivideo.net/videohls.php?d=…">`
  /// on o group(3) já é a media-url direta.
  static final _coverHref = RegExp(
    r'id="player(\d+)"[^>]*>\s*(?:<a class="ad-protected-cover" href="([^"]+)"'
    r'|<iframe[^>]*src="([^"]+)")',
  );

  static final _metaRefresh = RegExp(
    r'window\.location\.replace\("([^"]+)"\)|'
    r'http-equiv="refresh"[^>]*url=([^">]+)',
  );

  static final _mediaUrl = RegExp(r'id="media-display"[^>]*data-url="([^"]+)"');

  static final _stCodeFileOnly = RegExp(r"file:\s*'([^']+)'");

  static const _loadingMarker = 'Carregando...';

  /// "Assistir X Online em HD" → "X". NÃO passa pelo [TextUtils.cleanTitle]:
  /// o 'Dublado'/'Legendado' da variante é o único sinal de áudio da fonte e
  /// cleanTitle remove esses tokens de propósito (dedupe cross-source).
  static String cleanCardTitle(String raw) {
    var t = raw
        .replaceAll('&amp;', '&')
        .replaceFirst(RegExp(r'^\s*Assistir\s+', caseSensitive: false), '')
        .replaceFirst(
          RegExp(r'\s*Online(?: em HD)?\s*$', caseSensitive: false),
          '',
        )
        .replaceFirst(RegExp(r'\s*Online\s+HD\s*$', caseSensitive: false), '')
        .replaceFirst(
          RegExp(r'\s*Todos os Epis[oó]dios\s*$', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.isEmpty) t = raw.trim();
    return t;
  }

  static List<Anime> parseSearch(String html) {
    final out = <Anime>[];
    final seen = <String>{};
    for (final m in _searchCard.allMatches(html)) {
      final url = m.group(1)!;
      if (!seen.add(url)) continue;
      final name = cleanCardTitle(m.group(2) ?? '');
      if (name.isEmpty) continue;
      out.add(Anime(name: name, url: url, source: AnimeSource.animesDigital));
    }
    return out;
  }

  /// `(url, número, título cru)` da página. O `título cru` carrega
  /// "Dublado"/"Legendado" (áudio da variante).
  static List<(String, String, String)> parseEpisodePage(String html) {
    final out = <(String, String, String)>[];
    final seen = <String>{};
    final block = html.indexOf('class="itens_ep"');
    if (block < 0) return out;
    final end = (block + 200000).clamp(block, html.length);
    final scope = html.substring(block, end);
    for (final m in _epItem.allMatches(scope)) {
      final url = m.group(1)!;
      if (!seen.add(url)) continue;
      final raw = m.group(2)!.trim();
      if (raw == _loadingMarker) continue;
      final en = _episodeNumber.firstMatch(raw);
      // Sem "Episódio N" no título (movie/esp.): o item é único → '1'.
      out.add((url, en != null ? en.group(1)!.replaceAll('.', '') : '1', raw));
    }
    return out;
  }

  static String? parseMediaUrl(String html) =>
      _mediaUrl.firstMatch(html)?.group(1)?.replaceAll('&amp;', '&');

  /// `(playerId, capa)` em ordem de aba.
  static List<(int, String)> parseCovers(String html) {
    final out = <(int, String)>[];
    for (final m in _coverHref.allMatches(html)) {
      final tab = int.tryParse(m.group(1)!) ?? 0;
      final href = (m.group(2) ?? m.group(3))?.replaceAll('&amp;', '&') ?? '';
      if (href.isEmpty || !href.startsWith('http')) continue;
      out.add((tab, href));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// `(m3u8, quality)` — só os que apontam para `.m3u8`.
  /// `(m3u8, quality)` a partir da página STCode; aceita label simples quando
  /// a config não traz (fallback `file:` apenas).
  /// Objeto de config (`{file:'…', label:"…"}`) — as duas chaves vêm em
  /// qualquer ordem, então casar o OBJETO e extrair dentro dele.
  static final _stCodeObj = RegExp(r'\{[^{}]*file[^{}]*\}', dotAll: true);

  static final _stFile = RegExp("file\\s*:\\s*[\"']([^\"']+)[\"']");
  static final _stLabel = RegExp("label\\s*:\\s*[\"']([^\"']+)[\"']");

  static List<(String, String)> parseStCodeSources(String html) {
    final out = <(String, String)>[];
    final seen = <String>{};
    for (final obj in _stCodeObj.allMatches(html)) {
      final chunk = obj.group(0)!;
      final file = _stFile.firstMatch(chunk)?.group(1);
      if (file == null || !file.contains('.m3u8')) continue;
      if (!seen.add(file)) continue;
      final label = _stLabel.firstMatch(chunk)?.group(1)?.trim() ?? 'Auto';
      out.add((file, label));
    }
    if (out.isEmpty) {
      final only = _stCodeFileOnly.firstMatch(html)?.group(1);
      if (only != null && only.contains('.m3u8')) out.add((only, 'Auto'));
    }
    return out;
  }

  static String? parseHop(String html) {
    final m = _metaRefresh.firstMatch(html);
    if (m == null) return null;
    return (m.group(1) ?? m.group(2))?.replaceAll('&amp;', '&');
  }

  /// Dublado/legendado a partir do título da variante (a página importa o
  /// áudio inteiro; a variante é homogênea).
  static String? audioOf(String name) {
    final n = name.toLowerCase();
    if (n.contains('dublado')) return 'dublado';
    if (n.contains('legendado')) return 'legendado';
    return null;
  }

  // --------------------------------------------------------------------------
  // Fluxo (rede)
  // --------------------------------------------------------------------------

  @override
  Future<ScraperResult<List<Anime>>> search(String animeName) async {
    try {
      final q = TextUtils.cleanSearchQuery(animeName).trim();
      if (q.isEmpty) {
        return ScraperResult.failure(
          EmptyResultError(message: 'Empty query', source: source),
        );
      }
      final uri = Uri.parse(_base + '/pesquisa/' + Uri.encodeFull(q) + '/');
      final res = await _get(uri);
      if (res.statusCode != 200) {
        return ScraperResult.failure(
          EmptyResultError(message: 'HTTP ${res.statusCode}', source: source),
        );
      }
      final list = parseSearch(res.body);
      if (list.isEmpty) {
        return ScraperResult.failure(
          EmptyResultError(message: 'No results', source: source),
        );
      }
      return ScraperResult.success(list);
    } catch (e) {
      debugPrint('[AnimesDigital] search error: $e');
      return ScraperResult.failure(
        UnknownError(
          message: 'Search failed: $e',
          source: source,
          originalError: e,
        ),
      );
    }
  }

  @override
  Future<Anime?> resolveAnime(Anime animeRef) async {
    if (animeRef.url.startsWith('$_base/anime/a/')) {
      return animeRef;
    }
    // O site casa consulta de PATH só com %20 (espaço cru/+ → 0 hits) e é
    // LITERAL: "…4th Season Part 1 & 2" volta 0. Une os hits de [name],
    // [englishName] e o [name] sem o rabo de "Part N"; dedupe por URL.
    final seen = <Anime>[];
    final urls = <String>{};
    final queries = <String>{
      TextUtils.cleanSearchQuery(animeRef.name),
      if (animeRef.englishName != null && animeRef.englishName!.isNotEmpty)
        TextUtils.cleanSearchQuery(animeRef.englishName!),
      TextUtils.cleanSearchQuery(
        animeRef.name.replaceAll(
          RegExp(r'\s*Part\s+\d+(?:\s*&\s*\d+)?\s*$', caseSensitive: false),
          '',
        ),
      ),
    };
    for (final q in queries) {
      if (q.isEmpty) continue;
      final result = await search(q);
      switch (result) {
        case Success(data: final candidates):
          for (final a in candidates) {
            if (a.url.isNotEmpty && urls.add(a.url)) seen.add(a);
          }
          if (seen.isNotEmpty) break; // 1ª query com hits basta
        default:
          continue;
      }
    }
    if (seen.isEmpty) return null;
    return _pickBest(animeRef, seen);
  }

  /// Desambiguação LOCAL. O base [bestMatch] usa `seasonOfCandidateUrl` (cauda
  /// da URL), mas nesta fonte a temporada vive no TÍTULO ("… 4th Season
  /// Dublado", "… 2ª temporada") e `normalize` EMPATA os variantes (dublado e
  /// "Todos os Episódios" viram lixo). Score: tiers do baseMatch + temporada
  /// pelo título + penalidade de filme/ova.
  static Anime _pickBest(Anime ref, List<Anime> cands) {
    final q = AnimeSourceAdapter.normalize(ref.name);
    final qSeason = TextUtils.seasonOf(ref.name);
    int score(Anime a) {
      final t = AnimeSourceAdapter.normalize(a.name);
      var s = 0;
      if (t == q) {
        s += 100;
      } else if (t.startsWith(q) || q.startsWith(t)) {
        s += 60;
      } else if (t.contains(q) || q.contains(t)) {
        s += 40;
      } else {
        final shared = q
            .split(' ')
            .toSet()
            .intersection(t.split(' ').toSet())
            .length;
        s += shared * 8 > 39 ? 39 : shared * 8;
      }
      s -= ((t.length - q.length).abs()) ~/ 8;
      if (qSeason != null) {
        final cs = TextUtils.seasonOf(a.name);
        s += cs == qSeason ? 40 : (cs != null ? -40 : 0);
      }
      for (final tok in const [
        'film',
        'movie',
        'ova',
        'special',
        'gaiden',
        'recap',
        'hentai',
      ]) {
        if (t.contains(tok) && !q.contains(tok)) s -= 25;
      }
      if (qSeason == null && TextUtils.seasonOf(a.name) != null) s -= 5;
      return s;
    }

    final sorted = [...cands]
      ..sort((a, b) {
        final c = score(b).compareTo(score(a));
        if (c != 0) return c;
        return a.url.compareTo(b.url);
      });
    return sorted.first;
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    final target = await resolveAnime(anime);
    if (target == null) {
      return ScraperResult.failure(
        EmptyResultError(message: 'No page for ${anime.name}', source: source),
      );
    }
    try {
      // Paginação: `/anime/a/<slug>` + `/anime/a/<slug>/page/N/`; ~50 itens
      // por página (One Piece dublado = 18 páginas). A presença do link
      // `/page/(N+1)/` no HTML define se há próxima.
      final eps = <Episode>[];
      final seen = <String>{};
      final audio = audioOf(target.name);
      var pageUrl = target.url.replaceAll(RegExp(r'/+$'), '');
      for (var page = 1; page <= 40; page++) {
        final res = await _get(Uri.parse(pageUrl));
        if (res.statusCode != 200) break;
        for (final (url, num, raw) in parseEpisodePage(res.body)) {
          if (!seen.add(url)) continue;
          eps.add(
            Episode(
              number: num,
              url: url,
              season: null,
              owner: target,
              title: raw,
              description: audio,
            ),
          );
        }
        if (!RegExp('/page/${page + 1}/').hasMatch(res.body)) break;
        if (pageUrl.contains('/page/')) {
          pageUrl = pageUrl.replaceFirst(
            RegExp(r'/page/\d+/$'),
            '/page/${page + 1}/',
          );
        } else {
          pageUrl = '$pageUrl/page/${page + 1}/';
        }
      }
      eps.sort(
        (a, b) => (int.tryParse(a.number) ?? 0).compareTo(
          int.tryParse(b.number) ?? 0,
        ),
      );
      if (eps.isEmpty) {
        return ScraperResult.failure(
          EmptyResultError(message: 'No episodes', source: source),
        );
      }
      return ScraperResult.success(eps);
    } catch (e) {
      debugPrint('[AnimesDigital] getEpisodes error: $e');
      return ScraperResult.failure(
        UnknownError(
          message: 'getEpisodes failed: $e',
          source: source,
          originalError: e,
        ),
      );
    }
  }

  @override
  Future<List<VideoSource>> resolveVideo(
    Anime match,
    int episodeNumber, {
    Anime? catalog,
  }) async {
    // Localização DIRETA (sem paginar o catálogo inteiro): a lista é
    // newest-first e monotônica por página — a posição do EP n é
    // página = 1 + ((maxNum − n) ~/ 50). 2 GETs no pior caso em vez de ~18.
    final target = await resolveAnime(match);
    if (target == null) {
      debugPrint('[AnimesDigital] sem página para "${match.name}"');
      return const [];
    }
    final located = await _locateEpisode(target, episodeNumber);
    if (located == null) {
      debugPrint(
        '[AnimesDigital] EP $episodeNumber não listado em '
        '${match.url}',
      );
      return const [];
    }
    return _resolveEpisodeStreams(located);
  }

  /// Página de paginação máxima nos links `/page/<N>/` de uma página do anime.
  static int parseMaxPage(String html) {
    var max = 1;
    for (final m in RegExp('/page/(\\d+)/').allMatches(html)) {
      final v = int.tryParse(m.group(1)!) ?? 0;
      if (v > max) max = v;
    }
    return max;
  }

  /// Acha o item de EP [n] em [target] descerndo as páginas em ordem.
  /// A paginação do site é irregalar (stride 47-51 com 14-18 itens/página e
  /// buracos — medido 07/10), então sem matemática: desce até a página cujo
  /// `max < n` (monotônico descendente — depois disso n não aparece) e devolve
  /// o item quando o número casa. Buracos/EPs não renderizados → null (honesto;
  /// a fonte serve bem os lançamentos recentes e falha silenciosa nos antigos).
  Future<Episode?> _locateEpisode(Anime target, int n) async {
    final base = target.url.replaceAll(RegExp(r'/+$'), '');
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    final http.Response r1;
    try {
      r1 = await _get(Uri.parse(base));
    } catch (e) {
      debugPrint('[AnimesDigital] locate r1 error: $e');
      return null;
    }
    if (r1.statusCode != 200) return null;
    final maxPages = parseMaxPage(r1.body);
    var items = parseEpisodePage(r1.body);
    var maxNum = 0;
    for (final (_, num, _) in items) {
      final v = int.tryParse(num) ?? 0;
      if (v > maxNum) maxNum = v;
    }
    if (maxNum <= 0) return null;
    if (n > maxNum) return null; // futuro/não lançado
    Episode? found;
    for (final (url, num, raw) in items) {
      if ((int.tryParse(num) ?? -1) == n) {
        found = Episode(
          number: num,
          url: url,
          season: null,
          owner: target,
          title: raw,
          description: audioOf(target.name),
        );
        return found;
      }
    }
    // Desce as páginas seguintes; para no cruzamento (monotônico).
    for (var page = 2; page <= maxPages && page <= 40; page++) {
      if (DateTime.now().isAfter(deadline)) break;
      final http.Response rp;
      try {
        rp = await _get(Uri.parse('$base/page/$page/'));
      } catch (e) {
        break;
      }
      if (rp.statusCode != 200) continue;
      items = parseEpisodePage(rp.body);
      if (items.isEmpty) continue;
      for (final (url, num, raw) in items) {
        if ((int.tryParse(num) ?? -1) == n) {
          return Episode(
            number: num,
            url: url,
            season: null,
            owner: target,
            title: raw,
            description: audioOf(target.name),
          );
        }
      }
      // Se TODOS os números desta página já ficaram abaixo de n, monotônico
      // descendente ⇒ nas outras páginas também. Honestamente vazio.
      var pageMax = 0;
      for (final (_, num, _) in items) {
        final v = int.tryParse(num) ?? 0;
        if (v > pageMax) pageMax = v;
      }
      if (pageMax < n) break;
    }
    return null;
  }

  /// Percorre as abas (player1/player2/…) e devolve um `VideoSource` por
  /// stream HLS vivo. O `videohls.php` exige o Referer do site de origem.
  Future<List<VideoSource>> _resolveEpisodeStreams(Episode episode) async {
    final audio = episode.description ?? audioOf(episode.title ?? '') ?? '';
    final out = <VideoSource>[];
    final seen = <String>{};
    final http.Response page;
    try {
      page = await _get(Uri.parse(episode.url));
    } catch (e) {
      debugPrint('[AnimesDigital] video page error: $e');
      return out;
    }
    if (page.statusCode != 200) return out;
    final jar = CookieJar();
    for (final (tab, cover) in parseCovers(page.body)) {
      if (!cover.contains('campaign.php?token=') &&
          !cover.contains('videohls.php')) {
        continue;
      }
      try {
        final media = cover.contains('videohls.php')
            ? cover // formato novo: iframe já entrega a media-url
            : await _unwrapCampaign(cover, episode.url, jar);
        if (media == null) {
          debugPrint('[AnimesDigital] player$tab: cover wrap falhou');
          continue;
        }
        for (final (m3u8, label) in await _resolvePlayable(media, jar)) {
          if (!seen.add(m3u8.toLowerCase())) continue;
          final h = RegExp(r'(\d{3,4})').firstMatch(label)?.group(1);
          final nice = label.contains(RegExp(r'\d[0-9]*'))
              ? label.trim().split(RegExp(r'\s+')).first
              : (label.trim().isEmpty ? 'Auto' : label.trim());
          debugPrint(
            '[AnimesDigital] ep=${episode.number} p$tab -> '
            '$nice ($m3u8)',
          );
          out.add(
            VideoSource(
              url: m3u8,
              quality: nice,
              dashHeight: h == null ? null : int.tryParse(h),
              headers: {'User-Agent': _userAgent, 'Referer': _videoReferer},
              audio: audio.isNotEmpty ? audio : null,
            ),
          );
        }
      } catch (e) {
        debugPrint('[AnimesDigital] player$tab chain error: $e');
      }
    }
    return out;
  }

  /// Capa (`investcentro.com/campaign.php?token=…`) → artigo do mixumenu com
  /// `#media-display`. Trata os dois caminhos vistos ao vivo:
  ///  (1) investcentro 200 com `meta refresh`/replace → mixumenu; ou
  ///  (2) investcentro 302 direto.
  /// mixumenu responde 302 (Set-Cookie `token`/`post_data` + Location artigo) e
  /// o artigo SÓ entrega `media-display` com esses cookies — refetch com a
  /// jarra completa. Retorna null quando algum passo falha.
  Future<String?> _unwrapCampaign(
    String coverUrl,
    String referer,
    CookieJar jar,
  ) async {
    final r1 = await _chainGet(Uri.parse(coverUrl), jar, referer: referer);
    String? hop2;
    if (r1.statusCode >= 300 && r1.statusCode < 400) {
      hop2 = r1.headers['location'];
    } else if (r1.statusCode == 200) {
      hop2 = parseHop(r1.body);
    }
    if (hop2 == null || hop2.isEmpty) return null;
    final r2 = await _chainGet(Uri.parse(hop2), jar);
    final loc2 = r2.headers['location'];
    if (r2.statusCode >= 300 &&
        r2.statusCode < 400 &&
        loc2 != null &&
        loc2.isNotEmpty) {
      final r3 = await _chainGet(Uri.parse(loc2), jar);
      if (r3.statusCode != 200) return null;
      return parseMediaUrl(r3.body);
    }
    if (r2.statusCode != 200) return null;
    return parseMediaUrl(r2.body);
  }

  /// GET da cadeia de vídeo: sem cache, jarra coletando Set-Cookie e redirects
  /// **manuais** — o http.Client segue até 5 e devolve a resposta final,
  /// perdendo o Set-Cookie de cada salto (o artigo do mixumenu exige o eco do
  /// `token`/`post_data`). 30x → devolve a própria resposta p/ dissectar.
  Future<http.Response> _chainGet(
    Uri uri,
    CookieJar jar, {
    String? referer,
  }) async {
    final client = _client ?? http.Client();
    try {
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..maxRedirects = 0;
      req.headers.addAll({
        'User-Agent': _userAgent,
        ...?jar.headerFor(uri),
        if (referer != null) 'Referer': referer,
      });
      final streamed = await client.send(req);
      final res = await http.Response.fromStream(streamed);
      jar.collect(res);
      return res;
    } finally {
      if (_client == null) client.close();
    }
  }

  /// media-url → (m3u8, quality) HLS validados.
  /// (a) videohls.php: página STCode; o Referer deve ser animesdigital.org.
  /// (b) Blogger bridge (`bg.mp4`): segue os redirects manualmente e aceita
  /// apenas o corpo final que começar com `#EXTM3U`.
  Future<List<(String, String)>> _resolvePlayable(
    String mediaUrl,
    CookieJar jar,
  ) async {
    final out = <(String, String)>[];
    if (mediaUrl.contains('videohls.php')) {
      final res = await _chainGet(
        Uri.parse(mediaUrl),
        jar,
        referer: _videoReferer,
      );
      if (res.statusCode != 200) return out;
      for (final (file, label) in parseStCodeSources(res.body)) {
        if (await _isLiveHls(file, jar)) out.add((file, label));
      }
      return out;
    }
    var url = mediaUrl;
    for (var hop = 0; hop < 4; hop++) {
      final res = await _chainGet(Uri.parse(url), jar, referer: _videoReferer);
      if (res.statusCode < 300 || res.statusCode >= 400) {
        if (res.body.trimLeft().startsWith('#EXTM3U')) out.add((url, 'Auto'));
        break;
      }
      final loc = res.headers['location'];
      if (loc == null || loc.isEmpty) break;
      url = Uri.parse(url).resolve(loc).toString();
    }
    return out;
  }

  /// Probe: GET Range 0-255 da playlist. HLS vivo sempre devolve `#EXTM3U`;
  /// morto devolve 404 (o catálogo antigo do AnimeFire foi o caso pitivo).
  Future<bool> _isLiveHls(String url, CookieJar jar) async {
    try {
      final client = _client ?? http.Client();
      try {
        final res = await client.get(
          Uri.parse(url),
          headers: {'User-Agent': _userAgent, 'Range': 'bytes=0-255'},
        );
        return res.statusCode >= 200 &&
            res.statusCode < 300 &&
            res.body.contains('#EXTM3U');
      } finally {
        if (_client == null) client.close();
      }
    } catch (e) {
      debugPrint('[AnimesDigital] hls probe error: $e');
      return false;
    }
  }

  /// Contrato da interface: episódio → fontes direto (o `episode.url` aponta
  /// para a página `/video/a/` deste mesmo source). Simplesmente desembrulha
  /// os players e devolve as m3u8 que de fato respondem.
  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    final sources = await _resolveEpisodeStreams(episode);
    if (sources.isEmpty) {
      return ScraperResult.failure(
        EmptyResultError(
          message: 'No video sources for ${episode.url}',
          source: source,
        ),
      );
    }
    return ScraperResult.success(sources);
  }

  @override
  Future<AvailabilityReport> checkAvailability(String animeName) async {
    final report = AvailabilityReport(source: source, animeName: animeName);
    final r = await search(animeName);
    switch (r) {
      case Success(data: final animes) when animes.isNotEmpty:
        report.status = AvailabilityStatus.available;
        return report;
      default:
        report.status = AvailabilityStatus.notFound;
        return report;
    }
  }
}

/// Jarra de cookies mínima para a cadeia de vídeo. O pacote http junta
/// múltiplos cabeçalhos `Set-Cookie` numa string com bendiCounter; o
/// parse carrega pares `name=value` mídia-noj (do atributo" até `;`),
/// descartando `expires`/`path`/`secure`/etc (o que interessa é token/posti).
class CookieJar {
  final Map<String, String> jar = {};

  static const _attrs = {
    'expires',
    'path',
    'domain',
    'secure',
    'httponly',
    'samesite',
    'max-age',
    'version',
    'comment',
  };

  void collect(http.Response response) =>
      ingest(response.headers['set-cookie']);

  /// O pacote `http` pode unir vários `Set-Cookie` numa única string — e as
  /// datas de `expires` carregam vírgulas. Parse: quebra nos ", ", re-colando
  /// pedaços que não começam com `name=` (continuação de data) e ignorando
  /// atributos (`expires`, `path`, `max-age`, …).
  void ingest(String? raw) {
    if (raw == null || raw.isEmpty) return;
    final chunks = <String>[];
    for (final piece in raw.split(RegExp(r',\s*'))) {
      if (chunks.isEmpty || RegExp(r'^[-\w]+=').hasMatch(piece)) {
        chunks.add(piece);
      } else {
        chunks[chunks.length - 1] = '${chunks[chunks.length - 1]},$piece';
      }
    }
    for (final chunk in chunks) {
      final pair = chunk.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim().toLowerCase();
      final value = pair.substring(eq + 1).trim();
      if (_attrs.contains(name)) continue; // atributo, não cookie
      if (value.isEmpty || value == 'deleted') {
        jar.remove(name);
        continue;
      }
      jar[name] = value;
    }
  }

  Map<String, String>? headerFor(Uri uri) {
    if (jar.isEmpty) return null;
    return {'Cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; ')};
  }
}
