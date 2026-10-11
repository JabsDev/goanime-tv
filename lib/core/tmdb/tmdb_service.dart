import 'dart:convert';
import 'dart:math' as math;

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

  /// Último erro visto pela API. Antes these campos não existiam e TODA
  /// resposta não-200 virava `[]` — o "Testar chave" então acusava a chave
  /// do usuário por qualquer falha (rede, 429, 404), que é exatamente o
  /// tipo de diagnóstico inútil que o fez acreditar ter errado algo.
  static int? lastStatusCode;
  static String? lastErrorMessage;

  /// Verificação barata e inequívoca da chave: um id fixo e pequeno em vez
  /// de `discover` (que carrega filtros e pode devolver vazio legítimamente).
  static Future<({bool ok, String message})> verifyKey() async {
    if (!isConfigured) {
      return (ok: false, message: 'Nenhuma chave configurada.');
    }
    lastStatusCode = null;
    lastErrorMessage = null;
    try {
      // Fight Club (id 550): existe sempre, é minúsculo, e o TMDB só
      // responde 200 se a chave v3 for aceita.
      final res = await _get('/movie/550', const {});
      lastStatusCode = res.statusCode;
      if (res.statusCode == 200) {
        return (ok: true, message: 'Chave válida — a API respondeu 200.');
      }
      return (ok: false, message: _diagnose(res));
    } catch (e) {
      lastErrorMessage = '$e';
      return (ok: false, message: 'Erro de rede: $e');
    }
  }

  /// Mensagem legível a partir de uma resposta de erro do TMDB.
  static String _diagnose(http.Response res) {
    var msg = 'HTTP ${res.statusCode}';
    try {
      final d = jsonDecode(res.body);
      if (d is Map && d['status_message'] is String) {
        msg = '${d['status_message']} (HTTP ${res.statusCode})';
        lastErrorMessage = 'status_code ${d['status_code']}: ${d['status_message']}';
      } else {
        lastErrorMessage = msg;
      }
    } catch (_) {
      lastErrorMessage = msg;
    }
    switch (res.statusCode) {
      case 401:
        return 'Chave recusada pelo TMDB — $msg';
      case 403:
        return 'Acesso negado pelo TMDB — $msg';
      case 404:
        return 'Recurso não encontrado no TMDB — $msg';
      case 429:
        return 'Limite de requisições do TMDB estourado — $msg';
      default:
        return 'Falha na API do TMDB — $msg';
    }
  }

  static const _userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36';

  /// Idiomas do acervo asiático, separados por **pipe**.
  ///
  /// ⚠️ Público de propósito: é a constante que já quebrou o catálogo inteiro
  /// duas vezes com um caractere. Se puder ser testado, tem que ser testado.
  ///
  /// Pipe, não vírgula. Na documentação do TMDB: comma = AND, pipe = OR.
  /// Com vírgula, `ja,ko,zh,th` vira "idioma original é japonês **E** coreano
  /// **E** chinês **E** tailandês" — impossível — e o TMDB responde
  /// **HTTP 200 com `results: []`**, sem nenhum erro. Foi exatamente essa
  /// falha silenciosa que fez o app nunca mostrar nada do catálogo TMDB
  /// mesmo com a chave válida (verificado com curl em 11/10/2026:
  /// vírgula → total_results 0; pipe → 20001).
  static const asianLanguages = 'ja|ko|zh|th';

  /// Idiomas da linha **"Dramas e Doramas"**: coreano, chinês e tailandês.
  ///
  /// `ja` fica de fora de propósito: o sort por popularidade em japonês é
  /// dominado por anime (Naruto, Bleach, Doraemon…), que o AniList já
  /// cataloga com metadados melhores — incluir aqui só duplicaria card.
  /// Dorama japonês ao vivo pode voltar depois com filtro dedicado.
  static const dramaLanguages = 'ko|zh|th';

  /// `with_type` do TMDB para **Scripted** (drama/série de ficção).
  ///
  /// ⚠️ A numeração NÃO é a óbvia. Verificado contra a API em 11/10/2026:
  ///   0=Documentário · 1=Notícia · 2=Minissérie · 3=Reality
  ///   **4=Scripted** · 5=Talk Show · 6=Vídeo
  /// Usar 1 (achando que era "Scripted") devolvia programas de notícia e
  /// variedade em coreano/japonês — sem nenhum drama — e ainda zerava a
  /// lista quando combinado com `vote_count`. Segundo erro de suposição
  /// nesta API depois do separador vírgula/pipe.
  static const typeScripted = '4';

  /// Mínimo de votos para a linha de dramas. Notícias e variedades mal
  /// chegam a dezenas de votos; dramas conhecidos passam de centenas.
  static const _minVotes = '30';

  /// Chave padrão embutida NO BUILD, via `--dart-define`.
  ///
  /// 🔑 A chave do TMDB é feita para viver no cliente (a doc do TMDB pede
  /// exatamente isso), então tê-la no APK não é vazar segredo: é o
  /// desenho da API. O que NÃO pode é **entrar no repositório git** — o
  /// secret scanning do GitHub marcaria o repo na hora. Por isso ela vem
  /// de `--dart-define=TMDB_API_KEY_DEFAULT=...`, injetada pelo CI a partir
  /// do secret `TMDB_API_KEY_DEFAULT`. Nunca commitar o valor literal.
  ///
  /// Vazio (build local sem a define) = app sem chave padrão, e o usuário
  /// ainda pode colar a própria nas Configurações.
  static const defaultApiKey =
      String.fromEnvironment('TMDB_API_KEY_DEFAULT', defaultValue: '');

  /// Existe chave padrão embutida neste build?
  static bool get hasDefaultKey => defaultApiKey.trim().isNotEmpty;

  /// Catálogo TMDB só opera com chave válida + toggle ligado.
  static bool get isConfigured => SettingsService.instance.tmdbConfigured;

  /// Chave em uso: a do usuário tem precedência sobre a padrão do build.
  /// Permite que qualquer usuário troque por uma própria (ou por uma que
  /// não esteja saturada) sem esperar o próximo build.
  static String? get _apiKey {
    if (!isConfigured) return null;
    final own = SettingsService.instance.tmdbApiKey.trim();
    if (own.isNotEmpty) return own;
    final fallback = defaultApiKey.trim();
    return fallback.isEmpty ? null : fallback;
  }

  /// A chave em uso veio do build, não do usuário?
  static bool get usingDefaultKey =>
      SettingsService.instance.tmdbApiKey.trim().isEmpty && hasDefaultKey;

  /// Rótulo curto da origem da chave, para a UI explicar ao usuário.
  static String get keyOriginLabel {
    if (!isConfigured) return 'desligado';
    if (!usingDefaultKey) return 'sua chave';
    return 'chave padrão do app';
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
    if (id is! num) return null;
    // `??` NÃO cai quando o campo existe mas está VAZIO: um item do
    // /discover/tv com `name: ""` (comum em entrada sem título localizado)
    // descartava o título em vez de tentar `original_name`.
    String pick(String key) {
      final v = raw[key];
      return (v == null) ? '' : v.toString().trim();
    }

    final title = TextUtils.cleanTitle(
        [pick('name'), pick('title'), pick('original_name')]
            .firstWhere((t) => t.isNotEmpty, orElse: () => ''));
    if (title.isEmpty) return null;

    // Sem tradução PT-BR, o TMDB devolve o título original em coreano/
    // japonês/chinês — inútil para o público do app e ocuparia um card com
    // texto ilegível. Fica só o que tem alfabeto latino; a rede de filtragem
    // da query já remove a maior parte, isto é a rede de segurança.
    if (!RegExp(r'[A-Za-z]').hasMatch(title)) return null;
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
      if (res.statusCode != 200) {
        debugPrint('[TMDB] search falhou: ${_diagnose(res)}');
        return const [];
      }
      return parseSearchMulti(res.body);
    } catch (e) {
      debugPrint('[TMDB] search error: $e');
      return const [];
    }
  }

  /// Categoria + ordenação. [genreId] do mapa de [genres].
  ///
  /// `filters` deixa os parâmetros opcionais de fora virem opt-in: o default
  /// é o conjunto mínimo que o TMDB **garante** devolver resultados. Filtrar
  /// demais já custou duas rodadas de "volta vazio" sem explicação.
  static Future<List<Anime>> discover({
    required String mediaType,
    int? genreId,
    int page = 1,
    String sortBy = 'popularity.desc',
    bool onlyAsianOrigin = true,
    bool scriptedOnly = true,
    /// Idiomas do filtro de origem. Null usa [asianLanguages].
    String? languages,
    bool minVotes = false,
  }) async {
    if (!isConfigured) return const [];
    final path = mediaType == 'movie' ? '/discover/movie' : '/discover/tv';
    try {
      final res = await _get(path, {
        if (genreId != null) 'with_genres': '$genreId',
        'sort_by': sortBy,
        'page': '$page',
        if (scriptedOnly && mediaType == 'tv') 'with_type': typeScripted,
        if (onlyAsianOrigin && mediaType == 'tv')
          'with_original_language': languages ?? asianLanguages,
        if (minVotes && mediaType == 'tv') 'vote_count.gte': _minVotes,
      });
      if (res.statusCode != 200) {
        debugPrint('[TMDB] discover falhou: ${_diagnose(res)}');
        lastDiscoverDiagnostics =
            'discover ${_diagnose(res)} · body: ${res.body.substring(0, math.min(200, res.body.length))}';
        return const [];
      }
      final list = parseDiscover(res.body, mediaType);
      lastDiscoverDiagnostics =
          'discover 200 · ${list.length} títulos · body: ${res.body.substring(0, math.min(120, res.body.length))}';
      return list;
    } catch (e) {
      debugPrint('[TMDB] discover error: $e');
      lastErrorMessage = '$e';
      return const [];
    }
  }

  /// Relatório legível da última chamada de `discover`. Exposto porque
  /// "volta vazio" não informa nada — com isto o usuário consegue dizer
  /// **onde** a chamada quebrrou (status, filtro, resposta).
  static String lastDiscoverDiagnostics = '(sem chamada ainda)';

  /// Diagnóstico completo para o botão "Testar chave": valida a chave E
  /// faz uma descoberta real, para separar "chave aceita" de "filtro sem
  /// resultado".
  static Future<({bool ok, String message})> diagnose() async {
    final v = await verifyKey();
    if (!v.ok) return v;

    // Mesma chamada que a Home usa, sem filtro nenhum.
    final res = await discover(mediaType: 'tv', scriptedOnly: false,
        onlyAsianOrigin: false);
    if (res.isNotEmpty) {
      return (
        ok: true,
        message: 'Chave válida e catálogo respondendo (${res.length} títulos).'
      );
    }
    // Chave aceita mas descoberta vazia: o problema é filtro, não chave.
    return (
      ok: false,
      message: 'Chave válida, mas a descoberta não trouxe nada. '
          '$lastDiscoverDiagnostics'
    );
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