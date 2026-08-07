import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/anilist/anilist_service.dart';

void main() {
  const jwt =
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.3oFw7u5fJHXG1bNmRaxBCj9nGV0n6t9Y60SwvX3D5H4';

  group('extractAccessToken', () {
    test('lê o token do fragment canônico do pin', () {
      final url = 'https://anilist.co/api/v2/oauth/pin'
          '#access_token=$jwt&token_type=Bearer&expires_in=86400&state=abc';
      expect(AniListService.extractAccessToken(url), jwt);
    });

    test('token vindo colado no path (webview sem fragment) também funciona', () {
      final url = 'https://anilist.co/api/v2/oauth/pin#access_token=$jwt';
      expect(AniListService.extractAccessToken(url), jwt);
    });

    test('fragment sem access_token retorna null', () {
      final url = 'https://anilist.co/api/v2/oauth/pin#state=abc';
      expect(AniListService.extractAccessToken(url), isNull);
    });

    test('sem fragment retorna null', () {
      final url = 'https://anilist.co/api/v2/oauth/pin';
      expect(AniListService.extractAccessToken(url), isNull);
    });

    test('token em query (errado para Implicit) não é aceito', () {
      final url =
          'https://anilist.co/api/v2/oauth/pin?access_token=$jwt&state=abc';
      expect(AniListService.extractAccessToken(url), isNull);
    });

    test('caracteres de escape são decodificados', () {
      final url = 'https://anilist.co/api/v2/oauth/pin'
          '#access_token=abc%2Bdef%2Fghi';
      expect(AniListService.extractAccessToken(url), 'abc+def/ghi');
    });
  });

  group('isJwtToken', () {
    test('JWT com 3 segmentos é aceito', () {
      expect(AniListService.isJwtToken(jwt), isTrue);
    });

    test('token sem prefixo eyJ é rejeitado', () {
      expect(AniListService.isJwtToken('abc.def.ghi'), isFalse);
    });

    test('token com menos de 3 segmentos é rejeitado', () {
      expect(AniListService.isJwtToken('eyJ.abc'), isFalse);
    });
  });

  group('isPinCallback', () {
    test('URL do pin anilist.co é reconhecida', () {
      expect(
        AniListService.isPinCallback(
          Uri.parse('https://anilist.co/api/v2/oauth/pin#access_token=x'),
        ),
        isTrue,
      );
    });

    test('outros hosts são rejeitados', () {
      expect(
        AniListService.isPinCallback(
          Uri.parse('https://evil.example.com/api/v2/oauth/pin'),
        ),
        isFalse,
      );
    });

    test('outros paths do anilist.co não são pin', () {
      expect(
        AniListService.isPinCallback(
          Uri.parse('https://anilist.co/login'),
        ),
        isFalse,
      );
    });
  });
}