class SkipInterval {
  final String skipType; // op, ed, mixed-op, mixed-ed, recap
  final double start; // seconds
  final double end; // seconds
  final String skipId;
  final double episodeLength; // seconds stored

  const SkipInterval({
    required this.skipType,
    required this.start,
    required this.end,
    required this.skipId,
    required this.episodeLength,
  });

  bool get isOpening => skipType.contains('op');
  bool get isEnding => skipType.contains('ed');
  bool get isRecap => skipType == 'recap';
}

class SkipResult {
  final bool found;
  final List<SkipInterval> intervals;

  const SkipResult({required this.found, required this.intervals});
}

class RelationRule {
  final int fromStart;
  final int fromEnd;
  final int toMalId;
  final int toStart;
  final int toEnd;

  const RelationRule({
    required this.fromStart,
    required this.fromEnd,
    required this.toMalId,
    required this.toStart,
    required this.toEnd,
  });

  bool contains(int ep) => ep >= fromStart && ep <= fromEnd;
  int mapEpisode(int ep) => ep - fromStart + toStart;
}
