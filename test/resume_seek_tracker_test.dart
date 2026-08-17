import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/features/player/resume_seek_tracker.dart';

void main() {
  late DateTime now;
  late ResumeSeekTracker tracker;

  setUp(() {
    now = DateTime(2026, 1, 1);
    tracker = ResumeSeekTracker(clock: () => now);
  });

  test('Furo 1: amostra pré-ready não confirma; re-seek após ready', () {
    tracker.arm(120);
    // posição pré-ready já "no alvo" NÃO confirma (time-pos enfileirado).
    expect(tracker.onPosition(119), isFalse);
    expect(tracker.confirmed, isFalse);
    tracker.markVideoReady();
    // posição caiu para ~0 depois de pronto → re-seek emitido.
    expect(tracker.onPosition(0.5), isTrue);
  });

  test('confirmação exige 2 amostras consecutivas (time-pos fantasma)', () {
    tracker.arm(120);
    tracker.markVideoReady();
    expect(tracker.onPosition(119), isFalse);
    expect(tracker.confirmed, isFalse); // 1ª amostra não confirma
    expect(tracker.onPosition(119), isFalse);
    expect(tracker.confirmed, isTrue); // 2ª amostra consecutiva confirma
    expect(tracker.isArmed, isFalse);
  });

  test('Furo 2: backoff + teto de tentativas', () {
    tracker.arm(120);
    tracker.markVideoReady();
    expect(tracker.onPosition(0.5), isTrue); // retries 1
    expect(tracker.onPosition(0.5), isFalse); // backoff não decorrido
    now = now.add(const Duration(milliseconds: 1500));
    expect(tracker.onPosition(0.5), isTrue); // retries 2
    now = now.add(const Duration(milliseconds: 1500));
    expect(tracker.onPosition(0.5), isTrue); // retries 3
    now = now.add(const Duration(milliseconds: 1500));
    expect(tracker.onPosition(0.5), isFalse); // teto → desiste
    expect(tracker.confirmed, isTrue);
  });

  test('zona de conforto não dispara seek e confirma', () {
    tracker.arm(120);
    tracker.markVideoReady();
    expect(tracker.onPosition(117), isFalse);
    expect(tracker.onPosition(117), isFalse);
    expect(tracker.confirmed, isTrue);
  });

  test('arm(0)/reset() desarma', () {
    tracker.arm(120);
    tracker.reset();
    expect(tracker.isArmed, isFalse);
    expect(tracker.onPosition(0.5), isFalse);
    tracker.arm(0);
    expect(tracker.isArmed, isFalse);
  });

  test('pré-ready nunca re-emite seek', () {
    tracker.arm(120);
    expect(tracker.onPosition(0.5), isFalse);
    expect(tracker.onPosition(0.5), isFalse);
    expect(tracker.confirmed, isFalse);
  });

  test('seek manual para o início não é raptado (zona já confirmou)', () {
    tracker.arm(120);
    tracker.markVideoReady();
    expect(tracker.onPosition(119), isFalse);
    expect(tracker.onPosition(119), isFalse);
    expect(tracker.confirmed, isTrue);
    // posição caiu por causa de um seek manual do usuário → sem novo seek.
    expect(tracker.onPosition(0.5), isFalse);
  });
}
