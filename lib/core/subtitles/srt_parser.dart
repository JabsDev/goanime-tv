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
