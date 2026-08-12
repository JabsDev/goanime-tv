import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/updater/github_release_api.dart';
import '../../core/updater/update_service.dart';
import '../../shared/widgets/tv_button.dart';

/// Diálogo de andamento da atualização: download (com %), instalação,
/// concluído e erro.
///
/// Réage ao estado/progresso ao vivo do `UpdateService` via
/// `ValueListenableBuilder` — a mesma rota de diálogo evolui
/// `downloading → installing → done/error` sem trocar de janela.
class UpdateFlowDialog extends StatelessWidget {
  final ReleaseInfo? release;
  const UpdateFlowDialog({super.key, this.release});

  @override
  Widget build(BuildContext context) {
    final s = UpdateService.instance;
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(24),
        child: ValueListenableBuilder<UpdateState>(
          valueListenable: s.state,
          builder: (context, state, _) {
            switch (state) {
              case UpdateState.downloading:
                return _downloading(s);
              case UpdateState.installing:
                return _installing();
              case UpdateState.done:
                return _done(s);
              case UpdateState.error:
                return _error(s);
              default:
                return const SizedBox.shrink();
            }
          },
        ),
      ),
    );
  }

  Widget _downloading(UpdateService s) {
    return ValueListenableBuilder<double?>(
      valueListenable: s.progress,
      builder: (context, p, _) {
        final indeterminate = p == null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(
              icon: Icons.downloading,
              title: 'Baixando atualização',
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: p,
                minHeight: 8,
                color: ThemeConstants.primary,
                backgroundColor: ThemeConstants.surfaceLight,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  indeterminate
                      ? 'Conectando...'
                      : '${(p * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: ThemeConstants.textSecondary,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                TVButton(
                  label: 'Cancelar',
                  isPrimary: false,
                  onPressed: s.cancelDownload,
                  width: 160,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _installing() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(
          icon: Icons.settings_suggest,
          title: 'Instalando...',
        ),
        SizedBox(height: 16),
        LinearProgressIndicator(
          minHeight: 6,
          color: ThemeConstants.primary,
          backgroundColor: ThemeConstants.surfaceLight,
        ),
        SizedBox(height: 12),
        Text(
          'Aguarde a confirmação do Android. Se o app fechar, reabra o '
          'GoAnime TV após a instalação.',
          style: TextStyle(
            color: ThemeConstants.textSecondary,
            fontSize: 14,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _done(UpdateService s) {
    return _ResultBody(
      icon: Icons.check_circle,
      iconColor: const Color(0xFF4CAF50),
      title: 'Atualização concluída',
      message: release?.tagName != null
          ? 'Versão ${release!.tagName} instalada. Reabra o GoAnime TV.'
          : 'Versão nova instalada. Reabra o GoAnime TV.',
      children: [
        TVButton(
          label: 'Fechar',
          onPressed: s.dismiss,
          width: 160,
        ),
      ],
    );
  }

  Widget _error(UpdateService s) {
    final canOpen = s.canOpenInstaller;
    return _ResultBody(
      icon: Icons.error_outline,
      iconColor: ThemeConstants.accent,
      title: 'Não foi possível atualizar',
      message: s.errorMessage ?? 'Erro desconhecido.',
      children: [
        if (canOpen)
          TVButton(
            label: 'Abrir instalador do sistema',
            isPrimary: false,
            onPressed: s.openSystemInstaller,
            width: 260,
          ),
        if (s.pending != null)
          TVButton(
            label: 'Tentar novamente',
            isPrimary: false,
            onPressed: () => s.downloadAndInstall(s.pending!),
            width: 220,
          ),
        TVButton(
          label: 'Fechar',
          onPressed: s.dismiss,
          width: 160,
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final IconData icon;
  final String title;
  const _Header({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: ThemeConstants.primary, size: 28),
        const SizedBox(width: 12),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _ResultBody extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final List<Widget> children;

  const _ResultBody({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: iconColor, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          message,
          style: const TextStyle(
            color: ThemeConstants.textSecondary,
            fontSize: 16,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(spacing: 12, runSpacing: 12, children: children),
      ],
    );
  }
}