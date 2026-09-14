import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import 'mt_provider.dart';
import 'srt_parser.dart';

/// Vocabulário Helsinki-NLP `vocab.yml` (`"▁hello": 123`).
/// ponytail: parse manual de `token: id` (~15 linhas), sem dep yaml.
class MarianVocab {
  final Map<String, int> tokenToId;
  late final List<String> idToToken;
  late final int bosId;
  late final int eosId;
  late final int unkId;

  MarianVocab(this.tokenToId) {
    idToToken = List.filled(tokenToId.length, '<unk>');
    tokenToId.forEach((tok, id) {
      if (id >= 0 && id < idToToken.length) idToToken[id] = tok;
    });
    bosId = tokenToId['<s>'] ?? tokenToId['<pad>'] ?? 0;
    eosId = tokenToId['</s>'] ?? 1;
    unkId = tokenToId['<unk>'] ?? 3;
  }

  static final _line = RegExp(r'''^"((?:[^"\\]|\\.)*)":\s*(\d+)\s*$''');

  static MarianVocab parse(String yml) {
    final map = <String, int>{};
    for (final raw in yml.split('\n')) {
      final m = _line.firstMatch(raw.trim());
      if (m == null) continue;
      map[m.group(1)!.replaceAll(r'\"', '"').replaceAll(r'\\', r'\')] =
          int.parse(m.group(2)!);
    }
    if (map.isEmpty) throw const FormatException('vocab.yml vazio');
    return MarianVocab(map);
  }

  /// Vocab Xenova/HF `vocab.json` (`{token: id}`; peças ▁ como no yml).
  static MarianVocab fromPieces(Map<String, dynamic> json) {
    final map = <String, int>{};
    json.forEach((k, v) {
      final id = v is int ? v : int.tryParse(v.toString());
      if (id != null) map[k] = id;
    });
    if (map.isEmpty) throw const FormatException('vocab.json vazio');
    return MarianVocab(map);
  }

  /// Encode greedy longest-match (Marian ▁ marca início de palavra).
  List<int> encode(String text) {
    final out = <int>[];
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      var rest = '▁$word';
      while (rest.isNotEmpty) {
        var hit = -1;
        var len = 0;
        for (var l = rest.length; l > 0; l--) {
          final id = tokenToId[rest.substring(0, l)];
          if (id != null) {
            hit = id;
            len = l;
            break;
          }
        }
        out.add(hit >= 0 ? hit : unkId);
        rest = hit >= 0 ? rest.substring(len) : rest.substring(1);
      }
    }
    return out;
  }

  String decode(List<int> ids) {
    final sb = StringBuffer();
    for (final id in ids) {
      if (id == bosId || id == eosId) continue;
      final t = (id >= 0 && id < idToToken.length) ? idToToken[id] : '<unk>';
      sb.write(t.startsWith('▁') ? ' ${t.substring(1)}' : t);
    }
    return sb
        .toString()
        .trim()
        .replaceAll(RegExp(r'\s+([.,!?;:…%)])'), r'$1')
        .replaceAll(' <unk>', '�');
  }
}

/// Passo de inferência (encoder 1x + decoder por prefixo). Interface p/ teste
/// sem nativo; produção = [OrtMarianSession].
abstract class MarianSession {
  Future<List<double>> stepLogits(List<int> encoderIds, List<int> decoderIds);
  Future<void> close();
}

/// Sessão Marian encoder+decoder via onnxruntime (beam 1 = greedy).
/// Modelos: export optimum (`encoder_model.onnx`, `decoder_model.onnx`,
/// int8) + `vocab.yml` Helsinki na pasta do modelo.
/// Nomes de input/output descobertos por posição (1º IO), tolerando exports.
class OrtMarianSession implements MarianSession {
  final String modelDir;
  OrtSession? _enc;
  OrtSession? _dec;

  OrtMarianSession(this.modelDir);

  void _open() {
    if (_enc != null) return;
    final opts = OrtSessionOptions()..setIntraOpNumThreads(2);
    _enc = OrtSession.fromFile(File('$modelDir/encoder_model.onnx'), opts);
    _dec = OrtSession.fromFile(File('$modelDir/decoder_model.onnx'), opts);
  }

