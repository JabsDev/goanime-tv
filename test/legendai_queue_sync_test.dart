import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/subtitles/legendai/legendai_connection.dart';
import 'package:goanime_tv/core/subtitles/legendai/legendai_protocol.dart';
import 'package:goanime_tv/core/subtitles/legendai/legendai_queue_sync.dart';
import 'package:goanime_tv/core/subtitles/subtitle_store.dart';

/// Servidor LegendAI fake em memória (MockClient) — replica idempotência,
/// estados e `/srt` (202→200).
class FakeServer {
  final jobs = <String, Map<String, dynamic>>{};
  int creates = 0;
  int _n = 0;

  void setState(
    String id,
    String state, {
    String? step,
    int pct = 0,
    Map<String, dynamic>? summary,
  }) {
    final j = jobs[id]!;
    j['state'] = state;
    j['step'] = step;
    j['pct'] = pct;
    if (summary != null) j['summary'] = summary;
    j['updated_ms'] = (_n + 1) * 1000;
  }

  MockClient client() => MockClient((req) async {
    final path = req.url.path;
    if (path == '/v1/info') {
      return _json({
        'name': 'PC-Jabs',
        'host': '127.0.0.1',
        'port': 8765,
        'protocol': 1,
        'version': '0.2.0',
        'url': 'http://127.0.0.1:8765',
      });
    }
    if (path == '/v1/health') {
      return _json({
        'app': 'legendai',
        'version': '0.2.0',
        'protocol': 1,
        'name': 'PC-Jabs',
        'tier': 'Tier2',
        'gpu': true,
        'busy': 0,
        'queue': jobs.length,
        'models': {'stt': 'a', 'translation': 'b'},
      });
    }
    if (path == '/v1/uploads' && req.method == 'POST') {
      return _json({
        'upload_id': 'upload-${_n++}',
        'bytes': req.bodyBytes.length,
      }, 201);
    }
    if (path == '/v1/jobs' && req.method == 'GET') {
      return _json(jobs.values.toList());
    }
    if (path == '/v1/jobs' && req.method == 'POST') {
      creates++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final cid = body['client_job_id'] as String?;
      for (final existing in jobs.values) {
        if (existing['client_job_id'] == cid) {
          return _json(existing, 202);
        }
      }
      final id = 'job-${_n++}';
      final item = <String, dynamic>{
        'job_id': id,
        'client_job_id': cid,
        'anime_key': body['anime_key'],
        'episode': body['episode'],
        'state': 'pending',
        'step': null,
        'pct': 0,
        'detail': null,
        'origin': 'remote',
        'created_ms': 1000,
        'updated_ms': 1000,
      };
      jobs[id] = item;
      return _json(item, 202);
    }
    final srtMatch = RegExp(r'^/v1/jobs/([^/]+)/srt$').firstMatch(path);
    if (srtMatch != null) {
      final id = srtMatch.group(1)!;
      final j = jobs[id];
      if (j == null) return _json({'code': 'not_found'}, 404);
      if (j['state'] == 'done') {
        return http.Response(
          '1\n00:00:01,000 --> 00:00:02,000\nOlá PC\n',
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      }
      if (j['state'] == 'error') {
        return _json({'code': 'no_speech', 'message': 'sem fala'}, 409);
      }
      return _json(j, 202);
    }
    final cancelMatch = RegExp(r'^/v1/jobs/([^/]+)/cancel$').firstMatch(path);
    if (cancelMatch != null) {
      final id = cancelMatch.group(1)!;
      if (jobs[id] == null) return _json({'code': 'not_found'}, 404);
      jobs[id]!['state'] = 'cancelled';
      return _json({'ok': true});
    }
    final deleteMatch = RegExp(r'^/v1/jobs/([^/]+)$').firstMatch(path);
    if (deleteMatch != null && req.method == 'DELETE') {
      jobs.remove(deleteMatch.group(1));
      return http.Response('', 204);
    }
    return http.Response('not found', 404);
  });

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory subsTmp;
  late FakeServer server;
  late LegendAiQueueSync sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorage.init();
    await SettingsService.instance.init();
    tmp = await Directory.systemTemp.createTemp('legendai_store');
    subsTmp = await Directory.systemTemp.createTemp('legendai_subs');
    server = FakeServer();
    final conn = LegendAiConnection.instance;
    conn.debugUseClient(null);
    await conn.disconnect();
    conn.debugUseClient(server.client());
    await conn.saveAndConnect(host: '127.0.0.1', port: 8765);
    sync = LegendAiQueueSync(
      connection: conn,
      storeDirForTest: tmp,
      subsDirForTest: subsTmp,
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(() async {
      await sync.flush();
      sync.dispose();
      await tmp.delete(recursive: true);
      await subsTmp.delete(recursive: true);
      LegendAiConnection.instance.debugUseClient(null);
      await LegendAiConnection.instance.disconnect();
    });
    await sync.init();
  });

  test('submit enfileira e reenvio é idempotente', () async {
    final r1 = await sync.submit(
      animeKey: 'Bocchi',
      episode: 1,
      url: 'https://cdn/a.m3u8',
    );
    await pumpEventQueue();
    expect(r1, isNotNull);
    expect(server.creates, 1);
    expect(sync.jobs.value, hasLength(1));
    expect(sync.jobs.value.first.state, LegendAiState.pending);

    final r2 = await sync.submit(
      animeKey: 'Bocchi',
      episode: 1,
      url: 'https://cdn/a.m3u8',
    );
    expect(r2!.jobId, r1!.jobId);
    expect(server.creates, 1, reason: 'não pode duplicar no PC');
  });

