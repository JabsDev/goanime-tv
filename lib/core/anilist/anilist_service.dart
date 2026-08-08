import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/anilist_models.dart';
import 'anilist_auth_service.dart';
import '../../data/models/anime.dart';
import '../cache/app_caches.dart';
import '../constants/app_constants.dart';
import '../profile/profile_service.dart';
import '../utils/text_utils.dart';

/// Categorized AniList connectivity status. Drives the Home banner: instead of
/// a single generic error, the UI tells the user whether we're offline, being
/// rate-limited, IP-blocked by Cloudflare, session-expired or facing a 5xx.
enum AniListStatus { ok, offline, ipBlocked, rateLimited, authError, serverError }

/// Ponytail: Manages AniList API requests and authentication state.
class AniListService {
  /// Last categorized AniList failure — a side effect of the existing calls,
  /// not a health monitor. Reset to [AniListStatus.ok] on any success.
  static AniListStatus lastErrorStatus = AniListStatus.ok;

  /// Test hook: swaps the raw `http.post` calls (which the service makes
  /// directly, bypassing [apiClient]) with a mock client.
  static http.Client? httpOverride;

  // ponytail: pacing global único para graphql.anilist.co — uma única fonte de
  // verdade para que um enrich em lote (busca) não derrube o updateProgress/
  // login com rate-limit (bug idêntico ao descrito no relatório AnimeCaos).
  // Global; per-account/per-type queues se throughput importar.
  static DateTime _lastGraphqlAt = DateTime.fromMillisecondsSinceEpoch(0);
  static Duration anilistRequestGap = const Duration(milliseconds: 800);

  /// Serializes AniList requests (min gap) — mirrors the AnimeFire `_throttle`.
  static Future<void> _gateAnilist() async {
    final now = DateTime.now();
    final since = now.difference(_lastGraphqlAt);
    if (since < anilistRequestGap) {
      await Future.delayed(anilistRequestGap - since);
    }
    _lastGraphqlAt = DateTime.now();
  }

