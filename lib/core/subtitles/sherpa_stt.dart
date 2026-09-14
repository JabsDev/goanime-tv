import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'mt_provider.dart';
import 'srt_parser.dart';

/// Trecho de fala com offset (segundos) no PCM original.
class SpeechChunk {
  final double startSec;
  final Float32List samples;
  const SpeechChunk(this.startSec, this.samples);
}

/// Motor STT destacável (teste sem nativo). Produção = [SherpaSttEngine].
abstract class SttEngine {
  Future<void> init(String modelDir, {required String task});
  Future<List<SpeechChunk>> segments(Float32List pcm);
  Future<String> decode(SpeechChunk chunk);
  Future<void> free();
}

/// Whisper via sherpa_onnx em isolate persistente (UI nunca trava).
/// L1: `task=translate, language=ja` (tiny-ja fine-tuned → EN, depois Marian).
/// L2 Forte: `task=transcribe` (base → JA, depois NLLB).
/// VAD silero quando `vad.onnx` existe na pasta; senão janelas fixas de 30s.
class SherpaSttEngine implements SttEngine {
  _SttWorker? _worker;
  bool _hasVad = false;

  @override
  Future<void> init(String modelDir, {required String task}) async {
    _hasVad = await File('$modelDir/vad.onnx').exists();
    _worker = await _SttWorker.spawn(modelDir, task: task, withVad: _hasVad);
  }

  @override
  Future<List<SpeechChunk>> segments(Float32List pcm) async {
    final w = _worker;
    if (w == null) throw StateError('SttEngine.init() antes de segments()');
    return w.segments(pcm, withVad: _hasVad);
  }

  @override
  Future<String> decode(SpeechChunk chunk) async {
    final w = _worker;
    if (w == null) throw StateError('SttEngine.init() antes de decode()');
    return w.decode(chunk.samples);
  }

  @override
  Future<void> free() async {
    await _worker?.close();
    _worker = null;
  }
}

/// Isolate persistente: cria recognizer+VAD uma vez, decodifica N segmentos.
/// Tudo nativo roda aqui; o isolate principal só orquestra (progresso/cancel).
class _SttWorker {
  final Isolate _iso;
  final SendPort _cmd;
  final ReceivePort _resp;
  int _seq = 0;
  final _pending = <int, Completer<dynamic>>{};

  _SttWorker._(this._iso, this._cmd, this._resp) {
    _resp.listen((m) {
      final mm = m as Map;
      _pending.remove(mm['id'])?.complete(mm['value']);
    });
  }

  static Future<_SttWorker> spawn(String modelDir,
      {required String task, required bool withVad}) async {
    final ready = ReceivePort();
    final iso = await Isolate.spawn(
        _entry, [ready.sendPort, modelDir, task, withVad],
        debugName: 'stt-worker');
    final cmd = await ready.first as SendPort;
    final resp = ReceivePort();
    final w = _SttWorker._(iso, cmd, resp);
    await w._call('ping', null); // garante recognizer pronto
    return w;
  }

  Future<dynamic> _call(String op, dynamic arg) {
    final id = _seq++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _cmd.send({'id': id, 'op': op, 'arg': arg, 'reply': _resp.sendPort});
    return c.future;
  }

  Future<List<SpeechChunk>> segments(Float32List pcm,
      {required bool withVad}) async {
    // PCM cru não cruza isolate barato acima de ~50MB; EP 24min 16k mono =
    // ~46MB — envia em blocos de 60s e remonta offsets aqui.
    const blockSec = 60;
    const sr = 16000;
    final out = <SpeechChunk>[];
    for (var off = 0; off < pcm.length; off += blockSec * sr) {
      final end = (off + blockSec * sr).clamp(0, pcm.length);
      final segs = await _call('segments',
          [off ~/ sr, Float32List.fromList(pcm.sublist(off, end)), withVad]);
      for (final s in (segs as List)) {
        out.add(SpeechChunk((s[0] as num).toDouble(),
            Float32List.fromList((s[1] as List).cast<double>())));
      }
    }
    return out;
  }

  Future<String> decode(Float32List samples) async {
    final v = await _call('decode', samples) as String;
    if (v.startsWith('__STT_ERROR__')) {
      throw StateError(v.substring('__STT_ERROR__'.length));
    }
    return v;
  }

  Future<void> close() async {
    try {
      await _call('free', null).timeout(const Duration(seconds: 5));
    } catch (_) {}
    _resp.close();
    _iso.kill(priority: Isolate.immediate);
  }

