import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/device_capability.dart';
import 'mt_provider.dart';
import 'sherpa_stt.dart';
import 'srt_parser.dart';

/// Canal do STT whisper-ja-anime-v0.3 (Kotlin → ORT embarcado). Abstrato p/
/// teste sem nativo; devolve CSV de ids de tokens (detokenização é no Dart).
abstract class Jav03Channel {
  /// [modelDir] tem os 3 grafos + tokens.txt; [files] = [mel, encoder, decoder].
  /// [audio] = PCM 16 kHz mono. [promptIds] = [sot, lang, task, nots, eot].
  Future<String> decode(
      String modelDir, List<String> files, Float32List audio, List<int> promptIds);
  Future<void> dispose();
}

class MethodJav03Channel implements Jav03Channel {
  static const _ch = MethodChannel('goanime/jav03_stt');

  /// [threads]: intra-op do ORT (default 4; o edge 30 tem 6 cores).
  int threads = 4;

  @override
  Future<String> decode(String modelDir, List<String> files,
      Float32List audio, List<int> promptIds) async {
    final out = await _ch.invokeMethod<String>('decode', {
      'modelDir': modelDir,
      'files': files,
      'threads': threads,
      'promptIds': promptIds,
      // MethodChannel transporta Float32List como float[] no Android.
      'audio': audio,
    });
    return out ?? '';
  }

  @override
  Future<void> dispose() => _ch.invokeMethod('dispose');
}

/// Detokenizador byte-level BPE do v0.3. Carrega `tokens.txt` (1 token por id,
/// 20480 linhas) e o mapa bytes→unicode do GPT-2 (calculado em runtime).
///
/// Armadilha do relatório §6.4: sem o decodificador byte-level, kanji vêm como
/// bytes UTF-8 mapeados e a saída é mojibake (CER 292%). Aqui o mapa é aplicado
/// de verdade.
class Jav03Tokenizer {
  final List<String> _tokens;
  final Map<int, int> _unicodeToByte; // codepoint do char do vocab -> byte

  /// Primeiro id especial. NO v0.3 e' 18871 (vocab 20480); no whisper pequeno
  /// e' 50257 (.vocab 51865). Hardcodar quebrava o student (o id 19000 eh um
  /// token NORMAL la e era descartado -> delecao massiva).
  final int specialStart;
  Jav03Tokenizer._(this._tokens, this._unicodeToByte, this.specialStart);

  static Future<Jav03Tokenizer> load(String tokensTxtPath) async {
    final lines = await File(tokensTxtPath).readAsLines();
    // Índice = id; arquivo do sherpa tem uma linha por id (inclui especiais).
    final tokens = List<String>.generate(lines.length, (i) => lines[i]);
    return Jav03Tokenizer._(tokens, _buildUnicodeToByte(), _specialFrom(tokens));
  }

  /// Descobre o primeiro id especial lendo o final do vocab do whisper: os
  /// tokens byte-level do GPT-2 sao os primeiros; os especiais (eot, sot,
  /// <|ja|>...) vem depois. O representante e' o `   ` do GPT-2 eno meio.
  static int _specialFrom(List<String> tokens) {
    // O small (multilingue) tem 51865 linhas: specials a partir de 50257.
    // O v0.3 (retreinado) tem 20480: specials a partir de 18871.
    // Heuristica robusta: o token <|startoftranscript|> esta' no arquivo
    // literal se ele existir; e' o primeiro especial.
    final i = tokens.indexOf('<|startoftranscript|>');
    return i >= 0 ? i : 50257;
  }

  /// Mapa reverso do GPT-2 byte encoder (bytes_to_unicode()).
  static Map<int, int> _buildUnicodeToByte() {
    final bs = <int>[
      ...List<int>.generate(0x7E - 0x21 + 1, (i) => 0x21 + i), // '!'..'~'
      ...List<int>.generate(0xAC - 0xA1 + 1, (i) => 0xA1 + i), // '¡'..'¬'
      ...List<int>.generate(0xFF - 0xAE + 1, (i) => 0xAE + i), // '®'..'ÿ'
    ];
    final cs = <int>[...bs];
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    final map = <int, int>{};
    for (var i = 0; i < bs.length; i++) {
      map[cs[i]] = bs[i];
    }
    return map;
  }


