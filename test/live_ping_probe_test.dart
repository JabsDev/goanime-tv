// Live probe for SourcePingService (NOT CI): run:
//   flutter test test/live_ping_probe_test.dart --dart-define=LIVE=1
import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/sources/source_ping_service.dart';
import 'package:goanime_tv/data/models/anime.dart';

void main() {
  final live = const String.fromEnvironment('LIVE') == '1';
  test('LIVE ping probe', timeout: const Timeout(Duration(minutes: 2)), () async {
    if (!live) return;

    final report = StringBuffer();
    final svc = SourcePingService.instance;
    for (final source in AnimeSource.values) {
      final ms = await svc.ping(source);
      report.writeln('  ${source.name.padRight(20)} -> '
          '${ms == null ? SourcePingService.unknownPing : '$ms ms'}');
    }

    // Same instance must reuse cache on the second probe.
    final first = await svc.ping(AnimeSource.animeFire);
    final second = await svc.ping(AnimeSource.animeFire);
    report.writeln('\nCache check animeFire: first=$first second=$second');

    // ignore: avoid_print
    print(report.toString());
  });
}