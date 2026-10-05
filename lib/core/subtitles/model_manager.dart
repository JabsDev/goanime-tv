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
  // STT JA dedicado. Poda Fase 1: só os tiers ALTOS. ANTES era o SenseVoice
  // (multilíngue, 86,6% de erro em galgame, 80% de deleção — o tokenizer de
  // caracteres chinês degrada japonês). Substituído pelo whisper-small
  // DESTILADO nos dados de anime (distill1-4 em asr_eval): encoder int8 +
  // decoder int8 no formato sherpa, ~375 MB, ~23% filtrado. Fica no tier
  // 'sensevoice' (chave já persistida nos aparelhos). Roda pelo motor ORT
  // próprio (canal jav03), não pelo sherpa.
  'sensevoice-ja': AiModelSpec(
      id: 'sensevoice-ja', label: 'Voz JA dedicada (Whisper anime leve)',
      hint: 'Voz · Whisper destilado p/ anime, leve e mais preciso (passo 1 de 2)',
      mb: 420, sha256: 'PINAR', strongOnly: false,
      repo: 'Jabs2/whisper-small-anime-distill',
      remoteFiles: [
        'mel.onnx',
        'encoder_model.int8.onnx',
        'encoder_model.int8.onnx.data',
        'decoder_model.int8.onnx',
        'decoder_model.int8.onnx.data',
        'tokens.txt',
      ],
      files: [
        'mel.onnx',
        'encoder_model.int8.onnx',
        'encoder_model.int8.onnx.data',
        'decoder_model.int8.onnx',
        'decoder_model.int8.onnx.data',
        'tokens.txt',
      ]),
  // VAD silero opcional (sem ele, janelas fixas de 30s).
  'silero-vad': AiModelSpec(
      id: 'silero-vad', label: 'VAD silero (opcional)',
      hint: 'Áudio · corta silêncios p/ transcrever mais rápido. Opcional',
      mb: 3, sha256: 'PINAR', strongOnly: false,
      repo: 'deepghs/silero-vad-onnx',
      remoteFiles: ['silero_vad.onnx'],
      files: ['vad.onnx']),
  // Whisper-ja-anime-v0.3 (efwkjn), int8 encoder + fp16 decoder + front-end de
  // mel (grafo ONNX). Roda pela C API do ONNX Runtime JA embarcado (o
  // libonnxruntime.so do fork sherpa) — sem segundo runtime. CER ~6,5%
  // (filtrado) contra 16,2% do anime-whisper, com deleção 3× menor.
  // ATENÇÃO: o artefato é export optimum + quantização; o export sherpa do
  // v0.3 está quebrado (decoder diverge do torch com prompt de 4 tokens).
  // Nomes locais normalizados; a ordem casa remoteFiles.
  'whisper-ja-anime-v03': AiModelSpec(
      id: 'whisper-ja-anime-v03', label: 'Voz anime v0.3 (Whisper JA anime)',
      hint: 'Voz · Whisper ja anime v0.3, menos erro e menos deleção (grande; passo 1 de 2)',
      mb: 900, sha256: 'PINAR', strongOnly: false,
      repo: 'Jabs2/whisper-ja-anime-v03-onnx',
      remoteFiles: [
        'mel.onnx',
        'encoder_model.int8.onnx',
        'encoder_model.int8.onnx.data',
        'decoder_model.fp16.onnx',
        'tokens.txt',
      ],
      files: [
        'mel.onnx',
        'encoder_model.int8.onnx',
        'encoder_model.int8.onnx.data',
        'decoder_model.fp16.onnx',
        'tokens.txt',
      ]),
  // MT JA→PT direta via llama.cpp (GGUF auto-contido, tokenizer embutido).
  // Q4_K_M oficial (tencent). Poda Fase 1: o Q3_K_M saiu do catálogo.
  'hymt-ja-pt-q4': AiModelSpec(
      id: 'hymt-ja-pt-q4', label: 'Tradução JA→PT (Hy-MT2 Q4_K_M)',
      hint: 'Tradução · igual ao Q3, com mais qualidade (passo 2 de 2)',
      mb: 1133, sha256: 'PINAR', strongOnly: false,
      repo: 'tencent/Hy-MT2-1.8B-GGUF',
      remoteFiles: ['Hy-MT2-1.8B-Q4_K_M.gguf'],
      files: ['model.gguf']),
  // MT de domínio (Recomendado): Hy-MT2 1.8B fine-tune em mangá/anime,
  // aceita destino PT. No EP3 (209 falas do anime-whisper) traduziu 30/30
  // falas de pausa e 0 saiu em japonês; o Hy-MT2 base IQ3M falhou em 22%.
  // EXIGE o chat template HunYuan + bloco de terminologia: com prompt cru
  // o base degrada (cjk 35 -> 101). Não usar prompt cru.
  'hymt-ja-pt-manga-v3': AiModelSpec(
      id: 'hymt-ja-pt-manga-v3', label: 'Tradução mangá (Hy-MT2 v3 Q4)',
      hint: 'Tradução · fine-tune de mangá, melhor p/ JA de anime (passo 2 de 2)',
      mb: 1133, sha256: 'PINAR', strongOnly: false,
      repo: 'fumetodev/Hy-MT2-1.8B-JP-Manga-Finetune-v3-multilingual-GGUF',
      remoteFiles: ['manga-v3a-Q4_K_M.gguf'],
      files: ['model.gguf']),
  // Auditorias de legenda: LLM leve DIFERENTE do tradutor (segundo par de
  // olhos). Mesmo runtime llama.cpp nativo; só o GGUF muda. Dois passes no
  // job: PRÉ-tradução (JA) e PÓS-tradução (PT). O escolhido fica em
  // Settings (settings_ai_audit); 'off' = sem auditoria (comportamento atual).
  // NOTA HONESTA: os repos apontados ainda não estão hospedados no HF; o
  // teste no aparelho usa os GGUFs via adb push (arquivos presentes = pronto).
  // Auditor seq2seq próprio (ByT5 fine-tunado, ONNX int8/fp32). Limpa a
  // transcrição JA ANTES de traduzir. NÃO é LLM nem tradutor. Hoje os arquivos
  // vêm por adb push; o repo abaixo é o destino p/ publicar (download futuro).
  'ja-seq2seq': AiModelSpec(
      id: 'ja-seq2seq', label: 'Auditor JA seq2seq (ByT5)',
      hint: 'Auditoria · limpa a transcrição JA antes de traduzir (rápido)',
      mb: 551, sha256: 'PINAR', strongOnly: false,
      repo: 'Jabs2/goanime-auditor-ja',
      remoteFiles: ['encoder.onnx', 'decoder.onnx'],
      files: ['encoder.onnx', 'decoder.onnx']),
  'heretic-1b-it': AiModelSpec(
      id: 'heretic-1b-it', label: 'Auditor gemma-3 1B (Heretic)',
      hint: 'Voz · revisa a legenda antes e depois da tradução (teste)',
      mb: 769, sha256: 'PINAR', strongOnly: false,
      repo: 'Andycurrent/Gemma-3-1B-it-GLM-4.7-Flash-Heretic-Uncensored-Thinking_GGUF',
      remoteFiles: ['Gemma-3-1B-it-GLM-4.7-Flash-Heretic-Uncensored-Thinking_Q4_k_m.gguf'],
      files: ['auditor.gguf']),
  'qwen3-06b': AiModelSpec(
      id: 'qwen3-06b', label: 'Auditor Qwen3 0.6B',
      hint: 'Voz · revisa a legenda antes e depois da tradução (teste)',
      mb: 767, sha256: 'PINAR', strongOnly: false,
      repo: 'Qwen/Qwen3-0.6B-GGUF',
      remoteFiles: ['Qwen3-0.6B-Q8_0.gguf'],
      files: ['auditor.gguf']),
  'lfm25-dist': AiModelSpec(
      id: 'lfm25-dist', label: 'Auditor LFM dist 350M',
      hint: 'Voz · revisa a legenda antes e depois da tradução (teste)',
      mb: 146, sha256: 'PINAR', strongOnly: false,
      repo: 'Jabs2/lfm25-dist-gguf',
      remoteFiles: ['lfm25-dist-q4km.gguf'],
      files: ['auditor.gguf']),
  'lfm12b-audit': AiModelSpec(
      id: 'lfm12b-audit', label: 'Auditor LFM 1.2B',
      hint: 'Voz · revisa a legenda antes e depois da tradução (teste)',
      mb: 540, sha256: 'PINAR', strongOnly: false,
      repo: 'Jabs2/lfm12b-ja-gguf',
      remoteFiles: ['lfm12b-ja-iq3m.gguf'],
      files: ['auditor.gguf']),
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

  /// GGUF válido = existe + tamanho >= 95% do catálogo + magic "GGUF".
  /// `exists()` sozinho marcava download truncado como "instalado" e o
  /// nativo falhava com "falha ao carregar" (ver screenshot EP3).
  /// ponytail: piso 95% de spec.mb + magic, sem sha completo até pinar HF.
  static Future<bool> isValidGguf(File f, int specMb) async {
    try {
      if (!await f.exists()) return false;
      if (await f.length() < (specMb * 1048576 * 0.95).round()) return false;
      final raf = await f.open(mode: FileMode.read);
      try {
        final m = await raf.read(4);
        return m.length == 4 &&
            m[0] == 0x47 &&
            m[1] == 0x47 &&
            m[2] == 0x55 &&
            m[3] == 0x46;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> isReady(String id) async {
    final spec = aiModelCatalog[id];
    if (spec == null) return false;
    final dir = Directory('${(await modelsDir()).path}/$id');
    for (final f in spec.files) {
      final file = File('${dir.path}/$f');
      if (f.endsWith('.gguf')) {
        if (!await isValidGguf(file, spec.mb)) return false;
      } else if (!await file.exists()) {
        return false;
      }
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
    // Ethernet é cabeado e geralmente não-metrado (ex.: emulador/TV box).
    if (!allowMetered &&
        !conn.contains(ConnectivityResult.wifi) &&
        !conn.contains(ConnectivityResult.ethernet)) {
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
    final mb = aiModelCatalog[modelId]?.mb;
    if (filename.endsWith('.gguf') && mb != null) {
      if (!await isValidGguf(dest, mb)) {
        try {
          await dest.delete();
        } catch (_) {}
        throw const ModelDownloadException(
            'Modelo incompleto ou corrompido — baixe de novo no Wi-Fi.');
      }
    }
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
    int maxAttempts = 4,
  }) async {
    await dest.parent.create(recursive: true);
    final client = HttpClient();
    try {
      // Wi-Fi/4G real: o CDN do HF corta o corpo no meio ("Connection closed
      // while receiving data") e uma queda bastava para matar o download
      // inteiro (Haibane no Moto G7: SenseVoice + LFM falhavam e voltavam a
      // "faltando" sem mensagem). Os bytes já escritos ficam no arquivo, o
      // Range retoma de onde parou → cada tentativa só custa o pedaço faltante.
      for (var attempt = 1;; attempt++) {
        try {
          return await _fetchOnce(client, dest, url, headers, onProgress);
        } on ModelDownloadException catch (e) {
          // 'Download incompleto' pede retomada; só nessa última tenta
          // rethrow p/ o chamador ler a mensagem amigável.
          final partial =
              e.message.startsWith('Download incompleto');
          if (partial && attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 1 << attempt));
            continue;
          }
          rethrow;
        } on HttpException {
          if (attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 1 << attempt));
            continue;
          }
          // Sem o erro cru dentro: ele é longo (URL inteira) e a tela
          // mostra só a dica acionável; o detalhe fica no logcat.
          throw const ModelDownloadException(
              'Conexão caiu no meio do download. Toque em Gerar/ Baixar de '
              'novo — retoma de onde parou.');
        } on SocketException {
          if (attempt < maxAttempts) {
            await Future.delayed(Duration(seconds: 1 << attempt));
            continue;
          }
          throw const ModelDownloadException(
              'Sem rede no meio do download. Confira o Wi-Fi e toque em '
              'Gerar/ Baixar de novo — retoma de onde parou.');
        }
      }
    } finally {
      client.close();
    }
  }

  static Future<File> _fetchOnce(
    HttpClient client,
    File dest,
    String url,
    Map<String, String> headers,
    void Function(int got, int total)? onProgress,
  ) async {
    var start = await dest.exists() ? await dest.length() : 0;
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
    final knownLen = resp.contentLength >= 0;
    final total = (resp.contentLength < 0 ? 0 : resp.contentLength) + start;
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
    // Download interrompido parecia "completo" (causa do EP3): só confia
    // no total quando o servidor informou Content-Length.
    if (knownLen && got != total) {
      throw ModelDownloadException(
          'Download incompleto ($got/$total bytes). Tente de novo no Wi-Fi.');
    }
    return dest;
  }

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 11; TV) AppleWebKit/537.36';

  /// Download multi-parte (N conexões em paralelo por `Range`) para arquivos
  /// grandes — o vídeo do archive.org serve ~1-2 MB/s por conexão e aceita
  /// `Range`, então paralelizar dá 2-4x. Cada parte baixa em um arquivo
  /// próprio e retoma independente; no fim são concatenadas no destino. Se o
  /// servidor não expõe tamanho/206, cai no [fetchFile] (1 conexão) intacto.
  static Future<File> fetchFileParallel({
    required File dest,
    required String url,
    Map<String, String> headers = const {},
    int connections = 4,
    int minChunkBytes = 4 * 1024 * 1024,
    void Function(int got, int total)? onProgress,
    int maxAttempts = 4,
  }) async {
    final client = HttpClient();
    try {
      final total = await _probeTotal(client, url, headers);
      if (total == null || total <= 0) {
        return fetchFile(
            dest: dest, url: url, headers: headers, onProgress: onProgress);
      }
      if (await dest.exists() && await dest.length() == total) {
        onProgress?.call(total, total);
        return dest;
      }
      // Ajusta as conexões ao tamanho (evita 8 conexões p/ um arquivo pequeno).
      final n = (total / minChunkBytes).ceil().clamp(1, connections);
      if (n <= 1) {
        return fetchFile(
            dest: dest, url: url, headers: headers, onProgress: onProgress);
      }
      final chunk = (total / n).ceil();
      final parts = Directory('${dest.path}.parts');
      await parts.create(recursive: true);
      await dest.parent.create(recursive: true);
      final got = List<int>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        final f = File('${parts.path}/$i');
        if (await f.exists()) got[i] = await f.length();
      }
      void report() =>
          onProgress?.call(got.fold<int>(0, (a, b) => a + b), total);
      report();
      await Future.wait([
        for (var i = 0; i < n; i++)
          _downloadPart(
            client: client,
            url: url,
            headers: headers,
            part: File('${parts.path}/$i'),
            start: i * chunk,
            end: ((i + 1) * chunk - 1).clamp(0, total - 1),
            maxAttempts: maxAttempts,
            onDelta: (d) {
              got[i] += d;
              report();
            },
          ),
      ]);
      // Concatena (I/O local, rápido) e confere o tamanho final.
      final out = dest.openWrite();
      try {
        for (var i = 0; i < n; i++) {
          await out.addStream(File('${parts.path}/$i').openRead());
        }
      } finally {
        await out.close();
      }
      final len = await dest.length();
      if (len != total) {
        throw ModelDownloadException(
            'Download incompleto ($len/$total bytes). Tente de novo.');
      }
      try {
        await parts.delete(recursive: true);
      } catch (_) {}
      onProgress?.call(total, total);
      return dest;
    } finally {
      client.close();
    }
  }

  /// `Content-Range: bytes 0-0/12345` → 12345; null se o servidor não
  /// aceita `Range` (aí o chamador cai no single-connection).
  static Future<int?> _probeTotal(
      HttpClient client, String url, Map<String, String> headers) async {
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
        req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      }
      req.headers.set('Range', 'bytes=0-0');
      final resp = await req.close();
      final cr = resp.headers.value('content-range');
      await resp.drain<void>();
      if (resp.statusCode == 206 && cr != null) {
        final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
        if (m != null) return int.tryParse(m.group(1)!);
      }
      if (resp.statusCode == 200 && resp.contentLength > 0) {
        return resp.contentLength;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _downloadPart({
    required HttpClient client,
    required String url,
    required Map<String, String> headers,
    required File part,
    required int start,
    required int end,
    required int maxAttempts,
    required void Function(int delta) onDelta,
  }) async {
    final want = end - start + 1;
    for (var attempt = 1;; attempt++) {
      try {
        final have = await part.exists() ? await part.length() : 0;
        if (have >= want) return;
        final req = await client.getUrl(Uri.parse(url));
        headers.forEach(req.headers.set);
        if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
          req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        }
        req.headers.set('Range', 'bytes=${start + have}-$end');
        final resp = await req.close();
        if (resp.statusCode == 416) return; // parte já completa
        if (resp.statusCode != 200 && resp.statusCode != 206) {
          throw ModelDownloadException('HTTP ${resp.statusCode} em $url');
        }
        final sink =
            part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        try {
          await for (final b in resp) {
            sink.add(b);
            onDelta(b.length);
          }
        } finally {
          await sink.close();
        }
        if (await part.length() >= want) return;
        throw ModelDownloadException(
            'Download incompleto da parte $start-$end. Tente de novo.');
      } on ModelDownloadException catch (e) {
        final retryable = e.message.startsWith('Download incompleto') ||
            e.message.startsWith('HTTP ');
        if (retryable && attempt < maxAttempts) {
          await Future.delayed(Duration(seconds: 1 << attempt));
          continue;
        }
        rethrow;
      } on HttpException {
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(seconds: 1 << attempt));
          continue;
        }
        throw const ModelDownloadException(
            'Conexão caiu no meio do download. Tente de novo — retoma de '
            'onde parou.');
      } on SocketException {
        if (attempt < maxAttempts) {
          await Future.delayed(Duration(seconds: 1 << attempt));
          continue;
        }
        throw const ModelDownloadException(
            'Sem rede no meio do download. Confira o Wi-Fi e tente de novo.');
      }
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
