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
      for (final id in ['hymt-ja-pt-q3km', 'hymt-ja-pt-q4']) {
        final spec = aiModelCatalog[id]!;
        expect(spec.files, ['model.gguf']);
        expect(spec.remoteFiles.single.endsWith('.gguf'), isTrue);
      }
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
