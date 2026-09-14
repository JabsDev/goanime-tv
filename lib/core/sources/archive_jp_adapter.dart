import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../scraper/scraper_result.dart';
import 'anime_source_adapter.dart';

/// Fonte de teste JA cru p/ o workflow de legenda IA (estudo §Haibane):
/// 13 mp4s japoneses sem legenda do Archive.org (`haibane-renmei_202606`,
/// ~140 MB cada). Sem scraping: URLs diretas estáveis.
/// Buscar "Haibane Renmei" no app → fonte archiveJp → EP → picker mostra
/// `[Gerar legenda com IA]` (sem candidatas HLS, cai no transcribe L1).
class ArchiveJpAdapter extends AnimeSourceAdapter {
  static const itemId = 'haibane-renmei_202606';
  static const animeTitle = 'Haibane Renmei';
  static const episodeCount = 13;

  static String videoUrl(int ep) {
    final n = ep.toString().padLeft(2, '0');
    return 'https://archive.org/download/$itemId/'
        'Haibane%20Renmei%20-%20S01E$n.mp4';
  }

  @override
  AnimeSource get source => AnimeSource.archiveJp;

  @override
  Future<ScraperResult<List<Anime>>> search(String query) async {
    final q = query.toLowerCase();
    if (!q.contains('haibane')) return ScraperResult.success(const []);
    return ScraperResult.success([
      Anime(
        name: animeTitle,
        url: 'https://archive.org/details/$itemId',
        source: source,
        episodes: episodeCount,
      ),
    ]);
  }

  @override
  Future<ScraperResult<List<Episode>>> getEpisodes(Anime anime) async {
    return ScraperResult.success(List.generate(
      episodeCount,
      (i) => Episode(
        number: '${i + 1}',
        url: videoUrl(i + 1),
        title: '$animeTitle EP${i + 1}',
        source: source,
      ),
    ));
  }

  @override
  Future<ScraperResult<List<VideoSource>>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    final n = int.tryParse(episode.number) ?? 0;
    if (n < 1 || n > episodeCount) {
      return ScraperResult.failure(
          EmptyResultError(message: 'EP fora de 1..$episodeCount', source: source));
    }
    return ScraperResult.success([
      VideoSource(
        url: videoUrl(n),
        quality: 'JA cru',
        audio: 'japonês',
      ),
    ]);
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
          report.episodeCount = episodeCount;
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