  @override
  Future<List<double>> stepLogits(
      List<int> encoderIds, List<int> decoderIds) async {
    _open();
    final enc = _enc!;
    final dec = _dec!;
    final n = encoderIds.length;
    final m = decoderIds.length;
    final encOut = enc.run(
      OrtRunOptions(),
      {
        enc.inputNames[0]: OrtValueTensor.createTensorWithDataList(
            Int64List.fromList(encoderIds), [1, n]),
        enc.inputNames[1]: OrtValueTensor.createTensorWithDataList(
            Int64List.fromList(List.filled(n, 1)), [1, n]),
      },
      [enc.outputNames[0]],
    );
    final hidden = (encOut[0] as OrtValueTensor).value as List;
    final flatHidden = hidden
        .expand((e) => (e as List).expand((x) => (x as List).cast<double>()))
        .toList();
    final h = flatHidden.length ~/ n;
    final decOut = dec.run(
      OrtRunOptions(),
      {
        dec.inputNames[0]: OrtValueTensor.createTensorWithDataList(
            Int64List.fromList(decoderIds), [1, m]),
        dec.inputNames[1]: OrtValueTensor.createTensorWithDataList(
            Float32List.fromList(flatHidden), [1, n, h]),
        dec.inputNames[2]: OrtValueTensor.createTensorWithDataList(
            Int64List.fromList(List.filled(n, 1)), [1, n]),
      },
      [dec.outputNames[0]],
    );
    final logits = (decOut[0] as OrtValueTensor).value as List;
    // última posição: [1, m, V] -> [V]
    final last = (logits[0] as List)[m - 1] as List;
    return last.map((e) => (e as num).toDouble()).toList();
  }

  @override
  Future<void> close() async {
    _enc?.release();
    _dec?.release();
    _enc = null;
    _dec = null;
  }
}

/// Tradução EN/ES→PT greeted greedy, chunk por frase (≤64 tokens).
/// Carga sequencial: [dispose] antes de subir outro provider.
/// `targetPrefix`: modelos multilíngues exigem token de alvo na entrada
/// (ex. `>>por<<` no opus-mt-en-mul); null = Helsinki unidirecional.
class MarianMtProvider extends MtProvider {
  final String modelDir;
  final MarianSession? sessionForTest;
  final String? vocabForTest;
  final String? targetPrefix;
  MarianVocab? _vocab;
  MarianSession? _session;

  MarianMtProvider(this.modelDir,
      {this.sessionForTest, this.vocabForTest, this.targetPrefix});

  @override
  String get id => 'marian';

  @override
  Future<void> load() async {
    final raw = vocabForTest ?? await File('$modelDir/vocab.json').readAsString().catchError(
        (_) => File('$modelDir/vocab.yml').readAsString());
    _vocab = raw.trimLeft().startsWith('{')
        ? MarianVocab.fromPieces(jsonDecode(raw) as Map<String, dynamic>)
        : MarianVocab.parse(raw);
    _session = sessionForTest ?? OrtMarianSession(modelDir);
  }

  static final _sentSplit = RegExp(r'(?<=[.!?…])\s+');

  @override
  Future<String> translate(String text,
      {required String src, required String tgt}) async {
    final vocab = _vocab;
    final session = _session;
    if (vocab == null || session == null) {
      throw StateError('MarianMtProvider.load() antes de translate()');
    }
    final parts = text.split(_sentSplit).where((s) => s.trim().isNotEmpty);
    final out = <String>[];
    final prefixId =
        targetPrefix != null ? vocab.tokenToId[targetPrefix] : null;
    for (final p in parts) {
      var ids = vocab.encode(p.trim());
      if (ids.length > 62) ids = ids.sublist(0, 62); // ponytail: trunca, não re-chunka
      if (prefixId != null) ids = [prefixId, ...ids];
      out.add(vocab.decode(await _greedy(vocab, session, ids)));
    }
    return out.join(' ');
  }

  Future<List<int>> _greedy(
      MarianVocab vocab, MarianSession session, List<int> enc) async {
    final dec = <int>[vocab.bosId];
    for (var i = 0; i < 128; i++) {
      final logits = await session.stepLogits(enc, dec);
      var best = 0;
      var bestV = logits[0];
      for (var k = 1; k < logits.length; k++) {
        if (logits[k] > bestV) {
          bestV = logits[k];
          best = k;
        }
      }
      if (best == vocab.eosId) break;
      dec.add(best);
    }
    return dec;
  }

  @override
  Future<void> dispose() async {
    await _session?.close();
    _session = null;
    _vocab = null;
  }

  /// Cache hit não retraduz (Rota S): traduz o .srt fonte e salva via store.
  Future<String> translateSrt(String srcSrt,
      {required String src, required String tgt}) async {
    final cues = SrtParser.parse(srcSrt);
    return SrtParser.format(
        await translateCues(cues, src: src, tgt: tgt));
  }
}
