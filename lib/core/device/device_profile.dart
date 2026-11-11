import 'package:flutter/foundation.dart';

/// Mimes usados no perfil de decode (mesmos do `HardwareChannel.kt`).
const String kMimeH264 = 'video/avc';
const String kMimeHevc = 'video/hevc';
const String kMimeVp9 = 'video/x-vnd.on2.vp9';
const String kMimeAv1 = 'video/av01';

/// Nível de potência do aparelho — separa "pouca RAM" de "CPU/decode fraco".
///
/// O projetor H713 (4×A53 @1,3 GHz, 32 bits, 1 GB) e o Fire Stick Lite
/// (4×A53 @1,7 GHz, 1 GB) têm a mesma RAM, mas não a mesma capacidade de
/// tocar HD. O teto de qualidade segue o nível, não a RAM.
enum DeviceTier {
  low('Limitado', 480, '480p'),
  mid('Intermediário', 720, '720p'),
  high('Capaz', null, 'melhor disponível');

  const DeviceTier(this.label, this.maxQualityHeight, this.qualityLabel);

  final String label;

  /// Teto de qualidade padrão (altura em px). `null` = sem teto.
  final int? maxQualityHeight;

  /// Rótulo legível do teto ("480p", "720p", "melhor disponível").
  final String qualityLabel;
}

/// Capacidade de um codec: aceleração de hardware + maior tamanho suportado.
@immutable
class CodecSupport {
  const CodecSupport({
    required this.hardware,
    this.maxWidth = 0,
    this.maxHeight = 0,
  });

  /// Há decoder com aceleração de hardware (não só software).
  final bool hardware;

  /// Maior resolução que o decoder aceita. 0 = desconhecida.
  final int maxWidth;
  final int maxHeight;

  bool supportsHeight(int height) => maxHeight >= height;

  factory CodecSupport.fromMap(Map<Object?, Object?> map) {
    final w = _asInt(map['maxWidth']);
    final h = _asInt(map['maxHeight']);
    return CodecSupport(
      hardware: _asBool(map['hardware']),
      maxWidth: w,
      maxHeight: h,
    );
  }

  /// Resumo curto para diagnóstico: "HW 1080p", "SW 480p", "—".
  String get shortLabel {
    if (maxHeight <= 0) return hardware ? 'HW' : '—';
    final res = maxHeight >= 2160
        ? '4K'
        : maxHeight >= 1440
        ? '1440p'
        : maxHeight >= 1080
        ? '1080p'
        : maxHeight >= 720
        ? '720p'
        : '480p';
    return '${hardware ? 'HW' : 'SW'} $res';
  }
}

/// Retrato do hardware coletado no boot (Android). Campos que o aparelho não
/// expõe ficam em zero/null — o score trata cada ausência com neutralidade.
@immutable
class DeviceProfile {
  const DeviceProfile({
    required this.model,
    required this.manufacturer,
    required this.hardware,
    required this.androidRelease,
    required this.sdkInt,
    required this.abis,
    required this.is64Bit,
    required this.neon,
    required this.cores,
    required this.cpuMaxFreqMhz,
    required this.totalRamMb,
    required this.availableRamMb,
    required this.lowRamDevice,
    required this.memoryClassMb,
    required this.codecs,
  });

  final String model;
  final String manufacturer;
  final String hardware;
  final String androidRelease;
  final int sdkInt;
  final List<String> abis;
  final bool is64Bit;
  final bool neon;
  final int cores;
  final int? cpuMaxFreqMhz;
  final int totalRamMb;
  final int availableRamMb;
  final bool lowRamDevice;
  final int memoryClassMb;
  final Map<String, CodecSupport> codecs;

  CodecSupport? codec(String mime) => codecs[mime];

  /// Decoder H.264 de hardware em 720p? H.264 é o codec-base das fontes: sem
  /// ele, 720p em software num aparelho fraco não sustenta tempo real.
  bool get hwH264At720 {
    final c = codecs[kMimeH264];
    return c != null && c.hardware && c.supportsHeight(720);
  }

  bool get hwH264At1080 {
    final c = codecs[kMimeH264];
    return c != null && c.hardware && c.supportsHeight(1080);
  }

  bool get hwHevcAt720 {
    final c = codecs[kMimeHevc];
    return c != null && c.hardware && c.supportsHeight(720);
  }

