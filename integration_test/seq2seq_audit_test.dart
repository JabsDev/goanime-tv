import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/core/subtitles/seq2seq_audit.dart';
import 'package:goanime_tv/core/subtitles/srt_parser.dart';

/// Testa o AUDITOR seq2seq treinado NO APARELHO (ONNX int8 nativo).
/// Modelos em /data/local/tmp/auditor/ (encoder.int8.onnx + decoder.int8.onnx).
/// Entrada: as mesmas 12 cues JA do STT do EP3 (trecho de 2 min).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const dir = '/data/local/tmp/auditor';

  SrtCue c(int i, double s, double e, String t) => SrtCue(
        index: i,
        start: Duration(milliseconds: (s * 1000).round()),
        end: Duration(milliseconds: (e * 1000).round()),
        text: t,
      );

  final cues = <SrtCue>[
    c(1, 2.1, 2.9, 'こっち、こっち!'),
    c(2, 4.2, 6.0, 'ジーンって街にあるんじゃないの?'),
    c(3, 6.4, 6.7, 'んっ、んんっ!'),
    c(4, 8.0, 10.4, '血外れのもっと外れって感じかな?'),
    c(5, 10.9, 14.3, '近くにごちがあったりして、用がないと誰も近寄らないの?'),
    c(6, 17.4, 18.2, '気をつけてぇ。'),
    c(7, 25.8, 26.3, 'これこれ。'),
    c(8, 27.2, 29.6, '気が悪かったから心配してたんだわ。'),
    c(9, 44.1, 46.1, 'じゃあどうして氷のかかりになったの?'),
    c(10, 47.3, 49.2, 'そして、で別に、あははっ!'),
    c(11, 51.3, 51.7, 'わかった!'),
    c(12, 62.6, 64.1, 'するけど怖くないよー?'),
  ];

  testWidgets('auditor seq2seq no aparelho', (tester) async {
    final a = Seq2SeqAuditProvider(dir);
    // aquece (carrega as sessoes ORT) + 1a cue
    final warm = Stopwatch()..start();
    final first = await a.fix(cues[0].text);
    // ignore: avoid_print
    print('WARM ${warm.elapsedMilliseconds}ms -> $first');

    final sw = Stopwatch()..start();
    final out = <SrtCue>[cues[0].withText(first)];
    const n = 12;
    for (var i = 1; i < n && i < cues.length; i++) {
      final t0 = Stopwatch()..start();
      final r = await a.fix(cues[i].text);
      // ignore: avoid_print
      print('CUE ${i + 1}/12 ${t0.elapsedMilliseconds}ms '
          '${r.trim() == cues[i].text.trim() ? "(igual)" : "(mudou)"}\n'
          '  in : ${cues[i].text}\n  out: $r');
      out.add(cues[i].withText(r));
    }
    await a.dispose();
    // ignore: avoid_print
    print('TOTAL=${sw.elapsedMilliseconds}ms');

    final srt = SrtParser.format(out);
    for (final p in ['/sdcard/Download/ep3_seq2seq_ja.srt',
                     '/data/local/tmp/ep3_seq2seq_ja.srt',
                     '/data/user/0/com.example.goanime_tv/ep3_seq2seq_ja.srt']) {
      try {
        await File(p).writeAsString(srt);
        // ignore: avoid_print
        print('SRT salvo em $p');
        break;
      } catch (_) {/* sem permissao: tenta o proximo */}
    }
  });
}
