import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/legendai/legendai_protocol.dart';

void main() {
  group('LegendAiJob.fromJson', () {
    test('payload completo (running, step, detail)', () {
      final job = LegendAiJob.fromJson({
        'job_id': 'job-1-2',
        'client_job_id': 'goanime:Bocchi:1',
        'anime_key': 'Bocchi',
        'episode': 1,
        'state': 'running',
        'step': 'transcribe',
        'pct': 42,
        'detail': '42% do áudio',
        'origin': 'remote',
        'created_ms': 100,
        'updated_ms': 200,
      });
      expect(job.jobId, 'job-1-2');
      expect(job.clientJobId, 'goanime:Bocchi:1');
      expect(job.animeKey, 'Bocchi');
      expect(job.episode, 1);
      expect(job.state, LegendAiState.running);
      expect(job.step, LegendAiStep.transcribe);
      expect(job.pct, 42);
      expect(job.detail, '42% do áudio');
      expect(job.isActive, isTrue);
      expect(job.isTerminal, isFalse);
    });

    test('campos ausentes ganham defaults seguros', () {
      final job = LegendAiJob.fromJson({'job_id': 'j1'});
      expect(job.jobId, 'j1');
      expect(job.clientJobId, isNull);
      expect(job.state, LegendAiState.unknown);
      expect(job.step, isNull);
      expect(job.pct, 0);
      expect(job.summary, isNull);
      expect(job.error, isNull);
    });

    test('estado/step desconhecidos não derrubam a desserialização', () {
      final job = LegendAiJob.fromJson({
        'job_id': 'j2',
        'state': 'queued_forever',
        'step': 'quantum',
      });
      expect(job.state, LegendAiState.unknown);
      expect(job.step, LegendAiStep.unknown);
      // Estado desconhecido é terminal: evita polling eterno.
      expect(job.isTerminal, isTrue);
    });

    test('item concluído traz summary e erro com hint', () {
      final done = LegendAiJob.fromJson({
        'job_id': 'j3',
        'state': 'done',
        'summary': {
          'duration_secs': 1420.5,
          'segments': 243,
          'source_lang': 'ja',
          'target_lang': 'pt',
          'srt_bytes': 26112,
          'eta_secs': null,
        },
      });
      expect(done.isTerminal, isTrue);
      expect(done.summary!.segments, 243);
      expect(done.summary!.durationSecs, 1420.5);
      expect(done.summary!.srtBytes, 26112);

      final failed = LegendAiJob.fromJson({
        'job_id': 'j4',
        'state': 'error',
        'error': {
          'code': 'no_audio_track',
          'message': 'Vídeo sem faixa de áudio.',
          'hint': 'Tente outra fonte.',
        },
      });
      expect(failed.error!.code, 'no_audio_track');
      expect(failed.error!.hint, 'Tente outra fonte.');
    });
  });

  group('LegendAiJobRequest.toJson', () {
    test('serializa source url + headers + opts', () {
      const req = LegendAiJobRequest(
        clientJobId: 'goanime:X:2',
        animeKey: 'X',
        episode: 2,
        url: 'https://cdn/a.m3u8',
        headers: {'Referer': 'https://animegg.org/'},
        preferredStt: 'whisper-small-q5',
      );
      final json = req.toJson();
      expect(json['client_job_id'], 'goanime:X:2');
      expect(json['anime_key'], 'X');
      expect(json['episode'], 2);
      expect(json['source'], {
        'type': 'url',
        'url': 'https://cdn/a.m3u8',
        'headers': {'Referer': 'https://animegg.org/'},
      });
      expect(json['source_lang'], 'auto');
      expect(json['target_lang'], 'pt');
      expect(json['translate'], isTrue);
      expect(json['preferred_stt'], 'whisper-small-q5');
      expect(json.containsKey('priority'), isFalse);
    });

    test('source srt serializa a rota S remota (Fase 5)', () {
      const req = LegendAiJobRequest(
        clientJobId: 'goanime:X:2:srt-en',
        animeKey: 'X',
        episode: 2,
        srt: '1\n00:00:01,000 --> 00:00:02,000\nHello\n',
        sourceLang: 'en',
      );
      final json = req.toJson();
      expect(json['source']['type'], 'srt');
      expect(json['source']['srt'], contains('Hello'));
      expect(json['source']['source_lang'], 'en');
      expect(json['source_lang'], 'en');
    });

    test('source upload serializa o fallback de áudio (Fase 5)', () {
      const req = LegendAiJobRequest(
        clientJobId: 'goanime:X:2:upload',
        animeKey: 'X',
        episode: 2,
        uploadId: 'upload-1-0',
        uploadFormat: 's16le',
      );
      final json = req.toJson();
      expect(json['source'], {
        'type': 'upload',
        'upload_id': 'upload-1-0',
        'format': 's16le',
      });
    });
  });

  group('LegendAiUpload', () {
    test('parseia a resposta do POST /v1/uploads', () {
      final up = LegendAiUpload.fromJson({
        'upload_id': 'upload-1-2',
        'bytes': 12345,
      });
      expect(up.uploadId, 'upload-1-2');
      expect(up.bytes, 12345);
      // Campos ausentes não quebram.
      expect(LegendAiUpload.fromJson(const {}).uploadId, '');
    });
  });

  group('LegendAiHealth/Info', () {
    test('health parseia modelos e contadores', () {
      final h = LegendAiHealth.fromJson({
        'app': 'legendai',
        'version': '0.2.0',
        'protocol': 1,
        'name': 'PC-Jabs',
        'tier': 'Tier2',
        'gpu': true,
        'busy': 1,
        'queue': 4,
        'models': {'stt': 'whisper-small-q5', 'translation': 'hy-mt2'},
      });
      expect(h.protocol, 1);
      expect(h.name, 'PC-Jabs');
      expect(h.tier, 'Tier2');
      expect(h.gpu, isTrue);
      expect(h.busy, 1);
      expect(h.queue, 4);
      expect(h.models.stt, 'whisper-small-q5');
    });

    test('info parseia url de pareamento', () {
      final i = LegendAiInfo.fromJson({
        'name': 'PC-Jabs',
        'host': '192.168.2.109',
        'port': 8765,
        'protocol': 1,
        'version': '0.2.0',
        'url': 'http://192.168.2.109:8765',
      });
      expect(i.host, '192.168.2.109');
      expect(i.port, 8765);
      expect(i.url, 'http://192.168.2.109:8765');
    });
  });
}
