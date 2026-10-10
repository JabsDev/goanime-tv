import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../data/models/anime.dart';
import '../network/api_client.dart';
import '../storage/settings_service.dart';
import '../utils/text_utils.dart';

/// Cliente do catálogo **TMDB** — a peça que falta no app para K-drama,
/// C-drama, dorama japonês, donghua, novelas e filmes.
///
/// Por que TMDB e não outra coisa: o catálogo canônico atual é o AniList,
/// que é **exclusivamente anime**. O TMDB cobre a família toda (drama,
/// donghua, novela, filme) com metadados ricos e tradução oficial em
/// português (`language=pt-BR`).
///
/// 🔑 **A chave é do usuário** (`SettingsService.tmdbApiKey`). O app não tem
/// backend, então não há onde embutir um segredo: com chave embutida no APK
/// qualquer um a extrai e consome a cota. Sem chave, [isConfigured] é falso
/// e todo método aqui devolve vazio — o app segue funcionando só com AniList.
///
/// Endpoints usados (REST v3):
///  - `GET /search/multi?query=&language=pt-BR` → filmes+séries+anime
///  - `GET /discover/tv?with_genres=&sort_by=popularity.desc` → por categoria
///  - `GET /genre/tv/list` e `/genre/movie/list` → categorias
///  - `GET /tv/{id}?append_to_response=external_ids` → detalhe + id externo
class TmdbService {
  TmdbService._();

  static final TmdbService instance = TmdbService._();

  static const _base = 'https://api.themoviedb.org/3';
  static const _imageBase = 'https://image.tmdb.org/t/p';

  /// Cota do TMDB é ~50 req/s, mas num aparelho TV não faz sentido
  /// martelar: este gap serializa as chamadas e evita 429 numa varredura
  /// de índice.
  static Duration requestGap = const Duration(milliseconds: 120);
  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  /// Cliente injetável (testes).
  static http.Client? httpOverride;

  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  /// Catálogo TMDB só opera com chave válida + toggle ligado.
  static bool get isConfigured => SettingsService.instance.tmdbConfigured;

  static String? get _apiKey {
    if (!isConfigured) return null;
    final k = SettingsService.instance.tmdbApiKey.trim();
    return k.isEmpty ? null : k;
  }

  static Future<http.Response> _get(String path, Map<String, String> q) async {
    final key = _apiKey;
    if (key == null) {
      return http.Response(jsonEncode({'status_code': 7,
        'status_message': 'TMDB sem chave configurada'}), 401);
    }
    final gap = DateTime.now().difference(_lastRequest).inMilliseconds;
    if (gap < requestGap.inMilliseconds) {
      await Future.delayed(Duration(milliseconds: requestGap.inMilliseconds - gap));
    }
    _lastRequest = DateTime.now();

    final params = <String, String>{
      ...q,
      'api_key': key,
      'language': 'pt-BR',
    };
    final uri = Uri.parse('$_base$path').replace(queryParameters: params);
    final client = httpOverride;
    return client != null
        ? client.get(uri, headers: {'User-Agent': _userAgent})
        : apiClient.get(uri, headers: {'User-Agent': _userAgent});
  }

  // ────────────────────────────── parse ───────────────────────────────────

