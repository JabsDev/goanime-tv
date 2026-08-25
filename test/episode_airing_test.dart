// Self-checks for the "episódio ainda não lançado" helper: detection logic
// (nextAiringEpisode bounds) and the PT-BR relative date formatting.
import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/utils/episode_airing.dart';
import 'package:goanime_tv/data/models/anime.dart';

void main() {
  final now = DateTime(2026, 8, 24, 12, 0); // segunda-feira, meio-dia

  DateTime at(int day, int hour, int minute) =>
      DateTime(2026, 8, day, hour, minute);
  int epoch(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

  test('sem info de exibição → null (não classifica)', () {
    expect(
      notAiredMessage(tappedEpisode: 8, anime: Anime(name: 'X', url: '')),
      isNull,
    );
  });

  test('episódio abaixo do próximo a lançar → null (falta real na fonte)', () {
    final anime = Anime(
      name: 'X',
      url: '',
      nextAiringEpisode: 8,
      nextAiringAt: epoch(at(25, 18, 0)),
    );
    expect(notAiredMessage(tappedEpisode: 7, anime: anime, now: now), isNull);
  });

  test('episódio == próximo a lançar, data amanhã → mensagem com data', () {
    final anime = Anime(
      name: 'X',
      url: '',
      nextAiringEpisode: 8,
      nextAiringAt: epoch(at(25, 18, 0)),
    );
    expect(
      notAiredMessage(tappedEpisode: 8, anime: anime, now: now),
      'O Episódio 8 ainda não foi lançado. '
      'Lançamento previsto: amanhã às 18:00.',
    );
  });

  test('episódio == próximo a lançar, mesmo dia → "hoje às ..."', () {
    final anime = Anime(
      name: 'X',
      url: '',
      nextAiringEpisode: 8,
      nextAiringAt: epoch(at(24, 20, 30)),
    );
    expect(
      notAiredMessage(tappedEpisode: 8, anime: anime, now: now),
      'O Episódio 8 ainda não foi lançado. '
      'Lançamento previsto: hoje às 20:30.',
    );
  });

  test('episódio além do próximo → data do próximo como referência', () {
    final anime = Anime(
      name: 'X',
      url: '',
      nextAiringEpisode: 8,
      nextAiringAt: epoch(at(25, 18, 0)),
    );
    expect(
      notAiredMessage(tappedEpisode: 9, anime: anime, now: now),
      'O Episódio 9 ainda não foi lançado. '
      'O próximo episódio (Ep 8) está previsto para amanhã às 18:00.',
    );
  });

  test('episódio == próximo mas sem data → só o aviso base', () {
    final anime = Anime(name: 'X', url: '', nextAiringEpisode: 8);
    expect(
      notAiredMessage(tappedEpisode: 8, anime: anime, now: now),
      'O Episódio 8 ainda não foi lançado.',
    );
  });

  test('formatRelativeDate: hoje / amanhã / dias / data longa', () {
    expect(formatRelativeDate(at(24, 9, 5), now), 'hoje às 09:05');
    expect(formatRelativeDate(at(25, 9, 5), now), 'amanhã às 09:05');
    expect(formatRelativeDate(at(27, 9, 5), now), 'em 3 dias (27/08 às 09:05)');
    expect(formatRelativeDate(DateTime(2026, 9, 5, 9, 5), now),
        '05/09/2026 às 09:05');
  });
}