  static Future<http.Response> _anilistPost(
    String query, {
    String? token,
    Map<String, dynamic>? variables,
  }) async {
    await _gateAnilist();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final body = <String, dynamic>{
      'query': query,
      if (variables != null) 'variables': variables,
    };
    final client = httpOverride;
    if (client != null) {
      return client.post(
        Uri.parse(AppConstants.anilistApi),
        headers: headers,
        body: jsonEncode(body),
      );
    }
    return http
        .post(
          Uri.parse(AppConstants.anilistApi),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(AppConstants.requestTimeout);
  }

  /// Maps a failure to a categorized [AniListStatus]. `body` carries the
  /// Cloudflare challenge signature ("1020") for IP blocks.
  static void _classifyFailure(Object e, int? statusCode, String body) {
    if (statusCode == 429) {
      lastErrorStatus = AniListStatus.rateLimited;
      return;
    }
    if (statusCode == 403 || body.contains('1020')) {
      lastErrorStatus = AniListStatus.ipBlocked;
      return;
    }
    if (statusCode == 401 || statusCode == 400) {
      lastErrorStatus = AniListStatus.authError;
      return;
    }
    if (statusCode != null && statusCode >= 500) {
      lastErrorStatus = AniListStatus.serverError;
      return;
    }
    if (e is TimeoutException || e is SocketException || e is http.ClientException) {
      lastErrorStatus = AniListStatus.offline;
      return;
    }
    lastErrorStatus = AniListStatus.serverError;
  }

  /// Fetches distinct AniList title variants (romaji/english/native) for a
  /// query, used as new search queries when the original fan-out is empty.
  /// Cached in [AppCaches.enrichment]; no new anilistId is stored.
  static Future<List<String>> getTitleVariants(String query) async {
    final cleaned = TextUtils.cleanTitle(query);
    if (cleaned.isEmpty) return [];
    final cacheKey = 'variants:$cleaned';
    final cached = AppCaches.enrichment.get<List<String>>(cacheKey);
    if (cached != null) return cached;

    // Reuse the enrichment detail already fetched for this title when present.
    final detail = AppCaches.enrichment.get<AniListMediaDetail>(cleaned);
    if (detail != null) {
      final titles = _titlesOf(detail, cleaned);
      AppCaches.enrichment.set(cacheKey, titles);
      return titles;
    }

    try {
      const q = '''
        query (\$search: String) {
          Media(search: \$search, type: ANIME) {
            id
            title { romaji english native }
          }
        }
      ''';
      final res = await _anilistPost(q, variables: {'search': cleaned});
      if (res.statusCode != 200) {
        _classifyFailure(TimeoutException(''), res.statusCode, res.body);
        return [];
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final media = json['data']?['Media'] as Map<String, dynamic>?;
      if (media == null) return [];
      final title = (media['title'] as Map?)?.cast<String, dynamic>() ?? {};
      final titles = <String>{};
      for (final k in ['romaji', 'english', 'native']) {
        final t = title[k]?.toString();
        if (t != null && t.isNotEmpty) titles.add(t);
      }
      titles.remove(cleaned);
      lastErrorStatus = AniListStatus.ok;
      final result = titles.toList();
      AppCaches.enrichment.set(cacheKey, result);
      return result;
    } catch (e) {
      debugPrint('[AniList] getTitleVariants error: $e');
      _classifyFailure(e, null, '');
      return [];
    }
  }

  static List<String> _titlesOf(AniListMediaDetail detail, String cleaned) {
    final titles = <String>{
      if (detail.englishName != null && detail.englishName!.isNotEmpty)
        detail.englishName!,
    };
    titles.remove(cleaned);
    return titles.toList();
  }

  /// Runs [enrich] over [animes] with a pool of 6 in-flight GraphQL calls
  /// (micro-semáforo, sem dependência nova). A busca que enriquece ~50 cards
  /// não dispara mais a rajada paralela que derrubava o rate-limit.
  static Future<void> enrichBatch(List<Anime> animes) async {
    const pool = 6;
    var i = 0;
    final workers = List.generate(pool, (_) async {
      while (i < animes.length) {
        final anime = animes[i];
        i++;
        try {
          await enrich(anime);
        } catch (e) {
          debugPrint('[AniList] enrich error: $e');
        }
      }
    });
    await Future.wait(workers);
  }

  static String _currentState = '';

  static String get currentState {
    return _currentState;
  }

  /// Authorize URL generic use (QR/scan): Implicit Grant — no PKCE, because
  /// AniList rejects code/verifier exchanges with `401 invalid_client`. The
  /// access token comes back in the redirect URI fragment.
  /// Authorize URL generic use (QR/scan): Implicit Grant — no PKCE, because
  /// AniList rejects code/verifier exchanges with `401 invalid_client`. The
  /// access token comes back in the redirect URI fragment.
  /// ponytail: NÃO passamos `redirect_uri` — a doc do AniList exige apenas
  /// `client_id` + `response_type=token`; passar um redirect não-registrado
  /// faz o authorize retornar `unsupported_grant_type` (ver
  /// https://docs.anilist.co/guide/auth/implicit). O redirect final (pin)
  /// é interceptado no WebView.
  static String get authUrl {
    return 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=${AppConstants.anilistClientId}'
        '&response_type=token'
        '&state=${_generateState()}';
  }

  /// Extrai o `access_token` da URL canônica do pin do AniList (Implicit Grant).
  /// O token vem no fragment (`#...access_token=...`), que nunca é enviado ao
  /// servidor. Opera sobre a string crua porque algumas builds de `webview`
  /// colapsam o fragment dentro do path — parsear com `Uri.parse` perderia o
  /// `#`. Retorna `null` se não houver token.
  static String? extractAccessToken(String rawUrl) {
    final hashIndex = rawUrl.indexOf('#');
    if (hashIndex < 0) return null;
    final hash = rawUrl.substring(hashIndex + 1);
    if (hash.isEmpty) return null;
    final params = Uri.splitQueryString(hash);
    final token = params['access_token']?.trim();
    if (token == null || token.isEmpty) return null;
    return Uri.decodeComponent(token);
  }

  /// Validação pré-sintática barata: todo JWT começa com `eyJ` e tem ao menos
  /// 3 segmentos (`header.payload.signature`). A validação forte (rede) vive em
  /// [saveToken], que exige um Viewer real antes de persistir.
  static bool isJwtToken(String token) {
    if (!token.startsWith('eyJ')) return false;
    return token.split('.').length >= 3;
  }

  /// `true` se a URL é o redirect final do pin (`/api/v2/oauth/pin`) que devolve
  /// o token. É a origem que interceptamos no WebView antes de renderizar.
  static bool isPinCallback(Uri uri) {
    return uri.host == 'anilist.co' && uri.path.startsWith('/api/v2/oauth/pin');
  }

  /// `true` para qualquer redirect do AniList que devolva o token (fragment com
  /// `access_token`). O redirect registrado no painel pode não ser exatamente o
  /// `/oauth/pin` — interceptor trata qualquer URL de `anilist.co` que carregue
  /// o token, mantendo o allowlist de host (Fase 3/9).
  static bool isOAuthCallback(String rawUrl) {
    final uri = Uri.parse(rawUrl);
    if (uri.host != 'anilist.co') return false;
    return isPinCallback(uri) || extractAccessToken(rawUrl) != null;
  }

  static Future<bool> isLoggedIn() async {
    return (await getToken()) != null;
  }

  /// Token do perfil ativo — fonte única de verdade. Nunca lê o cache global
  /// para decisão de auth (isso era a origem do bug de token vazando entre os
  /// perfis). O cache global só serve de espelho (ver Fase 5/9).
  static Future<String?> getToken() async {
    final profileToken = ProfileService.instance.currentProfile?.anilistToken;
    if (profileToken != null && profileToken.isNotEmpty) return profileToken;
    return null;
  }

  /// Porta de entrada ÚNICA do token no app. Valida de fato via Viewer
  /// (`_fetchUser`); só persiste se o usuário responder. A fonte de verdade é o
  /// perfil ativo (`ProfileService`); o cache global fica como leitura rápida.
  static Future<bool> saveToken(String token) async {
    if (!isJwtToken(token)) return false;
    final user = await _fetchUser(token);
    if (user == null) return false;
    final ps = ProfileService.instance;
    if (ps.currentProfile != null) {
      ps.updateCurrentProfileAnilist(
        token: token,
        userId: user.id,
        userName: user.name,
        avatar: user.avatar,
      );
    } else {
      // Fresh install sem perfil: cria e ativa um perfil AniList para a fonte
      // de verdade não ficar vazia (caso do banner da Home).
      final profile = await ps.createAnilistProfile(token, user);
      await ps.switchProfile(profile.id);
    }
    await AnilistAuthService.saveToken(token);
    await AnilistAuthService.saveUserData('user', {
      'id': user.id,
      'name': user.name,
      'avatar': user.avatar,
    });
    return true;
  }

  static String _generateState() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<AniListUser?> getUser() async {
    // Fonte de verdade: dados do perfil ativo.
    final profile = ProfileService.instance.currentProfile;
    if (profile?.anilistToken != null &&
        profile!.anilistUserId != null &&
        profile.anilistUserName != null) {
      return AniListUser(
        id: profile.anilistUserId!,
        name: profile.anilistUserName!,
        avatar: profile.anilistAvatar,
      );
    }
    final data = await AnilistAuthService.getUserData('user');
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
    await AnilistAuthService.saveUserData('user', {
      'id': user.id,
      'name': user.name,
      'avatar': user.avatar,
    });
    return user;
  }

  static Future<void> logout() async {
    await AnilistAuthService.removeToken();
    // Limpa também os dados AniList do perfil ativo (fonte de verdade).
    ProfileService.instance.updateCurrentProfileAnilist(clear: true);
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

  static Future<AniListEntry?> getMediaListEntry(int mediaId) async {
    final lists = await getUserAnimeList();
    for (var list in lists) {
      for (var entry in list.entries) {
        if (entry.media.id == mediaId) {
          return entry;
        }
      }
    }
    return null;
  }

  ///Espelho local da lista AniList (CURRENT/REPEATING/etc). Lê do cache pinta
  ///instantâneo na home; refresh async sobe a rede (menos requisição, simples).
  static Future<List<AniListGroup>> getCachedAnimeLists() async {
    final raw = await AnilistAuthService.getUserData('lists_cache');
    if (raw == null) return [];
    final listsJson = raw['lists'] as List? ?? [];
    return listsJson
        .map((l) => AniListGroup.fromJson(l as Map<String, dynamic>))
        .toList();
  }

  static Future<int?> getCachedProgress(int mediaId) async {
    final lists = await getCachedAnimeLists();
    for (var list in lists) {
      for (var entry in list.entries) {
        if (entry.media.id == mediaId) {
          return entry.progress ?? 0;
        }
      }
    }
    return null;
  }

  static void _persistListsCache(List<AniListGroup> lists) {
    AnilistAuthService.saveUserData('lists_cache', {
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
        // ponytail: o parser AniListEntry.fromJson lê nextAiringEpisode de
        // media (schema real). Espelhar aqui no mesmo lugar, senão o cache de
        // listas perde o countdown na volta (round-trip quebra a exibição).
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
          if (e.nextEpisode != null || e.timeUntilAiring != null)
            'nextAiringEpisode': {
              'episode': e.nextEpisode,
              'timeUntilAiring': e.timeUntilAiring,
            },
        },
      };
    }).toList();
  }

  ///Push best-effort: atualiza progresso do anime na lista AniList. Fire-and-
  ///forget; falha de rede/logado só mantém no local. Throttle por chamada.
  static Future<bool> updateProgress({
    required int mediaId,
    required int progress,
    String? status,
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
        'status': status ?? 'CURRENT',
      },
    );
    return res != null;
  }

