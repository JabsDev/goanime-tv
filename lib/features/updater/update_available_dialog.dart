import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/updater/github_release_api.dart';
import '../../core/updater/version_compare.dart';
import '../../shared/widgets/tv_button.dart';

/// Prompt "Nova versão" — navegável 100% por D-pad.
/// Segue o padrão do `AnilistLoginDialog` (surface + TvButton + foco inicial
/// na ação principal).
class UpdateAvailableDialog extends StatelessWidget {
  final ReleaseInfo release;
  final VoidCallback onUpdate;
  final VoidCallback onLater;
  final VoidCallback onIgnore;

  const UpdateAvailableDialog({
    super.key,
    required this.release,
    required this.onUpdate,
    required this.onLater,
    required this.onIgnore,
  });

  @override
  Widget build(BuildContext context) {
    final label = release.versionLabel ?? release.tagName;
    return Dialog(
      backgroundColor: ThemeConstants.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      child: Container(
        width: 640,
        constraints: const BoxConstraints(maxHeight: 440),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.system_update_alt,
                  color: ThemeConstants.primary,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Nova versão ${versionLabelFromTag(release.tagName)} disponível',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  release.changelog?.isNotEmpty == true
                      ? release.changelog!
                      : 'Atualize para a versão $label para receber correções '
                          'e melhorias.',
                  style: const TextStyle(
                    color: ThemeConstants.textSecondary,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                TVButton(
                  label: 'Atualizar agora',
                  icon: Icons.download,
                  onPressed: onUpdate,
                  width: 220,
                  autofocus: true,
                ),
                const SizedBox(width: 16),
                TVButton(
                  label: 'Agora não',
                  isPrimary: false,
                  onPressed: onLater,
                  width: 180,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: onIgnore,
                style: TextButton.styleFrom(
                  foregroundColor: ThemeConstants.textMuted,
                ),
                child: const Text(
                  'Ignorar esta versão',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}