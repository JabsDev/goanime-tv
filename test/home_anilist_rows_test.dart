import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/utils/nsfw_filter.dart';
import 'package:goanime_tv/data/models/anilist_models.dart';
import 'package:goanime_tv/features/home/anilist_rows.dart';

void main() {
  AniListEntry entry(
    int id,
    String title, {
    required String status,
    int? updatedAt,
    bool isAdult = false,
    List<String> genres = const [],
  }) =>
      AniListEntry(
        media: AniListMedia(
          id: id,
          title: title,
          status: status,
          isAdult: isAdult,
          genres: genres,
        ),
        status: status,
        updatedAt: updatedAt,
      );

  group('recentCompletedSeeds', () {
    test('pega os 2 COMPLETED mais recentes, do mais novo para o mais antigo',
        () {
      final lists = [
        AniListGroup(name: 'Completed', entries: [
          entry(1, 'Antigo', status: 'COMPLETED', updatedAt: 100),
          entry(2, 'Recente', status: 'COMPLETED', updatedAt: 300),
          entry(3, 'Meio', status: 'COMPLETED', updatedAt: 200),
        ]),
      ];

      final seeds = recentCompletedSeeds(lists, nsfw: NsfwFilterSetting.strict);

      expect(seeds.map((s) => s.mediaId), [2, 3]);
      expect(seeds.map((s) => s.title), ['Recente', 'Meio']);
    });

    test('ignora CURRENT/PLANNING e entradas sem updatedAt vão para o fim', () {
      final lists = [
        AniListGroup(name: 'Completed', entries: [
          entry(1, 'Sem data', status: 'COMPLETED'),
          entry(2, 'Assistindo', status: 'CURRENT', updatedAt: 999),
          entry(3, 'Planejado', status: 'PLANNING', updatedAt: 998),
          entry(4, 'Concluído', status: 'COMPLETED', updatedAt: 10),
        ]),
      ];

      final seeds = recentCompletedSeeds(lists, nsfw: NsfwFilterSetting.off);

      expect(seeds.map((s) => s.mediaId), [4, 1]);
    });

    test('não repete o mesmo media e respeita o limite', () {
      final lists = [
        AniListGroup(name: 'Completed', entries: [
          entry(7, 'Repetido', status: 'COMPLETED', updatedAt: 300),
          entry(7, 'Repetido', status: 'COMPLETED', updatedAt: 250),
          entry(8, 'Outro', status: 'COMPLETED', updatedAt: 100),
          entry(9, 'Terceiro', status: 'COMPLETED', updatedAt: 50),
        ]),
      ];

      final seeds = recentCompletedSeeds(lists, nsfw: NsfwFilterSetting.off);

      expect(seeds.map((s) => s.mediaId), [7, 8]);
    });

    test('descarta o seed principal por id e por título limpo', () {
      final lists = [
        AniListGroup(name: 'Completed', entries: [
          entry(1, 'Naruto', status: 'COMPLETED', updatedAt: 400),
          entry(2, 'Bleach', status: 'COMPLETED', updatedAt: 300),
          entry(3, 'One Piece', status: 'COMPLETED', updatedAt: 200),
        ]),
      ];

      final byId = recentCompletedSeeds(
        lists,
        nsfw: NsfwFilterSetting.off,
        exclude: (title: 'Outro nome', anilistId: 1),
      );
      expect(byId.map((s) => s.mediaId), [2, 3]);

      final byTitle = recentCompletedSeeds(
        lists,
        nsfw: NsfwFilterSetting.off,
        exclude: (title: 'BLEACH (Dublado)', anilistId: null),
      );
      expect(byTitle.map((s) => s.mediaId), [1, 3]);
    });

    test('respeita o filtro NSFW', () {
      final lists = [
        AniListGroup(name: 'Completed', entries: [
          entry(1, 'Adulto', status: 'COMPLETED', updatedAt: 300, isAdult: true),
          entry(2, 'Ecchi', status: 'COMPLETED', updatedAt: 200,
              genres: ['Ecchi']),
          entry(3, 'Normal', status: 'COMPLETED', updatedAt: 100),
        ]),
      ];

      expect(
        recentCompletedSeeds(lists, nsfw: NsfwFilterSetting.strict)
            .map((s) => s.mediaId),
        [3],
      );
      expect(
        recentCompletedSeeds(lists, nsfw: NsfwFilterSetting.soft)
            .map((s) => s.mediaId),
        [2, 3],
      );
      expect(
        recentCompletedSeeds(lists, nsfw: NsfwFilterSetting.off, limit: 3)
            .map((s) => s.mediaId),
        [1, 2, 3],
      );
    });
  });

  group('inactiveGroups', () {
    test('mantém só grupos inativos e ordena por updatedAt decrescente', () {
      final lists = [
        AniListGroup(name: 'Completed', entries: [
          entry(1, 'Velho', status: 'COMPLETED', updatedAt: 100),
          entry(2, 'Novo', status: 'COMPLETED', updatedAt: 300),
        ]),
        AniListGroup(name: 'Watching', entries: [
          entry(3, 'Atual', status: 'CURRENT', updatedAt: 999),
        ]),
        AniListGroup(name: 'Paused', entries: [
          entry(4, 'Pausado', status: 'PAUSED', updatedAt: 50),
        ]),
      ];

      final groups = inactiveGroups(lists, nsfw: NsfwFilterSetting.off);

      expect(groups.map((g) => g.name), ['Completed', 'Paused']);
      expect(groups.first.entries.map((e) => e.media.id), [2, 1]);
    });

    test('remove grupo que fica vazio depois do filtro NSFW', () {
      final lists = [
        AniListGroup(name: 'Completed', entries: [
          entry(1, 'Adulto', status: 'COMPLETED', isAdult: true),
        ]),
      ];

      expect(inactiveGroups(lists, nsfw: NsfwFilterSetting.strict), isEmpty);
    });
  });
}