  bool get hwHevcAt1080 {
    final c = codecs[kMimeHevc];
    return c != null && c.hardware && c.supportsHeight(1080);
  }

  bool get hwVp9At1080 {
    final c = codecs[kMimeVp9];
    return c != null && c.hardware && c.supportsHeight(1080);
  }

  bool get hwAv1At1080 {
    final c = codecs[kMimeAv1];
    return c != null && c.hardware && c.supportsHeight(1080);
  }

  /// Maior resolução de hardware entre os codecs que o app usa. Serve para
  /// exibir "decode até 1080p" mesmo sem detalhar cada mime.
  int get maxHardwareDecodeHeight {
    var max = 0;
    for (final c in codecs.values) {
      if (c.hardware && c.maxHeight > max) max = c.maxHeight;
    }
    return max;
  }

  /// ABI principal (a primeira é a preferida pelo Android).
  String get abi => abis.isEmpty ? 'desconhecida' : abis.first;

  String get ramLabel =>
      totalRamMb > 0 ? '${(totalRamMb / 1024).toStringAsFixed(1)} GB' : '?';

  String get availableRamLabel =>
      availableRamMb > 0 ? '$availableRamMb MB livres' : 'RAM livre ?';

  String get cpuLabel {
    final clock = cpuMaxFreqMhz != null ? ' @ $cpuMaxFreqMhz MHz' : '';
    final bits = is64Bit ? '64 bits' : '32 bits';
    final neonTag = neon ? ' · NEON' : '';
    return '$cores núcleos$clock · $bits$neonTag';
  }

  String get decodeLabel {
    final parts = <String>[
      'H.264 ${codecs[kMimeH264]?.shortLabel ?? '—'}',
      'HEVC ${codecs[kMimeHevc]?.shortLabel ?? '—'}',
      'VP9 ${codecs[kMimeVp9]?.shortLabel ?? '—'}',
      'AV1 ${codecs[kMimeAv1]?.shortLabel ?? '—'}',
    ];
    return parts.join(' · ');
  }

  factory DeviceProfile.fromMap(Map<String, dynamic> map) {
    final rawCodecs = map['codecs'];
    final codecs = <String, CodecSupport>{};
    if (rawCodecs is Map) {
      rawCodecs.forEach((key, value) {
        if (key is String && value is Map) {
          codecs[key] = CodecSupport.fromMap(value);
        }
      });
    }
    final rawAbis = map['abis'];
    final abis = <String>[
      if (rawAbis is List)
        for (final a in rawAbis)
          if (a is String && a.isNotEmpty) a,
    ];
    return DeviceProfile(
      model: _asString(map['model']),
      manufacturer: _asString(map['manufacturer']),
      hardware: _asString(map['hardware']),
      androidRelease: _asString(map['androidRelease']),
      sdkInt: _asInt(map['sdkInt']),
      abis: abis,
      is64Bit: _asBool(map['is64Bit']),
      neon: _asBool(map['neon']),
      cores: _asInt(map['cores']).clamp(1, 64),
      cpuMaxFreqMhz: _positiveOrNull(map['cpuMaxFreqMhz']),
      totalRamMb: _asInt(map['totalRamMb']),
      availableRamMb: _asInt(map['availableRamMb']),
      lowRamDevice: _asBool(map['lowRamDevice']),
      memoryClassMb: _asInt(map['memoryClassMb']),
      codecs: codecs,
    );
  }
}

/// Resultado do benchmark de vídeo: fps efetivo tocado em cada resolução.
///
/// Diferente do [DeviceBenchmark] (microbenchmark de CPU), este mede o
/// caminho real do player (decode + render do mpv) com clipes H.264 locais
/// em 480p/720p/1080p. É a evidência mais forte para decidir o teto de
/// qualidade, porque reproduz o cenário que o usuário vê: "toca 720p sem
/// travar?".
@immutable
class VideoBenchmark {
  const VideoBenchmark({
    required this.fpsByHeight,
    this.containerFps = 30,
    this.hardwareDecode = false,
    this.elapsed = Duration.zero,
  });

  /// fps medido por altura (480/720/1080). Resoluções não medidas — porque o
  /// teste parou quando a anterior não sustentou, ou porque o aparelho não
  /// abriu o clipe — simplesmente não aparecem.
  final Map<int, double> fpsByHeight;

