import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/updater/update_service.dart';
import '../../core/utils/nsfw_filter.dart';
import '../../shared/widgets/app_top_bar.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../../shared/widgets/tv_button.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeConstants.background,
      body: Column(
        children: [
          AppTopBar(
            title: 'Configurações',
            icon: Icons.settings,
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: SettingsService.instance.liteModeListenable,
              builder: (context, liteActive, _) {
                final auto = SettingsService.instance.autoDetectedLowEnd;
                final user = SettingsService.instance.userPreference;
                return ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 48, vertical: 24),
                  children: [
                    Text(
                      'Desempenho',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Reduz animações, sombras, cache paralelo e enriquecimento '
                      'AniList em busca. Mantém todas as funções principais — '
                      'apenas efeitos visuais pesados são cortados.',
                      style: const TextStyle(
                        fontSize: 14,
                        color: ThemeConstants.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _StatusCard(
                      autoDetectedLowEnd: auto,
                      liteActive: liteActive,
                      userPreference: user,
                    ),
                    const SizedBox(height: 16),
                    _ModeOption(
                      label: 'Automático',
                      description: auto
                          ? 'Dispositivo fraco detectado — ativando modo lite'
                          : 'Dispositivo capaz — mantendo modo completo',
                      selected: user == null,
                      onTap: () =>
                          SettingsService.instance.setUserPreference(null),
                    ),
                    _ModeOption(
                      label: 'Modo lite (sempre)',
                      description:
                          'Corta efeitos visuais pesados em qualquer aparelho',
                      selected: user == true,
                      onTap: () =>
                          SettingsService.instance.setUserPreference(true),
                    ),
                    _ModeOption(
                      label: 'Modo completo (sempre)',
                      description:
                          'Mantém animações, sombras e paralelismo integral',
                      selected: user == false,
                      onTap: () =>
                          SettingsService.instance.setUserPreference(false),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      'Filtro de conteúdo',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Esconde animes adultos e ecchi da busca, da home e das '
                      'listas. Níveis: ecchi é mais leve que hentai. O filtro '
                      'vem ativado por padrão.',
                      style: TextStyle(
                        fontSize: 14,
                        color: ThemeConstants.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ValueListenableBuilder<NsfwFilterSetting>(
                      valueListenable:
                          SettingsService.instance.nsfwFilterListenable,
                      builder: (context, nsfwSetting, _) {
                        return Column(
                          children: [
                            _ModeOption(
                              label: 'Filtrar (padrão)',
                              description:
                                  'Esconde animes hentai e ecchi',
                              selected: nsfwSetting == NsfwFilterSetting.strict,
                              onTap: () => SettingsService.instance
                                  .setNsfwFilterLevel(NsfwFilterSetting.strict),
                            ),
                            _ModeOption(
                              label: 'Permitir ecchi',
                              description:
                                  'Esconde só hentai, mostra animes ecchi',
                              selected: nsfwSetting == NsfwFilterSetting.soft,
                              onTap: () => SettingsService.instance
                                  .setNsfwFilterLevel(NsfwFilterSetting.soft),
                            ),
                            _ModeOption(
                              label: 'Desativado',
                              description:
                                  'Mostra todo o conteúdo, sem filtro',
                              selected: nsfwSetting == NsfwFilterSetting.off,
                              onTap: () => SettingsService.instance
                                  .setNsfwFilterLevel(NsfwFilterSetting.off),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      'Atualizações',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Verifica no GitHub por versões novas e atualiza app '
                      'instalado por cima (sem perder seus dados).',
                      style: TextStyle(
                        fontSize: 14,
                        color: ThemeConstants.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _UpdateToggle(
                      on: UpdateService.instance.checkOnLaunch,
                      onChanged: (v) =>
                          UpdateService.instance.setCheckOnLaunch(v),
                    ),
                    const SizedBox(height: 12),
                    _CheckNowRow(),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool autoDetectedLowEnd;
  final bool liteActive;
  final bool? userPreference;

  const _StatusCard({
    required this.autoDetectedLowEnd,
    required this.liteActive,
    required this.userPreference,
  });

  @override
  Widget build(BuildContext context) {
    final detectorLabel = autoDetectedLowEnd
        ? 'Dispositivo fraco detectado'
        : 'Dispositivo capaz detectado';
    final activeLabel = liteActive ? 'Modo ativo: Lite' : 'Modo ativo: Completo';
    final sourceLabel = userPreference == null
        ? 'Escolha: Automática'
        : userPreference!
            ? 'Escolha: Lite forçado'
            : 'Escolha: Completo forçado';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ThemeConstants.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ThemeConstants.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                liteActive ? Icons.bolt : Icons.spa,
                color: ThemeConstants.primary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Text(
                activeLabel,
                style: const TextStyle(
                  fontSize: 16,
                  color: ThemeConstants.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            detectorLabel,
            style: const TextStyle(
              fontSize: 14,
              color: ThemeConstants.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            sourceLabel,
            style: const TextStyle(
              fontSize: 14,
              color: ThemeConstants.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeOption extends StatefulWidget {
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _ModeOption({
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ModeOption> createState() => _ModeOptionState();
}

class _UpdateToggle extends StatefulWidget {
  final bool on;
  final ValueChanged<bool> onChanged;

  const _UpdateToggle({required this.on, required this.onChanged});

  @override
  State<_UpdateToggle> createState() => _UpdateToggleState();
}

class _UpdateToggleState extends State<_UpdateToggle> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) =>
          FocusKeyHandler.handle(node, event, _toggle),
      child: Semantics(
        button: true,
        toggled: widget.on,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: ThemeConstants.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isFocused
                      ? ThemeConstants.primary
                      : ThemeConstants.surfaceLight,
                  width: _isFocused ? 2 : 1.5,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.on ? Icons.check_box : Icons.check_box_outline_blank,
                    color: widget.on
                        ? ThemeConstants.primary
                        : ThemeConstants.textSecondary,
                    size: 26,
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Verificar no início',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: ThemeConstants.white,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Checa no primeiro frame depois do app abrir.',
                          style: TextStyle(
                            fontSize: 13,
                            color: ThemeConstants.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggle() {
    if (mounted) widget.onChanged(!widget.on);
  }
}

class _CheckNowRow extends StatefulWidget {
  @override
  State<_CheckNowRow> createState() => _CheckNowRowState();
}

class _CheckNowRowState extends State<_CheckNowRow> {
  bool _busy = false;

  Future<void> _checkNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    final updater = UpdateService.instance;
    final result = await updater.check(manual: true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Você está na versão mais recente.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TVButton(
          label: 'Verificar agora',
          icon: Icons.refresh,
          isPrimary: false,
          onPressed: _checkNow,
          width: 220,
        ),
        const SizedBox(width: 20),
        _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: ThemeConstants.primary,
                ),
              )
            : Text(
                'Versão instalada: ${UpdateService.instance.installedVersionLabel}',
                style: const TextStyle(
                  fontSize: 15,
                  color: ThemeConstants.textMuted,
                ),
              ),
      ],
    );
  }
}

class _ModeOptionState extends State<_ModeOption> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Focus(
        onFocusChange: (f) => setState(() => _isFocused = f),
        onKeyEvent: (node, event) =>
            FocusKeyHandler.handle(node, event, widget.onTap),
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 18),
                decoration: BoxDecoration(
                  color: widget.selected
                      ? ThemeConstants.primary.withValues(alpha: 0.12)
                      : ThemeConstants.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: widget.selected
                        ? ThemeConstants.primary
                        : _isFocused
                            ? ThemeConstants.primary
                            : ThemeConstants.surfaceLight,
                    width: widget.selected ? 2 : 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: widget.selected
                          ? ThemeConstants.primary
                          : ThemeConstants.textSecondary,
                      size: 24,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.label,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: widget.selected
                                  ? ThemeConstants.white
                                  : ThemeConstants.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.description,
                            style: const TextStyle(
                              fontSize: 13,
                              color: ThemeConstants.textMuted,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}