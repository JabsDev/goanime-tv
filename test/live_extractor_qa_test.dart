// Live extractor QA (NOT CI): run with --dart-define=LIVE=1
import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/sources/dooplay_v2_extractor.dart';

void main() {
  final live = const String.fromEnvironment('LIVE') == '1';
  test('LIVE extractor on QA episodes', timeout: const Timeout(Duration(minutes: 5)), () async {
    if (!live) return;
    final cases = [
      ('Solo Leveling',
          'https://animesonline.cloud/episodio/solo-leveling-episodio-01'),
      ('Kimetsu Hashira Geiko-hen ep1',
          'https://animesonline.cloud/episodio/kimetsu-no-yaiba-hashira-geiko-hen-episodio-01'),
      ('Naruto Shippuuden Dublado ep1',
          'https://animesonline.cloud/episodio/naruto-shippuuden-dublado-episodio-01'),
    ];
    for (final (label, url) in cases) {
      final ex = DooPlayV2Extractor(baseUrl: 'https://animesonline.cloud');
      try {
        final vs = await ex.extractPlayable(url);
        // ignore: avoid_print
        print('$label OK: ${vs.length} -> ${vs.map((v) => v.url).toList()}');
      } catch (e) {
        // ignore: avoid_print
        print('$label -> $e');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  });
}