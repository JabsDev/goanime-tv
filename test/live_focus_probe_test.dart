// Live probe #3 — targeted: exact main-series URLs per source for the 4 animes,
// resolving video for first/middle/last episodes via each source adapter + the
// repo fallback. Run:
//  flutter test test/live_focus_probe_test.dart --dart-define=LIVE=1 --timeout 20m
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/core/sources/source_registry.dart';

// Per-source entry points (from real searches above).
final _targets = [
  // animeFire
  Anime(name: 'One Piece', url: 'https://animefire.io/animes/one-piece-todos-os-episodios', source: AnimeSource.animeFire),
  Anime(name: 'Black Clover', url: 'https://animefire.io/animes/black-clover-todos-os-episodios', source: AnimeSource.animeFire),
  Anime(name: 'Black Butler', url: 'https://animefire.io/animes/kuroshitsuji-todos-os-episodios', source: AnimeSource.animeFire),
  Anime(name: 'Haibane Renmei', url: 'https://animefire.io/animes/haibane-renmei-todos-os-episodios', source: AnimeSource.animeFire),
  // goyabu
  Anime(name: 'One Piece', url: 'https://goyabu.io/anime/one-piece-online-hd-3', source: AnimeSource.goyabu),
  Anime(name: 'Black Clover', url: 'https://goyabu.io/anime/black-clover', source: AnimeSource.goyabu),
  Anime(name: 'Haibane Renmei', url: 'https://goyabu.io/anime/haibane-renmei', source: AnimeSource.goyabu),
  // dooPlay
  Anime(name: 'One Piece', url: 'https://betteranime.io/animes/one-piece/', source: AnimeSource.dooPlay),
  Anime(name: 'Black Clover', url: 'https://betteranime.io/animes/black-clover/', source: AnimeSource.dooPlay),
  Anime(name: 'Black Butler', url: 'https://betteranime.io/animes/black-butler/', source: AnimeSource.dooPlay),
  // animePlayer
  Anime(name: 'One Piece: Gyojin Tou-hen', url: 'https://animeplayer.com.br/animes/one-piece/kyojin/', source: AnimeSource.animePlayer),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final live = const String.fromEnvironment('LIVE') == '1';
  test(
    'LIVE focused probe',
    () async {
      if (!live) return;
      HttpOverrides.global = null;
      final sb = StringBuffer();

      for (final t in _targets) {
        sb.writeln('\n--- ${t.source.name}: "${t.name}"');
        final adapter = SourceRegistry.forSource(t.source);
        // Exact page is known here, so the match is the target itself.
        for (final n in [1, 5, 10, 15, 20]) {
          final vs =
              await adapter.resolveVideo(t, n);
          sb.writeln(
            '  EP$n -> ${vs.length} vid: '
            '${vs.map((v) => '${v.quality}/${_host(v.url)}').join(", ")}',
          );
        }
      }

      File('/home/jabs/codes-ai/goanime-tv/.qa/focus_probe.txt')
          .writeAsStringSync(sb.toString());
      // ignore: avoid_print
      print(sb.toString());
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

String _host(String url) {
  try {
    return Uri.parse(url).host.replaceFirst('www.', '');
  } catch (_) {
    return '?';
  }
}