  /// fps da fonte dos clipes (30). O alvo de tempo real é
  /// `containerFps × kVideoFpsRatio`.
  final double containerFps;

  /// O decode usou aceleração de hardware (`hwdec-current` ≠ `no`).
  final bool hardwareDecode;

  final Duration elapsed;

  bool get isEmpty => fpsByHeight.isEmpty;

  double? fpsFor(int height) => fpsByHeight[height];

  /// Resolução mais alta que rodou em tempo real, ou `null` se nem 480p.
  int? get sustainedHeight => videoSustainedHeight(this);
}

/// fps mínimo para dizer que uma resolução "roda": 85% do fps da fonte, com
/// piso de [kVideoFpsFloor]. Abaixo disso o olho vê engasgo mesmo que o vídeo
/// não pare por completo.
const double kVideoFpsRatio = 0.85;
const double kVideoFpsFloor = 20;

double videoRequiredFps(double containerFps) {
  final scaled = containerFps * kVideoFpsRatio;
  return scaled > kVideoFpsFloor ? scaled : kVideoFpsFloor;
}

bool videoSustainsFps(double fps, double containerFps) =>
    fps >= videoRequiredFps(containerFps);

/// Maior altura cujo fps medido sustenta tempo real. `null` = limitação.
int? videoSustainedHeight(VideoBenchmark video) {
  var best = 0;
  for (final entry in video.fpsByHeight.entries) {
    if (entry.key > best && videoSustainsFps(entry.value, video.containerFps)) {
      best = entry.key;
    }
  }
  return best == 0 ? null : best;
}

/// Divisor de nível a partir do que o vídeo provou rodar.
DeviceTier videoTier(VideoBenchmark video) {
  final sustained = videoSustainedHeight(video);
  if (sustained == null || sustained < 720) return DeviceTier.low;
  if (sustained < 1080) return DeviceTier.mid;
  return DeviceTier.high;
}

/// Score 0–100 coerente com o nível: a base vem da resolução sustentada e o
/// resto da folga de fps (0–8 pts) na melhor resolução medida.
double videoScore(VideoBenchmark video) {
  final sustained = videoSustainedHeight(video);
  final base = sustained == null
      ? 18.0
      : sustained >= 1080
      ? 88.0
      : sustained >= 720
      ? 66.0
      : 42.0;
  final measured = sustained == null
      ? video.fpsByHeight.values.fold<double>(0, (a, b) => a > b ? a : b)
      : video.fpsByHeight[sustained] ?? 0;
  final ratio = video.containerFps > 0 ? measured / video.containerFps : 0.0;
  final headroom = ((ratio - 1) / 0.2).clamp(0.0, 1.0) * 8;
  return (base + headroom).clamp(0.0, 100.0);
}

/// Resultado da avaliação: nível + score 0–100 + porquês (diagnóstico).
@immutable
class DeviceAssessment {
  const DeviceAssessment({
    required this.tier,
    required this.score,
    this.reasons = const [],
    this.benchmarkUsed = false,
    this.videoBenchmarkUsed = false,
  });

  final DeviceTier tier;
  final int score;
  final List<String> reasons;
  final bool benchmarkUsed;

  /// O nível foi decidido pelo benchmark de vídeo (fps real), não só pelo
  /// perfil estático de hardware.
  final bool videoBenchmarkUsed;

  int? get maxQualityHeight => tier.maxQualityHeight;

  /// Perfil indisponível (desktop/teste/canal falhou): não penaliza o usuário.
  static const unknown = DeviceAssessment(
    tier: DeviceTier.high,
    score: 80,
    reasons: ['Perfil de hardware indisponível; usando modo completo.'],
  );
}

// Pesos (somam 100). O clock domina de propósito: é o que separa o projetor
// de 1,3 GHz do Fire Stick de 1,7 GHz com a mesma RAM.
const double _freqWeight = 35;
const double _coresWeight = 8;
const double _coresBonus8 = 2;
const double _bitsWeight = 8;
const double _totalRamWeight = 10;
const double _availableRamWeight = 7;
const double _decodeWeight = 20;
const double _benchmarkWeight = 10;

