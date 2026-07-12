import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/digests/sha256.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/anilist_models.dart';
import '../../data/models/anime.dart';
import '../cache/app_caches.dart';
import '../constants/app_constants.dart';
import '../utils/text_utils.dart';

class AniListService {
  static const _tokenKey = 'anilist_token';
  static const _userKey = 'anilist_user';

  /// PKCE code verifier stored during auth URL generation.
  static String? _codeVerifier;

  /// PKCE state parameter stored during auth URL generation.
  static String? _state;

  /// Generates a cryptographically random base64url string of [byteLength] bytes
  /// (no padding).
  static String _randomBase64Url(int byteLength) {
    final random = Random.secure();
    final bytes = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Computes SHA-256 digest of [input], returns unpadded base64url.
  static String _sha256Base64Url(String input) {
    final digest = SHA256Digest();
    final inputBytes = Uint8List.fromList(utf8.encode(input));
    final hash = Uint8List(digest.digestSize);
    digest.update(inputBytes, 0, inputBytes.length);
    digest.doFinal(hash, 0);
    return base64Url.encode(hash).replaceAll('=', '');
  }

  /// Generates a 128-byte PKCE code verifier.
  static String _generateCodeVerifier() => _randomBase64Url(128);

  /// Generates a 32-byte state parameter.
  static String _generateState() => _randomBase64Url(32);

  static String get authUrl {
    _codeVerifier = _generateCodeVerifier();
    final challenge = _sha256Base64Url(_codeVerifier!);
    _state = _generateState();
    return 'https://anilist.co/api/v2/oauth/authorize'
        '?client_id=${AppConstants.anilistClientId}'
        '&response_type=code'
        '&code_challenge=$challenge'
        '&code_challenge_method=S256'
        '&state=$_state';
  }

  /// The PKCE code verifier for the current auth session (used by pairing
  /// server and WebView flow).
  static String? get currentCodeVerifier => _codeVerifier;

  /// The PKCE state parameter for the current auth session.
  static String? get currentState => _state;

  /// Exchanges the authorization [code] for an access token using the PKCE
  /// [verifier]. Returns the access token on success, null on failure.
  static Future<String?> exchangeCodeForToken(
    String code,
    String verifier, {
    String? redirectUri,
  }) async {
    try {
      final body = {
        'grant_type': 'authorization_code',
        'client_id': AppConstants.anilistClientId,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirectUri ?? 'https://anilist.co/api/v2/oauth/callback',
      };
      final res = await http
          .post(
            Uri.parse(AppConstants.anilistTokenEndpoint),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: body,
          )
          .timeout(AppConstants.requestTimeout);
      if (res.statusCode != 200) {
        debugPrint('[AniList] Token exchange error ${res.statusCode}: ${res.body}');
        return null;
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final token = json['access_token'] as String?;
      if (token == null || !token.startsWith('eyJ')) return null;
      final saved = await saveToken(token);
      return saved ? token : null;
    } catch (e) {
      debugPrint('[AniList] Token exchange error: $e');
      return null;
    }
  }

  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_tokenKey);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<bool> saveToken(String token) async {
    if (!token.startsWith('eyJ')) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    final user = await _fetchUser(token);
    if (user != null) {
      await prefs.setString(_userKey, jsonEncode({
        'id': user.id,
        'name': user.name,
        'avatar': user.avatar,
      }));
      return true;
    }
    await prefs.remove(_tokenKey);
    return false;
  }

  static Future<AniListUser?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_userKey);
    if (data == null) return null;
    try {
      return AniListUser.fromJson(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
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
    return _fetchAnimeList(token);
  }

  static Future<List<AniListGroup>> _fetchAnimeList(String token) async {
    final user = await getUser();
    if (user == null) return [];
    const query = '''query (\$userId: Int) {
      MediaListCollection(userId: \$userId, type: ANIME, status_not: PLANNING) {
        lists {
          name
          entries {
            media {
              id
              title { romaji english native }
              coverImage { large }
              episodes
              format
            }
          }
        }
      }
    }''';
    final res = await _graphQL(query, token, variables: {'userId': user.id});
    if (res == null) return [];
    final collection = res['MediaListCollection'] as Map?;
    if (collection == null) return [];
    final lists = collection['lists'] as List? ?? [];
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
      url: '',
      source: AnimeSource.animeFire,
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
