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
        'lfm12b-ja-pt-iq3m'
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

    test('modelo desconhecido falha alto', () async {
      const mgr = ModelManager();
      expect(
          () => mgr.downloadModel('inexistente',
              connectivityForTest: () async => [ConnectivityResult.wifi]),
          throwsA(isA<ArgumentError>()));
    });
  });
}