  /// Resultado de `search/multi` → [Anime]. `media_type` vira [Anime.mediaType]
  /// ('tv' | 'movie'); `person` é descartado (não é conteúdo assistível).
  static List<Anime> parseSearchMulti(String body) {
    final rows = _results(body);
    if (rows == null) return const [];
    final out = <Anime>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final type = raw['media_type']?.toString() ?? '';
      if (type != 'tv' && type != 'movie') continue;
      final anime = _toAnime(raw, type);
      if (anime != null) out.add(anime);
    }
    return out;
  }

  /// Resultado de `discover/tv` ou `discover/movie` → [Anime].
  static List<Anime> parseDiscover(String body, String mediaType) {
    final rows = _results(body);
    if (rows == null) return const [];
    final out = <Anime>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final anime = _toAnime(raw, mediaType);
      if (anime != null) out.add(anime);
    }
    return out;
  }

  /// `genre/tv/list` + `genre/movie/list` → mapa `id → nome`.
  static Map<int, String> parseGenres(String body) {
    final decoded = _decode(body);
    final genres = decoded?['genres'];
    if (genres is! List) return const {};
    final out = <int, String>{};
    for (final g in genres) {
      if (g is! Map) continue;
      final id = g['id'];
      final name = g['name']?.toString() ?? '';
      if (id is num && name.isNotEmpty) out[id.toInt()] = name;
    }
    return out;
  }

  static Map<String, dynamic>? _decode(String body) {
    try {
      final d = jsonDecode(body);
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  static List? _results(String body) {
    final d = _decode(body);
    final r = d?['results'];
    return r is List ? r : null;
  }

  static Anime? _toAnime(Map raw, String mediaType) {
    final id = raw['id'];
    final title = TextUtils.cleanTitle(
        (raw['name'] ?? raw['title'] ?? raw['original_name'] ?? '').toString());
    if (id is! num || title.isEmpty) return null;
    final poster = raw['poster_path']?.toString() ?? '';
    final backdrop = raw['backdrop_path']?.toString() ?? '';
    final overview = raw['overview']?.toString() ?? '';
    return Anime(
      name: title,
      // O app ainda não tem detalhe TMDB; a URL serve de identidade para o
      // catálogo e de destino para a busca por nome.
      url: 'https://www.themoviedb.org/${mediaType == 'movie' ? 'movie' : 'tv'}/$id',
      source: AnimeSource.anilist,
      tmdbId: id.toInt(),
      mediaType: mediaType,
      fallbackImageUrl: poster.isEmpty ? null : '$_imageBase/w342$poster',
      bannerImage: backdrop.isEmpty ? null : '$_imageBase/w780$backdrop',
      description: TextUtils.cleanTitle(overview),
      status: raw['status']?.toString(),
      averageScore: (raw['vote_average'] as num?)?.toDouble(),
      episodes: (raw['number_of_episodes'] as num?)?.toInt(),
      genres: _genreNames(raw['genre_ids']),
    );
  }

  /// Só guarda os nomes; `genre_ids` são numéricos e viram nome via
  /// [genreNames] quando o chamador já os tem em cache.
  static List<String> _genreNames(Object? ids) {
    if (ids is! List) return const [];
    return ids.map((e) => e.toString()).toList(growable: false);
  }

  /// Substitui ids numéricos pelos nomes, usando o mapa de cache.
  static List<Anime> nameGenres(List<Anime> items, Map<int, String> names) {
    if (names.isEmpty) return items;
    return items
        .map((a) => Anime(
              name: a.name,
              url: a.url,
              source: a.source,
              tmdbId: a.tmdbId,
              mediaType: a.mediaType,
              fallbackImageUrl: a.fallbackImageUrl,
              bannerImage: a.bannerImage,
              description: a.description,
              status: a.status,
              averageScore: a.averageScore,
              episodes: a.episodes,
              genres: a.genres
                  .map((g) => names[int.tryParse(g) ?? -1] ?? g)
                  .toList(),
            ))
        .toList();
  }

  // ────────────────────────────── consultas ───────────────────────────────

  /// Busca livre (filmes + séries + anime em PT-BR).
  static Future<List<Anime>> search(String query, {int page = 1}) async {
    final q = TextUtils.cleanSearchQuery(query);
    if (q.isEmpty || !isConfigured) return const [];
    try {
      final res = await _get('/search/multi', {
        'query': q,
        'page': '$page',
        'include_adult': 'false',
      });
      if (res.statusCode != 200) return const [];
      return parseSearchMulti(res.body);
    } catch (e) {
      debugPrint('[TMDB] search error: $e');
      return const [];
    }
  }

  /// Categoria + ordenação. [genreId] do mapa de [genres].
  static Future<List<Anime>> discover({
    required String mediaType,
    int? genreId,
    int page = 1,
    String sortBy = 'popularity.desc',
  }) async {
    if (!isConfigured) return const [];
    final path = mediaType == 'movie' ? '/discover/movie' : '/discover/tv';
    try {
      final res = await _get(path, {
        if (genreId != null) 'with_genres': '$genreId',
        'sort_by': sortBy,
        'page': '$page',
        'include_adult': 'false',
        // Anime é `tv` com origem japonesa: sem isso o catálogo mistura
        // reality/talk show e infiltra conteúdo que o app não tem como servir.
        if (mediaType == 'tv') ...{
          'with_original_language': 'ja,ko,zh,th',
          'with_type': '1',
        },
      });
      if (res.statusCode != 200) return const [];
      return parseDiscover(res.body, mediaType);
    } catch (e) {
      debugPrint('[TMDB] discover error: $e');
      return const [];
    }
  }

  /// Categorias de séries (drama/dorama/novela/anime).
  static Future<Map<int, String>> tvGenres() => _genres('/genre/tv/list');
  static Future<Map<int, String>> movieGenres() => _genres('/genre/movie/list');

  static Future<Map<int, String>> _genres(String path) async {
    if (!isConfigured) return const {};
    try {
      final res = await _get(path, const {});
      if (res.statusCode != 200) return const {};
      return parseGenres(res.body);
    } catch (e) {
      debugPrint('[TMDB] genres error: $e');
      return const {};
    }
  }

  /// Detalhe de um título — inclui `external_ids` (tv_id/imdb_id), que é o
  /// que casa com o catálogo do AniList quando existir correspondência.
  static Future<Map<String, dynamic>?> detail(int tmdbId, String mediaType) async {
    if (!isConfigured) return null;
    final path = mediaType == 'movie' ? '/movie/$tmdbId' : '/tv/$tmdbId';
    try {
      final res = await _get(path, const {'append_to_response': 'external_ids'});
      if (res.statusCode != 200) return null;
      return _decode(res.body);
    } catch (e) {
      debugPrint('[TMDB] detail error: $e');
      return null;
    }
  }
}