  static void _entry(List<dynamic> args) {
    final main = args[0] as SendPort;
    final modelDir = args[1] as String;
    final task = args[2] as String;
    final withVad = args[3] as bool;
    sherpa.initBindings();
    final recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: '$modelDir/encoder.int8.onnx',
            decoder: '$modelDir/decoder.int8.onnx',
            language: 'ja',
            task: task,
          ),
          tokens: '$modelDir/tokens.txt',
          modelType: 'whisper',
          numThreads: 2,
          debug: false,
        ),
      ),
    );
    sherpa.VoiceActivityDetector? vad;
    if (withVad) {
      // Best-effort: VAD incompatível/ausente cai p/ janelas fixas (fallback
      // testado no Dart; nunca falha o job por causa do VAD).
      try {
        vad = sherpa.VoiceActivityDetector(
          config: sherpa.VadModelConfig(
            sileroVad: sherpa.SileroVadModelConfig(
                model: '$modelDir/vad.onnx', maxSpeechDuration: 30),
            sampleRate: 16000,
            numThreads: 1,
            debug: false,
          ),
          bufferSizeInSeconds: 120,
        );
      } catch (_) {
        vad = null;
      }
    }
    final inbox = ReceivePort();
    main.send(inbox.sendPort);
    inbox.listen((raw) {
      final m = raw as Map;
      final SendPort reply = m['reply'] as SendPort;
      final id = m['id'];
      try {
        switch (m['op'] as String) {
          case 'ping':
            reply.send({'id': id, 'value': true});
          case 'segments':
            final baseSec = (m['arg'] as List)[0] as int;
            final pcm = (m['arg'] as List)[1] as Float32List;
            final useVad = (m['arg'] as List)[2] as bool;
            reply.send({'id': id, 'value': _segment(vad, pcm, baseSec, useVad)});
          case 'decode':
            final samples = m['arg'] as Float32List;
            final stream = recognizer.createStream();
            stream.acceptWaveform(samples: samples, sampleRate: 16000);
            recognizer.decode(stream);
            final text = recognizer.getResult(stream).text.trim();
            stream.free();
            reply.send({'id': id, 'value': text});
          case 'free':
            vad?.free();
            recognizer.free();
            reply.send({'id': id, 'value': true});
            inbox.close();
        }
      } catch (e) {
        reply.send({'id': id, 'value': _error(e)});
      }
    });
  }

  static List<List<dynamic>> _segment(sherpa.VoiceActivityDetector? vad,
      Float32List pcm, int baseSec, bool useVad) {
    const sr = 16000;
    if (!useVad || vad == null) {
      // ponytail: sem VAD, janelas fixas de 30s (cobre OP/ED longas sem corte).
      final out = <List<dynamic>>[];
      for (var off = 0; off < pcm.length; off += 30 * sr) {
        final end = (off + 30 * sr).clamp(0, pcm.length);
        out.add([
          baseSec + off / sr,
          Float32List.fromList(pcm.sublist(off, end))
        ]);
      }
      return out;
    }
    vad.acceptWaveform(pcm);
    vad.flush();
    final out = <List<dynamic>>[];
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      if (seg.samples.length < sr ~/ 4) continue; // <250ms = ruído
      out.add([baseSec + seg.start / sr, seg.samples]);
    }
    vad.reset();
    return out;
  }

  static String _error(Object e) => '__STT_ERROR__$e';
}

/// STT L1/L2: PCM 16k mono → cues EN (translate) ou JA (transcribe).
/// Orquestração pura (IO + timestamps); nativo vive no [SttEngine].
/// O chamador (job) faz [dispose] antes de subir o MT — nunca ambos residentes.
class SherpaSttProvider extends SttProvider {
  final String modelDir;
  final SttEngine? engineForTest;

  /// 'translate' (L1 tiny-ja ja→en) ou 'transcribe' (L2 base ja).
  final String task;
  SttEngine? _engine;

  SherpaSttProvider(this.modelDir,
      {this.task = 'translate', this.engineForTest});

  @override
  String get id {
    final base = modelDir.split('/').last;
    if (base.contains('small')) return 'whisper-small';
    if (task == 'transcribe') return 'whisper-base';
    return 'whisper-tiny-ja';
  }

  @override
  Future<void> load() async {
    _engine = engineForTest ?? SherpaSttEngine();
    await _engine!.init(modelDir, task: task);
  }

  @override
  Future<List<SrtCue>> transcribe(String pcm16kPath,
      {void Function(double progress)? onProgress}) async {
    final engine = _engine;
    if (engine == null) throw StateError('SherpaSttProvider.load() antes');
    final bytes = await File(pcm16kPath).readAsBytes();
    final shorts = bytes.buffer.asInt16List();
    final pcm = Float32List(shorts.length);
    for (var i = 0; i < shorts.length; i++) {
      pcm[i] = shorts[i] / 32768.0;
    }
    final chunks = await engine.segments(pcm);
    final cues = <SrtCue>[];
    for (var i = 0; i < chunks.length; i++) {
      final text = await engine.decode(chunks[i]);
      onProgress?.call(chunks.isEmpty ? 1 : (i + 1) / chunks.length);
      if (text.trim().isEmpty) continue;
      final start = chunks[i].startSec;
      final end = start + chunks[i].samples.length / 16000.0;
      cues.add(SrtCue(
        index: cues.length + 1,
        start: Duration(milliseconds: (start * 1000).toInt()),
        end: Duration(milliseconds: (end * 1000).toInt()),
        text: text,
      ));
    }
    return cues;
  }

  @override
  Future<void> dispose() async {
    await _engine?.free();
    _engine = null;
  }
}
