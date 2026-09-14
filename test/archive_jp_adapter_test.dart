import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/archive_jp_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

void main() {
  final adapter = ArchiveJpAdapter();

  group('ArchiveJpAdapter (fonte JA cru p/ teste IA)', () {
    test('search casa "haibane", ignora resto', () async {
      final hit =
          (await adapter.search('Haibane Renmei')) as Success<List<Anime>>;
      expect(hit.data, hasLength(1));
      expect(hit.data.first.source, AnimeSource.archiveJp);
      final miss = (await adapter.search('Naruto')) as Success<List<Anime>>;
      expect(miss.data, isEmpty);
    });

    test('13 episódios com URL direta do Archive', () async {
      final eps = (await adapter.getEpisodes(Anime(
          name: 'Haibane Renmei',
          url: 'x',
          source: AnimeSource.archiveJp))) as Success<List<Episode>>;
      final list = eps.data;
      expect(list, hasLength(13));
      expect(list.first.url,
          'https://archive.org/download/haibane-renmei_202606/Haibane%20Renmei%20-%20S01E01.mp4');
      expect(list.last.url.endsWith('S01E13.mp4'), isTrue);
    });

    test('getVideoSources entrega mp4 JA cru', () async {
      final src = (await adapter.getVideoSources(
              Episode(number: '1', url: 'x', source: AnimeSource.archiveJp)))
          as Success<List<VideoSource>>;
      final vs = src.data;
      expect(vs.single.url.endsWith('.mp4'), isTrue);
      expect(vs.single.subtitleCandidates, isEmpty); // JA cru: transcribe L1
    });

    test('EP fora de 1..13 falha alto', () async {
      final bad = await adapter.getVideoSources(
          Episode(number: '99', url: 'x', source: AnimeSource.archiveJp));
      expect(bad, isA<Failure>());
    });
  });
}
