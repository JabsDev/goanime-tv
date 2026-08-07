class AppConstants {
  static const String appName = 'GoAnime TV';
  static const String baseSiteUrl = 'https://animefire.io';

  static const String goyabuBase = 'https://goyabu.io';
  static const String betterAnimeBase = 'https://betteranime.io';
  static const String anilistApi = 'https://graphql.anilist.co';
  static const String anilistOAuth = 'https://anilist.co/api/v2/oauth/authorize';
  static const String anilistClientId = '46975';
  // ponytail: Implicit Grant (response_type=token) — sem client_secret no APK.
  // Antes o client_secret estava hardcoded aqui, extraível por qualquer um com
  // o APK. Implicit Grant retorna o access_token direto no redirect fragment,
  // então não há code exchange nem secret necessário.
  // ponytail: Implicit Grant canônico — o redirect final é a página de pin do
  // AniList, interceptada no WebView via NavigationDelegate (Fase 3). Nada de
  // servidor loopback 127.0.0.1:8090.
  static const String anilistRedirectUri = 'https://anilist.co/api/v2/oauth/pin';
  static const String anilistTokenEndpoint = 'https://anilist.co/api/v2/oauth/token';

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Safari/537.36';
  // Increased timeout to handle redirects and slower sources
  static const Duration requestTimeout = Duration(seconds: 30);
}
