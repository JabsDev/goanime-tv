import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart';
import 'package:flutter/foundation.dart';
import '../../data/models/anime.dart';
import '../../data/models/episode.dart';
import '../constants/app_constants.dart';
import '../network/api_client.dart';
import 'anime_source_adapter.dart';

/// AllAnime provider: GraphQL API for search, episode listing and stream URLs.
class AllAnimeAdapter implements AnimeSourceAdapter {
  const AllAnimeAdapter();

  static const String _persistedQueryHash =
      'd405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec';
  static const String _keyPhrase = 'Xot36i3lK3:v1';
  static const String _origin = 'https://youtu-chan.com';

  @override
  AnimeSource get source => AnimeSource.allAnime;

  @override
  Future<List<Anime>> search(String animeName) async {
    try {
      const gql = '''
        query(\$search: SearchInput, \$limit: Int, \$page: Int, \$translationType: VaildTranslationTypeEnumType, \$countryOrigin: VaildCountryOriginEnumType) {
          shows(search: \$search, limit: \$limit, page: \$page, translationType: \$translationType, countryOrigin: \$countryOrigin) {
            edges {
              _id
              name
              englishName
              availableEpisodes
              thumbnail
            }
          }
        }
      ''';
      final vars = {
        'search': {
          'allowAdult': false,
          'allowUnknown': false,
          'query': animeName
        },
        'limit': 40,
        'page': 1,
        'translationType': 'sub',
        'countryOrigin': 'ALL',
      };
      final res = await apiClient.postJson(
        Uri.parse(AppConstants.allAnimeAPI),
        json: {
          'query': gql,
          'variables': vars,
        },
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': AppConstants.allAnimeReferer,
        },
      );
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body);
      final edges = data['data']?['shows']?['edges'] as List? ?? [];

