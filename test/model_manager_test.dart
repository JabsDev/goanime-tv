import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/model_manager.dart';

void main() {
  group('Catálogo HF', () {
    test('toda entrada tem repo + arquivos paralelos + URL válida', () {
      expect(aiModelCatalog, isNotEmpty);
      for (final spec in aiModelCatalog.values) {
        expect(spec.repo.contains('/'), isTrue, reason: spec.id);
        expect(spec.remoteFiles.length, spec.files.length,
            reason: spec.id);
        for (final r in spec.remoteFiles) {
          final url = spec.fileUrl(r);
          expect(url.startsWith('https://huggingface.co/'), isTrue);
          expect(url.contains('/resolve/main/'), isTrue);
        }
      }
    });

    test('GGUF Hy-MT2 auto-contido (1 arquivo → model.gguf)', () {
      for (final id in [
        'hymt-ja-pt-q4',
        'hymt-ja-pt-manga-v3',
      ]) {
        final spec = aiModelCatalog[id]!;
        expect(spec.files, ['model.gguf']);
        expect(spec.remoteFiles.single.endsWith('.gguf'), isTrue);
      }
    });

    test('catálogo podado: tiers baixos fora (Fase 1)', () {
      for (final id in [
        'whisper-tiny-ja',
        'whisper-base',
        'whisper-small',
        'anime-whisper-ja',
        'hymt-ja-pt-q3km',
        'lfm12b-ja-pt-iq3m',
        'qwen06-ja-pt-q4',
        'qwen06-ja-pt-anime-q4',
        'lmt60-ja-pt-q4km',
      ]) {
        expect(aiModelCatalog.containsKey(id), isFalse, reason: id);
      }
    });
  });

  group('ModelManager.isValidGguf', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('gguf'));
    tearDown(() async => tmp.delete(recursive: true));

    Future<File> gguf(String name, List<int> head, {int? size}) async {
      final f = File('${tmp.path}/$name');
      final raf = await f.open(mode: FileMode.write);
      await raf.writeFrom(head);
      if (size != null) await raf.truncate(size);
      await raf.close();
      return f;
    }

    test('inexistente é inválido', () async {
      expect(await ModelManager.isValidGguf(File('${tmp.path}/x.gguf'), 1),
          isFalse);
    });

    test('pequeno ou magic errado é inválido', () async {
      final small = await gguf('s.gguf', const [0x47, 0x47, 0x55, 0x46],
          size: 10);
      expect(await ModelManager.isValidGguf(small, 1), isFalse);
      final bad =
          await gguf('b.gguf', const [1, 2, 3, 4], size: 2 * 1048576);
      expect(await ModelManager.isValidGguf(bad, 1), isFalse);
    });

    test('magic + tamanho ok é válido', () async {
      final ok = await gguf('ok.gguf', const [0x47, 0x47, 0x55, 0x46],
          size: 2 * 1048576);
      expect(await ModelManager.isValidGguf(ok, 1), isTrue);
    });
  });

  group('ModelManager.downloadModel', () {
    test('recusa sem Wi-Fi antes de qualquer rede', () async {
      const mgr = ModelManager();
      expect(
          () => mgr.downloadModel('hymt-ja-pt-q4',
              connectivityForTest: () async => [ConnectivityResult.mobile]),
          throwsA(isA<ModelDownloadException>()));
    });

    test('aceita ethernet além de Wi-Fi', () async {
      const mgr = ModelManager();
      expect(
          () => mgr.downloadModel('inexistente',
              connectivityForTest: () async => [ConnectivityResult.ethernet]),
          throwsA(isA<ArgumentError>()));
    });

    test('modelo desconhecido falha alto', () async {
      const mgr = ModelManager();
      expect(
          () => mgr.downloadModel('inexistente',
              connectivityForTest: () async => [ConnectivityResult.wifi]),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('ModelManager.fetchFile — queda no meio + resume', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('fetch'));
    tearDown(() async => tmp.delete(recursive: true));

    // Servidor fake: 1ª conexão manda metade do corpo declarado e corta o
    // socket (replica "Connection closed while receiving data" do HF no 4G).
    // 2ª em diante (com Range) manda o resto via 206.
    test('retoma e completa após queda no meio do corpo', () async {
      final body = List<int>.generate(4096, (i) => i & 0xff);
      var reqs = 0;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((sock) {
        sock.listen((data) {
          final req = String.fromCharCodes(data);
          if (!req.contains('\r\n\r\n')) return;
          reqs++;
          final rng = RegExp(r'bytes=(\d+)').firstMatch(req);
          if (reqs == 1) {
            final half = body.sublist(0, body.length ~/ 2);
          sock.add(utf8.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n'));
            sock.add(half);
            sock.destroy(); // queda abrupta antes do tamanho prometido
          } else {
            final start =
                rng == null ? 0 : int.parse(rng.group(1)!);
            final rest = body.sublist(start);
            sock.add(utf8.encode(
                'HTTP/1.1 206 Partial Content\r\n'
                'Content-Length: ${rest.length}\r\n\r\n'));
            sock.add(rest);
            sock.close();
          }
        });
      });
      addTearDown(server.close);
      final dest = File('${tmp.path}/model.bin');
      final out = await ModelManager.fetchFile(
          dest: dest, url: 'http://127.0.0.1:${server.port}/m.bin');
      expect(out, dest);
      expect(await dest.readAsBytes(), body);
      expect(reqs, 2, reason: 'uma queda + uma retomada com Range');
    });
  });

  group('ModelManager.fetchFileParallel — multi-parte por Range', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('fetchp'));
    tearDown(() async => tmp.delete(recursive: true));

    test('baixa em várias conexões e concatena na ordem', () async {
      final body =
          List<int>.generate(10 * 1024 * 1024, (i) => i & 0xff); // 10 MB
      final ranges = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final r = req.headers.value('range');
        if (r == null) {
          req.response.statusCode = 200;
          req.response.headers.contentLength = body.length;
          req.response.add(body);
        } else {
          ranges.add(r);
          final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(r)!;
          final start = int.parse(m.group(1)!);
          final end =
              m.group(2)!.isEmpty ? body.length - 1 : int.parse(m.group(2)!);
          final sub = body.sublist(start, end + 1);
          req.response.statusCode = 206;
          req.response.headers
              .set('Content-Range', 'bytes $start-$end/${body.length}');
          req.response.headers.contentLength = sub.length;
          req.response.add(sub);
        }
        await req.response.close();
      });
      addTearDown(server.close);

      final dest = File('${tmp.path}/v.mp4');
      final out = await ModelManager.fetchFileParallel(
        dest: dest,
        url: 'http://127.0.0.1:${server.port}/v.mp4',
        connections: 3,
        minChunkBytes: 4 * 1024 * 1024,
      );
      expect(out, dest);
      expect(await dest.length(), body.length);
      expect(await dest.readAsBytes(), body,
          reason: 'as partes precisam ser concatenadas na ordem');
      // 1 probe (bytes=0-0) + 3 partes.
      expect(ranges.length, greaterThanOrEqualTo(4));
      expect(File('${dest.path}.parts').existsSync(), isFalse,
          reason: 'diretório de partes deve ser limpo no fim');
    });

    test('servidor sem Range cai no single-connection', () async {
      final body = List<int>.generate(1024 * 1024, (i) => i & 0xff);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        // Ignora Range e devolve 200 com o corpo inteiro.
        req.response.statusCode = 200;
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
      });
      addTearDown(server.close);

      final dest = File('${tmp.path}/v2.mp4');
      final out = await ModelManager.fetchFileParallel(
          dest: dest, url: 'http://127.0.0.1:${server.port}/v2.mp4');
      expect(await dest.length(), body.length);
      expect(out, dest);
    });
  });
}
