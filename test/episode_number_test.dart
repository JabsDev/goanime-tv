import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/utils/episode_number.dart';

void main() {
  group('episodeNumberFromTitle', () {
    test('english prefixes', () {
      expect(episodeNumberFromTitle('Episode 130 - Foo'), 130);
      expect(episodeNumberFromTitle('Episode 5'), 5);
      expect(episodeNumberFromTitle('EP 1 · Scent'), 1);
      expect(episodeNumberFromTitle('Ep. 12: Bar'), 12);
    });

    test('pt-BR', () {
      expect(episodeNumberFromTitle('Black Clover - Episódio 1 - Asta e Yuno'),
          1);
      expect(episodeNumberFromTitle('Episódio 3 - Foo'), 3);
      expect(episodeNumberFromTitle('Hero - Ep 5 - Baz'), 5);
    });

    test('null sem número ou com extras', () {
      expect(episodeNumberFromTitle('One Piece Special'), isNull);
      expect(episodeNumberFromTitle('Movie 5 - Recapitulação'), isNull);
      expect(episodeNumberFromTitle('Naruto OVA 2'), isNull);
      expect(episodeNumberFromTitle('Sem nenhum padrao'), isNull);
      expect(episodeNumberFromTitle(''), isNull);
    });
  });

  group('episodeNumberFromUrl', () {
    test('último segmento numérico', () {
      expect(episodeNumberFromUrl('https://animefire.io/animes/black-clover/1'),
          1);
      expect(episodeNumberFromUrl('https://animefire.io/v/170/'), 170);
    });

    test('null quando não há número na URL', () {
      expect(episodeNumberFromUrl('https://animefire.io/animes/black-clover'),
          isNull);
      expect(episodeNumberFromUrl(''), isNull);
      expect(episodeNumberFromUrl('not a url'), isNull);
    });
  });
}