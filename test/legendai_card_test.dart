import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/legendai/legendai_connection.dart';
import 'package:goanime_tv/core/subtitles/subtitle_job_manager.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/features/ai_subtitle/ai_subtitle_card.dart';

Anime _anime() => Anime(name: 'Haibane', url: 'http://x');

Future<void> _pump(WidgetTester tester, {List<VideoSource>? sources}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final src = sources ?? [VideoSource(url: 'http://x/ep1.m3u8', quality: '720p')];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            AiSubtitleCard(
              anime: _anime(),
              episode: const CatalogEpisode(number: 1),
              episodeIndex: 0,
              episodeList: const [CatalogEpisode(number: 1)],
              provider: AnimeSource.animeFire,
              sources: src,
            ),
          ],
        ),
      ),
    ),
  );
}

MockClient _server() => MockClient((req) async {
  final body = req.url.path == '/v1/info'
      ? {
          'name': 'PC-Jabs',
          'host': '127.0.0.1',
          'port': 8765,
          'protocol': 1,
          'version': '0.2.0',
          'url': 'http://127.0.0.1:8765',
        }
      : {
          'app': 'legendai',
          'version': '0.2.0',
          'protocol': 1,
          'name': 'PC-Jabs',
          'tier': 'Tier2',
          'gpu': true,
          'busy': 0,
          'queue': 0,
          'models': {'stt': 'a', 'translation': 'b'},
        };
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorage.init();
    await SettingsService.instance.init();
    SubtitleJobManager.instance.lastCrashHint = null;
    final tmp = await Directory.systemTemp.createTemp('card_models');
    addTearDown(() => tmp.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmp.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async => call.method == 'check' ? <String>['mobile'] : null,
        );
    LegendAiConnection.instance.debugUseClient(null);
    await LegendAiConnection.instance.disconnect();
  });

  tearDown(() async {
    LegendAiConnection.instance.debugUseClient(null);
    await LegendAiConnection.instance.disconnect();
  });

  testWidgets('modo padrão é "No aparelho" (comportamento antigo intacto)', (
    tester,
  ) async {
    await _pump(tester);
    await tester.pump();
    expect(find.text('Onde gerar'), findsOneWidget);
    expect(find.text('No PC (LegendAI)'), findsOneWidget);
    expect(find.text('Gerar legenda'), findsOneWidget);
    expect(find.text('Gerar no PC'), findsNothing);
  });

  testWidgets('"No PC" sem PC configurado avisa e não troca de modo', (
    tester,
  ) async {
    await _pump(tester);
    await tester.pump();
    expect(
      find.text(
        'PC não configurado — veja Configurações → '
        'LegendAI (PC).',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('No PC (LegendAI)'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    // Continua no modo aparelho.
    expect(find.text('Gerar legenda'), findsOneWidget);
    expect(find.text('Gerar no PC'), findsNothing);
  });

  testWidgets('PC conectado permite trocar para "No PC" e gerar', (
    tester,
  ) async {
    // PC pareado e respondendo.
    final conn = LegendAiConnection.instance;
    conn.debugUseClient(_server());
    await SettingsService.instance.setLegendAiAddress('127.0.0.1', 8765);
    await conn.test();
    expect(conn.status.value, LegendAiStatus.online);

    await _pump(tester);
    await tester.pump();
    await tester.tap(find.text('No PC (LegendAI)'));
    await tester.pump();
    expect(find.text('Gerar no PC'), findsOneWidget);
    expect(find.text('Gerar legenda'), findsNothing);
    // Rota transcrever: oferece o fallback de upload do áudio (Fase 5).
    expect(find.text('Enviar áudio do aparelho'), findsOneWidget);
  });

  testWidgets('fonte com candidata EN mostra a rota traduzir (rota S)', (
    tester,
  ) async {
    await _pump(
      tester,
      sources: [
        VideoSource(
          url: 'http://x/ep1.m3u8',
          quality: '720p',
          subtitleCandidates: const [
            SubtitleRef(
              label: 'English',
              lang: 'en',
              uri: 'http://x/ep1.en.srt',
            ),
          ],
        ),
      ],
    );
    await tester.pump();
    expect(
      find.text('1 candidata(s) EN/ES na fonte · rota: traduzir'),
      findsOneWidget,
    );
  });

  testWidgets('rota traduzir no PC não mostra o fallback de upload', (
    tester,
  ) async {
    final conn = LegendAiConnection.instance;
    conn.debugUseClient(_server());
    await SettingsService.instance.setLegendAiAddress('127.0.0.1', 8765);
    await conn.test();

    await _pump(
      tester,
      sources: [
        VideoSource(
          url: 'http://x/ep1.m3u8',
          quality: '720p',
          subtitleCandidates: const [
            SubtitleRef(
              label: 'English',
              lang: 'en',
              uri: 'http://x/ep1.en.srt',
            ),
          ],
        ),
      ],
    );
    await tester.pump();
    await tester.tap(find.text('No PC (LegendAI)'));
    await tester.pump();
    expect(find.text('Gerar no PC'), findsOneWidget);
    expect(find.text('Enviar áudio do aparelho'), findsNothing);
  });
}
