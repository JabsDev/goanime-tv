import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../utils/device_capability.dart';
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
  Future<void> init(String modelDir,
      {required String task, int threads = 2});
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
  Future<void> init(String modelDir,
      {required String task, int threads = 2}) async {
    // Guarda anti-crash nativo: sherpa estoura sem mensagem se faltar arquivo.
    for (final f in const [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'tokens.txt'
    ]) {
      if (!await File('$modelDir/$f').exists()) {
        throw StateError('Modelo de voz incompleto (falta $f). Baixe de novo.');
      }
    }
    _hasVad = await File('$modelDir/vad.onnx').exists();
    _worker =
        await _SttWorker.spawn(modelDir, task: task, withVad: _hasVad, threads: threads);
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
  final ReceivePort _errPort;
  late final StreamSubscription _errSub;
  int _seq = 0;
  final _pending = <int, Completer<dynamic>>{};

  _SttWorker._(this._iso, this._cmd, this._resp, this._errPort) {
    _resp.listen((m) {
      final mm = m as Map;
      _pending.remove(mm['id'])?.complete(mm['value']);
    });
    // Erro não-tratado no isolate vira falha dos pendentes — nunca crash.
    _errSub = _errPort.listen((e) {
      final pending = _pending.values.toList();
      _pending.clear();
      for (final c in pending) {
        if (!c.isCompleted) c.completeError(StateError('worker STT: $e'));
      }
    });
  }

  static Future<_SttWorker> spawn(String modelDir,
      {required String task,
      required bool withVad,
      int threads = 2}) async {
    final ready = ReceivePort();
    final errors = ReceivePort();
    Isolate? iso;
    try {
      iso = await Isolate.spawn(
          _entry, [ready.sendPort, modelDir, task, withVad, threads],
          debugName: 'stt-worker', onError: errors.sendPort);
    } catch (e) {
      ready.close();
      errors.close();
      throw StateError('Falha ao iniciar o worker de voz: $e');
    }
    final errs = <Object>[];
    final errSub = errors.listen((e) => errs.add(e));
    try {
      // Handshake com teto: isolate morto/travado vira erro legível,
      // nunca trava o app nem mata o processo em silêncio.
      final first = await ready.first
          .timeout(const Duration(seconds: 120), onTimeout: () => null);
      if (first == null) {
        throw StateError(
            'Modelo de voz travou ao carregar (timeout 2 min). '
            'Tente de novo ou baixe o modelo novamente.');
      }
      if (first is Map) {
        throw StateError('Falha ao carregar voz: ${first['error']}');
      }
      final resp = ReceivePort();
      // A partir daqui, erros do isolate vão p/ o listener do worker.
      await errSub.cancel();
      final w = _SttWorker._(iso, first as SendPort, resp, errors);
      await w._call('ping', null);
      if (errs.isNotEmpty) {
        throw StateError('Falha ao carregar voz: ${errs.first}');
      }
      return w;
    } catch (e) {
      try {
        iso.kill(priority: Isolate.immediate);
      } catch (_) {}
      errors.close();
      rethrow;
    } finally {
      await errSub.cancel();
    }
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
    await _errSub.cancel();
    _errPort.close();
    _resp.close();
    _iso.kill(priority: Isolate.immediate);
  }

  static void _entry(List<dynamic> args) {
    final main = args[0] as SendPort;
    final modelDir = args[1] as String;
    final task = args[2] as String;
    final withVad = args[3] as bool;
    final threads = args[4] as int;
    // Qualquer throw aqui (binding, modelo corrompido) vira mensagem
    // de erro no handshake — nunca morte silenciosa do isolate.
    late final sherpa.OfflineRecognizer recognizer;
    sherpa.VoiceActivityDetector? vad;
    try {
      sherpa.initBindings();
      recognizer = sherpa.OfflineRecognizer(
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
            numThreads: threads,
            debug: false,
          ),
        ),
      );
    } catch (e) {
      main.send({'error': '$e'});
      return;
    }
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
    final low = await DeviceCapability.isLowEnd();
    await _engine!.init(modelDir, task: task, threads: low ? 1 : 2);
  }

  /// Lê o PCM em fatias de 60s (view Int16 sem cópia + 1 Float32 por fatia).
  /// Antes carregava o EP inteiro em Float32 (~46 MB p/ 24 min) + cópias do
  /// engine — OOM e morte do app em aparelho fraco. Pico agora ~4 MB + sherpa.
  @override
  Future<List<SrtCue>> transcribe(String pcm16kPath,
      {void Function(double progress)? onProgress}) async {
    final engine = _engine;
    if (engine == null) throw StateError('SherpaSttProvider.load() antes');
    const sr = 16000;
    const sliceSec = 60;
    final file = File(pcm16kPath);
    final totalBytes = await file.length();
    final totalSamples = totalBytes ~/ 2;
    final raf = await file.open();
    try {
      final cues = <SrtCue>[];
      var done = 0;
      while (done < totalSamples) {
        final n = (totalSamples - done).clamp(0, sliceSec * sr);
        final bytes = await raf.read(n * 2);
        final shorts = bytes.buffer.asInt16List();
        final pcm = Float32List(shorts.length);
        for (var i = 0; i < shorts.length; i++) {
          pcm[i] = shorts[i] / 32768.0;
        }
        final baseSec = done / sr;
        for (final chunk in await engine.segments(pcm)) {
          final text = await engine.decode(chunk);
          if (text.trim().isEmpty) continue;
          final start = baseSec + chunk.startSec;
          final end = start + chunk.samples.length / sr;
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
