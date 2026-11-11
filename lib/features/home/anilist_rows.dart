import '../../core/utils/nsfw_filter.dart';
import '../../core/utils/text_utils.dart';
import '../../data/models/anilist_models.dart';

/// Seed de uma linha de recomendação vinda das listas AniList (o id sempre
/// existe; títulos locais podem não ter, por isso o seed principal aceita
/// `anilistId` nulo e resolve por enrich).
typedef RecommendationSeed = ({String title, int mediaId});

/// Os [limit] animes concluídos mais recentes do AniList, por `updatedAt`
/// decrescente — o último finalizado aparece primeiro.
///
/// [exclude] evita repetir na linha "terminou" o mesmo título que já abriu a
/// linha "assistiu"; [nsfw] descarta o que o filtro do usuário esconde.
List<RecommendationSeed> recentCompletedSeeds(
  List<AniListGroup> lists, {
  required NsfwFilterSetting nsfw,
  ({String title, int? anilistId})? exclude,
  int limit = 2,
}) {
  final completed = lists
      .expand((g) => g.entries)
      .where((e) =>
          e.status == 'COMPLETED' &&
          NsfwFilter.shouldShowMedia(e.media, nsfw))
      .toList()
    ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));

  final seen = <int>{};
  final seeds = <RecommendationSeed>[];
  for (final entry in completed) {
    if (exclude != null &&
        (exclude.anilistId == entry.media.id ||
            TextUtils.cleanTitle(exclude.title).toLowerCase() ==
                TextUtils.cleanTitle(entry.media.title).toLowerCase())) {
      continue;
    }
    if (!seen.add(entry.media.id)) continue;
    seeds.add((title: entry.media.title, mediaId: entry.media.id));
    if (seeds.length == limit) break;
  }
  return seeds;
}

/// Grupos que não são CURRENT/REPEATING/PLANNING (Completos, Pausados,
/// Dropados), com os títulos mais recentemente atualizados primeiro. Grupos
/// que ficarem vazios pelo filtro NSFW saem da lista.
List<AniListGroup> inactiveGroups(
  List<AniListGroup> lists, {
  required NsfwFilterSetting nsfw,
}) {
  return lists
      .where((g) => g.entries.any((e) =>
          e.status != 'CURRENT' &&
          e.status != 'REPEATING' &&
          e.status != 'PLANNING' &&
          NsfwFilter.shouldShowMedia(e.media, nsfw)))
      .map((g) => AniListGroup(
            name: g.name,
            entries: g.entries
                .where((e) => NsfwFilter.shouldShowMedia(e.media, nsfw))
                .toList()
              ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0)),
          ))
      .where((g) => g.entries.isNotEmpty)
      .toList();
}