      final byId = <String, Map>{};
      for (final e in edges) {
        final show = e as Map;
        final id = show['_id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final hasEnglish = show['englishName']?.toString().isNotEmpty == true;
        if (byId.containsKey(id)) {
          final existing = byId[id]!;
          final existingHasEnglish =
              existing['englishName']?.toString().isNotEmpty == true;
          if (existingHasEnglish && !hasEnglish) {
            byId[id] = show;
          }
        } else {
          byId[id] = show;
        }
      }

      int epCount(Map show) {
        final ae = show['availableEpisodes'];
        if (ae is Map) {
          final sub = ae['sub'];
          if (sub is num) return sub.toInt();
        } else if (ae is num) {
          return ae.toInt();
        }
        return 0;
      }

      // Sort by sub episode count descending so the main series (most episodes)
      // ranks above spin-offs/specials (mirrors GoAnime).
      final shows = byId.values.toList()
        ..sort((a, b) => epCount(b).compareTo(epCount(a)));

      return shows.map((show) {
        final name = show['name']?.toString() ??
            show['englishName']?.toString() ??
            '';
        final id = show['_id']?.toString() ?? '';
        if (name.isEmpty || id.isEmpty) return null;
        return Anime(
          name: name,
          url: id,
          source: AnimeSource.allAnime,
          allAnimeId: id,
          fallbackImageUrl: show['thumbnail']?.toString(),
        );
      }).whereType<Anime>().toList();
    } catch (e) {
      debugPrint('[AllAnime] Search error: $e');
      return [];
    }
  }

  @override
  Future<EpisodesResult> getEpisodes(Anime anime) async {
    final animeId = anime.allAnimeId ?? anime.url;
    const gql = '''
      query (\$showId: String!) {
        show(_id: \$showId) {
          _id
          thumbnail
          availableEpisodesDetail
        }
      }
    ''';
    final vars = {'showId': animeId};
    try {
      final res = await apiClient.postJson(
        Uri.parse(AppConstants.allAnimeAPI),
        json: {
          'query': gql,
          'variables': vars,
        },
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': AppConstants.allAnimeReferer,
        },
      );
      if (res.statusCode != 200) return EpisodesResult([], {});
      final data = jsonDecode(res.body);
      final detail = data['data']?['show']?['availableEpisodesDetail'];
      if (detail == null) return EpisodesResult([], {});

      final episodeTypes = <String, List<Episode>>{};
      for (final type in ['sub', 'dub', 'raw']) {
        final list = (detail[type] as List?)?.cast<String>();
        if (list != null && list.isNotEmpty) {
          final sorted = List<String>.from(list);
          sorted.sort((a, b) => (double.tryParse(a) ?? 0).compareTo(double.tryParse(b) ?? 0));
          episodeTypes[type] = sorted
              .map((e) => Episode(
                    number: e,
                    url: e,
                    thumbnail: anime.imageUrl,
                  ))
              .toList();
        }
      }

      if (episodeTypes.isEmpty) return EpisodesResult([], {});
      if (episodeTypes.length == 1) {
        return EpisodesResult(episodeTypes.values.first, episodeTypes);
      }
      return EpisodesResult([], episodeTypes);
    } catch (e) {
      debugPrint('[AllAnime] Episodes error: $e');
      return EpisodesResult([], {});
    }
  }

  @override
  Future<List<VideoSource>> getVideoSources(
    Episode episode, {
    Anime? anime,
  }) async {
    final animeId = anime?.allAnimeId ?? anime?.url ?? '';
    return _extractFromAllAnime(animeId, episode.url);
  }

  Future<List<VideoSource>> _extractFromAllAnime(
    String animeId,
    String episodeNumber,
  ) async {
    if (animeId.isEmpty || episodeNumber.isEmpty) return [];
    try {
      final varsMap = {
        'showId': animeId,
        'translationType': 'sub',
        'episodeString': episodeNumber,
      };

      String? body = await _tryPersistedQueryGET(varsMap);
      if (body == null ||
          (!body.contains('sourceUrl') && !body.contains('tobeparsed'))) {
        body = await _legacyPOST(varsMap);
      }
      if (body == null || body.isEmpty) return [];
      if (body.contains('AA_CRYPTO_MISSING') || body.contains('NEED_CAPTCHA')) {
        debugPrint('[AllAnime] API is Cloudflare/captcha gated — skipping');
        return [];
      }

      final entries = _extractSourceEntries(body);
      if (entries.isEmpty) return [];

      final results = await Future.wait(
        entries.map((e) => _resolveAllAnimeLinks(e)),
      );
      final sources = <VideoSource>[];
      final seen = <String>{};
      for (final list in results) {
        for (final s in list) {
          if (seen.add(s.url)) sources.add(s);
        }
      }
      return sources;
    } catch (e) {
      debugPrint('[AllAnime] Extract error: $e');
      return [];
    }
  }

  Future<String?> _tryPersistedQueryGET(Map<String, String> varsMap) async {
    try {
      final varsBytes = jsonEncode(varsMap);
      final extBytes = jsonEncode({
        'persistedQuery': {
          'version': 1,
          'sha256Hash': _persistedQueryHash,
        }
      });
      final getUrl = '${AppConstants.allAnimeAPI}'
          '?variables=${Uri.encodeQueryComponent(varsBytes)}'
          '&extensions=${Uri.encodeQueryComponent(extBytes)}';
      final res = await apiClient
          .get(
            Uri.parse(getUrl),
            headers: {
              'User-Agent': AppConstants.userAgent,
              'Referer': AppConstants.allAnimeReferer,
              'Origin': _origin,
            },
          )
          .timeout(AppConstants.requestTimeout);
      if (res.statusCode != 200) return null;
      return res.body;
    } catch (e) {
      debugPrint('[AllAnime] GET path failed: $e');
      return null;
    }
  }

  Future<String?> _legacyPOST(Map<String, String> varsMap) async {
    try {
      const gql = '''
        query (\$showId: String!, \$translationType: VaildTranslationTypeEnumType!, \$episodeString: String!) {
          episode(showId: \$showId, translationType: \$translationType, episodeString: \$episodeString) {
            episodeString
            sourceUrls
          }
        }
      ''';
      final res = await apiClient.postJson(
        Uri.parse(AppConstants.allAnimeAPI),
        json: {
          'query': gql,
          'variables': varsMap,
        },
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': AppConstants.allAnimeReferer,
        },
      );
      if (res.statusCode != 200) return null;
      return res.body;
    } catch (e) {
      debugPrint('[AllAnime] POST path failed: $e');
      return null;
    }
  }

  List<String> _extractSourceEntries(String response) {
    final sources = <String>[];
    if (response.contains('"tobeparsed"')) {
      final blob = _extractToBeParsedBlob(response);
      if (blob != null) {
        final decoded = _decodeToBeParsed(blob);
        if (decoded != null) {
          for (final url in decoded) {
            sources.add(_decodeSourceURL(url));
          }
          return sources;
        }
      }
    }

    try {
      final data = jsonDecode(response) as Map;
      final urls = data['data']?['episode']?['sourceUrls'] as List?;
      if (urls != null && urls.isNotEmpty) {
        for (final u in urls) {
          final raw = u['sourceUrl']?.toString() ?? '';
          if (raw.isEmpty) continue;
          sources.add(_decodeSourceURL(
            raw.startsWith('--') ? raw.substring(2) : raw,
          ));
        }
        return sources;
      }
    } catch (_) {}

    final re = RegExp(r'"sourceUrl"\s*:\s*"--([^"]*)"');
    for (final m in re.allMatches(response)) {
      sources.add(_decodeSourceURL(m.group(1)!));
    }
    return sources;
  }

  String? _extractToBeParsedBlob(String response) {
    final m = RegExp(r'"tobeparsed"\s*:\s*"([^"]*)"').firstMatch(response);
    return m?.group(1);
  }

  /// Decrypts the AES-256-CTR `tobeparsed` blob and returns the source URLs.
  List<String>? _decodeToBeParsed(String blob) {
    try {
      Uint8List? data;
      try {
        data = base64.decode(blob);
      } on Exception {
        data = base64Url.decode(blob);
      }
      if (data == null || data.length < 30) return null;

      final nonce = data.sublist(1, 13);
      final ciphertext = data.sublist(13, data.length - 16);

      final keyBytes = SHA256Digest().process(utf8.encode(_keyPhrase));
      final iv = Uint8List(16);
      iv.setRange(0, 12, nonce);
      iv[15] = 0x02;

      final encrypter = enc.Encrypter(
        enc.AES(enc.Key(keyBytes), mode: enc.AESMode.ctr),
      );
      final plaintext = encrypter.decryptBytes(
        enc.Encrypted(ciphertext),
        iv: enc.IV(iv),
      );
      final decoded = utf8.decode(plaintext);

      final result = <String>[];
      try {
        final json = jsonDecode(decoded) as Map;
        final urls = json['data']?['episode']?['sourceUrls'] as List?;
        if (urls != null) {
          for (final u in urls) {
            final raw = u['sourceUrl']?.toString() ?? '';
            if (raw.isNotEmpty) result.add(raw.startsWith('--') ? raw.substring(2) : raw);
          }
          return result;
        }
      } catch (_) {}

      final re = RegExp(r'"sourceUrl"\s*:\s*"--([^"]*)"');
      for (final m in re.allMatches(decoded)) {
        result.add(m.group(1)!);
      }
      return result.isNotEmpty ? result : null;
    } catch (e) {
      debugPrint('[AllAnime] tobeparsed decode error: $e');
      return null;
    }
  }

  String _decodeSourceURL(String encoded) {
    final buffer = StringBuffer();
    for (var i = 0; i + 1 < encoded.length; i += 2) {
      final pair = encoded.substring(i, i + 2);
      buffer.write(_hexSubstitute(pair));
    }
    var result = buffer.toString();
    result = result.replaceAll('/clock', '/clock.json');
    if (result.startsWith('/')) {
      result = 'https://${AppConstants.allAnimeBase}$result';
    }
    return result;
  }

  static String _hexSubstitute(String hex) {
    const map = {
      '79': 'A', '7a': 'B', '7b': 'C', '7c': 'D', '7d': 'E', '7e': 'F', '7f': 'G',
      '70': 'H', '71': 'I', '72': 'J', '73': 'K', '74': 'L', '75': 'M', '76': 'N', '77': 'O',
      '68': 'P', '69': 'Q', '6a': 'R', '6b': 'S', '6c': 'T', '6d': 'U', '6e': 'V', '6f': 'W',
      '60': 'X', '61': 'Y', '62': 'Z',
      '59': 'a', '5a': 'b', '5b': 'c', '5c': 'd', '5d': 'e', '5e': 'f', '5f': 'g',
      '50': 'h', '51': 'i', '52': 'j', '53': 'k', '54': 'l', '55': 'm', '56': 'n', '57': 'o',
      '48': 'p', '49': 'q', '4a': 'r', '4b': 's', '4c': 't', '4d': 'u', '4e': 'v', '4f': 'w',
      '40': 'x', '41': 'y', '42': 'z',
      '08': '0', '09': '1', '0a': '2', '0b': '3', '0c': '4', '0d': '5', '0e': '6', '0f': '7',
      '00': '8', '01': '9',
      '15': '-', '16': '.', '67': '_', '46': '~',
      '02': ':', '17': '/', '07': '?', '1b': '#',
      '63': '[', '65': ']', '78': '@',
      '19': '!', '1c': '\$', '1e': '&',
      '10': '(', '11': ')', '12': '*', '13': '+', '14': ',',
      '03': ';', '05': '=', '1d': '%',
    };
    return map[hex] ?? hex;
  }

  /// Fetches a single AllAnime source URL and parses every available quality.
  Future<List<VideoSource>> _resolveAllAnimeLinks(String sourceUrl) async {
    try {
      final res = await apiClient.get(
        Uri.parse(sourceUrl),
        headers: {
          'User-Agent': AppConstants.userAgent,
          'Referer': AppConstants.allAnimeReferer,
        },
      );
      if (res.statusCode != 200) return [];
      final body = res.body;
      final links = <VideoSource>[];
      final seen = <String>{};

      void add(String url, String quality) {
        if (url.isEmpty || !seen.add(url)) return;
        links.add(VideoSource(
          url: url,
          quality: quality,
          headers: {
            'User-Agent': AppConstants.userAgent,
            'Referer': AppConstants.allAnimeReferer,
          },
        ));
      }

      try {
        final json = jsonDecode(body) as Map;
        final list = json['links'] as List?;
        if (list != null && list.isNotEmpty) {
          for (final l in list) {
            final link = (l['link']?.toString() ?? '').replaceAll('\\', '');
            String quality = l['resolutionStr']?.toString() ?? 'Auto';
            if (quality.isEmpty) {
              quality = (l['hls'] == true) ? 'HLS' : 'Auto';
            }
            add(link, quality);
          }
          if (links.isNotEmpty) return links;
        }
      } catch (_) {}

      // Regex fallback for mp4 links with resolution labels.
      final re = RegExp(r'"link"\s*:\s*"([^"]*)".*?"resolutionStr"\s*:\s*"([^"]*)"');
      for (final m in re.allMatches(body)) {
        add(m.group(1)!.replaceAll('\\', ''), m.group(2)!);
      }
      return links;
    } catch (e) {
      debugPrint('[AllAnime] Resolve links error: $e');
      return [];
    }
  }
}
