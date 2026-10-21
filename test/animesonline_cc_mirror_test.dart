import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/scraper/scraper_result.dart';
import 'package:goanime_tv/core/sources/animesonline_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';

/// Espelho `animesonlinecc.to` (tema antigo do cluster AnimesOnline).
///
/// O site lista a grade em `#seasons .se-c` → `ul.episodios li a[href]`, com
/// o mesmo link repetido (capa + título). O player é iframe do Blogger e hoje
/// responde 403 no googlevideo — por isso o adapter fica fora do fan-out
/// (`implemented == false`), mas a listagem precisa continuar correta para o
/// dia em que o player voltar.
void main() {
  const base = 'https://animesonlinecc.to';

  String page() => '''
<html><body>
<div id="seasons">
  <div class="se-c">
    <div class="se-q"><span class="se-t se-o">1</span><span class="title">Temporada 1</span></div>
    <div class="se-a" style="display:block">
      <ul class="episodios">
        <li>
          <div class="imagen"><a href="$base/episodio/bleach-episodio-1/"><img src="$base/1.jpg"></a></div>
          <div class="episodiotitle"><a href="$base/episodio/bleach-episodio-1/">Episodio 1</a></div>
        </li>
        <li>
          <div class="imagen"><a href="$base/episodio/bleach-episodio-2/"><img src="$base/2.jpg"></a></div>
          <div class="episodiotitle"><a href="$base/episodio/bleach-episodio-2/">Episodio 2</a></div>
        </li>
      </ul>
    </div>
  </div>
</div>
</body></html>
''';

  test('parseia a grade do tema antigo e fica desligado do fan-out',
      () async {
    final adapter = AnimesOnlineAdapter(
      source: AnimeSource.animesOnlineCc,
      client: MockClient((req) async => http.Response(page(), 200)),
    );

    expect(adapter.implemented, isFalse,
        reason: 'player Blogger (googlevideo 403) — espelho desligado');

    final anime = Anime(
      name: 'Bleach',
      url: '$base/anime/bleach/',
      source: AnimeSource.animesOnlineCc,
    );
    final result = await adapter.getEpisodes(anime);
    final eps = (result as Success<List<Episode>>).data;

    expect(eps, hasLength(2), reason: 'dedupe capa + título');
    expect(eps.map((e) => '${e.season}-${e.number}'), ['1-1', '1-2']);
    expect(eps.first.thumbnail, '$base/1.jpg');
    expect(eps.first.url, '$base/episodio/bleach-episodio-1/');
  });
}