  // ponytail: nextAiringEpisode pertence a Media.media no schema AniList, não
  // ao entry (MediaList). Mover para cá corrige o HTTP 400 que zerou as listas
  // (regressão b81de7e). Const exposta como única fonte: o teste de regressão
  // (T1) e o script de contrato validam exatamente esta string.
  @visibleForTesting
  static const listQuery = '''query (\$userId: Int) {
  MediaListCollection(userId: \$userId, type: ANIME) {
    lists {
      name
      entries {
        progress
        status
        media {
           id
           title { romaji english native }
           coverImage { large extraLarge }
           bannerImage
           episodes
           format
           status
           nextAiringEpisode { episode timeUntilAiring }
         }
      }
    }
  }
}''';

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
    final res = await _graphQL(listQuery, token, variables: {'userId': user.id});
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
      final res = await _anilistPost(query, token: token, variables: variables);
      if (res.statusCode != 200) {
        debugPrint('[AniList] GraphQL error ${res.statusCode}: ${res.body}');
        _classifyFailure(TimeoutException(''), res.statusCode, res.body);
        if (res.statusCode == 401 || res.statusCode == 400) {
          await logout();
        }
        return null;
      }
      final json = jsonDecode(res.body) as Map?;
      if (json == null || json['data'] == null) {
        debugPrint('[AniList] Invalid response: ${res.body}');
        lastErrorStatus = AniListStatus.serverError;
        return null;
      }
      lastErrorStatus = AniListStatus.ok;
      return (json['data'] as Map).cast<String, dynamic>();
    } catch (e) {
      debugPrint('[AniList] GraphQL error: $e');
      _classifyFailure(e, null, '');
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

    final diskKey = 'catalog_${jsonEncode(variables)}';
    try {
      final res = await _anilistPost(_catalogQuery, variables: variables);
      if (res.statusCode != 200) {
        debugPrint('[AniList] Catalog error ${res.statusCode}: ${res.body}');
        _classifyFailure(TimeoutException(''), res.statusCode, res.body);
        final disk = await _readCatalogDisk(diskKey);
        if (disk != null) return disk;
        return [];
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json.containsKey('errors')) {
        debugPrint('[AniList] Catalog error: ${json['errors']}');
        lastErrorStatus = AniListStatus.serverError;
        final disk = await _readCatalogDisk(diskKey);
        if (disk != null) return disk;
        return [];
      }
      lastErrorStatus = AniListStatus.ok;
      final media = json['data']?['Page']?['media'] as List? ?? [];
      final animes = media
          .map((m) => _mediaToAnime(m as Map<String, dynamic>))
          .where((a) => a.name.isNotEmpty)
          .toList();
      AppCaches.search.set<List<Anime>>(cacheKey, animes);
      await _writeCatalogDisk(diskKey, animes);
      return animes;
    } catch (e) {
      debugPrint('[AniList] Catalog fetch error: $e');
      _classifyFailure(e, null, '');
      final disk = await _readCatalogDisk(diskKey);
      if (disk != null) return disk;
      return [];
    }
  }

  /// Catalog disk cache (sem expiração) — a Home abre instantânea na primeira
  /// carga do dia e segue servindo na falha de rede. O refresh é o próprio
  /// fluxo normal (sempre tenta a rede primeiro; disco é fallback).
  static Future<List<Anime>?> _readCatalogDisk(String diskKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(diskKey);
      if (raw == null) return null;
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => _animeFromJson(e as Map<String, dynamic>))
          .where((a) => a.name.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[AniList] Catalog disk read error: $e');
      return null;
    }
  }

  static Future<void> _writeCatalogDisk(String diskKey, List<Anime> animes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        diskKey,
        jsonEncode(animes.map(_animeToJson).toList()),
      );
    } catch (e) {
      debugPrint('[AniList] Catalog disk write error: $e');
    }
  }

  static Map<String, dynamic> _animeToJson(Anime a) => {
        'name': a.name,
        'englishName': a.englishName,
        'anilistId': a.anilistId,
        'fallbackImageUrl': a.fallbackImageUrl,
        'bannerImage': a.bannerImage,
        'description': a.description,
        'episodes': a.episodes,
        'status': a.status,
        'averageScore': a.averageScore,
        'genres': a.genres,
      };

  static Anime _animeFromJson(Map<String, dynamic> m) => Anime(
        name: m['name']?.toString() ?? '',
        englishName: m['englishName']?.toString(),
        url: '',
        source: AnimeSource.animeFire,
        anilistId: m['anilistId'] as int?,
        fallbackImageUrl: m['fallbackImageUrl']?.toString(),
        bannerImage: m['bannerImage']?.toString(),
        description: m['description']?.toString(),
        episodes: m['episodes'] as int?,
        status: m['status']?.toString(),
        averageScore: (m['averageScore'] as num?)?.toDouble(),
        genres: (m['genres'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );

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
    if (anime.episodes == null && media.nextAiringEpisodeNumber != null) {
      anime.episodes = media.nextAiringEpisodeNumber! - 1;
    }
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
            nextAiringEpisode { episode timeUntilAiring }
          }
        }
      ''';
      final res = await _anilistPost(query, variables: {'search': cleaned});
      if (res.statusCode != 200) {
        _classifyFailure(TimeoutException(''), res.statusCode, res.body);
        return null;
      }
      final jsonResp = jsonDecode(res.body) as Map<String, dynamic>;
      if (jsonResp.containsKey('errors')) {
        lastErrorStatus = AniListStatus.serverError;
        return null;
      }
      lastErrorStatus = AniListStatus.ok;
      final media = AniListGraphQLResponse.fromJson(jsonResp).data.media;
      AppCaches.enrichment.set<AniListMediaDetail>(cleaned, media);
      return media;
    } catch (e) {
      debugPrint('[AniList] Enrich error: $e');
      _classifyFailure(e, null, '');
      return null;
    }
  }

  /// Fetches detailed episode information from AniList for a specific media.
  /// Returns a list of AniListEpisode objects, each containing episode number,
  /// title, description, and thumbnail if available.
  static Future<List<AniListEpisode>> getEpisodesV2(int mediaId) async {
    final token = await getToken();
    if (token == null) return [];

    const query = '''
      query (\$mediaId: Int) {
        Media(id: \$mediaId) {
          id
          episodesV2 {
            episodeNumber
            title
            description
            thumbnail
          }
        }
      }
    ''';

    try {
      final res = await _anilistPost(
        query,
        variables: {'mediaId': mediaId},
      );

      if (res.statusCode != 200) {
        debugPrint('[AniList] getEpisodesV2 error ${res.statusCode}');
        _classifyFailure(TimeoutException(''), res.statusCode, res.body);
        return [];
      }

      lastErrorStatus = AniListStatus.ok;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>?;
      final media = data?['Media'] as Map<String, dynamic>?;
      final episodesV2 = media?['episodesV2'] as List?;

      if (episodesV2 == null) return [];

      return episodesV2
          .map((ep) => AniListEpisode.fromMap(ep as Map<String, dynamic>))
          .toList();
    } catch (e, stackTrace) {
      debugPrint('[AniList] getEpisodesV2 error: $e\n$stackTrace');
      _classifyFailure(e, null, '');
      return [];
    }
  }
}
