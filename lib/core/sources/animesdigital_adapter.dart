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
    }.where((q) => q.isNotEmpty).toList();
    // Buscas em paralelo: uma ida e volta em vez de até três em sequência.
    final results = await Future.wait(queries.map(search));
    for (final result in results) {
      switch (result) {
        case Success(data: final candidates):
          for (final a in candidates) {
            if (a.url.isNotEmpty && urls.add(a.url)) seen.add(a);
          }
        default:
          continue;
      }
    }
    if (seen.isEmpty) return null;
    return _pickBestAsync(animeRef, seen);
  }

  /// Temporada de um candidato: pelo título ("… 4th Season Dublado") ou pelo
  /// slug da URL, sem os sufixos de variante. Slime 4 ("…-ken-4-todos-episodios")
  /// só é reconhecida pela URL — o título cru "… Ken 4" não tem a palavra
  /// "season".
  static int? _seasonOfCandidate(Anime a) {
    final fromName = TextUtils.seasonOf(a.name);
    if (fromName != null) return fromName;
    final stripped = a.url
        .replaceAll(RegExp(r'/+$'), '')
        .replaceAll(
          RegExp(r'(?:-(?:dublado|legendado|todos-episodios))+$'),
          '',
        );
    return AnimeSourceAdapter.seasonOfCandidateUrl(stripped);
  }

  @visibleForTesting
  static int? seasonOfCandidateForTest(String url) => _seasonOfCandidate(
        Anime(name: '', url: url, source: AnimeSource.animesDigital),
      );

  /// Escolhe entre os candidatos. Se o topo empata (variantes da mesma
  /// temporada, ex.: "dublado" incompleto × "todos os episódios"), vence a que
  /// lista mais episódios na primeira página — um GET por candidato, em paralelo.
  Future<Anime> _pickBestAsync(Anime ref, List<Anime> cands) async {
    final ranked = _rank(ref, cands);
    final top = ranked.where((r) => r.$2 >= ranked.first.$2 - 10).take(3);
    final tied = top.toList();
    if (tied.length < 2) return tied.first.$1;
    final counts = await Future.wait(tied.map((r) async {
      try {
        final res = await _get(Uri.parse(r.$1.url.replaceAll(RegExp(r'/+$'), '')));
        if (res.statusCode != 200) return 0;
        var max = 0;
        for (final (_, num, _) in parseEpisodePage(res.body)) {
          final v = int.tryParse(num) ?? 0;
          if (v > max) max = v;
        }
        return max;
      } catch (_) {
        return 0;
      }
    }));
    var best = 0;
    for (var i = 1; i < tied.length; i++) {
      if (counts[i] > counts[best]) best = i;
    }
    return tied[best].$1;
  }

  /// Candidatos com nota, do melhor para o pior (desempate por URL).
  static List<(Anime, int)> _rank(Anime ref, List<Anime> cands) {
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
        final cs = _seasonOfCandidate(a);
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
      if (qSeason == null && _seasonOfCandidate(a) != null) s -= 5;
      return s;
    }

    final list = [for (final a in cands) (a, score(a))]
      ..sort((x, y) {
        final c = y.$2.compareTo(x.$2);
        if (c != 0) return c;
        return x.$1.url.compareTo(y.$1.url);
      });
    return list;
  }

  /// Só a primeira página: a lista é newest-first, então basta ver se há itens.
  /// (O padrão paginaria as ~18 páginas do One Piece, ~10 s — estourava o
  /// timeout e derrubava um match que estava bom.)
  @override
  Future<bool> isPageAlive(Anime anime) async {
    final base = anime.url.replaceAll(RegExp(r'/+$'), '');
    final res = await _get(Uri.parse(base));
    if (res.statusCode != 200) return false;
    return parseEpisodePage(res.body).isNotEmpty;
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

  /// Acha o item de EP [n] em [target] indo direto à página provável. A lista é
  /// newest-first (~50 itens por página, com buracos e stride irregular): a
  /// página ≈ 1 + (maxNum − n) ÷ itens-da-página-1, e depois anda ±1 conforme os
  /// números da página caem acima ou abaixo de n. No máximo [maxFetches] GETs —
  /// antes descia página a página (até 17 GETs num aparelho lento).
  Future<Episode?> _locateEpisode(Anime target, int n) async {
    const maxFetches = 5;
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
    final first = parseEpisodePage(r1.body);
    final maxNum = _maxNumOf(first);
    if (maxNum <= 0) return null;
    if (n > maxNum) return null; // futuro/não lançado
    final direct = _episodeIn(first, n, target);
    if (direct != null) return direct;
    if (first.isEmpty) return null;

    var page = (1 + (maxNum - n) ~/ first.length).clamp(2, maxPages);
    final tried = <int>{1};
    for (var fetches = 0; fetches < maxFetches; fetches++) {
      if (page < 2 || page > 40 || page > maxPages) break;
      if (!tried.add(page)) break;
      if (DateTime.now().isAfter(deadline)) break;
      final http.Response rp;
      try {
        rp = await _get(Uri.parse('$base/page/$page/'));
      } catch (_) {
        break;
      }
      if (rp.statusCode != 200) break;
      final items = parseEpisodePage(rp.body);
      final ep = _episodeIn(items, n, target);
      if (ep != null) return ep;
      if (items.isEmpty) {
        page++;
        continue;
      }
      if (_maxNumOf(items) < n) {
        page--; // n é mais novo: página anterior
      } else if (_minNumOf(items) > n) {
        page++; // n é mais antigo: próxima página
      } else {
        return null; // n está no intervalo da página mas não listado: buraco
      }
    }
    return null;
  }

  Episode? _episodeIn(
    List<(String, String, String)> items,
    int n,
    Anime target,
  ) {
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
    return null;
  }

  static int _maxNumOf(List<(String, String, String)> items) {
    var max = 0;
    for (final (_, num, _) in items) {
      final v = int.tryParse(num) ?? 0;
      if (v > max) max = v;
    }
    return max;
  }

  static int _minNumOf(List<(String, String, String)> items) {
    int? min;
    for (final (_, num, _) in items) {
      final v = int.tryParse(num);
      if (v == null || v <= 0) continue;
      if (min == null || v < min) min = v;
    }
    return min ?? 0;
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
          // O rótulo do jwplayer ("720p HD") não é confiável: o stream medido
          // em 07/10 era 1920×1080. Mostra "HD" e não passa altura para o
          // proxy/picker, para não prometer uma resolução que não existe.
          final label720 = label;
          const nice = 'HD';
          debugPrint(
            '[AnimesDigital] ep=${episode.number} p$tab -> '
            '$nice (site: $label720) ($m3u8)',
          );
          out.add(
            VideoSource(
              url: m3u8,
              quality: nice,
              dashHeight: null,
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
