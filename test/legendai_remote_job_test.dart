import 'package:flutter_test/flutter_test.dart';

import 'package:goanime_tv/core/subtitles/legendai/legendai_protocol.dart';
import 'package:goanime_tv/core/subtitles/legendai/legendai_remote_job.dart';
import 'package:goanime_tv/core/subtitles/subtitle_job_manager.dart';

RemoteJob _job({
  required LegendAiState state,
  LegendAiStep? step,
  int pct = 0,
  LegendAiErrorDetail? error,
  LegendAiJobSummary? summary,
}) => RemoteJob(
  jobId: 'j1',
  clientJobId: 'goanime:X:1',
  animeKey: 'X',
  episode: 1,
  state: state,
  step: step,
  pct: pct,
  error: error,
  summary: summary,
);

void main() {
  group('RemoteJob.toDisplayState (mapeamento §8.5)', () {
    test('pending → "Na fila do PC"', () {
      final st = _job(state: LegendAiState.pending).toDisplayState();
      expect(st.phase, JobPhase.idle);
      expect(st.message, contains('fila do PC'));
    });

    test('extract → baixando no PC', () {
      final st = _job(
        state: LegendAiState.running,
        step: LegendAiStep.extract,
      ).toDisplayState();
      expect(st.phase, JobPhase.downloadingVideo);
    });

    test('transcribe → transcrevendo com %', () {
      final st = _job(
        state: LegendAiState.running,
        step: LegendAiStep.transcribe,
        pct: 42,
      ).toDisplayState();
      expect(st.phase, JobPhase.transcribing);
      expect(st.progress, closeTo(0.42, 0.001));
      expect(st.detail, contains('42%'));
    });

    test('translate → traduzindo', () {
      final st = _job(
        state: LegendAiState.running,
        step: LegendAiStep.translate,
        pct: 90,
      ).toDisplayState();
      expect(st.phase, JobPhase.translating);
    });

    test('format/export → salvando', () {
      for (final step in [LegendAiStep.format, LegendAiStep.export]) {
        final st = _job(
          state: LegendAiState.running,
          step: step,
        ).toDisplayState();
        expect(st.phase, JobPhase.saving);
      }
    });

    test('done → done com nº de falas', () {
      final st = _job(
        state: LegendAiState.done,
        summary: const LegendAiJobSummary(
          durationSecs: 1,
          segments: 12,
          sourceLang: 'ja',
          targetLang: 'pt',
          srtBytes: 100,
        ),
      ).toDisplayState();
      expect(st.phase, JobPhase.done);
      expect(st.progress, 1);
      expect(st.message, contains('12'));
    });

    test('error → failed com mensagem amigável', () {
      final st = _job(
        state: LegendAiState.error,
        error: const LegendAiErrorDetail(
          code: 'no_audio_track',
          message: 'sem áudio',
        ),
      ).toDisplayState();
      expect(st.phase, JobPhase.failed);
      expect(st.error, contains('faixa de áudio'));
    });

    test('cancelled → cancelled', () {
      final st = _job(state: LegendAiState.cancelled).toDisplayState();
      expect(st.phase, JobPhase.cancelled);
    });
  });

  group('RemoteJob serialização', () {
    test('round-trip preserva campos voláteis e locais', () {
      final job = RemoteJob(
        jobId: 'j9',
        clientJobId: 'goanime:X:3',
        animeKey: 'X',
        episode: 3,
        state: LegendAiState.done,
        step: LegendAiStep.done,
        pct: 100,
        downloaded: true,
        tag: 'ja-ai',
        srcHash: 'abc',
        createdMs: 10,
        updatedMs: 20,
      );
      final back = RemoteJob.fromJson(job.toJson());
      expect(back.jobId, 'j9');
      expect(back.clientJobId, 'goanime:X:3');
      expect(back.episode, 3);
      expect(back.state, LegendAiState.done);
      expect(back.downloaded, isTrue);
      expect(back.tag, 'ja-ai');
      expect(back.srcHash, 'abc');
    });

    test('merge atualiza estado mas preserva downloaded/tag', () {
      final job = RemoteJob(
        jobId: 'j1',
        animeKey: 'X',
        episode: 1,
        state: LegendAiState.running,
        tag: 'en-ai',
        srcHash: 'hash',
      );
      job.merge(
        LegendAiJob(
          jobId: 'j1',
          state: LegendAiState.done,
          pct: 100,
          summary: const LegendAiJobSummary(
            durationSecs: 2,
            segments: 5,
            sourceLang: 'ja',
            targetLang: 'pt',
            srtBytes: 9,
          ),
        ),
      );
      expect(job.state, LegendAiState.done);
      expect(job.summary!.segments, 5);
      expect(job.tag, 'en-ai');
      expect(job.srcHash, 'hash');
      expect(job.downloaded, isFalse);
    });
  });
}
