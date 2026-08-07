import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/constants/app_constants.dart';
import 'package:goanime_tv/core/anilist/anilist_service.dart';

void main() {
  test('authUrl gera URL Implicit Grant sem redirect_uri (doc AniList)', () {
    final uri = Uri.parse(AniListService.authUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, 'anilist.co');
    expect(uri.path, '/api/v2/oauth/authorize');
    expect(uri.queryParameters['client_id'], AppConstants.anilistClientId);
    expect(uri.queryParameters['response_type'], 'token');
    // Não passamos redirect_uri — a doc do AniList exige só client_id +
    // response_type; enviar redirect não-registrado causa unsupported_grant_type.
    expect(uri.queryParameters.containsKey('redirect_uri'), isFalse);
    expect(uri.queryParameters.containsKey('state'), isTrue);
    expect(uri.queryParameters['state'], isNotEmpty);
  });
}