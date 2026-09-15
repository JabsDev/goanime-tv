import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/subtitles/model_manager.dart';
import '../../core/subtitles/subtitle_store.dart';
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
                      '(lento, uma vez por episódio, vale por 5 dias). Modelos '
                      'baixam só no Wi-Fi.',
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
                          _ModeOption(
                            label: 'Transcrição leve (padrão)',
                            description:
                                'Whisper tiny-ja (78 MB) — roda no stick fraco',
                            selected: stt == 'tiny',
                            onTap: () => SettingsService.instance
                                .setSttModel('tiny'),
                          ),
                          _ModeOption(
                            label: 'Transcrição completa',
                            description:
                                'Whisper base (170 MB) — japonês melhor, aparelho médio+',
                            selected: stt == 'base',
                            onTap: () => SettingsService.instance
                                .setSttModel('base'),
                          ),
                          _ModeOption(
                            label: 'Transcrição superior',
                            description:
                                'Whisper small (380 MB) — bem melhor em JA, só aparelho forte',
                            selected: stt == 'small',
                            onTap: () => SettingsService.instance
                                .setSttModel('small'),
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
                          _ModeOption(
                            label: 'Tradução leve (padrão)',
                            description:
                                'Marian EN→PT (120 MB) — qualquer aparelho',
                            selected: mt == 'leve',
                            onTap: () => SettingsService.instance
                                .setMtEngine('leve'),
                          ),
                          _ModeOption(
                            label: 'Tradução completa',
                            description:
                                'NLLB JA→PT direto (1.28 GB) — só aparelho forte com 2 GB livres',
                            selected: mt == 'completa',
                            onTap: () => SettingsService.instance
                                .setMtEngine('completa'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _AiStorageRow(),
                    const SizedBox(height: 16),
                    const Text(
                      'Modelos (HuggingFace, só Wi-Fi)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: ThemeConstants.white,
                      ),
                    ),
                    const Text(
                      'Voz transforma áudio em texto; tradução leva p/ português.',
                      style: TextStyle(
                        fontSize: 14,
                        color: ThemeConstants.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const _ModelGroupTitle('Voz — transcreve o áudio'),
                    _ModelRow(modelId: 'whisper-tiny-ja', label: 'Voz leve (tiny)'),
                    _ModelRow(modelId: 'sensevoice-ja', label: 'Voz JA dedicada (SenseVoice)'),
                    _ModelRow(modelId: 'whisper-base', label: 'Voz completa (base)'),
                    _ModelRow(modelId: 'whisper-small', label: 'Voz superior (small)'),
                    const _ModelGroupTitle('Tradução — leva p/ português'),
                    _ModelRow(
                        modelId: 'hymt-ja-pt-q3km',
                        label: 'Tradução JA→PT (Hy-MT2 Q3)'),
                    _ModelRow(
                        modelId: 'hymt-ja-pt-q4',
                        label: 'Tradução JA→PT (Hy-MT2 Q4)'),
                    const _ModelGroupTitle('Áudio — ajuda a transcrição'),
                    _ModelRow(modelId: 'silero-vad', label: 'VAD silero (opcional)'),
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

/// Subtítulo de categoria na lista de modelos.
class _ModelGroupTitle extends StatelessWidget {
  final String text;
  const _ModelGroupTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Text(text,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: ThemeConstants.textSecondary,
          )),
    );
  }
}

/// Linha de status + download de um modelo (D-pad: TVButton focável).
/// Mostra Instalado/Faltando + MB do catálogo; baixa do HF só no Wi-Fi
/// (ModelManager recusa rede metered) com resume + progresso.
class _ModelRow extends StatefulWidget {
  final String modelId;
  final String label;
  const _ModelRow({required this.modelId, required this.label});

  @override
  State<_ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<_ModelRow> {
  Future<bool>? _ready;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _check();
  }

  void _check() {
    setState(() {
      _progress = null;
      _ready = const ModelManager().isReady(widget.modelId);
    });
  }

  Future<void> _download() async {
    setState(() => _progress = 0);
    try {
      await const ModelManager().downloadModel(
        widget.modelId,
        onProgress: (_, p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.label} pronto.')));
    } on ModelDownloadException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) _check();
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = aiModelCatalog[widget.modelId]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: FutureBuilder<bool>(
        future: _ready,
        builder: (context, snap) {
          final ready = snap.data ?? false;
          return Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.label} — ${ready ? 'instalado' : 'faltando'} '
                      '(${spec.mb} MB)',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 16),
                    ),
                    if (_progress != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: LinearProgressIndicator(
                            value: _progress,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation(
                                ThemeConstants.primary)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (!ready && _progress == null)
                TVButton(
                  label: 'Baixar',
                  width: 160,
                  onPressed: _download,
                ),
            ],
          );
        },
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ));
      return;
    }

    setState(() => _busy = true);
    final result = await updater.check(manual: true);
    if (!mounted) return;
    setState(() => _busy = false);

    if (result == false) {
      final msg = updater.lastCheckNotice ?? 'Você está na versão mais recente.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ));
    } else if (result == null) {
      // Só sobra erro de rede/timeout aqui: o no-op por estado ativo já foi
      // tratado no pré-check acima.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Não foi possível verificar atualizações agora. Tente novamente.'),
        duration: Duration(seconds: 3),
      ));
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