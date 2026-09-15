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
  final String label;
  final String hint;
  final int mb;
  final String sha256;
  final bool strongOnly;
  final String repo;
  final List<String> remoteFiles;
  final List<String> files;

  const AiModelSpec({
    required this.id,
    required this.label,
    required this.hint,
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
      id: 'whisper-tiny-ja', label: 'Voz leve (tiny)',
      hint: 'Voz · transforma o áudio japonês em texto inglês. Rápido, qualidade básica (passo 1 de 2)',
      mb: 110, sha256: 'PINAR', strongOnly: false,
      repo: 'csukuangfj/sherpa-onnx-whisper-tiny',
      remoteFiles: ['tiny-encoder.int8.onnx', 'tiny-decoder.int8.onnx', 'tiny-tokens.txt'],
      files: ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']),
  'whisper-base': AiModelSpec(
      id: 'whisper-base', label: 'Voz equilibrada (base)',
      hint: 'Voz · transcreve o japonês com mais qualidade. Mais lento (passo 1 de 2)',
      mb: 170, sha256: 'PINAR', strongOnly: false,
      repo: 'csukuangfj/sherpa-onnx-whisper-base',
      remoteFiles: ['base-encoder.int8.onnx', 'base-decoder.int8.onnx', 'base-tokens.txt'],
      files: ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']),
  'whisper-small': AiModelSpec(
      id: 'whisper-small', label: 'Voz superior (small)',
      hint: 'Voz · melhor transcrição de japonês. Só aparelho forte (passo 1 de 2)',
      mb: 380, sha256: 'PINAR', strongOnly: true,
      repo: 'csukuangfj/sherpa-onnx-whisper-small',
      remoteFiles: ['small-encoder.int8.onnx', 'small-decoder.int8.onnx', 'small-tokens.txt'],
      files: ['encoder.int8.onnx', 'decoder.int8.onnx', 'tokens.txt']),
  // STT JA dedicado: SenseVoice-small int8 multilíngue (encoder direto, sem
  // decoder autoregressivo — rápido e leve; idioma fixo 'ja' no provider).
  'sensevoice-ja': AiModelSpec(
      id: 'sensevoice-ja', label: 'Voz JA dedicada (SenseVoice)',
      hint: 'Voz · transcreve japonês direto, rápido no stick fraco (passo 1 de 2)',
      mb: 240, sha256: 'PINAR', strongOnly: false,
      repo: 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
      remoteFiles: ['model.int8.onnx', 'tokens.txt'],
      files: ['model.int8.onnx', 'tokens.txt']),
  // VAD silero opcional (sem ele, janelas fixas de 30s).
  'silero-vad': AiModelSpec(
      id: 'silero-vad', label: 'VAD silero (opcional)',
      hint: 'Áudio · corta silêncios p/ transcrever mais rápido. Opcional',
      mb: 3, sha256: 'PINAR', strongOnly: false,
      repo: 'deepghs/silero-vad-onnx',
      remoteFiles: ['silero_vad.onnx'],
      files: ['vad.onnx']),
  // MT JA→PT direta via llama.cpp (GGUF auto-contido, tokenizer embutido).
  // Q3_K_M comunitário (Jabs2, 6/6 no gate) e Q4_K_M oficial (tencent).
  'hymt-ja-pt-q3km': AiModelSpec(
      id: 'hymt-ja-pt-q3km', label: 'Tradução JA→PT (Hy-MT2 Q3)',
      hint: 'Tradução · leva japonês ou inglês p/ português (passo 2 de 2)',
      mb: 907, sha256: 'PINAR', strongOnly: false,
      repo: 'Jabs2/Hy-MT2-1.8B-Q3_K_M-GGUF',
      remoteFiles: ['Hy-MT2-1.8B-Q3_K_M.gguf'],
      files: ['model.gguf']),
  'hymt-ja-pt-q4': AiModelSpec(
      id: 'hymt-ja-pt-q4', label: 'Tradução JA→PT (Hy-MT2 Q4)',
      hint: 'Tradução · igual ao Q3, com mais qualidade (passo 2 de 2)',
      mb: 1133, sha256: 'PINAR', strongOnly: false,
      repo: 'tencent/Hy-MT2-1.8B-GGUF',
      remoteFiles: ['Hy-MT2-1.8B-Q4_K_M.gguf'],
      files: ['model.gguf']),
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
    if (await dest.exists() &&
        expectedSha256 != 'PINAR' &&
        sha256.convert(await dest.readAsBytes()).toString() ==
            expectedSha256) {
      return dest; // já íntegro
    }
    await fetchFile(
      dest: dest,
      url: url,
      onProgress: onProgress == null
          ? null
          : (got, total) =>
              onProgress(total <= 0 ? 0 : got / total),
    );
    if (expectedSha256 != 'PINAR') {
      final digest = sha256.convert(await dest.readAsBytes()).toString();
      if (digest != expectedSha256) {
        await dest.delete();
        throw const ModelDownloadException('sha256 divergente.');
      }
    }
    return dest;
  }

  /// Download genérico com resume + progresso em bytes (modelos e vídeos).
  /// Retoma de `dest.length()` via `Range`; servidor sem 206 recomeça do 0.
  static Future<File> fetchFile({
    required File dest,
    required String url,
    Map<String, String> headers = const {},
    void Function(int got, int total)? onProgress,
  }) async {
    await dest.parent.create(recursive: true);
    var start = await dest.exists() ? await dest.length() : 0;
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      // HF barra bots em alguns repos (401): UA de browser passa.
      // Só quando o chamador não definiu um (não quebra anti-bot de vídeos).
      if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
        req.headers.set(HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (Linux; Android 11; TV) AppleWebKit/537.36');
      }
      if (start > 0) req.headers.set('Range', 'bytes=$start-');
      var resp = await req.close();
      if (resp.statusCode == 416) {
        // Range além do fim = arquivo já completo.
        onProgress?.call(start, start);
        return dest;
      }
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw ModelDownloadException('HTTP ${resp.statusCode} em $url');
      }
      if (resp.statusCode == 200 && start > 0) start = 0; // sem resume
      final total =
          (resp.contentLength < 0 ? 0 : resp.contentLength) + start;
      final sink = dest.openWrite(
          mode: start > 0 ? FileMode.append : FileMode.write);
      var got = start;
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          got += chunk.length;
          onProgress?.call(got, total);
        }
      } finally {
        await sink.close();
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