  /// CSV de ids → texto. Ignora especiais (>= specialStart) e aplica o byte map.
  String detokenizeCsv(String csv) {
    if (csv.isEmpty) return '';
    final bytes = <int>[];
    for (final part in csv.split(',')) {
      final id = int.tryParse(part);
      if (id == null || id < 0 || id >= _tokens.length) continue;
      if (id >= specialStart) continue;
      for (final cu in _tokens[id].codeUnits) {
        final b = _unicodeToByte[cu];
        if (b != null) bytes.add(b);
      }
    }
    return utf8.decode(bytes, allowMalformed: true).trim();
  }

  /// Variante p/ teste: lista de ids.
  @visibleForTesting
  String detokenizeIds(List<int> ids) => detokenizeCsv(ids.join(','));
}

/// Engine STT: segmenta com o VAD do sherpa (código já testado) e decodifica
/// pelo canal jav03 (ORT embarcado). Reusa [SherpaSttEngine] para o VAD.
class Jav03SttEngine implements SttEngine {
  final Jav03Channel? channelForTest;
  final SttEngine? segmenterForTest;

  /// [sot, lang, task, notimestamps, eot] do modelo. Default = v0.3;
  /// o student treinado usa os ids do whisper pequeno.
  final List<int> promptIds;

  /// Nomes dos arquivos na pasta do modelo. Default = export optimum (v0.3);
  /// o student exportado pelo sherpa usa encoder.int8/decoder.int8/mel.onnx.
  final List<String> files;
  Jav03Channel? _ch;
  SttEngine? _segmenter;
  Jav03Tokenizer? _tok;
  String _modelDir = '';

  Jav03SttEngine(
      {this.channelForTest,
      this.segmenterForTest,
      this.promptIds = const [18872, 18880, 18974, 18978, 18871],
      this.files = const [
        'mel.onnx',
        'encoder_model.int8.onnx',
        'decoder_model.fp16.onnx',
      ]});

  @override
  Future<void> init(String modelDir,
      {required String task, int threads = 2}) async {
    _modelDir = modelDir;
    // Exige os 3 grafos + tokens.txt (guard anti-crash nativo, padrão sherpa).
    for (final f in [...files, 'tokens.txt']) {
      if (!await File('$modelDir/$f').exists()) {
        throw StateError('Modelo de voz incompleto (falta $f). Baixe de novo.');
      }
    }
    _tok = await Jav03Tokenizer.load('$modelDir/tokens.txt');
    _ch = channelForTest ?? MethodJav03Channel();
    // Segmentação (VAD) reusa o engine sherpa: mesmo isolate e mesmos
    // parâmetros afinados p/ anime. O decode é 100% pelo canal jav03.
    _segmenter = segmenterForTest ?? SherpaSttEngine(vadOnly: true);
    await _segmenter!.init(modelDir, task: task, threads: threads);
  }

  @override
  Future<List<SpeechChunk>> segments(Float32List pcm) async {
    final seg = _segmenter;
    if (seg == null) throw StateError('SttEngine.init() antes de segments()');
    return seg.segments(pcm);
  }

  @override
  Future<String> decode(SpeechChunk chunk) async {
    final ch = _ch;
    final tok = _tok;
    if (ch == null || tok == null) {
      throw StateError('SttEngine.init() antes de decode()');
    }
    final csv = await ch.decode(_modelDir, files, chunk.samples, promptIds);
    return tok.detokenizeCsv(csv);
  }

  @override
  Future<void> free() async {
    await _ch?.dispose();
    await _segmenter?.free();
    _ch = null;
    _segmenter = null;
    _tok = null;
  }
}

