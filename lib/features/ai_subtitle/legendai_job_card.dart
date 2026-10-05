import 'package:flutter/material.dart';

import '../../../core/constants/theme_constants.dart';
import '../../../core/subtitles/legendai/legendai_protocol.dart';
import '../../../core/subtitles/legendai/legendai_remote_job.dart';
import '../../../core/subtitles/subtitle_job_manager.dart';
import '../../../shared/widgets/tv_button.dart';

/// Card de status do job remoto no picker (aba "No PC").
///
/// `job == null` → botão "Gerar no PC". Depois disso, replica a UX do card
/// local (mensagem, barra, %, cancelar, erro + tentar de novo).
class LegendAiJobCard extends StatelessWidget {
  final RemoteJob? job;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  const LegendAiJobCard({
    super.key,
    required this.job,
    required this.onStart,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final j = job;
    if (j == null) {
      return TVButton(
        label: 'Gerar no PC',
        autofocus: true,
        onPressed: onStart,
      );
    }
    return _JobBody(
      state: j.toDisplayState(),
      onCancel: onCancel,
      onRetry: onStart,
    );
  }
}

class _JobBody extends StatelessWidget {
  final JobState state;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  const _JobBody({
    required this.state,
    required this.onCancel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final st = state;
    if (st.phase == JobPhase.failed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            st.error ?? 'Falhou no PC.',
            style: const TextStyle(color: Colors.redAccent, fontSize: 16),
          ),
          const SizedBox(height: 12),
          TVButton(label: 'Tentar de novo', onPressed: onRetry),
        ],
      );
    }
    if (st.phase == JobPhase.done) {
      return Text(
        st.message.isEmpty ? 'Legenda pronta no PC.' : st.message,
        style: const TextStyle(color: Colors.greenAccent, fontSize: 16),
      );
    }
    if (st.phase == JobPhase.cancelled) {
      return const Text(
        'Cancelado no PC.',
        style: TextStyle(color: ThemeConstants.textSecondary, fontSize: 16),
      );
    }
    final active = st.phase != JobPhase.idle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          st.message.isEmpty ? 'No PC…' : st.message,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        if (st.detail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              st.detail,
              style: const TextStyle(
                color: ThemeConstants.textSecondary,
                fontSize: 14,
              ),
            ),
          ),
        if (active) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: st.progress <= 0 ? null : st.progress,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(ThemeConstants.primary),
          ),
          const SizedBox(height: 4),
          Text(
            '${(st.progress * 100).toInt()}%',
            style: const TextStyle(
              color: ThemeConstants.textSecondary,
              fontSize: 14,
            ),
          ),
        ],
        const SizedBox(height: 12),
        TVButton(label: 'Cancelar', isPrimary: false, onPressed: onCancel),
      ],
    );
  }
}

/// Linha compacta de um job remoto para a fila unificada.
class LegendAiQueueRow extends StatelessWidget {
  final RemoteJob job;
  final VoidCallback onCancel;
  final VoidCallback onRemove;

  const LegendAiQueueRow({
    super.key,
    required this.job,
    required this.onCancel,
    required this.onRemove,
  });

  static String _phaseLabel(JobState st) => st.error ?? st.message;

  @override
  Widget build(BuildContext context) {
    final st = job.toDisplayState();
    final active = job.isActive;
    final title =
        '${job.animeKey.isEmpty ? 'Sem título' : job.animeKey} · EP${job.episode}';
    final tag = switch (job.tag) {
      'en-ai' => 'EN→PT',
      'es-ai' => 'ES→PT',
      _ => 'JA→PT',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ThemeConstants.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ThemeConstants.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                job.isDone
                    ? Icons.check_circle
                    : job.state == LegendAiState.error
                    ? Icons.error_outline
                    : job.isActive
                    ? Icons.cloud_upload_outlined
                    : Icons.cloud_outlined,
                color: job.isDone
                    ? Colors.greenAccent
                    : job.state == LegendAiState.error
                    ? Colors.redAccent
                    : ThemeConstants.primary,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$title  ·  PC  ·  $tag',
                  style: const TextStyle(
                    color: ThemeConstants.white,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _phaseLabel(st),
            style: TextStyle(
              color: job.state == LegendAiState.error
                  ? Colors.redAccent
                  : ThemeConstants.textSecondary,
              fontSize: 14,
            ),
          ),
          if (active) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: st.progress <= 0 ? null : st.progress,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(ThemeConstants.primary),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              if (active)
                TVButton(
                  label: 'Cancelar',
                  isPrimary: false,
                  width: 150,
                  onPressed: onCancel,
                ),
              if (!active)
                TVButton(
                  label: 'Remover',
                  isPrimary: false,
                  width: 150,
                  onPressed: onRemove,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
