import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/sources/animesdigital_adapter.dart';
import 'package:goanime_tv/data/models/anime.dart';

/// Variantes reais do Slime 4 (07/10/2026): a "dublado" lista 1..16, a
/// "todos os episódios" lista 1..24. Antes a busca escolhia a incompleta.
String _itensEp(int count) {
  final sb = StringBuffer('<div class="itens_ep">');
  for (var n = count; n >= 1; n--) {
    final num = n.toString().padLeft(2, '0');
    sb.write(
      '<div class="item_ep b_flex"><a href="https://animesdigital.org/video/a/$n" '
      'class="b_flex"><div class="dados"><div class="title_anime">'
      'Tensei shitara Slime Datta Ken 4th Season Dublado Episódio $num'
      '</div></div></a></div>',
    );
  }
  return '$sb</div>';
}

const _searchHtml = '''
<div class="itemA"><a href="https://animesdigital.org/anime/a/tensei-shitara-slime-datta-ken-4th-season-dublado" title="Assistir Tensei Shitara Slime Datta Ken 4th Season Dublado Online em HD"><span class="title_anime">x</span></a></div>
<div class="itemA"><a href="https://animesdigital.org/anime/a/tensei-shitara-slime-datta-ken-4-todos-episodios" title="Assistir Tensei Shitara Slime Datta Ken 4 Todos os Episódios Online em HD"><span class="title_anime">x</span></a></div>''';

http.Client _mock() => MockClient((req) async {
      final u = req.url.toString();
      if (u.contains('/pesquisa/')) return http.Response(_searchHtml, 200);
      if (u.endsWith('4-todos-episodios') || u.endsWith('4-todos-episodios/')) {
        return http.Response(_itensEp(24), 200);
      }
      if (u.contains('4th-season-dublado')) {
        return http.Response(_itensEp(16), 200);
      }
      return http.Response('nope', 404);
    });

void main() {
  _locateGroup();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Slime 4: escolhe a variante com todos os 24 episódios, não a dublado de 16',
      () async {
    final adapter = AnimesDigitalAdapter(client: _mock());
    final ref = Anime(
      name: 'Tensei Shitara Slime Datta Ken 4th Season Part 1 & 2',
      url: '',
      source: AnimeSource.animesDigital,
    );
    final match = await adapter.resolveAnime(ref);
    expect(match, isNotNull);
    expect(match!.url, endsWith('tensei-shitara-slime-datta-ken-4-todos-episodios'));
  });

  test('temporada lida pela URL quando o título não tem "season"', () {
    expect(
      AnimesDigitalAdapter.seasonOfCandidateForTest(
        'https://animesdigital.org/anime/a/tensei-shitara-slime-datta-ken-4-todos-episodios',
      ),
      4,
    );
    expect(
      AnimesDigitalAdapter.seasonOfCandidateForTest(
        'https://animesdigital.org/anime/a/tensei-shitara-slime-datta-ken-4th-season-dublado',
      ),
      4,
    );
    expect(
      AnimesDigitalAdapter.seasonOfCandidateForTest(
        'https://animesdigital.org/anime/a/tensei-shitara-slime-datta-ken-dublado',
      ),
      isNull,
    );
  });
}

/// Lista 150 episódios em 3 páginas de 50 (newest-first), com links /page/N/.
String _pagedPage(int page) {
  const total = 150;
  const size = 50;
  final top = total - (page - 1) * size;
  final bottom = top - size + 1;
  final sb = StringBuffer('<div class="itens_ep">');
  for (var n = top; n >= bottom && n >= 1; n--) {
    sb.write(
      '<div class="item_ep b_flex"><a href="https://animesdigital.org/video/a/$n" '
      'class="b_flex"><div class="title_anime">Serie Episódio $n</div></a></div>',
    );
  }
  sb.write('</div>');
  for (var p = 2; p <= 3; p++) {
    sb.write('<a href="https://animesdigital.org/anime/a/serie/page/$p/">$p</a>');
  }
  return sb.toString();
}

void _locateGroup() {
  group('localização de episódio (paginação)', () {
    test('ep do meio: acha em até 2 páginas, sem varrer tudo', () async {
      final requested = <String>[];
      final client = MockClient((req) async {
        final u = req.url.toString();
        requested.add(u);
        if (u.endsWith('/anime/a/serie')) {
          return http.Response(_pagedPage(1), 200);
        }
        final m = RegExp(r'/page/(\d+)/$').firstMatch(u);
        if (m != null) return http.Response(_pagedPage(int.parse(m.group(1)!)), 200);
        return http.Response('nope', 404);
      });
      final adapter = AnimesDigitalAdapter(client: client);
      final match = Anime(
        name: 'Serie',
        url: 'https://animesdigital.org/anime/a/serie',
        source: AnimeSource.animesDigital,
      );
      // Ep 75 está na página 2; o resultado final é a própria URL do episódio.
      final eps = await adapter.resolveVideo(match, 75);
      expect(eps, isEmpty); // não há página de vídeo mockada: o foco é a localização
      final pageGets = requested.where((u) => u.contains('/page/')).length;
      expect(pageGets, lessThanOrEqualTo(2));
    });
  });
}
