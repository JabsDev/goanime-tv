class AppConstants {
  static const String appName = 'GoAnime TV';
  static const String baseSiteUrl = 'https://animefire.io';
  // AllAnime - Atualizado para domínio funcional
  static const String allAnimeBase = 'allanime.to';
  static const String allAnimeAPI = 'https://api.allanime.to/api';
  static const String allAnimeReferer = 'https://allanime.to';
  static const String superFlixBase = 'https://superflixapi.pro';
  static const String superFlixReferer = 'https://superflixapi.pro/';
  
  // Adicionar: Headers para Cloudflare
  static const String superFlixUserAgent =
      'Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.6099.230 Safari/537.36';
  static const String goyabuBase = 'https://goyabu.io';
  static const String betterAnimeBase = 'https://betteranime.io';
  static const String animesRollBase = 'https://anroll.plus';
  static const String anikyuuBase = 'https://anikyuu.to';
  // Anitube - Atualizado para domínio funcional
  static const String anitubeBase = 'https://anitube.to';
  static const String dattebayoBase = 'https://www.dattebayo-br.com';
  // AnimesDigital - Atualizado com /index/ para evitar redirect loop
  static const String animesDigitalBase = 'https://animesdigital.org/index/';
  static const String animesDigitalReferer = 'https://animesdigital.org/index/';
  static const String anilistApi = 'https://graphql.anilist.co';
  static const String anilistOAuth = 'https://anilist.co/api/v2/oauth/authorize';
  static const String anilistClientId = '46975';
  // ponytail: Implicit Grant (response_type=token) — sem client_secret no APK.
  // Antes o client_secret estava hardcoded aqui, extraível por qualquer um com
  // o APK. Implicit Grant retorna o access_token direto no redirect fragment,
  // então não há code exchange nem secret necessário.
  static const String anilistRedirectUri = 'http://127.0.0.1:8090/callback';
  static const String anilistTokenEndpoint = 'https://anilist.co/api/v2/oauth/token';

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Safari/537.36';
  // Increased timeout to handle redirects and slower sources
  static const Duration requestTimeout = Duration(seconds: 30);
  
  // Specific timeout for SuperFlix (follow redirects can take longer)
  static const Duration superFlixTimeout = Duration(seconds: 45);
}
