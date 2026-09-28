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
        'hymt-ja-pt-q3km',
        'hymt-ja-pt-q4',
        'hymt-ja-pt-iq3m',
        'lfm12b-ja-pt-iq3m',
        'qwen06-ja-pt-q4'
      ]) {
        final spec = aiModelCatalog[id]!;
        expect(spec.files, ['model.gguf']);
        expect(spec.remoteFiles.single.endsWith('.gguf'), isTrue);
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
          () => mgr.downloadModel('hymt-ja-pt-q3km',
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
}
