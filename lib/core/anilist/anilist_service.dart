import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../data/models/anilist_models.dart';
import '../storage/local_storage.dart';
import '../../data/models/anime.dart';
import '../cache/app_caches.dart';
import '../constants/app_constants.dart';
import '../utils/text_utils.dart';

class AniListService {
  /// Auth URL using the Implicit Grant with AniList's pin redirect.
  /// The access token appears in the URL fragment
  /// (`#access_token=...`) or on the pin page itself after authorization.
  static String get authUrl {
    return 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=${AppConstants.anilistClientId}'
        '&response_type=token'
        '&redirect_uri=${Uri.encodeComponent('https://anilist.co/api/v2/oauth/pin')}';
  }

  static Future<bool> isLoggedIn() async {
    return LocalStorage.getToken() != null;
  }

  static Future<String?> getToken() async {
    return LocalStorage.getToken();
  }

  static Future<bool> saveToken(String token) async {
    if (!token.startsWith('eyJ')) return false;
    final saved = await LocalStorage.saveToken(token);
    if (!saved) return false;
    final user = await _fetchUser(token);
    if (user != null) {
      await LocalStorage.saveUserData('user', {
        'id': user.id,
        'name': user.name,
        'avatar': user.avatar,
      });
      return true;
    }
    await LocalStorage.removeToken();
    return false;
  }