  test(
    'refresh funde running→done e baixa o SRT para o SubtitleStore',
    () async {
      final r = await sync.submit(
        animeKey: 'Bocchi',
        episode: 1,
        url: 'https://cdn/a.m3u8',
      );
      await pumpEventQueue();
      final id = r!.jobId;

      server.setState(id, 'running', step: 'transcribe', pct: 50);
      await sync.refresh();
      expect(sync.jobById(id)!.state, LegendAiState.running);

      server.setState(
        id,
        'done',
        summary: {
          'duration_secs': 100.0,
          'segments': 7,
          'source_lang': 'ja',
          'target_lang': 'pt',
          'srt_bytes': 25,
          'eta_secs': null,
        },
      );
      await sync.refresh();

      final job = sync.jobById(id)!;
      expect(job.state, LegendAiState.done);
      expect(job.downloaded, isTrue);

      final file = await SubtitleStore.get(
        animeKey: 'Bocchi',
        ep: 1,
        tag: 'ja-ai',
        srcHash: SubtitleStore.sha256Of('https://cdn/a.m3u8'),
        subsDirForTest: subsTmp,
      );
      expect(file, isNotNull, reason: 'SRT remoto precisa ser salvo local');
      expect(await file!.readAsString(), contains('Olá PC'));
    },
  );

  test('job que some do PC vira erro reenviável', () async {
    final r = await sync.submit(
      animeKey: 'Bocchi',
      episode: 2,
      url: 'https://cdn/b.m3u8',
    );
    await pumpEventQueue();
    server.jobs.clear();
    await sync.refresh();
    final job = sync.jobById(r!.jobId)!;
    expect(job.state, LegendAiState.error);
    expect(job.error!.code, 'lost_on_pc');
  });

  test('cancel de item em execução chama /cancel', () async {
    final r = await sync.submit(
      animeKey: 'Bocchi',
      episode: 3,
      url: 'https://cdn/c.m3u8',
    );
    await pumpEventQueue();
    server.setState(r!.jobId, 'running', step: 'translate', pct: 80);
    await sync.refresh();
    final job = sync.jobById(r.jobId)!;
    await sync.cancel(job);
    expect(server.jobs[r.jobId]!['state'], 'cancelled');
  });

  test('espelho persiste e recarrega do disco', () async {
    await sync.submit(
      animeKey: 'Bocchi',
      episode: 4,
      url: 'https://cdn/d.m3u8',
    );
    await pumpEventQueue();
    await sync.flush(); // deixa o write do JSON terminar

    final sync2 = LegendAiQueueSync(
      connection: LegendAiConnection.instance,
      storeDirForTest: tmp,
      subsDirForTest: subsTmp,
    );
    addTearDown(sync2.dispose);
    await sync2.init();
    expect(sync2.jobs.value, hasLength(1));
    expect(sync2.jobs.value.first.animeKey, 'Bocchi');
    expect(sync2.jobs.value.first.episode, 4);
  });

  test('clientJobIdFor é estável e seguro', () {
    expect(
      LegendAiQueueSync.clientJobIdFor('Bocchi:Rock', 1),
      'goanime:Bocchi_Rock:1',
    );
    expect(
      LegendAiQueueSync.clientJobIdFor('X', 2),
      LegendAiQueueSync.clientJobIdFor('X', 2),
    );
    // Fase 5: a rota entra como sufixo (srt/upload), sem quebrar o id histórico.
    expect(
      LegendAiQueueSync.clientJobIdFor('X', 2, kind: 'srt-en'),
      'goanime:X:2:srt-en',
    );
    expect(
      LegendAiQueueSync.clientJobIdFor('X', 2, kind: 'upload'),
      'goanime:X:2:upload',
    );
  });

  test('submitSrt enfileira a rota S com id por idioma e tag', () async {
    final r = await sync.submitSrt(
      animeKey: 'Bocchi',
      episode: 5,
      srt: '1\n00:00:01,000 --> 00:00:02,000\nHello\n',
      sourceLang: 'en',
      tag: 'en-ai',
    );
    await pumpEventQueue();
    expect(r, isNotNull);
    expect(server.creates, 1);
    expect(sync.jobs.value.first.clientJobId, 'goanime:Bocchi:5:srt-en');
    expect(sync.jobs.value.first.tag, 'en-ai');
    // Reenvio idempotente pelo mesmo idioma não duplica.
    final r2 = await sync.submitSrt(
      animeKey: 'Bocchi',
      episode: 5,
      srt: 'outro',
      sourceLang: 'en',
    );
    expect(r2!.jobId, r!.jobId);
    expect(server.creates, 1);
  });

  test('submitUpload envia o áudio e enfileira a rota upload', () async {
    final audio = File('${tmp.path}/audio.pcm');
    await audio.writeAsBytes(List<int>.generate(2048, (i) => i % 256));
    final r = await sync.submitUpload(
      animeKey: 'Bocchi',
      episode: 6,
      audioFile: audio,
    );
    await pumpEventQueue();
    expect(r, isNotNull);
    expect(sync.jobs.value.first.clientJobId, 'goanime:Bocchi:6:upload');
    expect(sync.jobs.value.first.tag, 'ja-ai');
  });

  test('jobForEpisode encontra qualquer rota do episódio', () async {
    await sync.submitSrt(
      animeKey: 'X',
      episode: 7,
      srt: '1\n00:00:01,000 --> 00:00:02,000\nHola\n',
      sourceLang: 'es',
      tag: 'es-ai',
    );
    await pumpEventQueue();
    expect(sync.jobForEpisode('X', 7), isNotNull);
    expect(sync.jobForEpisode('X', 8), isNull);
    // O id exato da rota continua resolvendo por clientJobId.
    expect(
      sync.jobForClientId('goanime:X:7:srt-es'),
      isNotNull,
    );
  });
}
