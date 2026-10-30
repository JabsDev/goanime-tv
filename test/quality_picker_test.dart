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
    expect(qualityScore('Auto · dublado'), 0);
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

  group('defaultQualityIndex (teto do modo lite)', () {
    test('teto padrão do lite é 480p', () {
      expect(kDefaultMaxQualityHeight, 480);
      final s = srcs(['480p', '720p', '1080p']);
      expect(
        s[defaultQualityIndex(s, maxHeight: kDefaultMaxQualityHeight)].quality,
        '480p',
      );
    });

    test('sem teto continua na melhor qualidade', () {
      final s = srcs(['480p', '1080p', '720p']);
      expect(defaultQualityIndex(s), bestQualityIndex(s));
      expect(defaultQualityIndex(s, maxHeight: 720), 2); // 720p
    });

    test('teto 720p em lista ordenada pega o 720p, nunca o 1080p', () {
      final ordered = sortBestFirst(srcs(['720p', '480p', '1080p']));
      expect(ordered.map((e) => e.quality).toList(), ['1080p', '720p', '480p']);
      expect(defaultQualityIndex(ordered, maxHeight: 720), 1);
      expect(ordered[defaultQualityIndex(ordered, maxHeight: 720)].quality,
          '720p');
    });

    test('ordem da lista não importa (índice aponta para a fonte certa)', () {
      for (final order in [
        ['1080p', '480p', '720p'],
        ['480p', '720p', '1080p'],
        ['720p', '1080p', '480p'],
      ]) {
        final s = srcs(order);
        final idx = defaultQualityIndex(s, maxHeight: 720);
        expect(s[idx].quality, '720p', reason: 'ordem $order');
      }
    });

    test('só 1080p na fonte: toca a MENOR disponível (nunca falha)', () {
      final onlyHd = srcs(['1080p']);
      expect(defaultQualityIndex(onlyHd, maxHeight: 720), 0);

      // Duas acima do teto: escolhe a mais leve das duas.
      final above = srcs(['2160p', '1080p']);
      expect(above[defaultQualityIndex(above, maxHeight: 720)].quality,
          '1080p');
    });

    test('"Auto" (sem número) só é escolhido se nada numérico couber', () {
      // Sem alternativa numérica dentro do teto, "Auto" (score 0) é o padrão.
      expect(defaultQualityIndex(srcs(['Auto', '1080p']), maxHeight: 720), 0);
      // Com 720p disponível, o 720p ganha do "Auto".
      final s = srcs(['Auto', '1080p', '720p']);
      expect(s[defaultQualityIndex(s, maxHeight: 720)].quality, '720p');
    });
  });

  group('resolveStartIndex', () {
    test('escolha explícita é respeitada mesmo acima do teto', () {
      final s = srcs(['480p', '720p', '1080p']);
      final ordered = sortBestFirst(s);
      // Usuário escolheu 1080p explicitamente: o teto NÃO se aplica.
      final idx = resolveStartIndex(ordered, s,
          requested: 2, maxHeight: 720);
      expect(ordered[idx].quality, '1080p');
    });

    test('sem escolha aplica o teto', () {
      final s = srcs(['480p', '720p', '1080p']);
      final ordered = sortBestFirst(s);
      final idx = resolveStartIndex(ordered, s, requested: null, maxHeight: 720);
      expect(ordered[idx].quality, '720p');
    });

    test('sem escolha e sem teto volta ao comportamento antigo (melhor)', () {
      final s = srcs(['480p', '720p', '1080p']);
      final ordered = sortBestFirst(s);
      final idx = resolveStartIndex(ordered, s, requested: null);
      expect(ordered[idx].quality, '1080p');
    });

    test('retry re-resolve: remapeia por qualidade+url quando a identidade '
        'muda', () {
      final old = srcs(['480p', '720p']);
      final retried = srcs(['480p', '720p']); // objetos novos, mesmas URLs
      final ordered = sortBestFirst(retried);
      final idx = resolveStartIndex(ordered, old,
          requested: 1, maxHeight: 720); // usuário tinha escolhido 720p
      expect(ordered[idx].quality, '720p');
    });

    test('índice fora da lista cai na 1ª fonte da lista original '
        '(nunca estoura)', () {
      final s = srcs(['480p', '720p']);
      final ordered = sortBestFirst(s);
      final idx = resolveStartIndex(ordered, s, requested: 99, maxHeight: 720);
      expect(ordered[idx], s[0]);
      expect(resolveStartIndex(const [], const [], requested: 0), 0);
    });
  });
}
