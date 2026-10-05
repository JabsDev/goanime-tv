import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../utils/device_capability.dart';
import 'model_manager.dart';
import 'mt_provider.dart';
import 'srt_parser.dart';

/// Trecho de fala com offset (segundos) no PCM original.
class SpeechChunk {
  final double startSec;
  final Float32List samples;

  /// true = janela fixa emitida pela rede de recall do VAD (fala baixa que o
  /// Silero não detectou). Só observabilidade: o decode usa os samples iguais.
  final bool fallback;
  const SpeechChunk(this.startSec, this.samples, {this.fallback = false});
}

/// Heurística anti-alucinação para o texto das janelas de recall do VAD: sobre
/// música de abertura/efeito o STT devolve só pontuação ("…", "。") ou a mesma
/// sílaba repetida muitas vezes ("んんっ、んんっ…", "ふ、ふ、ふ…"). Isso não é
/// fala e não deve virar legenda. Aplicada só a chunks [SpeechChunk.fallback]
/// — nunca à saída normal do VAD nem de outros modelos.
bool looksLikeSttNoise(String text) {
  final stripped = text.replaceAll(
      RegExp(r'[\s、。．，,！!？?…‥・「」『』（）()\[\]{}<>—–\-ー~〜:：;；]'), '');
  if (stripped.isEmpty) return true;
  if (stripped.length >= 6 && stripped.split('').toSet().length <= 2) {
    return true;
  }
  return false;
}

/// Segmento sem conteúdo textual: só pausa, pontuação ou vocalização.
///
/// Distinto de [looksLikeSttNoise], que existe para as janelas de recall
/// sobre música. Aqui o segmento é fala real, mas o STT não conseguiu
/// transcrever nada além do resíduo — tipicamente "…" numa pausa de meio
/// segundo. Enviar isso ao MT produz lixo traduzido ou fala repetida.
bool isPauseOnly(String text) {
  final stripped = text.replaceAll(
      RegExp(r'[\s、。．，,！!？?…‥・「」『』（）()\[\]{}<>—–\-ー~〜:：;；]'), '');
  return stripped.isEmpty;
}

