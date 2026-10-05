import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:goanime_tv/core/subtitles/legendai/legendai_client.dart';
import 'package:goanime_tv/core/subtitles/legendai/legendai_protocol.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

LegendAiClient _client(
  Future<http.Response> Function(http.Request req) handler,
) => LegendAiClient(
  baseUrl: Uri.parse('http://127.0.0.1:8765'),
  client: MockClient(handler),
);

void main() {
  test('health 200 parseia e checa protocolo', () async {
    final client = _client((req) async {
      expect(req.url.path, '/v1/health');
      return _json({
        'app': 'legendai',
        'version': '0.2.0',
        'protocol': 1,
        'name': 'PC-Jabs',
        'tier': 'Tier2',
        'gpu': true,
        'busy': 0,
        'queue': 1,
        'models': {'stt': 'a', 'translation': 'b'},
      });
    });
    final h = await client.health();
    expect(h.name, 'PC-Jabs');
    expect(h.protocol, 1);
  });

  test('protocolo maior que o suportado é recusado', () async {
    final client = _client(
      (_) async => _json({
        'app': 'legendai',
        'version': '9.0',
        'protocol': 99,
        'name': 'PC',
        'tier': 'Tier3',
        'gpu': false,
        'busy': 0,
        'queue': 0,
        'models': {'stt': 'a', 'translation': 'b'},
      }),
    );
    expect(() => client.health(), throwsA(isA<LegendAiProtocolException>()));
  });

  test('erro do servidor vira LegendAiException com code/hint', () async {
    final client = _client(
      (_) async => _json({
        'code': 'invalid_request',
        'message': 'a URL da fonte está vazia',
        'hint': 'Envie source.url',
      }, 400),
    );
    try {
      await client.createJob(
        const LegendAiJobRequest(clientJobId: 'c', url: ''),
      );
      fail('deveria falhar');
    } on LegendAiException catch (e) {
      expect(e.code, 'invalid_request');
      expect(e.statusCode, 400);
      expect(e.hint, 'Envie source.url');
    }
  });

  test('createJob 202 devolve item pendente', () async {
    final client = _client((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/jobs');
      final body = jsonDecode(req.body) as Map;
      expect(body['source']['type'], 'url');
      return _json({
        'job_id': 'job-1',
        'client_job_id': 'goanime:X:1',
        'state': 'pending',
        'origin': 'remote',
      }, 202);
    });
    final job = await client.createJob(
      const LegendAiJobRequest(
        clientJobId: 'goanime:X:1',
        url: 'https://cdn/a.m3u8',
      ),
    );
    expect(job.jobId, 'job-1');
    expect(job.state, LegendAiState.pending);
  });

  test('listJobs envia since e devolve lista', () async {
    final client = _client((req) async {
      expect(req.url.queryParameters['since'], '123');
      return _json([
        {'job_id': 'a', 'state': 'running', 'pct': 10, 'updated_ms': 500},
        {'job_id': 'b', 'state': 'done'},
      ]);
    });
    final jobs = await client.listJobs(sinceMs: 123);
    expect(jobs, hasLength(2));
    expect(jobs.first.state, LegendAiState.running);
  });

  test('getSrt cobre 200/202/409', () async {
    final ready = _client(
      (_) async => http.Response(
        '1\n00:00:01,000 --> 00:00:02,000\nOlá\n',
        200,
        headers: {'content-type': 'text/plain; charset=utf-8'},
      ),
    );
    final r1 = await ready.getSrt('j1');
    expect(r1.ready, isTrue);
    expect(r1.srt, contains('Olá'));

    final pending = _client(
      (_) async => _json({'job_id': 'j1', 'state': 'running'}, 202),
    );
    final r2 = await pending.getSrt('j1');
    expect(r2.ready, isFalse);
    expect(r2.pending!.state, LegendAiState.running);

    final failed = _client(
      (_) async => _json({
        'code': 'no_speech',
        'message': 'nenhuma fala detectada',
      }, 409),
    );
    final r3 = await failed.getSrt('j1');
    expect(r3.ready, isFalse);
    expect(r3.error!.code, 'no_speech');
  });

  test('uploadAudio envia o corpo binário e reporta progresso', () async {
    final tmp = await Directory.systemTemp.createTemp('legendai_upload');
    addTearDown(() => tmp.delete(recursive: true));
    final file = File('${tmp.path}/audio.pcm');
    await file.writeAsBytes(List<int>.generate(4096, (i) => i % 256));

    var lastSent = 0;
    var lastTotal = 0;
    final client = _client((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/uploads');
      expect(req.headers['content-type'], 'application/octet-stream');
      expect(req.bodyBytes.length, 4096);
      return _json({'upload_id': 'upload-1-0', 'bytes': 4096}, 201);
    });
    final up = await client.uploadAudio(
      file,
      onProgress: (sent, total) {
        lastSent = sent;
        lastTotal = total;
      },
    );
    expect(up.uploadId, 'upload-1-0');
    expect(up.bytes, 4096);
    expect(lastSent, 4096);
    expect(lastTotal, 4096);
  });

  test('endereço inalcançável vira erro amigável de conexão', () async {
    final client = _client(
      (_) async => throw http.ClientException(
        'Connection refused',
        Uri.parse('http://x'),
      ),
    );
    try {
      await client.health();
      fail('deveria falhar');
    } on LegendAiException catch (e) {
      expect(e.isConnectionError, isTrue);
      expect(friendlyLegendAiError(e), contains('alcançar'));
    }
  });
}
