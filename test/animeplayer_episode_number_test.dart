import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/sources/animeplayer_adapter.dart';

// O site trocou o slug de `-episodio-N` para `-SxE` (`naruto-1x1`); o parser
// antigo devolvia null para tudo (número `0`) e nenhum episódio casava.
void main() {
  AnimePlayerAdapter adapter() => AnimePlayerAdapter();

  test('slug -SxE extrai o número do episódio', () {
    expect(
        adapter()
            .episodeNumber('https://animeplayer.com.br/episodios/naruto-1x1/'),
        1);
    expect(
        adapter().episodeNumber(
            'https://animeplayer.com.br/episodios/naruto-1x10/'),
        10);
    expect(
        adapter().episodeNumber(
            'https://animeplayer.com.br/episodios/naruto-1x100/'),
        100);
  });

  test('slug legado -episodio-N continua funcionando', () {
    expect(
        adapter().episodeNumber(
            'https://animeplayer.com.br/episodios/naruto-episodio-1/'),
        1);
  });

  test('slug desconhecido → null (não vira 0 silencioso no caller)', () {
    expect(adapter().episodeNumber('https://animeplayer.com.br/animes/x/'),
        isNull);
  });
}
