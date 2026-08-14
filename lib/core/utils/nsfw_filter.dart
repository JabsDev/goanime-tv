import '../../data/models/anime.dart';
import '../../data/models/anilist_models.dart';

/// Classificação de conteúdo de um anime. Ecchi é mais leve que hentai —
/// o filtro trata os dois em níveis distintos.
enum NsfwLevel { safe, ecchi, hentai }

/// Nível do filtro configurado pelo usuário.
///
/// `strict` (padrão) esconde ecchi + hentai; `soft` esconde só hentai;
/// `off` mostra tudo.
enum NsfwFilterSetting { strict, soft, off }

/// Filtro central de conteúdo NSFW. Pura e offline: classifica um anime a
/// partir dos sinais que o AniList já carregou (ou que o scraper trouxe).
///
/// Sinais usados:
///  - hentai: `isAdult` do AniList (sinal canônico e forte) ou título contendo
///    "hentai" (fallback para resultados sem enrich).
///  - ecchi: gênero "Ecchi" ou tags "Ecchi"/"Fan Service" do AniList.
///
/// NÃO usa `tag.isAdult` — a própria tag "Ecchi" é marcada adult no AniList e
/// classificaria um ecchi puro como hentai (falso-positivo). Keywords de título
/// são conservadoras de propósito: "ero" pegaria "Eromanga Sensei" (comédia
/// ecchi) como hentai.
class NsfwFilter {
  const NsfwFilter._();

  static const _hentaiTitleKeywords = ['hentai'];

  static const _ecchiGenres = {'ecchi'};
  static const _ecchiTags = {'ecchi', 'fan service'};

  static NsfwLevel classify(Anime anime) {
    return classifySignals(
      isAdult: anime.isAdult,
      genres: anime.genres,
      tags: const [],
      title: anime.name,
    );
  }

  static NsfwLevel classifySignals({
    required bool? isAdult,
    required List<String> genres,
    List<String> tags = const [],
    required String title,
  }) {
    if (isAdult == true) return NsfwLevel.hentai;

    final lower = title.toLowerCase();
    if (_hentaiTitleKeywords.any(lower.contains)) return NsfwLevel.hentai;

    final hasEcchi = genres.any((g) => _ecchiGenres.contains(g.toLowerCase())) ||
        tags.any((t) => _ecchiTags.contains(t.toLowerCase()));
    if (hasEcchi) return NsfwLevel.ecchi;

    return NsfwLevel.safe;
  }

  /// Conveniência para entradas de listas AniList do usuário.
  static NsfwLevel classifyMedia(AniListMedia media) {
    return classifySignals(
      isAdult: media.isAdult,
      genres: media.genres,
      title: media.title,
    );
  }

  /// Classifica um item salvo (favorito/histórico) que só guarda título e
  /// anilistId. [detail] vem do cache de enrichment quando disponível — sem
  /// metadata, cai no fallback de keyword do título (fail-open).
  static NsfwLevel classifyStoredItem({
    required String title,
    AniListMediaDetail? detail,
  }) {
    if (detail != null) {
      return classifySignals(
        isAdult: detail.isAdult,
        genres: detail.genres,
        tags: detail.tags,
        title: title,
      );
    }
    return classifySignals(isAdult: null, genres: const [], title: title);
  }

  static bool shouldShow(Anime anime, NsfwFilterSetting setting) {
    return levelAllowed(classify(anime), setting);
  }

  static bool shouldShowMedia(AniListMedia media, NsfwFilterSetting setting) {
    return levelAllowed(classifyMedia(media), setting);
  }

  static bool levelAllowed(NsfwLevel level, NsfwFilterSetting setting) {
    switch (setting) {
      case NsfwFilterSetting.strict:
        return level == NsfwLevel.safe;
      case NsfwFilterSetting.soft:
        return level != NsfwLevel.hentai;
      case NsfwFilterSetting.off:
        return true;
    }
  }

  static List<Anime> filter(List<Anime> animes, NsfwFilterSetting setting) {
    if (setting == NsfwFilterSetting.off) return animes;
    return animes.where((a) => shouldShow(a, setting)).toList();
  }
}
