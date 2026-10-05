import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:goanime_tv/core/subtitles/auditor.dart';
import 'package:goanime_tv/core/subtitles/srt_parser.dart';

/// Isola o estagio AuditJA no aparelho. Entrada: as 12 cues JA que o STT
/// destilado ja produziu no EP3 (trecho de 2 min). Mede tempo por cue e
/// imprime ANTES/DEPOIS — o gargalo do fluxo completo era aqui.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const stg = '/data/local/tmp/models_stage';

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

  testWidgets('auditJA isolado', (tester) async {
    final a = AuditProvider('$stg/auditor.gguf');
    final sw = Stopwatch()..start();
    await a.load();
    // ignore: avoid_print
    print('LOAD_OK ${sw.elapsedMilliseconds}ms (native so carrega no 1o audit)');

    // Mede só 2 cues: o objetivo é ver se o template de chat mata o runaway.
    const n = 2;
    final out = <SrtCue>[];
    for (var i = 0; i < n; i++) {
      final t0 = Stopwatch()..start();
      // ignore: avoid_print
      print('CUE ${i + 1}/$n START t=${sw.elapsedMilliseconds}ms');
      final r = await a.auditJa([cues[i]]);
      final dt = t0.elapsedMilliseconds;
      final same = r.first.text.trim() == cues[i].text.trim();
      // ignore: avoid_print
      print('CUE ${i + 1}/$n END ${dt}ms ${same ? "(sem mudanca)" : "(ALTEROU)"}\n'
          '  in : ${cues[i].text}\n  out: ${r.first.text}');
      out.add(r.first);
    }
    await a.dispose();
    // ignore: avoid_print
    print('AUDIT_JA_OK total=${sw.elapsedMilliseconds}ms');

    final srt = SrtParser.format(out);
    try {
      await File('/sdcard/Download/ep3_2_audit_ja.srt').writeAsString(srt);
    } catch (_) {
      await File('/data/local/tmp/ep3_2_audit_ja.srt').writeAsString(srt);
    }
  });
}
