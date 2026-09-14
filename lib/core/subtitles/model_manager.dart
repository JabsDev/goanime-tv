import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Catálogo de modelos on-device (plano §catálogo). Fonte: HuggingFace
/// (`repo` + `remoteFiles` paralelos a `files` locais).
/// sha256 reais via PINAR: `download` confere integridade só quando o sha
/// está pinado; enquanto PINAR, pula a verificação (rede = HF oficial).
class AiModelSpec {
  final String id;
  final int mb;
  final String sha256;
  final bool strongOnly;
  final String repo;
  final List<String> remoteFiles;
  final List<String> files;

  const AiModelSpec({
    required this.id,
    required this.mb,
    required this.sha256,
    required this.strongOnly,
    required this.repo,
    required this.remoteFiles,
    required this.files,
  }) : assert(remoteFiles.length == files.length);

  String fileUrl(String remote) =>
      'https://huggingface.co/$repo/resolve/main/$remote';
}

/// `final` (não const): assert de paralelismo remoteFiles/files.
final aiModelCatalog = <String, AiModelSpec>{
  // STT sherpa_onnx Whisper int8 (nomes locais normalizados; VAD opcional).
  // tiny multilíngue cobre JA via translate; upgrade = exportar tiny-ja
  // fine-tuned p/ layout sherpa (encoder/decoder/tokens).
  'whisper-tiny-ja': AiModelSpec(
      id: 'whisper-tiny-ja', mb: 50, sha256: 'PINAR', strongOnly: false,
      repo: 'csukuangfj/sherpa-onnx-whisper-tiny',
      remoteFiles: ['tiny-encoder.int8.onnx', 'tiny-decoder.int8.onnx', 'tiny-tokens.txt'],
      files: ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']),
  'whisper-base': AiModelSpec(
      id: 'whisper-base', mb: 150, sha256: 'PINAR', strongOnly: false,
      repo: 'csukuangfj/sherpa-onnx-whisper-base',
      remoteFiles: ['base-encoder.int8.onnx', 'base-decoder.int8.onnx', 'base-tokens.txt'],
      files: ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']),
  // VAD silero opcional (sem ele, janelas fixas de 30s).
  'silero-vad': AiModelSpec(
      id: 'silero-vad', mb: 3, sha256: 'PINAR', strongOnly: false,
      repo: 'deepghs/silero-vad-onnx',
      remoteFiles: ['silero_vad.onnx'],
      files: ['vad.onnx']),
  // MT leve: Marian opus-mt-en-mul int8 (alvo via prefixo >>por<<).
  'marian-en-pt-int8': AiModelSpec(
      id: 'marian-en-pt-int8', mb: 120, sha256: 'PINAR', strongOnly: false,
      repo: 'Xenova/opus-mt-en-mul',
      remoteFiles: ['onnx/encoder_model_int8.onnx', 'onnx/decoder_model_int8.onnx', 'vocab.json'],
      files: ['encoder_model.onnx', 'decoder_model.onnx', 'vocab.json']),
  // MT completa: NLLB int8 com decoder + decoder_with_past SEPARADOS (nunca
  // decoder_merged — crash Reshape no ORT Android, plano §L2).
  'nllb-600M-int8': AiModelSpec(
      id: 'nllb-600M-int8', mb: 1280, sha256: 'PINAR', strongOnly: true,
      repo: 'Xenova/nllb-200-distilled-600M',
      remoteFiles: ['onnx/encoder_model_int8.onnx', 'onnx/decoder_model_int8.onnx', 'onnx/decoder_with_past_model_int8.onnx', 'sentencepiece.bpe.model'],
      files: ['encoder_model.onnx', 'decoder_model.onnx', 'decoder_with_past_model.onnx', 'tokenizer.model']),
};

/// Download de modelos: só Wi-Fi (flag do chamador), Range/resume, sha256.
/// URLs resolvidas em runtime (sem URL hardcoded de CDN neste diff).
class ModelManager {
  final Future<Directory> Function()? dirForTest;
  const ModelManager({this.dirForTest});

  Future<Directory> modelsDir() async {
    if (dirForTest != null) return dirForTest!();
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/models');
  }

  Future<bool> isReady(String id) async {
    final spec = aiModelCatalog[id];
    if (spec == null) return false;
    final dir = Directory('${(await modelsDir()).path}/$id');
    for (final f in spec.files) {
      if (!await File('${dir.path}/$f').exists()) return false;
    }
    return true;
  }

  /// Baixa todos os arquivos de [modelId] do HF (pula os íntegros).
  /// Só Wi-Fi, salvo `allowMetered` (diálogo explícito no Settings).
  Future<Directory> downloadModel(
    String modelId, {
    bool allowMetered = false,
    Future<List<ConnectivityResult>> Function()? connectivityForTest,
    void Function(String file, double progress)? onProgress,
  }) async {
    final spec = aiModelCatalog[modelId];
    if (spec == null) throw ArgumentError('modelo desconhecido: $modelId');
    final conn = connectivityForTest != null
        ? await connectivityForTest()
        : await Connectivity().checkConnectivity();
    if (!allowMetered && !conn.contains(ConnectivityResult.wifi)) {
      throw const ModelDownloadException('Modelo só baixa no Wi-Fi.');
    }
    for (var i = 0; i < spec.files.length; i++) {
      await download(
        modelId: modelId,
        filename: spec.files[i],
        url: spec.fileUrl(spec.remoteFiles[i]),
        expectedSha256: spec.sha256,
        isWifi: true,
        onProgress: (p) => onProgress?.call(
            spec.files[i], (i + p) / spec.files.length),
      );
    }
    return Directory('${(await modelsDir()).path}/$modelId');
  }

  /// Baixa [url] com resume (`Range`) + sha256. `isWifi` vem do chamador
  /// (platform check); recusa em rede metered salvo `allowMetered`.
  Future<File> download({
    required String modelId,
    required String filename,
    required String url,
    required String expectedSha256,
    required bool isWifi,
    bool allowMetered = false,
    void Function(double progress)? onProgress,
  }) async {
    if (!isWifi && !allowMetered) {
      throw const ModelDownloadException('Modelo só baixa no Wi-Fi.');
    }
    final dir = Directory('${(await modelsDir()).path}/$modelId');
    await dir.create(recursive: true);
    final dest = File('${dir.path}/$filename');
    var start = 0;
    if (await dest.exists()) {
      if (expectedSha256 != 'PINAR' &&
          sha256.convert(await dest.readAsBytes()).toString() ==
              expectedSha256) {
        return dest; // já íntegro
      }
      start = await dest.length(); // resume
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      if (start > 0) req.headers.set('Range', 'bytes=$start-');
      final resp = await req.close();
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw ModelDownloadException('HTTP ${resp.statusCode}');
      }
      final total = (resp.contentLength < 0 ? 0 : resp.contentLength) + start;
      final sink = dest.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
      var got = start;
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress?.call(got / total);
        }
      } finally {
        await sink.close();
      }
      if (expectedSha256 != 'PINAR') {
        final digest = sha256.convert(await dest.readAsBytes()).toString();
        if (digest != expectedSha256) {
          await dest.delete();
          throw const ModelDownloadException('sha256 divergente.');
        }
      }
      return dest;
    } finally {
      client.close();
    }
  }

  Future<int> usedBytes() async {
    final root = await modelsDir();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final e in root.list(recursive: true)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<void> deleteAll() async {
    final root = await modelsDir();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => 'ModelDownloadException: $message';
}
