import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/scraper/scraper_result.dart';

void main() {
  group('isCloudflareChallenge', () {
    test('detects Verificação in content', () {
      expect(isCloudflareChallenge('<html>Verificação</html>', {}), true);
    });

    test('detects cf-browser-verification in content', () {
      expect(
        isCloudflareChallenge(
          '<html>cf-browser-verification</html>',
          {},
        ),
        true,
      );
    });

    test('detects cf-challenge in content', () {
      expect(
        isCloudflareChallenge('<html>cf-challenge</html>', {}),
        true,
      );
    });

    test('detects CF-Ray header', () {
      expect(
        isCloudflareChallenge('', {'CF-Ray': 'abc123'}),
        true,
      );
    });

    test('detects CF-Challenge header', () {
      expect(
        isCloudflareChallenge('', {'CF-Challenge': 'true'}),
        true,
      );
    });

    test('returns false for normal HTML', () {
      expect(
        isCloudflareChallenge(
          '<html><body>Normal anime page content</body></html>',
          {},
        ),
        false,
      );
    });

    test('returns false for empty inputs', () {
      expect(isCloudflareChallenge('', {}), false);
    });
  });
}
