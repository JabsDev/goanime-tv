import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';
import '../utils/text_utils.dart';

  /// Port/adapter abstraction for every anime provider.
  ///
  /// The catalog (AniList) owns the canonical episode list. A provider only
  /// knows how to:
  ///  - search its catalog for a query,
  ///  - internal list episodes for a given [Anime],
  ///  - resolve playable video sources for an [Episode].
  ///
  /// This decouples the orchestration layer ([AnimeRepository]) and the UI
  /// from the scraping details. Adding a new provider is implementing a single
  /// interface; the provider never defines the canonical episode list.
  ///
  /// The two verbs that drive the new on-demand flow live here with default
  /// implementations (built on [search]/[getEpisodes]/[getVideoSources]) so an
  /// adapter gets them for free and can override when its numbering differs:
  ///
  ///  - [resolveAnime]: locate the provider's page for a catalog [Anime].
  ///  - [resolveVideo]: given that page, resolve the streams of episode N.
abstract class AnimeSourceAdapter {
  AnimeSource get source;

  /// B11: whether this source has a real, usable search. Non-implemented
  /// adapters are excluded from the parallel search/resolve fan-out so one
  /// query doesn't fire ~12 dead requests.
  bool get implemented => true;

  Future<ScraperResult<List<Anime>>> search(String query);

  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime);

  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  });

  /// Check availability with detailed diagnosis
  Future<AvailabilityReport> checkAvailability(String animeName);

  /// Season pinning: when [entryUrl] itself carries a season tail
  /// (`…-ken-4` → 4, `…-4th-season` → 4, e.g. a split S4 entry whose NAME
  /// has no season signal), candidates on that same season page win over the
  /// base page — otherwise a season entry silently re-pins S1 and every
  /// episode resolves off-season. Single same-season candidate → it;
  /// several → [bestMatch] among them; none (or no URL season) → plain
  /// [bestMatch] over all, exactly as before.
  static Anime pinSeasonPage(String query, List<Anime> candidates,
      AnimeSource source, String entryUrl) {
    final entrySeason = seasonOfCandidateUrl(entryUrl);
    if (entrySeason != null) {
      final sameSeason = candidates
          .where((a) => seasonOfCandidateUrl(a.url) == entrySeason)
          .toList();
      if (sameSeason.length == 1) return sameSeason.single;
      if (sameSeason.length > 1) {
        return bestMatch(query, sameSeason, source);
      }
    }
    return bestMatch(query, candidates, source);
  }

  /// Locates this provider's own page for the catalog [animeRef] (a provider
  /// `Anime` whose `url` points at the video on this source). Runs one
  /// search-by-name; result is meant to be cached/persisted by the caller so
  /// the first resolution of an anime per provider pays the search only once.
  Future<Anime?> resolveAnime(Anime animeRef) async {
    final result = await search(TextUtils.cleanSearchQuery(animeRef.name));
    switch (result) {
      case Success(data: final candidates):
        if (candidates.isEmpty) return null;
        final valid = candidates.where((a) => a.url.isNotEmpty).toList();
        if (valid.isEmpty) return null;
        return pinSeasonPage(animeRef.name, valid, source, animeRef.url);
      case Failure():
      case Loading():
        return null;
    }
  }

  /// Resolves the playable [VideoSource]s of episode [episodeNumber] on a page
  /// previously matched by [resolveAnime]. Returns an empty list when this
  /// provider doesn't have that episode.
  ///
  /// [catalog] is the catalog (AniList) anime the user opened — its name may
  /// carry the season ("4th Season") when the catalog splits seasons into
  /// separate entries while the provider serves them on one combined page.
  /// Adapters with combined pages (AnimeFire) use it to map the
  /// season-relative number to the provider's absolute one.
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber,
      {Anime? catalog}) async {
    final eps = await getEpisodes(match);
    Episode? target;
    switch (eps) {
      case Success(:final data):
        for (final e in data) {
          if (int.tryParse(e.number) == episodeNumber) {
            target = e;
            break;
          }
        }
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

  /// Picks the candidate whose title best matches [query]. Prefers exact,
  /// prefix and containment matches; shorter/closer titles win ties; spin-offs
  /// (films, movies, OVAs, specials) are penalized so the catalog title maps to
  /// the main series. AnimeFire only grants its full-series-page bonus when the
  /// candidate's title matches the query exactly, so a spin-off sharing the
  /// "todos-os-episodios" slug can never ride that bonus to beat the series.
  ///
  /// Season signal: when [query] names a season ("…4th Season" → 4, via
  /// [TextUtils.seasonOf] on the ORIGINAL query — [normalize] destroys
  /// "4th"), the candidate whose URL tail sits in season position (`…-ken-4`
  /// → 4) gets +30 and a wrong-season candidate gets −30; the season-less
  /// base page gets −10 (honest S1 fallback when the season page is missing).
  /// No query hint → scores unchanged. Final tiebreak is by URL so the order
  /// is deterministic (no reliance on unstable sort of equal scores).
  static Anime bestMatch(
      String query, List<Anime> candidates, AnimeSource source) {
    final q = normalize(query);
    final querySeason = TextUtils.seasonOf(query);
    const urlSideTokens = [
      'film-',
      'movie-',
      '-ova',
      'special',
      'gaiden',
      'episode-of',
    ];
    const nameSideTokens = [
      'film',
      'movie',
      'ova',
      'special',
      'gaiden',
      'recap',
      // Visto ao vivo: animePlayer devolve "Naruto Hentai" em 1º para a
      // busca "Naruto" e o match grudava no hentai.
      'hentai',
    ];
    int score(Anime a) {
      final t = normalize(a.name);
      final u = a.url.toLowerCase();
      var s = 0;
      if (t == q) {
        s += 100;
      } else if (t.startsWith(q) || q.startsWith(t)) {
        s += 60;
      } else if (t.contains(q) || q.contains(t)) {
        s += 40;
      } else {
        final qt = q.split(' ').toSet();
        final tt = t.split(' ').toSet();
        s += qt.intersection(tt).length * 8;
      }
      final diff = (t.length - q.length).abs();
      s -= diff ~/ 8;
      // AnimeFire "full-series" page bonus — only for an exact title match, so
      // spin-offs/films sharing the slug never receive it for a wrong query.
      if (t == q &&
          source == AnimeSource.animeFire &&
          a.url.contains('todos-os-episodios')) {
        s += 15;
      }
      for (final tok in nameSideTokens) {
        if (t.contains(tok) && !q.contains(tok)) s -= 25;
      }
      // Spin-off/extra content detected by slug/url markers (titles like
      // "One Piece: Episode of..." or "Movie N" slip past the name tokens
      // because the site serves them under ambiguous names).
      if (urlSideTokens.any(u.contains)) {
        s -= 25;
      }
      // Among exact-title ties, prefer the non-dubbed page: the site serves the
      // same series as both "...-dublado-todos-os-episodios" and the plain one.
      if (u.contains('dublado') || u.contains('legendado')) {
        s -= 5;
      }
      if (querySeason != null) {
        final cs = seasonOfCandidateUrl(a.url);
        if (cs == querySeason) {
          s += 30;
        } else if (cs != null) {
          s -= 30;
        } else {
          s -= 10;
        }
      }
      return s;
    }

    candidates.sort((a, b) {
      final cmp = score(b).compareTo(score(a));
      if (cmp != 0) return cmp;
      return a.url.compareTo(b.url);
    });
    return candidates.first;
  }

  /// Season from a provider ANIME-page URL tail (`…-ken-4` → 4). ONLY the
  /// last slug segment counts, and only `-<N>` (1–2 digits) in tail position:
  /// pure IDs (`/15859/`), resolutions (`-720p`), years, and episode-style
  /// tails never match. A tail digit preceded by a non-season token
  /// (`hd`, `online`, `dublado`, `legendado`, `ova`, `movie`, `film`,
  /// `special`, `episodio`) is NOT a season (`…-online-hd-2` → null).
  /// Public (not test-only): [GoyabuAdapter] uses it in production to detect
  /// a wrongly pinned season page.
  static int? seasonOfCandidateUrl(String url) {
    var path = url.split('?').first.split('#').first.toLowerCase();
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final tail = path.split('/').last;
    // Keyword-anchored tails first: `…-4th-season`, `…-season-4`,
    // `…-temporada-4` (the `season`/`temporada` keyword makes these exact —
    // no false-positive risk like bare digits).
    var m = RegExp(r'-(\d{1,2})(?:st|nd|rd|th)?-season$').firstMatch(tail) ??
        RegExp(r'-season-(\d{1,2})$').firstMatch(tail) ??
        RegExp(r'-temporada-(\d{1,2})$').firstMatch(tail);
    if (m != null) return int.tryParse(m.group(1)!);
    m = RegExp(r'-(\d{1,2})$').firstMatch(tail);
    if (m == null) return null;
    const nonSeason = {
      'hd', 'online', 'dublado', 'legendado', 'ova', 'movie', 'filme',
      'film', 'special', 'episodio', 'episode',
    };
    final beforeParts = tail.substring(0, m.start).split('-');
    final before = beforeParts.isEmpty ? '' : beforeParts.last;
    if (nonSeason.contains(before)) return null;
    return int.tryParse(m.group(1)!);
  }

  static String normalize(String s) {
    var t = s.toLowerCase();
    const from = 'áàãâäéèêëíìîïóòõôöúùûüç';
    const to = 'aaaaaeeeeiiiiooooouuuuc';
    for (var i = 0; i < from.length; i++) {
      t = t.replaceAll(from[i], to[i]);
    }
    t = t.replaceAll(
        RegExp(r'\b(dublado|legendado|dub|sub|todos os episodios)\b'), ' ');
    t = t.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }
}

  /// Report of availability check for a specific anime and source
  final class AvailabilityReport {
    final AnimeSource source;
    final String animeName;
    late final AvailabilityStatus status;
    String? reason;
    int? episodeCount;
    String? usedVariation;

    AvailabilityReport({
      required this.source,
      required this.animeName,
    });
  }

  /// Status of availability check
  enum AvailabilityStatus {
    available,         // Anime encontrado
    notFound,          // Anime não existe
    foundWithVariation,// Encontrado com nome alternativo
    error,             // Erro desconhecido
    timeout,           // Timeout
    exception,         // Exceção
  }