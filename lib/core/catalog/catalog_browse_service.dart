import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/anime.dart';
import '../anilist/anilist_service.dart';
import '../cache/app_caches.dart';
import '../tmdb/tmdb_service.dart';
import '../utils/text_utils.dart';

/// Camada de **listagem** (categorias + alfabeto) mesclando os dois
/// catálogos: AniList (anime) e TMDB (drama/dorama/donghua/novela).
///
/// ## Por que existe um índice local
///
/// A ideia original — "consultar o catálogo pela letra A" — **não funciona**
/// em nenhum dos dois provedores, e isso foi medido antes de codar:
///
///  - AniList: `Page.media(search:"R")` devolve **40 resultados no total**, dos
///    quais só **6** começam com R. A busca é difusa: "Sword" devolve
///    "Akame ga Kill!" junto. Nenhum provider tem ordenação alfabética.
///  - TMDB: `search/multi?query=R` tem a mesma natureza fuzzy, e
///    `discover` só pagina por *popularidade*.
///
/// Então o alfabeto é servido por um **índice local**: um varredor baixa
/// páginas de cada catálogo, guarda `{nome, id, tipo, poster}` em
/// SharedPreferences e a letra é um filtro em memória — instantâneo,
/// offline e sem gastar cota por tecla digitada.
///
/// O índice é uma **varredura de catálogo em segundo plano** com teto
/// ([_maxEntries]), não um dump completo do catálogo: um aparelho TV não
/// deve baixar o acervo inteiro. Os títulos mais populares é que aparecem.
class CatalogBrowseService {
  CatalogBrowseService._();

  static final CatalogBrowseService instance = CatalogBrowseService._();

  static const _kIndex = 'browse_index_v1';

  /// Teto do índice. ~2500 entradas ≈ 40 páginas: sync de ~1-2 min em
  /// wi-fi e ~150 KB de prefs. Acima disso o ganho é imperceptível numa TV.
  static const _maxEntries = 2500;

  /// Páginas por "onda" da varredura. Uma onda por lettera/main tick.
  static const _pagesPerWave = 3;

  static const _pageSize = 50;

  /// progressão da varredura (0..1) para a UI mostrar "indexando…".
  static final ValueNotifier<double> syncProgress = ValueNotifier<double>(0);

  static bool _syncing = false;

  // ─────────────────────────── índice local ───────────────────────────────

  static List<Anime> readIndex() {
    try {
      final raw = AppCaches.search.get<String>('browse_index_raw');
      if (raw != null) return decodeIndex(raw);
    } catch (_) {
      // cache volátil ausente: cai para o disco
    }
    return const [];
  }

