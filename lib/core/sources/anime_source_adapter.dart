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
        return bestMatch(animeRef.name, valid, source);
      case Failure():
      case Loading():
        return null;
    }
  }

  /// Resolves the playable [VideoSource]s of episode [episodeNumber] on a page
  /// previously matched by [resolveAnime]. Returns an empty list when this
  /// provider doesn't have that episode.
  Future<List<VideoSource>> resolveVideo(Anime match, int episodeNumber) async {
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
  /// prefix and containment matches; shorter/closer titles win ties; movies,
  /// OVAs and specials are penalized so the catalog title maps to the main
  /// series. AnimeFire additionally prefers the full-series page.
  static Anime bestMatch(
      String query, List<Anime> candidates, AnimeSource source) {
    final q = normalize(query);
    int score(Anime a) {
      final t = normalize(a.name);
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
      if (source == AnimeSource.animeFire &&
          a.url.contains('todos-os-episodios')) {
        s += 15;
      }
      const sideTokens = ['film', 'movie', 'ova', 'special', 'gaiden', 'recap'];
      for (final tok in sideTokens) {
        if (t.contains(tok) && !q.contains(tok)) s -= 25;
      }
      return s;
    }

    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates.first;
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