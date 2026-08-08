import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/utils/quality_picker.dart';
import 'package:goanime_tv/data/models/episode.dart';

/// Fase 3 self-checks: best-quality auto-selection. Pure logic, no network.
void main() {
  List<VideoSource> srcs(List<String> qs) => [
        for (final q in qs) VideoSource(url: 'http://x/$q', quality: q),
      ];

  test('bestQualityIndex picks the highest numeric quality', () {
    final s = srcs(['480p', '1080p', '720p', 'Auto']);
    expect(bestQualityIndex(s), 1); // 1080p
  });

  test('bestQualityIndex keeps single source', () {
    expect(bestQualityIndex(srcs(['Auto'])), 0);
  });

  test('qualityScore parses numbers and falls back to labels', () {
    expect(qualityScore('1080p'), 1080);
    expect(qualityScore('Full HD'), 1080);
    expect(qualityScore('HD 720'), 720);
    expect(qualityScore('Auto'), 0);
    expect(qualityScore(''), 0);
  });

  test('sortBestFirst orders best first, stable for equal scores', () {
    final s = srcs(['720p', '480p', '1080p', '1080p']);
    final ordered = sortBestFirst(s);
    expect(ordered.map((e) => e.quality).toList(), [
      '1080p',
      '1080p',
      '720p',
      '480p',
    ]);
  });

  test('mapped index after sortBestFirst points to the chosen source', () {
    final s = srcs(['480p', '1080p', '720p']);
    final chosen = s[0]; // user picked 480p
    final ordered = sortBestFirst(s);
    final mapped = ordered.indexWhere((x) => identical(x, chosen));
    expect(mapped, 2);
    expect(ordered[mapped], chosen);
  });
}
