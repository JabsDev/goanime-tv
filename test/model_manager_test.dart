import 'dart:convert';

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

  group('Marian vocab.json + prefixo', () {
    const vocabJson = {
      '</s>': 0,
      '<unk>': 1,
      '<s>': 2,
      '<pad>': 3,
      '>>por<<': 4,
      '▁Hello': 5,
      '▁Olá': 6,
    };

    test('fromPieces monta encode/decode', () {
      final v = MarianVocab.fromPieces(vocabJson);
      expect(v.encode('Hello'), [5]);
      expect(v.decode([2, 6, 0]), 'Olá');
    });

    test('prefixo >>por<< entra na entrada do encoder', () async {
      List<int>? seenEnc;
      final mt = MarianMtProvider('unused',
          sessionForTest: _CaptureSession((e) => seenEnc = e),
          vocabForTest: jsonEncode(vocabJson),
          targetPrefix: '>>por<<');
      await mt.load();
      await mt.translate('Hello', src: 'en', tgt: 'pt');
      expect(seenEnc?.first, 4); // >>por<<
      await mt.dispose();
    });
  });
}

class _CaptureSession implements MarianSession {
  final void Function(List<int> enc) onStep;
  _CaptureSession(this.onStep);

  @override
  Future<List<double>> stepLogits(
      List<int> encoderIds, List<int> decoderIds) async {
    onStep(encoderIds);
    return List.filled(7, -10.0)..[0] = 10.0; // eos imediato
  }

  @override
  Future<void> close() async {}
}