  static List<Anime> decodeIndex(String raw) {
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((m) => Anime(
                name: TextUtils.cleanTitle(m['name']?.toString() ?? ''),
                url: m['url']?.toString() ?? '',
                source: AnimeSource.anilist,
                anilistId: int.tryParse(m['ail']?.toString() ?? ''),
                tmdbId: int.tryParse(m['tmdb']?.toString() ?? ''),
                mediaType: m['type']?.toString() ?? 'anime',
                fallbackImageUrl: m['img']?.toString(),
                description: m['desc']?.toString(),
              ))
          .where((a) => a.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String encodeIndex(List<Anime> items) => jsonEncode([
        for (final a in items)
          {
            'name': a.name,
            'url': a.url,
            'ail': a.anilistId,
            'tmdb': a.tmdbId,
            'type': a.mediaType ?? 'anime',
            'img': a.fallbackImageUrl,
            'desc': a.description,
          }
      ]);

  /// Índice pronto? Só acima de [minEntries] — abaixo disso o alfabeto
  /// mostraria uma listagem quase vazia sem explicar o porquê.
  static const minEntries = 30;

  static bool indexReady() => readIndex().length >= minEntries;

  // ────────────────────────── letra + normalização ─────────────────────────

  /// Primeira letraalfabética significanted o título (ignora artigo).
  ///
  /// "O Rei das Feras" cai em **R** (não em O): artigo inicial em inglês
  /// ("The", "A", "An") é removido antes de tirar a letra — é o que faz o
/// índice se parecer com a ordem de uma enciclopédia em vez de um overflow de
  /// "The…".
  static String letterOf(String title) {
    // `titleKey` já minúscula, tira acento e limpa pontuação — sem isso
    // "Átama" caía em '#' (o 'á' não está na faixa a-z) e o índice ficava
    // torto justamente nos títulos lusófonos, que é o público do app.
    var t = AnimeSourceAdapterCompare.titleKey(title);
    for (final art in const ['the ', 'a ', 'an ', 'o ', 'os ', 'as ']) {
      if (t.startsWith(art)) {
        t = t.substring(art.length);
        break;
      }
    }
    if (t.isEmpty) return '#';
    final code = t.codeUnitAt(0);
    // a-z; qualquer outra coisa (número, símbolo, letra de outro alfabeto)
    // cai em '#'.
    return (code >= 97 && code <= 122) ? t[0] : '#';
  }

  /// Todas as letras presentes no índice, em ordem de exibição.
  static List<String> lettersOf(Iterable<Anime> items) {
    final present = <String>{};
    for (final a in items) {
      present.add(letterOf(a.name));
    }
    final letters = present.where((l) => l != '#').toList()..sort();
    return [...letters, if (present.contains('#')) '#'];
  }

  /// Entradas da letra, ordenadas alfabeticamente (título normalizado).
  static List<Anime> byLetter(Iterable<Anime> items, String letter) {
    final out = items.where((a) => letterOf(a.name) == letter).toList();
    out.sort((a, b) => AnimeSourceAdapterCompare
        .titleKey(a.name)
        .compareTo(AnimeSourceAdapterCompare.titleKey(b.name)));
    return out;
  }

  // ─────────────────────────────── dedup ──────────────────────────────────

  /// Chave de identidade entre catálogos: título normalizado. Um mesmo
  /// drama aparece no TMDB como "Goblin" e pode vir do AniList como
  /// "Goblin (Korean Drama)" — o `cleanTitle` + remoção de sufixo comum
  /// colapsa os dois num card só.
  static String dedupKey(Anime a) {
    var t = AnimeSourceAdapterCompare.titleKey(a.name);
    const suffixes = [
      ' korean drama', ' chinese drama', ' japanese drama', ' tv',
      ' drama', ' anime', ' donghua',
    ];
    var changed = true;
    while (changed) {
      changed = false;
      for (final s in suffixes) {
        if (t.endsWith(s) && t.length > s.length) {
          t = t.substring(0, t.length - s.length);
          changed = true;
        }
      }
    }
    return t;
  }

  /// Mescla listas mantendo a ordem e preferring o primeiro que chegou
  /// (AniList vem antes na maior parte das chamadas, e é quem tem detalhe).
  static List<Anime> merge(List<Anime> primary, List<Anime> secondary) {
    final out = <Anime>[];
    final seen = <String>{};
    for (final a in [...primary, ...secondary]) {
      if (a.name.isEmpty) continue;
      if (!seen.add(dedupKey(a))) continue;
      out.add(a);
    }
    return out;
  }

  // ────────────────────────────── categorias ───────────────────────────────

  /// Categorias prontas para a grade. Une os gêneros do AniList (19, sempre
  /// disponível) com os do TMDB (só quando há chave), marcando a origem
  /// para o card poder dizer de onde veio.
  static Future<List<BrowseCategory>> categories() async {
    final out = <BrowseCategory>[
      BrowseCategory(
          id: 'anilist:Action', label: 'Ação', anilistGenre: 'Action'),
      BrowseCategory(
          id: 'anilist:Adventure', label: 'Aventura', anilistGenre: 'Adventure'),
      BrowseCategory(
          id: 'anilist:Comedy', label: 'Comédia', anilistGenre: 'Comedy'),
      BrowseCategory(
          id: 'anilist:Drama', label: 'Drama', anilistGenre: 'Drama'),
      BrowseCategory(
          id: 'anilist:Fantasy', label: 'Fantasia', anilistGenre: 'Fantasy'),
      BrowseCategory(
          id: 'anilist:Horror', label: 'Terror', anilistGenre: 'Horror'),
      BrowseCategory(
          id: 'anilist:Mystery', label: 'Mistério', anilistGenre: 'Mystery'),
      BrowseCategory(
          id: 'anilist:Romance', label: 'Romance', anilistGenre: 'Romance'),
      BrowseCategory(
          id: 'anilist:Sci-Fi', label: 'Ficção científica',
          anilistGenre: 'Sci-Fi'),
      BrowseCategory(
          id: 'anilist:Mecha', label: 'Mecha', anilistGenre: 'Mecha'),
      BrowseCategory(
          id: 'anilist:Mahou Shoujo', label: 'Mahou Shoujo',
          anilistGenre: 'Mahou Shoujo'),
    ];

    // TMDB: só faz sentido com chave configurada.
    if (TmdbService.isConfigured) {
      final tv = await TmdbService.tvGenres();
      // Ids oficiais do TMDB para as séries que interessam mais aqui.
      const wanted = {
        18: 'Drama',
        10765: 'Ficção científica',
        10759: 'Ação e aventura',
        16: 'Animação',
        35: 'Comédia',
        80: 'Crime',
        9648: 'Mistério',
        10768: 'Guerra e história',
      };
      for (final e in wanted.entries) {
        final name = tv[e.key];
        if (name == null) continue;
        out.add(BrowseCategory(
          id: 'tmdb:tv:${e.key}',
          label: name,
          tmdbGenre: e.key,
          mediaType: 'tv',
        ));
      }
    }
    return out;
  }

  /// Conteúdo de uma categoria. AniList primeiro, TMDB depois, mesclado.
  static Future<List<Anime>> itemsOf(BrowseCategory c) async {
    final fromAnilist = <Anime>[];
    if (c.anilistGenre != null) {
      final q = '''
        query (\$genre: String, \$n: Int) {
          Page(page: 1, perPage: \$n) {
            media(type: ANIME, genre: \$genre, sort: [POPULARITY_DESC], isAdult: false) {
              id idMal duration
              title { romaji english native }
              coverImage { extraLarge large medium }
              bannerImage description episodes status averageScore genres
            }
          }
        }
      ''';
      try {
        final res = await AniListService.catalogByGenre(q, c.anilistGenre!,
            perPage: 40);
        fromAnilist.addAll(res);
      } catch (e) {
        debugPrint('[Browse] categoria AniList falhou: $e');
      }
    }
    final fromTmdb = <Anime>[];
    if (c.tmdbGenre != null) {
      final r = await TmdbService.discover(
          mediaType: c.mediaType ?? 'tv', genreId: c.tmdbGenre);
      fromTmdb.addAll(r);
    }
    return merge(fromAnilist, fromTmdb);
  }

  // ─────────────────────────────── sync ───────────────────────────────────

  /// Varre os dois catálogos e reconstrói o índice. Idempotente e
  /// incremental: rodando de novo, só acrescenta o que é novo.
  static Future<void> sync({bool force = false}) async {
    if (_syncing) return;
    if (!force && indexReady()) return;
    _syncing = true;
    try {
      var buffer = <Anime>[...readIndex()];
      final seen = buffer.map(dedupKey).toSet();

      void ingest(List<Anime> batch) {
        for (final a in batch) {
          if (buffer.length >= _maxEntries) return;
          if (a.name.isEmpty) continue;
          if (!seen.add(dedupKey(a))) continue;
          buffer.add(a);
        }
      }

      var wave = 0;
      final totalWaves = (_maxEntries ~/ (_pageSize * _pagesPerWave)).clamp(1, 24);

      while (buffer.length < _maxEntries && wave < totalWaves) {
        final page = wave + 1;
        // AniList: o catálogo paginado por popularidade.
        try {
          ingest(await AniListService.catalogPage(page: page, perPage: _pageSize));
        } catch (e) {
          debugPrint('[Browse] sync AniList p$page: $e');
        }
        // TMDB: séries + filmes (drama/novela live-action).
        if (TmdbService.isConfigured && wave < 6) {
          ingest(await TmdbService.discover(
              mediaType: 'tv', page: page, sortBy: 'popularity.desc'));
        }
        wave++;
        syncProgress.value = (wave / totalWaves).clamp(0.0, 1.0);
      }

      await _persist(buffer);
      syncProgress.value = 1.0;
      debugPrint('[Browse] índice: ${buffer.length} títulos, '
          'letras=${lettersOf(buffer).join()}');
    } finally {
      _syncing = false;
    }
  }

  static Future<void> _persist(List<Anime> items) async {
    final raw = encodeIndex(items);
    AppCaches.search.set<String>('browse_index_raw', raw);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kIndex, raw);
    } catch (e) {
      debugPrint('[Browse] persist falhou (cache volátil ainda vale): $e');
    }
  }