/// Faixas dos níveis. Amplas de propósito: as duas métricas incertas
/// (clock ausente e benchmark) só precisam separar diferenças grandes.
const double kLowTierMaxScore = 62;
const double kHighTierMinScore = 80;

/// Combina hardware estático + benchmarks opcionais num nível acionável.
///
/// [benchmarkScore] é o índice 0–100 do `DeviceBenchmark` (CPU). [video] é o
/// resultado do benchmark de vídeo: quando existe, ele **manda** no nível,
/// porque mede o caminho real de decode/render — é o que corrige o caso de um
/// aparelho que pontua bem no microbenchmark e engasga em 720p.
DeviceAssessment assessDevice(
  DeviceProfile profile, {
  double? benchmarkScore,
  VideoBenchmark? video,
}) {
  final reasons = <String>[];
  final bench = benchmarkScore?.clamp(0.0, 100.0).toDouble();
  final hasVideo = video != null && !video.isEmpty;

  var score = 0.0;

  // CPU: clock do maior núcleo. Quando o /sys nega leitura, o benchmark
  // substitui a informação em vez de deixar todo aparelho igual.
  final freq = profile.cpuMaxFreqMhz;
  if (freq != null && freq > 0) {
    final norm = ((freq - 1000) / 800).clamp(0.0, 1.0);
    score += norm * _freqWeight;
    reasons.add('CPU ${profile.cores}× @ $freq MHz');
  } else if (bench != null) {
    score += (bench / 100) * _freqWeight;
    reasons.add('Clock do CPU indisponível; usando benchmark');
  } else {
    score += _freqWeight / 2;
    reasons.add('Clock do CPU indisponível (rode o benchmark)');
  }

  // Núcleos: 4 já basta para decodificar/UI; 8+ ganha o bônus.
  score += (profile.cores / 4).clamp(0.0, 1.0) * _coresWeight;
  if (profile.cores >= 8) score += _coresBonus8;

  // Instruções: 64 bits abre os decoders otimizados e mais registradores.
  if (profile.is64Bit) {
    score += _bitsWeight;
    reasons.add(
      'ABI ${profile.abi} (64 bits${profile.neon ? ' · NEON/ASIMD' : ''})',
    );
  } else {
    score += profile.neon ? 6 : 2;
    reasons.add('ABI ${profile.abi} (32 bits${profile.neon ? ' · NEON' : ''})');
  }

  // RAM: total pesa mais que livre (livre oscila com o uso do sistema).
  if (profile.totalRamMb > 0) {
    score +=
        ((profile.totalRamMb - 512) / 2560).clamp(0.0, 1.0) * _totalRamWeight;
    reasons.add('RAM ${profile.ramLabel}');
  } else {
    score += _totalRamWeight / 2;
  }
  if (profile.availableRamMb > 0) {
    score +=
        ((profile.availableRamMb - 256) / 768).clamp(0.0, 1.0) *
        _availableRamWeight;
    reasons.add(profile.availableRamLabel);
  } else {
    score += _availableRamWeight / 2;
  }

  // Decode: o que importa para o player é H.264/HEVC em 1080p; VP9/AV1 são
  // bônus (algumas fontes só servem AV1 e caem para software sem decoder).
  score += _decodeScore(profile);
  reasons.add('Decode: ${profile.decodeLabel}');

  if (bench != null) {
    score += 5 + (bench / 100) * 10; // 5–15, neutro (bench 50) = 10
    reasons.add('Benchmark ${bench.round()}/100');
  } else {
    score += _benchmarkWeight / 2;
  }

  DeviceTier tier;
  if (hasVideo) {
    tier = videoTier(video);
    reasons.add('Vídeo: ${_videoFpsLabel(video)}');
    if (video.hardwareDecode) reasons.add('Decode de vídeo por hardware');
    final total = videoScore(video).round().clamp(0, 100);
    // RAM ainda limita o "capaz": o teste de poucos segundos não reproduz a
    // pressão de memória de uma sessão inteira (buffers + cache + Flutter).
    if (tier == DeviceTier.high &&
        profile.totalRamMb > 0 &&
        profile.totalRamMb <= 1536) {
      tier = DeviceTier.mid;
      reasons.add('RAM ≤ 1,5 GB limita o teto a 720p');
    } else if (tier == DeviceTier.high &&
        profile.lowRamDevice &&
        profile.totalRamMb > 0 &&
        profile.totalRamMb <= 2048) {
      tier = DeviceTier.mid;
      reasons.add('Aparelho marcado como low-RAM pelo Android');
    }
    return DeviceAssessment(
      tier: tier,
      score: total,
      reasons: reasons,
      benchmarkUsed: bench != null,
      videoBenchmarkUsed: true,
    );
  }

  final total = score.round().clamp(0, 100);
  tier = total >= kHighTierMinScore
      ? DeviceTier.high
      : total >= kLowTierMaxScore
      ? DeviceTier.mid
      : DeviceTier.low;

  // Trava dura: sem H.264 em 720p por hardware, nada acima de 480p é honesto.
  if (!profile.hwH264At720) {
    if (tier != DeviceTier.low) {
      reasons.add('Sem H.264 de hardware em 720p');
    }
    tier = DeviceTier.low;
  } else if (profile.cpuMaxFreqMhz != null &&
      profile.cpuMaxFreqMhz! <= 1400 &&
      profile.totalRamMb > 0 &&
      profile.totalRamMb <= 1024) {
    // O caso do projetor H713: 1 GB + 1,3 GHz não sustenta 720p por muito
    // tempo (buffers do player + Flutter disputam a mesma RAM), mesmo que o
    // benchmark pontue bem num teste curto.
    if (tier != DeviceTier.low) {
      reasons.add('1 GB de RAM com CPU ≤ 1,4 GHz limita a 480p');
    }
    tier = DeviceTier.low;
  } else if (tier == DeviceTier.high) {
    // 1 GB (ou low-RAM do Android) não sustenta o modo completo em 1080p:
    // buffers do player + Flutter + cache estouram antes da CPU.
    if (profile.totalRamMb > 0 && profile.totalRamMb <= 1536) {
      tier = DeviceTier.mid;
      reasons.add('RAM ≤ 1,5 GB limita o teto a 720p');
    } else if (profile.lowRamDevice &&
        profile.totalRamMb > 0 &&
        profile.totalRamMb <= 2048) {
      tier = DeviceTier.mid;
      reasons.add('Aparelho marcado como low-RAM pelo Android');
    }
  }

  return DeviceAssessment(
    tier: tier,
    score: total,
    reasons: reasons,
    benchmarkUsed: bench != null,
  );
}

