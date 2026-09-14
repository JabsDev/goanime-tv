import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/marian_mt.dart';
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

    test('NLLB sem decoder_merged', () {
      final spec = aiModelCatalog['nllb-600M-int8']!;
      expect(
          spec.remoteFiles.any((f) => f.contains('merged')), isFalse);
      expect(spec.files.any((f) => f.contains('with_past')), isTrue);
    });
  });

  group('ModelManager.downloadModel', () {
    test('recusa sem Wi-Fi antes de qualquer rede', () async {
      const mgr = ModelManager();
      expect(
          () => mgr.downloadModel('marian-en-pt-int8',
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

  group('Marian prefixo de alvo (canal Kotlin)', () {
    test('prefixo >>por<< chega ao canal', () async {
      final ch = _PrefixCapture();
      final mt = MarianMtProvider('unused',
          targetPrefix: '>>por<<', channelForTest: ch);
      await mt.load();
      await mt.translate('Hello', src: 'en', tgt: 'pt');
      expect(ch.seenPrefix, '>>por<<');
      await mt.dispose();
    });
  });
}

class _PrefixCapture implements MarianChannel {
  String? seenPrefix;
  @override
  Future<String> translate(String modelDir, String text,
      {String? targetPrefix}) async {
    seenPrefix = targetPrefix;
    return 'PT';
  }

  @override
  Future<void> dispose() async {}
}
