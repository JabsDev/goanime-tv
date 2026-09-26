import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/subtitle_job_manager.dart';
import 'package:goanime_tv/data/models/anime.dart';
import 'package:goanime_tv/data/models/episode.dart';
import 'package:goanime_tv/features/ai_subtitle/ai_subtitle_card.dart';

Anime _anime() => Anime(name: 'Haibane', url: 'http://x');

Future<void> _pump(WidgetTester tester, {required List<SubtitleRef> cands}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final src = VideoSource(
    url: 'http://x/ep1.m3u8',
    quality: '720p',
    subtitleCandidates: cands,
  );
  // ScaffoldMessenger precisa de Scaffold; o card pede mensagens.
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          AiSubtitleCard(
            anime: _anime(),
            episode: const CatalogEpisode(number: 1),
            episodeIndex: 0,
            episodeList: const [CatalogEpisode(number: 1)],
            provider: AnimeSource.animeFire,
            sources: [src],
          ),
        ],
      ),
    ),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorage.init();
    await SettingsService.instance.init();
    SubtitleJobManager.instance.lastCrashHint = null;
    // path_provider mockado p/ o AiProviders ler o root de modelos vazio.
    final tmp = await Directory.systemTemp.createTemp('card_models');
    addTearDown(() => tmp.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  testWidgets('0 candidatas → rota transcrição (Voz visível)', (tester) async {
    await _pump(tester, cands: const []);
    await tester.pump();
    expect(
        find.text('Nenhuma candidata EN/ES · rota: gerar do áudio japonês'),
        findsOneWidget);
    expect(find.text('Voz Whisper tiny'), findsOneWidget);
    expect(find.text('Tradução LFM 1.2B IQ3_M'), findsOneWidget);
    expect(find.text('Gerar legenda'), findsOneWidget);
  });

  testWidgets('1 candidata EN → rota tradução (Voz escondida)', (tester) async {
    const c = SubtitleRef(label: 'en', lang: 'en', uri: 'http://x/ep1.en.srt');
    await _pump(tester, cands: const [c]);
    await tester.pump();
    expect(find.text('1 candidata(s) EN/ES na fonte · rota: traduzir'),
        findsOneWidget);
    expect(find.textContaining('Voz '), findsNothing);
  });
}
