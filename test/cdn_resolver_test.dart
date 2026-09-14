import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/sources/cdn_resolver.dart';

// Cobertura das variantes de pasta do CDN (Layer B do AnimesOnline).
// Ao vivo: "One Piece Dublado/131.mp4" dá 206, "One Piece/131.mp4" dá 404.
void main() {
  test('titleVariants inclui "X Dublado" (pasta com sufixo)', () {
    final vs = CdnResolver.titleVariants('One Piece', englishName: 'ONE PIECE');
    expect(vs, contains('One Piece'));
    expect(vs, contains('One Piece Dublado'));
    expect(vs, contains('OnePieceDublado'));
    expect(vs, contains('ONE PIECE Dublado'));
  });

  test('sem sufixo duplo quando o título já é dublado', () {
    final vs = CdnResolver.titleVariants('Naruto Dublado');
    expect(vs.any((v) => v.contains('Dublado Dublado')), isFalse);
    expect(vs.any((v) => v.contains('DubladoDublado')), isFalse);
  });

  test('título sujo do site ("One Piece –") é limpo antes das variantes', () {
    final vs = CdnResolver.titleVariants('One Piece –');
    expect(vs, contains('One Piece'));
    expect(vs, contains('One Piece Dublado'));
    expect(vs.any((v) => v.endsWith('–') || v.endsWith('-')), isFalse);
  });

  test('buildCandidateUrls alcança a pasta "X Dublado"', () {
    final urls = CdnResolver.buildCandidateUrls('One Piece', '131',
        hosts: ['https://mangas.cloud']);
    expect(
        urls,
        contains(
            'https://mangas.cloud/Animes/Letra-O/One Piece Dublado/131.mp4'));
  });

  test('resolve acha a 206 funda na matriz sem varrer tudo', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      // Só a pasta "Dublado" responde 206 (como ao vivo). O path vem
      // percent-encoded (%20), então casa sem os espaços.
      if (req.url.path.contains('Dublado/131.mp4')) {
        return http.Response('', 206,
            headers: {'content-range': 'bytes 0-0/140000000'});
      }
      return http.Response('nope', 404);
    });
    final url = await CdnResolver(client: client)
        .resolve('One Piece', 131, englishName: 'ONE PIECE');
    expect(
        url,
        'https://mangas.cloud/Animes/Letra-O/One Piece Dublado/131.mp4');
    final total = CdnResolver.buildCandidateUrls('One Piece', '131',
        englishName: 'ONE PIECE').length;
    expect(calls, lessThan(total));
  });
}