/// "480p 30 fps · 720p 21 fps ✗ · teto medido 480p".
String _videoFpsLabel(VideoBenchmark video) {
  const heights = [480, 720, 1080];
  final parts = <String>[];
  for (final h in heights) {
    final fps = video.fpsByHeight[h];
    if (fps == null) break;
    final mark = videoSustainsFps(fps, video.containerFps) ? '' : ' ✗';
    parts.add('${h}p ${fps.toStringAsFixed(0)} fps$mark');
  }
  final measured = video.fpsByHeight.keys.reduce((a, b) => a > b ? a : b);
  final sustained = videoSustainedHeight(video);
  if (sustained == null) {
    parts.add('não sustentou 480p');
  } else if (sustained < 1080) {
    parts.add('teto medido ${measured}p');
  }
  return parts.join(' · ');
}

double _decodeScore(DeviceProfile p) {
  var s = 0.0;
  final h264 = p.codecs[kMimeH264];
  if (h264 != null && h264.hardware) {
    if (h264.supportsHeight(720)) s += 5;
    if (h264.supportsHeight(1080)) s += 3;
  }
  final hevc = p.codecs[kMimeHevc];
  if (hevc != null && hevc.hardware) {
    if (hevc.supportsHeight(720)) s += 3;
    if (hevc.supportsHeight(1080)) s += 2;
  }
  final vp9 = p.codecs[kMimeVp9];
  if (vp9 != null && vp9.hardware && vp9.supportsHeight(1080)) s += 3;
  final av1 = p.codecs[kMimeAv1];
  if (av1 != null && av1.hardware && av1.supportsHeight(1080)) s += 4;
  return s.clamp(0.0, _decodeWeight);
}

// Helpers defensivos: o mapa vem de plataforma e pode ter tipos inesperados.

String _asString(Object? v) => v is String ? v : '';

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

int? _positiveOrNull(Object? v) {
  final n = _asInt(v);
  return n > 0 ? n : null;
}

bool _asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.toLowerCase() == 'true';
  return false;
}