  static Future<AniListUser?> getUser() async {
    final data = LocalStorage.getUserData('user');
    if (data == null) return null;
    try {
      return AniListUser.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  /// ponytail: valida o token no boot re-fetching Viewer. Se OK, atualiza o cache
  /// local de `user`; se vier null (401/400/network), faz logout limpo. Sem isso,
  /// um token presente mas inválido deixava `_anilistLoggedIn=true` + user null
  /// → dropdown aparecia como "Visitante" mas com itens de logado.
  static Future<AniListUser?> refreshUser() async {
    final token = await getToken();
    if (token == null) return null;
    final user = await _fetchUser(token);
    if (user == null) {
      await logout();
      return null;
    }
    await LocalStorage.saveUserData('user', {
      'id': user.id,
      'name': user.name,
      'avatar': user.avatar,
    });
    return user;
  }

  static Future<void> logout() async {
    await LocalStorage.removeToken();
    await LocalStorage.removeUserData('user');
  }

  static Future<AniListUser?> _fetchUser(String token) async {
    const query = '''{
      Viewer {
        id
        name
        avatar { large }
      }
    }''';
    final res = await _graphQL(query, token);
    if (res == null) return null;
    return AniListUser.fromJson(res['Viewer'] as Map<String, dynamic>);
  }

  static Future<List<AniListGroup>> getUserAnimeList() async {
    final token = await getToken();
    if (token == null) return [];
    final lists = await _fetchAnimeList(token);
    if (lists.isNotEmpty) _persistListsCache(lists);
    return lists;
  }

  ///Espelho local da lista AniList (CURRENT/REPEATING/etc). Lê do cache pinta
  ///instantâneo na home; refresh async sobe a rede (menos requisição, simples).
  static List<AniListGroup> getCachedAnimeLists() {
    final raw = LocalStorage.getUserData('lists_cache');
    if (raw == null) return [];
    final listsJson = raw['lists'] as List? ?? [];
    return listsJson
        .map((l) => AniListGroup.fromJson(l as Map<String, dynamic>))
        .toList();
  }

  static void _persistListsCache(List<AniListGroup> lists) {
    LocalStorage.saveUserData('lists_cache', {
      'lists': lists
          .map((l) => {'name': l.name, 'entries': _entriesToJson(l.entries)})
          .toList(),
    });
  }

  static List<Map<String, dynamic>> _entriesToJson(List<AniListEntry> entries) {
    return entries.map((e) {
      return <String, dynamic>{
        'progress': e.progress,
        'status': e.status,
        'nextAiringEpisode': e.nextEpisode == null && e.timeUntilAiring == null
            ? null
            : {
                'episode': e.nextEpisode,
                'timeUntilAiring': e.timeUntilAiring,
              },
        'media': {
          'id': e.media.id,
          'title': {
            'romaji': e.media.title,
            'english': null,
            'native': null,
          },
          'coverImage': {
            'large': e.media.coverImage,
            'extraLarge': e.media.coverImageExtra,
          },
          'bannerImage': e.media.bannerImage,
          'episodes': e.media.episodes,
          'format': e.media.format,
          'status': e.media.status,
        },
      };
    }).toList();
  }

  ///Push best-effort: atualiza progresso do anime na lista AniList. Fire-and-
  ///forget; falha de rede/logado só mantém no local. Throttle por chamada.
  static Future<bool> updateProgress({
    required int mediaId,
    required int progress,
  }) async {
    final token = await getToken();
    if (token == null) return false;
    const query = '''mutation (\$mediaId: Int, \$progress: Int, \$status: MediaListStatus) {
      SaveMediaListEntry(mediaId: \$mediaId, progress: \$progress, status: \$status) {
        id
        progress
        status
      }
    }''';
    final res = await _graphQL(
      query,
      token,
      variables: {
        'mediaId': mediaId,
        'progress': progress,
        'status': 'CURRENT',
      },
    );
    return res != null;
  }

  static Future<List<AniListGroup>> _fetchAnimeList(String token) async {
    final user = await getUser();
    if (user == null) {
      debugPrint('[AniList] _fetchAnimeList: user cache null — aborting');
      return [];
    }
    debugPrint('[AniList] _fetchAnimeList userId=${user.id}');
    // ponytail: status_not: PLANNING removido — precisamos dos entries
    // PLANNING para a seção "Planejados" da home. Antes, o filtro excluído
    // também não justificava watching vir vazio (CURRENT/REPEATING não eram
    // filtrados), mas expõe maior superfície de teste.
    const query = '''query (\$userId: Int) {
      MediaListCollection(userId: \$userId, type: ANIME) {
        lists {
          name
          entries {
            progress
            status
            nextAiringEpisode { episode timeUntilAiring }
            media {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              bannerImage
              episodes
              format
              status
            }
          }
        }
      }
    }''';
    final res = await _graphQL(query, token, variables: {'userId': user.id});
    if (res == null) {
      debugPrint('[AniList] _fetchAnimeList: _graphQL returned null');
      return [];
    }
    final collection = res['MediaListCollection'] as Map?;
    if (collection == null) {
      debugPrint('[AniList] _fetchAnimeList: MediaListCollection null. res=$res');
      return [];
    }
    final lists = collection['lists'] as List? ?? [];
    debugPrint('[AniList] _fetchAnimeList: ${lists.length} groups');
    for (final l in lists) {
      final entries = (l as Map)['entries'] as List? ?? [];
      debugPrint('[AniList] group "${l['name']}" entries=${entries.length}');
    }
    return lists
        .map((l) => AniListGroup.fromJson(l as Map<String, dynamic>))
        .toList();
  }

  static Future<Map<String, dynamic>?> _graphQL(
    String query, String token, {
    Map<String, dynamic>? variables,
  }) async {
    try {
      final body = <String, dynamic>{'query': query};
      if (variables != null) body['variables'] = variables;
      final res = await http.post(
        Uri.parse(AppConstants.anilistApi),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      ).timeout(AppConstants.requestTimeout);
      if (res.statusCode != 200) {
        debugPrint('[AniList] GraphQL error ${res.statusCode}: ${res.body}');
        if (res.statusCode == 401 || res.statusCode == 400) {
          await logout();
        }
        return null;
      }
      final json = jsonDecode(res.body) as Map?;
      if (json == null || json['data'] == null) {
        debugPrint('[AniList] Invalid response: ${res.body}');
        return null;
      }
      return (json['data'] as Map).cast<String, dynamic>();
    } catch (e) {
      debugPrint('[AniList] GraphQL error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Catalog (discovery) — uses AniList's curated lists instead of scraping
  // hardcoded search queries. Opening a title resolves episodes by name across
  // the PT-BR providers.
  // ---------------------------------------------------------------------------

  static const String _catalogQuery = '''
    query (\$sort: [MediaSort], \$season: MediaSeason, \$seasonYear: Int, \$perPage: Int) {
      Page(page: 1, perPage: \$perPage) {
        media(type: ANIME, sort: \$sort, season: \$season, seasonYear: \$seasonYear, isAdult: false) {
          id
          title { romaji english native }
          coverImage { extraLarge large medium }
          bannerImage
          description
          episodes
          status
          averageScore
          genres
        }
      }
    }
  ''';

  /// Trending anime right now.
  static Future<List<Anime>> getTrending({int perPage = 30}) {
    return _catalog({'sort': ['TRENDING_DESC'], 'perPage': perPage});
  }

  /// Most popular anime of the current season.
  static Future<List<Anime>> getPopularThisSeason({int perPage = 30}) {
    final now = DateTime.now();
    return _catalog({
      'sort': ['POPULARITY_DESC'],
      'season': _seasonFor(now.month),
      'seasonYear': now.year,
      'perPage': perPage,
    });
  }

  /// All-time popular anime (fallback / additional row).
  static Future<List<Anime>> getPopular({int perPage = 30}) {
    return _catalog({'sort': ['POPULARITY_DESC'], 'perPage': perPage});
  }

  static String _seasonFor(int month) {
    if (month <= 3) return 'WINTER';
    if (month <= 6) return 'SPRING';
    if (month <= 9) return 'SUMMER';
    return 'FALL';
  }

  static Future<List<Anime>> _catalog(Map<String, dynamic> variables) async {
    final cacheKey = 'anilist_catalog:${jsonEncode(variables)}';
    final cached = AppCaches.search.get<List<Anime>>(cacheKey);
    if (cached != null) return cached;
    try {
      final res = await http
          .post(
            Uri.parse(AppConstants.anilistApi),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'query': _catalogQuery, 'variables': variables}),
          )
          .timeout(AppConstants.requestTimeout);
      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json.containsKey('errors')) {
        debugPrint('[AniList] Catalog error: ${json['errors']}');
        return [];
      }
      final media = json['data']?['Page']?['media'] as List? ?? [];
      final animes = media
          .map((m) => _mediaToAnime(m as Map<String, dynamic>))
          .where((a) => a.name.isNotEmpty)
          .toList();
      AppCaches.search.set<List<Anime>>(cacheKey, animes);
      return animes;
    } catch (e) {
      debugPrint('[AniList] Catalog fetch error: $e');
      return [];
    }
  }

  /// Converts an AniList media node into an [Anime]. The [url] is intentionally
  /// empty and the source is a placeholder: episodes are resolved by title
  /// across every provider when the user opens the detail screen.
  static Anime _mediaToAnime(Map<String, dynamic> m) {
    final title = m['title'] as Map? ?? {};
    final name = title['romaji']?.toString() ??
        title['english']?.toString() ??
        title['native']?.toString() ??
        '';
    final cover = AniListCoverImage.fromJson(
      (m['coverImage'] as Map?)?.cast<String, dynamic>() ?? {},
    );
    return Anime(
      name: name,
      englishName: title['english']?.toString(),
      url: '',
      source: AnimeSource.animeFire,
      anilistId: m['id'] as int?,
      fallbackImageUrl: cover.best,
      bannerImage: m['bannerImage']?.toString(),
      description: m['description']?.toString(),
      episodes: m['episodes'] as int?,
      status: m['status']?.toString(),
      averageScore: (m['averageScore'] as num?)?.toDouble(),
      genres:
          (m['genres'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }

  /// In-flight enrichment requests keyed by cleaned title, so the same anime
  /// appearing in multiple sources only triggers a single AniList call.
  static final Map<String, Future<AniListMediaDetail?>> _enrichInflight = {};

  /// Fetches (and caches) AniList metadata for [anime] and copies it onto the
  /// object. The result is cached per cleaned title, so re-entering the app or
  /// browsing the same title again is instant and network-free.
  static Future<void> enrich(Anime anime) async {
    final cleaned = TextUtils.cleanTitle(anime.name);
    if (cleaned.isEmpty) return;

    final cached =
        AppCaches.enrichment.get<AniListMediaDetail>(cleaned);
    if (cached != null) {
      _applyDetail(anime, cached);
      return;
    }

    final future = _enrichInflight.putIfAbsent(cleaned, () => _fetchDetail(cleaned));
    try {
      final media = await future;
      if (media != null) _applyDetail(anime, media);
    } finally {
      _enrichInflight.remove(cleaned);
    }
  }

  static void _applyDetail(Anime anime, AniListMediaDetail media) {
    anime.anilistId ??= media.id;
    anime.englishName ??= media.englishName;
    anime.bannerImage = media.bannerImage;
    anime.description = media.description;
    anime.episodes = media.episodes;
    anime.status = media.status;
    anime.averageScore = media.averageScore;
    anime.genres = media.genres;
    if (media.coverImage.best.isNotEmpty) {
      anime.fallbackImageUrl = media.coverImage.best;
    }
  }

  static Future<AniListMediaDetail?> _fetchDetail(String cleaned) async {
    try {
      const query = '''
        query (\$search: String) {
          Media(search: \$search, type: ANIME) {
            id
            idMal
            title { romaji english native }
            coverImage { extraLarge large medium }
            bannerImage
            description
            episodes
            status
            averageScore
            genres
          }
        }
      ''';
      final res = await http
          .post(
            Uri.parse(AppConstants.anilistApi),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'query': query,
              'variables': {'search': cleaned},
            }),
          )
          .timeout(AppConstants.requestTimeout);
      if (res.statusCode != 200) return null;
      final jsonResp = jsonDecode(res.body) as Map<String, dynamic>;
      if (jsonResp.containsKey('errors')) return null;
      final media = AniListGraphQLResponse.fromJson(jsonResp).data.media;
      AppCaches.enrichment.set<AniListMediaDetail>(cleaned, media);
      return media;
    } catch (e) {
      debugPrint('[AniList] Enrich error: $e');
      return null;
    }
  }
}
