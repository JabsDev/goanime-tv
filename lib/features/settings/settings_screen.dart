import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/subtitles/ai_providers.dart';
import '../../core/subtitles/legendai/legendai_connection.dart';
import '../../core/subtitles/model_manager.dart';
import '../../core/subtitles/subtitle_store.dart';
import '../../core/subtitles/subtitle_job_manager.dart';
import '../../core/updater/update_service.dart';
import '../../core/utils/device_capability.dart';
import '../../core/utils/nsfw_filter.dart';
import '../../shared/widgets/app_top_bar.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../../shared/widgets/tv_button.dart';
import '../ai_subtitle/ai_model_row.dart';
import 'legendai_pair_screen.dart';
import 'legendai_queue_card.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// 1 único probe p/ todos os tiers (linha NÃO re-proba por build).
  Future<Map<String, bool>> _aiStatuses = AiProviders.readyMap(
    AiProviders.sttTiers.values
        .map((t) => t.id)
        .followedBy(AiProviders.mtTiers.values),
  );
  final Map<String, double> _downloading = {};

  @override
  void initState() {
    super.initState();
    DeviceCapability.isLowEnd().then((low) {
      if (mounted) setState(() => _lowEnd = low);
    });
  }

  bool? _lowEnd;

  Future<void> _download(String modelId) async {
    setState(() => _downloading[modelId] = 0);
    try {
      await const ModelManager().downloadModel(
        modelId,
        onProgress: (_, p) {
          if (mounted) setState(() => _downloading[modelId] = p);
        },
      );
      if (mounted) {
        setState(() {
          _aiStatuses = AiProviders.readyMap(
            AiProviders.sttTiers.values
                .map((t) => t.id)
                .followedBy(AiProviders.mtTiers.values),
          );
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Modelo pronto.')));
      }
    } on ModelDownloadException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _downloading.remove(modelId));
    }
  }

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
                    horizontal: 48,
                    vertical: 24,
                  ),
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
                        fontSize: 16,
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
                        fontSize: 16,
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
                              description: 'Esconde animes hentai e ecchi',
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
                              description: 'Mostra todo o conteúdo, sem filtro',
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
                      'Reprodução',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Pula automaticamente a introdução quando os tempos estiverem disponíveis.',
                      style: TextStyle(
                        fontSize: 16,
                        color: ThemeConstants.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ValueListenableBuilder<bool>(
                      valueListenable:
                          SettingsService.instance.autoSkipIntroListenable,
                      builder: (context, autoSkip, _) => _AutoSkipToggle(
                        on: autoSkip,
                        onChanged: (v) =>
                            SettingsService.instance.setAutoSkipIntro(v),
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      'Legenda IA (offline)',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Gera legenda PT-BR no aparelho, sem nuvem: traduz a '
                      'legenda existente (rápido) ou transcreve o áudio japonês '
                      '(lento, uma vez por episódio, vale por 5 dias). Só os '
                      'modelos de alta qualidade ficam disponíveis; baixam só '
                      'no Wi-Fi.',
                      style: TextStyle(
                        fontSize: 16,
                        color: ThemeConstants.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ValueListenableBuilder<String>(
                      valueListenable:
                          SettingsService.instance.sttModelListenable,
                      builder: (context, stt, _) => Column(
                        children: [
                          for (final tier in AiProviders.sttTierOrder)
                            AiModelRow(
                              heading: 'Voz',
                              tiers: [tier],
                              tierIds: {
                                for (final e in AiProviders.sttTiers.entries)
                                  e.key: e.value.id,
                              },
                              tierLabels: AiProviders.sttTierLabels,
                              selected: tier,
                              marked: stt == tier,
                              onSelect: (_) =>
                                  SettingsService.instance.setSttModel(tier),
                              statuses: _aiStatuses,
                              downloading: _downloading,
                              onDownload: _download,
                              lowEnd: _lowEnd ?? false,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ValueListenableBuilder<String>(
                      valueListenable:
                          SettingsService.instance.mtEngineListenable,
                      builder: (context, mt, _) => Column(
                        children: [
                          for (final tier in AiProviders.mtTierOrder)
                            AiModelRow(
                              heading: 'Tradução',
                              tiers: [tier],
                              tierIds: AiProviders.mtTiers,
                              tierLabels: AiProviders.mtTierLabels,
                              selected: tier,
                              marked: mt == tier,
                              onSelect: (_) =>
                                  SettingsService.instance.setMtEngine(tier),
                              statuses: _aiStatuses,
                              downloading: _downloading,
                              onDownload: _download,
                              lowEnd: _lowEnd ?? false,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _AiStorageRow(),
                    const SizedBox(height: 16),
                    const Text(
                      'Áudio — ajuda a transcrição',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.textSecondary,
                      ),
                    ),
                    AiModelRow(
                      heading: 'Áudio',
                      tiers: const ['vad'],
                      tierIds: const {'vad': 'silero-vad'},
                      tierLabels: const {'vad': 'VAD silero (opcional)'},
                      selected: 'vad',
                      onSelect: (_) {},
                      statuses: _aiStatuses,
                      downloading: _downloading,
                      onDownload: _download,
                    ),
                    const SizedBox(height: 32),
                    _LegendAiSection(),
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
                        fontSize: 16,
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

/// Espaço usado por legendas IA + modelos, com botões de limpeza.
/// D-pad: TVButton já é focável.
class _AiStorageRow extends StatefulWidget {
  const _AiStorageRow();

  @override
  State<_AiStorageRow> createState() => _AiStorageRowState();
}

class _AiStorageRowState extends State<_AiStorageRow> {
  Future<(int, int)>? _usage;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _usage = Future.wait([
        SubtitleStore.usedBytes(),
        const ModelManager().usedBytes(),
      ]).then((v) => (v[0], v[1]));
    });
  }

  static String _fmt(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(int, int)>(
      future: _usage,
      builder: (context, snap) {
        final subs = snap.data?.$1 ?? 0;
        final models = snap.data?.$2 ?? 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Espaço: legendas ${_fmt(subs)} · modelos ${_fmt(models)}',
              style: const TextStyle(
                fontSize: 16,
                color: ThemeConstants.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                TVButton(
                  label: 'Apagar legendas IA',
                  isPrimary: false,
                  onPressed: () async {
                    await SubtitleStore.clearAll();
                    // Limpa também o estado do job: senão o card fica preso em
                    // "Legenda pronta." mesmo sem arquivo nenhum.
                    SubtitleJobManager.instance.resetIdleState();
                    _refresh();
                  },
                ),
                TVButton(
                  label: 'Apagar modelos',
                  isPrimary: false,
                  onPressed: () async {
                    await const ModelManager().deleteAll();
                    _refresh();
                  },
                ),
              ],
            ),
          ],
        );
      },
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
    final activeLabel = liteActive
        ? 'Modo ativo: Lite'
        : 'Modo ativo: Completo';
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

class _AutoSkipToggle extends StatefulWidget {
  final bool on;
  final ValueChanged<bool> onChanged;

  const _AutoSkipToggle({required this.on, required this.onChanged});

  @override
  State<_AutoSkipToggle> createState() => _AutoSkipToggleState();
}

class _AutoSkipToggleState extends State<_AutoSkipToggle> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, _toggle),
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
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
                          'Pular introdução automaticamente',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: ThemeConstants.white,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Quando o tempo da intro estiver disponível, avança sozinho.',
                          style: TextStyle(
                            fontSize: 14,
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
      onKeyEvent: (node, event) => FocusKeyHandler.handle(node, event, _toggle),
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
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
                            fontSize: 14,
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
    final updater = UpdateService.instance;
    final st = updater.state.value;
    if (st != UpdateState.idle) {
      // Estado ativo → não chama check (que retornaria null). Dá feedback.
      final msg = switch (st) {
        UpdateState.checking => 'Verificação em andamento...',
        UpdateState.updateAvailable => 'Uma atualização já está disponível.',
        UpdateState.downloading => 'Uma atualização está sendo baixada.',
        UpdateState.installing => 'Uma atualização está sendo instalada.',
        UpdateState.done => 'A atualização foi concluída. Reabra o app.',
        UpdateState.error => 'A última atualização falhou.',
        UpdateState.idle => 'Uma atualização está em andamento.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
      return;
    }

    setState(() => _busy = true);
    final result = await updater.check(manual: true);
    if (!mounted) return;
    setState(() => _busy = false);

    if (result == false) {
      final msg =
          updater.lastCheckNotice ?? 'Você está na versão mais recente.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    } else if (result == null) {
      // Só sobra erro de rede/timeout aqui: o no-op por estado ativo já foi
      // tratado no pré-check acima.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Não foi possível verificar atualizações agora. Tente novamente.',
          ),
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
                  horizontal: 20,
                  vertical: 18,
                ),
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
                              fontSize: 14,
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

/// Seção "LegendAI (PC)": status/pareamento, modo padrão e fila unificada.
class _LegendAiSection extends StatefulWidget {
  const _LegendAiSection();

  @override
  State<_LegendAiSection> createState() => _LegendAiSectionState();
}

class _LegendAiSectionState extends State<_LegendAiSection> {
  bool _busy = false;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    final ok = await LegendAiConnection.instance.refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    final c = LegendAiConnection.instance;
    _snack(
      ok
          ? 'PC conectado${c.healthLabel.isEmpty ? '' : ' · ${c.healthLabel}'}'
          : 'PC não respondeu. Confira o endereço e se o LegendAI está aberto.',
    );
  }

  Future<void> _disconnect() async {
    await LegendAiConnection.instance.disconnect();
    if (!mounted) return;
    _snack('Desconectado.');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'LegendAI (PC)',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: ThemeConstants.white,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Gera a legenda no PC da rede local: o PC baixa o stream, '
          'transcreve e traduz, e o aparelho só recebe o SRT pronto. Escolha '
          '"No PC" no card do episódio quando estiver conectado.',
          style: TextStyle(
            fontSize: 16,
            color: ThemeConstants.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        ValueListenableBuilder<LegendAiStatus>(
          valueListenable: LegendAiConnection.instance.status,
          builder: (context, status, _) => _pairStatusLine(status),
        ),
        const SizedBox(height: 12),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation(ThemeConstants.primary),
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            TVButton(
              label: 'Conectar / parear',
              icon: Icons.qr_code_2,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LegendAiPairScreen()),
              ),
            ),
            TVButton(
              label: 'Testar conexão',
              isPrimary: false,
              icon: Icons.wifi_find,
              onPressed: _busy ? () {} : _test,
            ),
            if (LegendAiConnection.instance.isConfigured)
              TVButton(
                label: 'Desconectar',
                isPrimary: false,
                icon: Icons.link_off,
                onPressed: _busy ? () {} : _disconnect,
              ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Onde gerar por padrão',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: ThemeConstants.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<String>(
          valueListenable: SettingsService.instance.subtitleSourceListenable,
          builder: (context, src, _) => Column(
            children: [
              _ModeOption(
                label: 'No aparelho',
                description:
                    'Usa os modelos locais (Whisper anime + Hy-MT2). Mais lento.',
                selected: src != 'pc',
                onTap: () =>
                    SettingsService.instance.setSubtitleSource('device'),
              ),
              _ModeOption(
                label: 'No PC (LegendAI)',
                description:
                    'Envia o stream para o PC e recebe o SRT pronto da rede.',
                selected: src == 'pc',
                onTap: () => SettingsService.instance.setSubtitleSource('pc'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const LegendAiQueueCard(),
      ],
    );
  }

  Widget _pairStatusLine(LegendAiStatus status) {
    final address = SettingsService.instance.legendAiAddressListenable.value;
    final c = LegendAiConnection.instance;
    final (color, text) = switch (status) {
      LegendAiStatus.online => (
        Colors.greenAccent,
        'PC conectado · ${c.healthLabel}',
      ),
      LegendAiStatus.checking => (Colors.orangeAccent, 'Conectando…'),
      LegendAiStatus.offline => (Colors.redAccent, 'PC não respondeu'),
      LegendAiStatus.unconfigured => (
        ThemeConstants.textSecondary,
        'Nenhum PC configurado',
      ),
    };
    final showAddr =
        status != LegendAiStatus.unconfigured &&
        status != LegendAiStatus.checking &&
        address.isNotEmpty;
    return Row(
      children: [
        Icon(Icons.circle, size: 12, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            showAddr ? '$text · $address' : text,
            style: TextStyle(color: color, fontSize: 15),
          ),
        ),
      ],
    );
  }
}
