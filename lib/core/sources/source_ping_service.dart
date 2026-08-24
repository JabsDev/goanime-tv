import 'dart:async';
import 'dart:io';

import '../../data/models/anime.dart';

/// Measures source latency with a lightweight TCP connect (SYN/ACK round-trip
/// to port 443) as a proxy for the provider's effective latency. Cached for
/// [ttl] so re-opening the dialog doesn't re-probe.
class SourcePingService {
  SourcePingService._();

  static final SourcePingService instance = SourcePingService._();

  static const Duration ttl = Duration(seconds: 60);
  static const Duration timeout = Duration(seconds: 3);

  /// Prefix used when a probe fails or times out.
  static const String unknownPing = '--';

  static const Map<AnimeSource, String> _domains = {
    AnimeSource.animeFire: 'animefire.io',
    AnimeSource.goyabu: 'goyabu.io',
    AnimeSource.betterAnime: 'betteranime.io',
    AnimeSource.animesRoll: 'anroll.tv',
    AnimeSource.dooPlay: 'betteranime.io',
    AnimeSource.animePlayer: 'animeplayer.com.br',
    AnimeSource.animesOnlineCloud: 'animesonline.cloud',
    AnimeSource.animesDrive: 'animesdrive.online',
    AnimeSource.animeQ: 'animeq.blog',
    AnimeSource.animePlay: 'animeplay.cloud',
    AnimeSource.animesOnlineHdk: 'animesonlinehdk.com',
    AnimeSource.animesOrion: 'animesorion.cc',
    AnimeSource.animesHd: 'animeshd.to',
  };

  final Map<AnimeSource, ({int ms, DateTime at})> _cache = {};
  final Map<AnimeSource, Future<int?>> _inFlight = {};

  /// Returns the measured latency in milliseconds, or `null` if the source has
  /// no pingable domain ([AnimeSource] without streaming — AniList/AllAnime)
  /// or the probe failed/timed out.
  Future<int?> ping(AnimeSource source) {
    final cached = _cache[source];
    if (cached != null && DateTime.now().difference(cached.at) < ttl) {
      return Future.value(cached.ms);
    }
    return _inFlight[source] ??= _measure(source).whenComplete(() {
      _inFlight.remove(source);
    });
  }

  Future<int?> _measure(AnimeSource source) async {
    final host = _domains[source];
    if (host == null) return null;
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, 443, timeout: timeout);
      await socket.close();
      stopwatch.stop();
      final ms = stopwatch.elapsedMilliseconds;
      _cache[source] = (ms: ms, at: DateTime.now());
      return ms;
    } catch (_) {
      return null;
    }
  }
}