/// Provider STT pelo motor ORT (v0.3 ou student destilado). Mesma
/// orquestração do [SherpaSttProvider] (slices de 60 s, progresso,
/// cancelamento, filtros de pausa/ruído) — só troca o engine.
class Jav03SttProvider extends SttProvider {
  final String modelDir;
  final SttEngine? engineForTest;
  final String task;
  final List<int> promptIds;
  final List<String> files;
  final String providerId;
  SttEngine? _engine;

  Jav03SttProvider(this.modelDir,
      {this.task = 'transcribe',
      this.engineForTest,
      this.promptIds = const [18872, 18880, 18974, 18978, 18871],
      this.files = const [
        'mel.onnx',
        'encoder_model.int8.onnx',
        'decoder_model.fp16.onnx',
      ],
      this.providerId = 'whisper-ja-anime-v03'});

  @override
  String get id => providerId;

  @override
  Future<void> load() async {
    _engine = engineForTest ??
        Jav03SttEngine(promptIds: promptIds, files: files);
    final low = await DeviceCapability.isLowEnd();
    await _engine!.init(modelDir, task: task, threads: low ? 1 : 2);
  }

  @override
  Future<List<SrtCue>> transcribe(String pcm16kPath,
      {void Function(double progress)? onProgress,
      bool Function()? isCancelled}) async {
    final engine = _engine;
    if (engine == null) throw StateError('Jav03SttProvider.load() antes');
    const sr = 16000;
    const sliceSec = 60;
    final file = File(pcm16kPath);
    final totalBytes = await file.length();
    final totalSamples = totalBytes ~/ 2;
    debugPrint('[Jav03Stt] pcm totalSamples=$totalSamples '
        '(${(totalSamples / sr).toStringAsFixed(1)}s)');
    final raf = await file.open();
    try {
      final cues = <SrtCue>[];
      var done = 0;
      while (done < totalSamples) {
        if (isCancelled?.call() ?? false) return cues;
        final n = (totalSamples - done).clamp(0, sliceSec * sr);
        final bytes = await raf.read(n * 2);
        final shorts = bytes.buffer.asInt16List();
        final pcm = Float32List(shorts.length);
        for (var i = 0; i < shorts.length; i++) {
          pcm[i] = shorts[i] / 32768.0;
        }
        final baseSec = done / sr;
        final chunks = await engine.segments(pcm);
        chunks.sort((a, b) => a.startSec.compareTo(b.startSec));
        debugPrint('[Jav03Stt] slice base=${baseSec.toStringAsFixed(0)}s '
            'chunks=${chunks.length}');
        for (final chunk in chunks) {
          if (isCancelled?.call() ?? false) return cues;
          final text = await engine.decode(chunk);
          final start = baseSec + chunk.startSec;
          final end = start + chunk.samples.length / sr;
          final short = text.replaceAll('\n', ' ');
          debugPrint('[Jav03Stt] seg ${start.toStringAsFixed(1)}-'
              '${end.toStringAsFixed(1)}s '
              '${chunk.fallback ? '[fb] ' : ''}"'
              '${short.length > 60 ? short.substring(0, 60) : short}"');
          if (text.trim().isEmpty) continue;
          if (chunk.fallback && looksLikeSttNoise(text)) {
            debugPrint('[Jav03Stt] drop ruído ${start.toStringAsFixed(1)}s');
            continue;
          }
          if (isPauseOnly(text)) {
            debugPrint('[Jav03Stt] drop pausa ${start.toStringAsFixed(1)}s '
                '"$short"');
            continue;
          }
          cues.add(SrtCue(
            index: cues.length + 1,
            start: Duration(milliseconds: (start * 1000).toInt()),
            end: Duration(milliseconds: (end * 1000).toInt()),
            text: text,
          ));
        }
        done += n;
        onProgress?.call(totalSamples == 0 ? 1 : done / totalSamples);
      }
      return cues;
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> dispose() async {
    await _engine?.free();
    _engine = null;
  }
}
