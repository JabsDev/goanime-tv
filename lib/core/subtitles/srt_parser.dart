/// Parser/formatter SRT mínimo (Rota S: traduz só texto, preserva tempos).
/// ponytail: regex única + split por bloco; sem dep nova.
class SrtCue {
  final int index;
  final Duration start;
  final Duration end;
  final String text;

  const SrtCue({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  SrtCue withText(String t) =>
      SrtCue(index: index, start: start, end: end, text: t);
}

class SrtParser {
  static final _ts = RegExp(
      r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})');

  static Duration _toDur(String h, String m, String s, String ms) =>
      Duration(
        hours: int.parse(h),
        minutes: int.parse(m),
        seconds: int.parse(s),
        milliseconds: int.parse(ms),
      );

  static String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = d.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  /// Parse tolerante: blocos sem índice/timestamp válido são ignorados.
  static List<SrtCue> parse(String src) {
    final out = <SrtCue>[];
    final blocks = src.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    var n = 0;
    for (final b in blocks) {
      final lines =
          b.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      var i = 0;
      var idx = ++n;
      if (lines.isNotEmpty && int.tryParse(lines[0].trim()) != null) {
        idx = int.parse(lines[0].trim());
        i = 1;
      }
      if (i >= lines.length) continue;
      final m = _ts.firstMatch(lines[i]);
      if (m == null) continue;
      final text = lines.sublist(i + 1).join('\n').trim();
      if (text.isEmpty) continue;
      out.add(SrtCue(
        index: idx,
        start: _toDur(m.group(1)!, m.group(2)!, m.group(3)!, m.group(4)!),
        end: _toDur(m.group(5)!, m.group(6)!, m.group(7)!, m.group(8)!),
        text: text,
      ));
    }
    return out;
  }

  static String format(List<SrtCue> cues) {
    final sb = StringBuffer();
    for (var k = 0; k < cues.length; k++) {
      final c = cues[k];
      sb.writeln(k + 1);
      sb.writeln('${_fmt(c.start)} --> ${_fmt(c.end)}');
      sb.writeln(c.text);
      sb.writeln();
    }
    return sb.toString();
  }

  /// Formatação estilo legenda TV: no máx 2 linhas de ~42 chars.
  /// Determinístico (não depende do humor do LLM): quebra por palavra,
  /// equilibra as 2 linhas pelo ponto mais próximo do meio.
  static const maxLineChars = 42;
  static const maxLines = 2;

  /// Compensação do pré-roll do VAD (silero entrega o chunk com ~100-200ms
  /// de silêncio antes da fala → legenda "adiantada"). Só no path STT;
  /// Rota S preserva os tempos da fonte.
  static const sttLeadCompensation = Duration(milliseconds: 150);

  static String rewrap(String text) {
    final words =
        text.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '';
    final lines = <String>[];
    var cur = StringBuffer();
    for (final w in words) {
      // Palavra gigante (URL, onomatopeia JA): quebra dura, sem loop infinito.
      var word = w;
      while (word.length > maxLineChars) {
        if (cur.isNotEmpty) {
          lines.add(cur.toString());
          cur = StringBuffer();
        }
        lines.add(word.substring(0, maxLineChars));
        word = word.substring(maxLineChars);
      }
      final add = (cur.isEmpty ? '' : ' ') + word;
      if (cur.length + add.length <= maxLineChars) {
        cur.write(add);
      } else {
        lines.add(cur.toString());
        cur = StringBuffer(word);
      }
    }
    if (cur.isNotEmpty) lines.add(cur.toString());
    if (lines.length <= maxLines) {
      if (lines.length == 2) return _balance(lines[0], lines[1]);
      return lines.join('\n');
    }
    // >2 linhas: não joga fora, só reembala em 2 (o split proporcional
    // abaixo cuida de dividir a cue quando couber). Fallback honesto.
    return _balance(lines.sublist(0, lines.length ~/ 2).join(' '),
        lines.sublist(lines.length ~/ 2).join(' '));
  }

  /// Junta 2 metades movendo a fronteira p/ o espaço mais perto do meio.
  static String _balance(String a, String b) {
    final full = ('$a $b').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (full.length <= maxLineChars + 1) return full.replaceFirst(' ', '\n');
    final mid = full.length ~/ 2;
    var best = -1;
    var bestDist = 1 << 30;
    for (var i = 0; i < full.length; i++) {
      if (full[i] != ' ') continue;
      final d = (i - mid).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    if (best < 0) return full; // sem espaço: linha única longa (raro)
    final l1 = full.substring(0, best);
    final l2 = full.substring(best + 1);
    if (l1.length <= maxLineChars && l2.length <= maxLineChars) {
      return '$l1\n$l2';
    }
    return full; // excede mesmo: split proporcional divide a cue adiante
  }

  /// Pós-processamento aplicado antes de salvar o .srt:
  /// rewrap 42x2 + divide cue longa em N cues de ≤2 linhas com tempo
  /// proporcional aos chars + clamp [1s, 7s] + (STT) shift +150ms.
  /// Resolve os 2 sintomas do QA: linha única gigante (mpv encolhe a fonte
  /// p/ caber) e 2ª frase do chunk aparecendo adiantada.
  static List<SrtCue> postprocess(List<SrtCue> cues, {bool fromStt = false}) {
    final out = <SrtCue>[];
    for (final c in cues) {
      var start = c.start;
      if (fromStt) {
        start += sttLeadCompensation;
        if (start >= c.end - const Duration(milliseconds: 400)) {
          start = c.start; // chunk curtíssimo: não inverte
        }
      }
      final chunks = _splitGroups(c.text);
      if (chunks.length <= 1) {
        final dur = _clampDur(c.end - start);
        out.add(SrtCue(
            index: 0, start: start, end: start + dur, text: chunks.single));
        continue;
      }
      final total = chunks.fold(0, (n, g) => n + g.length);
      var cursor = start;
      final span = c.end - start;
      for (var i = 0; i < chunks.length; i++) {
        final share = total == 0 ? 1 / chunks.length : chunks[i].length / total;
        var dur = Duration(
            milliseconds: (span.inMilliseconds * share).round());
        dur = _clampDur(dur);
        if (i == chunks.length - 1) {
          // Última parte: estica até o fim do chunk (sem ultrapassar 7s).
          final rest = c.end - cursor;
          if (rest < dur) dur = _clampDur(rest);
        }
        if (cursor + dur > c.end) dur = c.end - cursor;
        if (dur.inMilliseconds < 400) dur = const Duration(milliseconds: 400);
        out.add(SrtCue(index: 0, start: cursor, end: cursor + dur, text: chunks[i]));
        cursor += dur + const Duration(milliseconds: 80);
        if (cursor >= c.end) break;
      }
    }
    // Reindexa + evita sobreposição com a próxima cue (shift pode colar).
    for (var i = 0; i < out.length; i++) {
      final c = out[i];
      var end = c.end;
      if (i + 1 < out.length && end > out[i + 1].start) {
        end = out[i + 1].start - const Duration(milliseconds: 80);
        if (end <= c.start + const Duration(milliseconds: 400)) {
          end = c.start + const Duration(milliseconds: 400);
        }
      }
      out[i] = SrtCue(index: i + 1, start: c.start, end: end, text: c.text);
    }
    return out;
  }

  /// Quebra o texto em grupos de ≤2 linhas balanceadas (cada grupo vira 1 cue).
  static List<String> _splitGroups(String text) {
    final words =
        text.replaceAll(RegExp(r'\s+'), ' ').trim().split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return [''];
    final lines = <String>[];
    var cur = StringBuffer();
    for (final w in words) {
      var word = w;
      while (word.length > maxLineChars) {
        if (cur.isNotEmpty) {
          lines.add(cur.toString());
          cur = StringBuffer();
        }
        lines.add(word.substring(0, maxLineChars));
        word = word.substring(maxLineChars);
      }
      final add = (cur.isEmpty ? '' : ' ') + word;
      if (cur.length + add.length <= maxLineChars) {
        cur.write(add);
      } else {
        lines.add(cur.toString());
        cur = StringBuffer(word);
      }
    }
    if (cur.isNotEmpty) lines.add(cur.toString());
    final groups = <String>[];
    for (var i = 0; i < lines.length; i += maxLines) {
      final g = lines.sublist(i, (i + maxLines).clamp(0, lines.length));
      groups.add(g.length == 2 ? _balance(g[0], g[1]) : g.single);
    }
    return groups;
  }

  static Duration _clampDur(Duration d) {
    if (d < const Duration(seconds: 1)) return const Duration(seconds: 1);
    if (d > const Duration(seconds: 7)) return const Duration(seconds: 7);
    return d;
  }

  /// Detecta idioma da legenda: tag explícita > nome do arquivo > null.
  /// Retorna 'en', 'es', 'ja' ou null (picker manual no dialog).
  static String? detectLang({String? tag, String? filename}) {
    for (final cand in [tag, filename]) {
      if (cand == null) continue;
      final l = cand.toLowerCase();
      if (RegExp(r'\b(en|eng|english)\b|\.en\.').hasMatch(l)) return 'en';
      if (RegExp(r'\b(es|spa|spanish|esp)\b|\.es\.').hasMatch(l)) return 'es';
      if (RegExp(r'\b(ja|jpn|japanese)\b|\.ja\.').hasMatch(l)) return 'ja';
    }
    return null;
  }
}
