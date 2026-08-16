import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/profile/profile_store.dart';
import 'package:goanime_tv/core/storage/local_storage.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String docs;
  _FakePathProvider(this.docs);
  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('watch_progress_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
    final p = ProfileStore.instance.createLocalProfile('A');
    await ProfileStore.instance.switchProfile(p.id);
    await LocalStorage.init();
  });

  tearDown(() async {
    ProfileStore.instance.resetForTest();
    await tmp.delete(recursive: true);
  });

  test('BUGFIX 75%: abrir ep e sair (saveWatchProgress) NÃO marca assistido',
      () async {
    await LocalStorage.saveWatchProgress(
      animeKey: 'naruto',
      episodeNumber: 4,
      position: const Duration(minutes: 3),
      totalEpisodes: 12,
    );
    final progress = LocalStorage.getWatchProgress('naruto')!;
    expect(progress['watched'], isEmpty, reason: 'sem gate de 75% nada é watachable');
    expect(progress['episode'], 4);
    // minutagem de retomada fica guardada por ep
    expect(LocalStorage.getResumePosition('naruto', 4),
        const Duration(minutes: 3));
  });

  test('retomada por episódio: posições independentes por ep', () async {
    await LocalStorage.saveWatchProgress(
        animeKey: 'naruto',
        episodeNumber: 2,
        position: const Duration(minutes: 10),
        totalEpisodes: 12);
    await LocalStorage.saveWatchProgress(
        animeKey: 'naruto',
        episodeNumber: 5,
        position: const Duration(minutes: 7),
        totalEpisodes: 12);
    expect(LocalStorage.getResumePosition('naruto', 2),
        const Duration(minutes: 10));
    expect(LocalStorage.getResumePosition('naruto', 5),
        const Duration(minutes: 7));
    expect(LocalStorage.getResumePositions('naruto').keys, containsAll([2, 5]));
  });

  test('gate 75%: markEpisodeWatched marca assistido E limpa a retomada do ep',
      () async {
    await LocalStorage.saveWatchProgress(
        animeKey: 'naruto',
        episodeNumber: 2,
        position: const Duration(minutes: 10),
        totalEpisodes: 12);
    await LocalStorage.markEpisodeWatched(
        animeKey: 'naruto', episodeIndex: 2);
    final progress = LocalStorage.getWatchProgress('naruto')!;
    expect(progress['watched'], contains(2));
    expect(LocalStorage.getResumePosition('naruto', 2), isNull);
  });

  test('fallback legado: position do último ep tocado vira retomada', () async {
    // schema antigo: um único last-played (episode+position), sem 'positions'.
    await ProfileStore.instance.setProgress('naruto', {
      'episode': 3,
      'position': 90000,
      'totalEpisodes': 12,
    });
    expect(LocalStorage.getResumePosition('naruto', 3),
        const Duration(milliseconds: 90000));
    expect(LocalStorage.getResumePosition('naruto', 1), isNull);
  });

  test('reconcileWatched (AniList) preserva positions e não perde watched',
      () async {
    // cenário: ep7 parado no meio (positions), watched 6..7 legado.
    await ProfileStore.instance.setProgress('naruto', {
      'positions': {'7': 60000},
      'watched': [6, 7],
      'episode': 7,
      'position': 60000,
      'totalEpisodes': 12,
    });
    await LocalStorage.reconcileWatched(animeKey: 'naruto', progress: 8);
    final progress = LocalStorage.getWatchProgress('naruto')!;
    expect(progress['watched'],
        containsAll([0, 1, 2, 3, 4, 5, 6, 7]));
    // retomada de ep não-assistido sobrevive ao reconcile
    expect(LocalStorage.getResumePositions('naruto')[7], 60000);
  });

  test('saveWatchProgress preserva o conjunto watched existente', () async {
    await LocalStorage.markEpisodeWatched(
        animeKey: 'naruto', episodeIndex: 0);
    await LocalStorage.saveWatchProgress(
        animeKey: 'naruto',
        episodeNumber: 5,
        position: const Duration(minutes: 2),
        totalEpisodes: 12);
    final progress = LocalStorage.getWatchProgress('naruto')!;
    expect(progress['watched'], contains(0));
  });

  test('markEpisodeWatched idempotente: re-marcar não duplica nem quebra pos',
      () async {
    await LocalStorage.saveWatchProgress(
        animeKey: 'naruto',
        episodeNumber: 1,
        position: const Duration(minutes: 10),
        totalEpisodes: 12);
    await LocalStorage.markEpisodeWatched(
        animeKey: 'naruto', episodeIndex: 1);
    await LocalStorage.markEpisodeWatched(
        animeKey: 'naruto', episodeIndex: 1);
    final progress = LocalStorage.getWatchProgress('naruto')!;
    expect(progress['watched'], [1]);
  });

  group('nextContinueIndex', () {
    test('ep em andamento (parado no meio) → retoma ELE MESMO', () {
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 12, watched: {0, 1, 2}, lastPlayedIndex: 4),
        4,
      );
    });

    test('ep concluído (watched) → próximo após o high-water', () {
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 12, watched: {0, 1, 2, 3}, lastPlayedIndex: 3),
        4,
      );
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 12, watched: {0, 1, 2, 3}, lastPlayedIndex: 2),
        4,
      );
    });

    test('sem watched: vira o último tocado (parcial) ou 0', () {
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 12, watched: {}, lastPlayedIndex: 7),
        7,
      );
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 12, watched: {}, lastPlayedIndex: -1),
        0,
      );
    });

    test('watched com gaps: high-water mais longe domina quando último foi visto',
        () {
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 12, watched: {0, 1, 2, 11}, lastPlayedIndex: 2),
        null,
      );
    });

    test('série terminada → null', () {
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 12, watched: {0, 1, 2, 3, 11}, lastPlayedIndex: 11),
        null,
      );
      expect(
        LocalStorage.nextContinueIndex(
            episodeCount: 0, watched: {}, lastPlayedIndex: -1),
        null,
      );
    });
  });

  test('clearResumePosition remove a retomada do ep (map e fallback legado)',
      () async {
    await LocalStorage.saveWatchProgress(
        animeKey: 'naruto',
        episodeNumber: 3,
        position: const Duration(minutes: 9),
        totalEpisodes: 12);
    expect(LocalStorage.getResumePosition('naruto', 3),
        const Duration(minutes: 9));

    await LocalStorage.clearResumePosition(
        animeKey: 'naruto', episodeIndex: 3);
    expect(LocalStorage.getResumePosition('naruto', 3), isNull);

    // fallback legado (schema antigo, position único do last-played)
    await ProfileStore.instance.setProgress('naruto', {
      'episode': 5,
      'position': 60000,
      'totalEpisodes': 12,
    });
    await LocalStorage.clearResumePosition(
        animeKey: 'naruto', episodeIndex: 5);
    expect(LocalStorage.getResumePosition('naruto', 5), isNull);
  });
}