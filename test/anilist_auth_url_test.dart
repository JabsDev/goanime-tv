import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/constants/app_constants.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';

void main() {
  test('authUrl gera URL Implicit Grant apontando para o pin do AniList', () {
    final uri = Uri.parse(AniListService.authUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, 'anilist.co');
    expect(uri.path, '/api/v2/oauth/authorize');
    expect(uri.queryParameters['client_id'], AppConstants.anilistClientId);
    expect(uri.queryParameters['response_type'], 'token');
    // Redirect final é a página de pin — o fluxo canônico que interceptamos.
    expect(
      uri.queryParameters['redirect_uri'],
      'https://anilist.co/api/v2/oauth/pin',
    );
    expect(uri.queryParameters.containsKey('state'), isTrue);
    expect(uri.queryParameters['state'], isNotEmpty);
  });
}