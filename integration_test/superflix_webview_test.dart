import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/core/sources/source_registry.dart';
import 'package:goanime_tv/features/superflix/superflix_web_screen.dart';

/// Verifies the SuperFlix WebView Turnstile bypass end-to-end on a real device:
/// search -> pick tmdb -> open WebView resolver -> resolve stream sources.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SuperFlix WebView resolves a stream', (tester) async {
    final sf = SourceRegistry.forSource(AnimeSource.superFlix);
    final results = await sf.search('the boys');
    debugPrint('SuperFlix search: ${results.length}');
    final anime = results.firstWhere(
      (a) => a.superFlixTmdbId != null,
      orElse: () => results.first,
    );
    debugPrint('pick: ${anime.name} tmdb=${anime.superFlixTmdbId}');

    final episode = Episode(
      number: '1',
      url:
          'https://superflixapi.best/serie/${anime.superFlixTmdbId}/1/1',
      source: AnimeSource.superFlix,
      owner: anime,
    );

    List<VideoSource>? captured;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await SuperFlixWebScreen.resolve(
                  context,
                  anime: anime,
                  episode: episode,
                );
              },
              child: const Text('go'),
            ),
          ),
        );
      }),
    ));

    await tester.tap(find.text('go'));
    // Give the WebView time to load + solve Turnstile + extract.
    for (var i = 0; i < 30 && captured == null; i++) {
      await tester.pump(const Duration(seconds: 2));
      await Future.delayed(const Duration(seconds: 2));
    }

    debugPrint('SuperFlix WebView sources: ${captured?.length ?? -1}');
    for (final s in captured ?? <VideoSource>[]) {
      final u = s.url.length > 90 ? '${s.url.substring(0, 90)}...' : s.url;
      debugPrint('  - [${s.quality}] $u');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