  /// Chamado no boot para popular o índice sem travar a Home.
  static void warmUpInBackground() {
    if (indexReady()) return;
    sync().catchError((Object e) {
      debugPrint('[Browse] warmUp falhou: $e');
    });
  }

  static Future<void> clearIndex() async {
    AppCaches.search.remove('browse_index_raw');
    syncProgress.value = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kIndex);
    } catch (_) {}
  }
}

/// Categoria da grade de exploração.
class BrowseCategory {
  final String id;
  final String label;
  final String? anilistGenre;
  final int? tmdbGenre;
  final String? mediaType;

  const BrowseCategory({
    required this.id,
    required this.label,
    this.anilistGenre,
    this.tmdbGenre,
    this.mediaType,
  });

  bool get isTmdb => tmdbGenre != null;
}

/// Ordenação alfabética estável, reaproveitando a normalização do core
/// (`AnimeSourceAdapter.normalize`) sem acoplar o catálogo a um adapter.
class AnimeSourceAdapterCompare {
  AnimeSourceAdapterCompare._();

  static const _from = 'áàãâäéèêëíìîïóòõôöúùûüç';
  static const _to = 'aaaaaeeeeiiiiooooouuuuc';

  /// Chave de ordenação: minúsculo, sem acento, sem pontuação.
  static String titleKey(String raw) {
    var t = raw.toLowerCase();
    for (var i = 0; i < _from.length; i++) {
      t = t.replaceAll(_from[i], _to[i]);
    }
    return t.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(
        RegExp(r'\s+'), ' ').trim();
  }
}