/// Copia `models/silero-vad/vad.onnx` para dentro da pasta do modelo STT
/// (o download grava em silero-vad/, o engine procura na pasta do modelo de
/// voz — caminhos divergentes, estudo §2.1: VAD baixado nunca era usado).
/// Best-effort: falha = janelas fixas de 30s (fallback seguro). Retorna true
/// se `$modelDir/vad.onnx` existir ao final. `rootForTest` p/ teste.
Future<bool> ensureVadInModelDir(String modelDir, {Directory? rootForTest}) async {
  try {
    if (await File('$modelDir/vad.onnx').exists()) return true;
    final root = rootForTest ?? await const ModelManager().modelsDir();
    final src = File('${root.path}/silero-vad/vad.onnx');
    if (!await src.exists()) return false;
    final tmp = File('$modelDir/vad.onnx.tmp');
    await tmp.parent.create(recursive: true);
    await src.copy(tmp.path); // renomear depois: cópia atômica no Android
    await tmp.rename('$modelDir/vad.onnx');
    return true;
  } catch (_) {
    return false; // nunca falhar o job por causa do VAD
  }
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

  /// 'whisper' (tiny/base/small) ou 'sensevoice' (JA dedicado).
  /// `vadOnly`: só o VAD silero (sem recognizer) — usado pelo engine jav03,
  /// que segmenta com o VAD do sherpa e decodifica pelo ONNX Runtime.
  final String sttKind;
  final bool vadOnly;
  SherpaSttEngine({this.sttKind = 'whisper', this.vadOnly = false});

  @override
  Future<void> init(String modelDir,
      {required String task, int threads = 2}) async {
    // Guarda anti-crash nativo: sherpa estoura sem mensagem se faltar arquivo.
    if (!vadOnly) {
      final needed = sttKind == 'sensevoice'
          ? const ['model.int8.onnx', 'tokens.txt']
          : const ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt'];
      for (final f in needed) {
        if (!await File('$modelDir/$f').exists()) {
          throw StateError('Modelo de voz incompleto (falta $f). Baixe de novo.');
        }
      }
    }
    // Log permanente: evidência de H1 (VAD na pasta certa) no logcat.
    _hasVad = await ensureVadInModelDir(modelDir);
    debugPrint('[SherpaStt] VAD: $_hasVad ($modelDir)${vadOnly ? ' (vad-only)' : ''}');
    _worker = await _SttWorker.spawn(modelDir,
        task: task,
        withVad: _hasVad,
        threads: threads,
        sttKind: sttKind,
        vadOnly: vadOnly);
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
      int threads = 2,
      String sttKind = 'whisper',
      bool vadOnly = false}) async {
    final ready = ReceivePort();
    final errors = ReceivePort();
    ReceivePort? resp;
    Isolate? iso;
    try {
      try {
        iso = await Isolate.spawn(
            _entry,
            [ready.sendPort, modelDir, task, withVad, threads, sttKind, vadOnly],
            debugName: 'stt-worker', onError: errors.sendPort);
      } catch (e) {
        ready.close();
        errors.close();
        throw StateError('Falha ao iniciar o worker de voz: $e');
      }
      // Handshake usa SÓ `ready`. `errors` tem UM listen vitalício (construtor
      // abaixo); ReceivePort faz buffer pré-listen, então erro de boot não se perde.
      // Nunca dois `listen`s no mesmo ReceivePort (nem sequenciais com cancel).
      final first = await ready.first
          .timeout(const Duration(seconds: 120), onTimeout: () => null);
      ready.close();
      if (first == null) {
        throw StateError(
            'Modelo de voz travou ao carregar (timeout 2 min). '
            'Tente de novo ou baixe o modelo novamente.');
      }
      if (first is Map) {
        throw StateError('Falha ao carregar voz: ${first['error']}');
      }
      resp = ReceivePort();
      final w = _SttWorker._(iso, first as SendPort, resp, errors);
      resp = null; // sucesso: ports pertencem ao worker (close() fecha)
      await w._call('ping', null,
          timeout: const Duration(seconds: 10));
      return w;
    } catch (e) {
      try {
        iso?.kill(priority: Isolate.immediate);
      } catch (_) {}
      resp?.close();
      errors.close();
      rethrow;
    }
  }

  Future<dynamic> _call(String op, dynamic arg,
      {Duration timeout = const Duration(seconds: 60)}) {
    final id = _seq++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _cmd.send({'id': id, 'op': op, 'arg': arg, 'reply': _resp.sendPort});
    // Teto anti-hang: isolate morto/OOM vira erro legível em vez de travar a
    // fila FIFO para sempre. Resposta tardia é ignorada (pending já removido).
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw StateError(
          'worker STT sem resposta (timeout ${timeout.inSeconds}s). '
          'Aparelho pode estar sem memória — tente o modelo de voz leve (tiny).');
    });
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
        out.add(SpeechChunk(
            (s[0] as num).toDouble(),
            Float32List.fromList((s[1] as List).cast<double>()),
            fallback: s.length > 2 && s[2] == true));
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
    // Free LONGO de propósito: sob pressão de memória o sherpa demora a
    // soltar o recognizer; timeout curto matava o isolate com o nativo
    // ainda alocado (vazamento) e o MT de ~1 GB logo depois tomava LMK-kill
    // (app "só fecha" na fase Carregando tradução). 30s garante free real.
    try {
      await _call('free', null).timeout(const Duration(seconds: 30));
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
    final sttKind = args.length > 5 ? args[5] as String : 'whisper';
    final vadOnly = args.length > 6 ? args[6] as bool : false;
    // Qualquer throw aqui (binding, modelo corrompido) vira mensagem
    // de erro no handshake — nunca morte silenciosa do isolate.
    sherpa.OfflineRecognizer? recognizer;  // null em vadOnly (engine jav03)
    sherpa.VoiceActivityDetector? vad;
    try {
      sherpa.initBindings();
      if (vadOnly) {
        // Engine jav03: aqui só o VAD. O recognizer (encoder/decoder) não é
        // criado — o decode daquele modelo é pelo ONNX Runtime, no Kotlin.
      } else if (sttKind == 'sensevoice') {
        // JA dedicado: encoder direto (sem decoder autoregressivo).
        recognizer = sherpa.OfflineRecognizer(
          sherpa.OfflineRecognizerConfig(
            model: sherpa.OfflineModelConfig(
              senseVoice: sherpa.OfflineSenseVoiceModelConfig(
                model: '$modelDir/model.int8.onnx',
                language: 'ja',
              ),
              tokens: '$modelDir/tokens.txt',
              numThreads: threads,
              debug: false,
            ),
          ),
        );
      } else {
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
      }
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
            // Recall/segmentação afinados p/ diálogo de anime (Haibane EP3):
            // o default (threshold 0.5, minSilence 0.5, maxSpeech 5) fundia
            // falas em blocos de 10-12s e o Silero v5 ainda pulava fala baixa.
            // maxSpeech menor mantém cues curtos; minSilence menor separa
            // falas vizinhas. A cobertura do que ainda escapar é garantida
            // por _recoverMissedSpeech.
            sileroVad: sherpa.SileroVadModelConfig(
                model: '$modelDir/vad.onnx',
                threshold: 0.4,
                minSilenceDuration: 0.3,
                minSpeechDuration: 0.15,
                maxSpeechDuration: 12),
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
            final rec = recognizer;
            if (rec == null) {
              reply.send({'id': id, 'value': _error('decode indisponível (vad-only)')});
              return;
            }
            final stream = rec.createStream();
            // finally de propósito: chunk com erro vazava o stream e o
            // recognizer.free() depois derrubava o processo (SIGSEGV no
            // dispose — app "só fechava" entre voz e tradução, sem breadcrumb).
            try {
              stream.acceptWaveform(samples: samples, sampleRate: 16000);
              rec.decode(stream);
              final text = rec.getResult(stream).text.trim();
              reply.send({'id': id, 'value': text});
            } catch (e) {
              reply.send({'id': id, 'value': _error(e)});
            } finally {
              try {
                stream.free();
              } catch (_) {}
            }
          case 'free':
            vad?.free();
            recognizer?.free();
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
    final v = vad;
    if (!useVad || v == null) {
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
    // CRÍTICO: alimentar o VAD em sub-chunks (~window_size), NUNCA com o bloco
    // inteiro. O `acceptWaveform` com 60s de uma vez faz o silero emitir
    // ~1 segmento de ~0,3s por bloco (Haibane EP3: 18 falas — pior que sem
    // VAD). Com chunks de 512 o mesmo VAD devolve ~121-148 segmentos corretos
    // (reproduzido na C API; ver .qa/haibane_ep3/relatorio-haibane-ep3.md).
    const chunk = 512;
    final out = <List<dynamic>>[];
    // Amostras cobertas por segmento do VAD: a rede de recall não pode
    // recortar o que o VAD já entregou (senão duplica cue).
    final covered = Uint8List(pcm.length);
    void drain() {
      while (!v.isEmpty()) {
        final seg = v.front();
        v.pop();
        if (seg.samples.length < sr ~/ 5) continue; // <200ms = ruído
        final s = seg.start < 0 ? 0 : seg.start;
        final e = (seg.start + seg.samples.length).clamp(0, pcm.length);
        if (e > s) covered.fillRange(s, e, 1);
        out.add([baseSec + seg.start / sr, seg.samples, false]);
      }
    }

    for (var off = 0; off < pcm.length; off += chunk) {
      final end = (off + chunk).clamp(0, pcm.length);
      v.acceptWaveform(pcm.sublist(off, end));
      drain();
    }
    v.flush();
    drain();
    v.reset();
    // Recall DESATIVADO: com o Silero v4 (k2-fsa) o VAD já cobre 1:44-3:00 sem
    // precisar forçar janelas. O recall enfiava a abertura (música) no Whisper,
    // que alucinava ("ん、ん、ん…" / "E o amor, e o amor…").
    // _recoverMissedSpeech(pcm, covered, baseSec, out);
    return out;
  }

  /// Rede de recall do VAD. O Silero v5 (deepghs/silero-vad-onnx, o modelo que
  /// o app baixa) é conservador: na Haibane Renmei EP3 ignorou por completo o
  /// diálogo baixo de 1:44-3:00 (o trecho tem fala real — confirmado por ASR
  /// com SenseVoice). Onde há energia de fala (RMS > 0,010) que o VAD NÃO
  /// cobriu, emite janelas fixas de 6s para o STT não perder o trecho. Música
  /// de fundo baixa (RMS tipicamente < 0,008) fica de fora, e o que já veio do
  /// VAD é preservado (sem sobreposição/duplicação).
  static void _recoverMissedSpeech(Float32List pcm, Uint8List covered,
      int baseSec, List<List<dynamic>> out) {
    const sr = 16000;
    const win = sr ~/ 4; // 0.25s: granularidade do portão de energia
    const thr2 = 0.010 * 0.010; // RMS mínimo de fala baixa
    const minRun = sr * 4 ~/ 5; // 0.8s: abaixo disso é transiente/ruído
    const hole = 5600; // 0.35s: ponte entre sílabas
    const fb = sr * 6; // janela de fallback (6s)
    const minChunk = sr ~/ 5; // 200ms
    final n = pcm.length;
    // 1) energia por janela de 0.25s -> marca "fala baixa" por amostra.
    final active = Uint8List(n);
    for (var a = 0; a < n; a += win) {
      final b = (a + win).clamp(0, n);
      var sum = 0.0;
      for (var k = a; k < b; k++) {
        sum += pcm[k] * pcm[k];
      }
      if (b > a && sum / (b - a) > thr2) active.fillRange(a, b, 1);
    }
    // 2) livres = fala baixa ainda não coberta pelo VAD.
    final free = Uint8List(n);
    for (var k = 0; k < n; k++) {
      if (active[k] != 0 && covered[k] == 0) free[k] = 1;
    }
    // 3) agrupa trechos livres (tolerando buracos curtos) e fatia em janelas.
    var i = 0;
    while (i < n) {
      if (free[i] == 0) {
        i++;
        continue;
      }
      var j = i;
      var last = i;
      while (j < n) {
        if (free[j] != 0) {
          last = j;
        } else if (covered[j] != 0 || j - last > hole) {
          break;
        }
        j++;
      }
      final end = (last + 1).clamp(0, n);
      if (end - i >= minRun) {
        var p = i;
        while (p < end) {
          var q = (p + fb).clamp(0, end);
          while (q > p && covered[q - 1] != 0) {
            q--;
          }
          if (q - p >= minChunk) {
            out.add([
              baseSec + p / sr,
              Float32List.fromList(pcm.sublist(p, q)),
              true
            ]);
          }
          p = q;
          while (p < end && covered[p] != 0) {
            p++;
          }
          if (p <= i) break; // segurança anti-loop
        }
      }
      i = end;
    }
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

  /// 'whisper' ou 'sensevoice' (JA dedicado, sempre transcribe).
  final String sttKind;
  SttEngine? _engine;

  SherpaSttProvider(this.modelDir,
      {this.task = 'translate', this.engineForTest, this.sttKind = 'whisper'});

  @override
  String get id {
    if (sttKind == 'sensevoice') return 'sensevoice-ja';
    final base = modelDir.split('/').last;
    if (base.contains('anime-whisper')) return 'anime-whisper-ja';
    if (base.contains('small')) return 'whisper-small';
    if (task == 'transcribe') return 'whisper-base';
    return 'whisper-tiny-ja';
  }

  @override
  Future<void> load() async {
    _engine = engineForTest ?? SherpaSttEngine(sttKind: sttKind);
    final low = await DeviceCapability.isLowEnd();
    await _engine!.init(modelDir, task: task, threads: low ? 1 : 2);
  }

  /// Lê o PCM em fatias de 60s (view Int16 sem cópia + 1 Float32 por fatia).
  /// Antes carregava o EP inteiro em Float32 (~46 MB p/ 24 min) + cópias do
  /// engine — OOM e morte do app em aparelho fraco. Pico agora ~4 MB + sherpa.
  @override
  Future<List<SrtCue>> transcribe(String pcm16kPath,
      {void Function(double progress)? onProgress,
      bool Function()? isCancelled}) async {
    final engine = _engine;
    if (engine == null) throw StateError('SherpaSttProvider.load() antes');
    const sr = 16000;
    const sliceSec = 60;
    final file = File(pcm16kPath);
    final totalBytes = await file.length();
    final totalSamples = totalBytes ~/ 2;
    // Diagnóstico do gap (EP3 1:44-3:00): tamanho do PCM vs. duração do vídeo
    // denuncia extração incompleta; log por segmento mostra se o texto veio
    // vazio (o `continue` abaixo é o que remove cue).
    debugPrint('[STT] pcm totalSamples=$totalSamples (${(totalSamples / sr).toStringAsFixed(1)}s)');
    final raf = await file.open();
    try {
      final cues = <SrtCue>[];
      var done = 0;
      while (done < totalSamples) {
        // Cancelado = cues parciais, sem throw (job manager vê o flag depois).
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
        // O recall de fala baixa anexa os fallbacks DEPOIS dos segmentos do
        // VAD no mesmo slice → ordem temporal quebrada. Ordena por início.
        chunks.sort((a, b) => a.startSec.compareTo(b.startSec));
        debugPrint('[STT] slice base=${baseSec.toStringAsFixed(0)}s chunks=${chunks.length}');
        for (final chunk in chunks) {
          if (isCancelled?.call() ?? false) return cues;
          final text = await engine.decode(chunk);
          final start = baseSec + chunk.startSec;
          final end = start + chunk.samples.length / sr;
          final short = text.replaceAll('\n', ' ');
          debugPrint('[STT] seg ${start.toStringAsFixed(1)}-${end.toStringAsFixed(1)}s '
              '${chunk.fallback ? '[fb] ' : ''}"${short.length > 60 ? short.substring(0, 60) : short}"');
          if (text.trim().isEmpty) continue;
          // Sobre música de abertura/efeito, o STT devolve só pontuação ou a
          // mesma sílaba repetida ("んんっ、んんっ…"). Essas janelas de recall
          // não viram legenda.
          if (chunk.fallback && looksLikeSttNoise(text)) {
            debugPrint('[STT] drop ruído ${start.toStringAsFixed(1)}s');
            continue;
          }
          // Segmento do VAD pode ser só pausa: o anime-whisper emite "…" com
          // 0,9s de áudio e nenhum conteúdo. 30 de 209 cues do EP3 são assim.
          // Não há o que traduzir, e o MT só tem como devolver ruído — então
          // some antes de gastar token. Vale para todos os MT (Hy-MT2, LFM,
          // LMT): a entrada ruim estraga a saída em qualquer um deles.
          if (isPauseOnly(text)) {
            debugPrint('[STT] drop pausa ${start.toStringAsFixed(1)}s "$short"');
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
