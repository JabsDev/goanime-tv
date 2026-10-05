import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/subtitles/legendai/legendai_job_manager.dart';
import '../../core/subtitles/legendai/legendai_remote_job.dart';
import '../../core/subtitles/subtitle_job_manager.dart';
import '../../shared/widgets/tv_button.dart';
import '../ai_subtitle/legendai_job_card.dart';

/// Fila unificada (aparelho + PC) da seção "LegendAI (PC)".
///
/// O job local é o do [`SubtitleJobManager`] (mostrado enquanto em execução);
/// os remotos vêm do espelho do PC (cancelar/remover). "Assistir com IA"
/// continua no card do episódio, único lugar que tem provider/fontes.
class LegendAiQueueCard extends StatelessWidget {
  const LegendAiQueueCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<RemoteJob>>(
      valueListenable: LegendAiJobManager.instance.jobs,
      builder: (context, remotes, _) {
        return ValueListenableBuilder<JobState>(
          valueListenable: SubtitleJobManager.instance.state,
          builder: (context, localState, _) {
            final localBusy = SubtitleJobManager.instance.isBusy;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Fila',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: ThemeConstants.white,
                        ),
                      ),
                    ),
                    TVButton(
                      label: 'Atualizar',
                      isPrimary: false,
                      width: 150,
                      onPressed: () => LegendAiJobManager.instance.refresh(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (localBusy) _LocalRow(state: localState),
                if (remotes.isEmpty && !localBusy)
                  const Text(
                    'Nenhum job na fila.',
                    style: TextStyle(
                      color: ThemeConstants.textSecondary,
                      fontSize: 15,
                    ),
                  ),
                for (final job in remotes)
                  LegendAiQueueRow(
                    job: job,
                    onCancel: () => _guard(
                      context,
                      () => LegendAiJobManager.instance.cancel(job),
                    ),
                    onRemove: () => _guard(
                      context,
                      () => LegendAiJobManager.instance.remove(job),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _guard(BuildContext context, Future<void> Function() action) {
    action().catchError((Object e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Falhou: $e')));
      }
    });
  }
}

class _LocalRow extends StatelessWidget {
  final JobState state;
  const _LocalRow({required this.state});

  @override
  Widget build(BuildContext context) {
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
          const Row(
            children: [
              Icon(Icons.smartphone, color: ThemeConstants.primary, size: 20),
              SizedBox(width: 8),
              Text(
                'Este aparelho',
                style: TextStyle(color: ThemeConstants.white, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            state.message.isEmpty ? 'Trabalhando…' : state.message,
            style: const TextStyle(
              color: ThemeConstants.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: state.progress <= 0 ? null : state.progress,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(ThemeConstants.primary),
          ),
        ],
      ),
    );
  }
}
