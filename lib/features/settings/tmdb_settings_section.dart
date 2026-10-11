import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/catalog/catalog_browse_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/tmdb/tmdb_service.dart';

/// Seção "Catálogo TMDB": liga o catálogo de drama/dorama/donghua/novela.
///
/// A chave v3 é **do usuário**. O app não tem backend, então não existe onde
/// guardar um segredo do lado do servidor: uma chave embutida no APK sai
/// qualquer pessoa que descompactar o pacote. Sem chave, tudo aqui continua
/// funcionando — só a aba de dramas fica desligada.
class TmdbSettingsSection extends StatefulWidget {
  const TmdbSettingsSection({super.key});

  @override
  State<TmdbSettingsSection> createState() => _TmdbSettingsSectionState();
}

class _TmdbSettingsSectionState extends State<TmdbSettingsSection> {
  final _controller = TextEditingController();
  bool _editing = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final k = SettingsService.instance.tmdbApiKey;
    if (k.isNotEmpty) _controller.text = k;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    final raw = _controller.text.trim();
    final err = SettingsService.validateTmdbKey(raw);
    if (err != null) {
      _snack(err);
      return;
    }
    setState(() => _busy = true);
    await SettingsService.instance.setTmdbApiKey(raw);
    // Índice precisa ser reconstruído: ele foi populado sem o TMDB.
    await CatalogBrowseService.clearIndex();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _editing = false;
    });
    _snack('Chave salva. Reindexando o catálogo…');
    CatalogBrowseService.warmUpInBackground();
  }

  Future<void> _clear() async {
    await SettingsService.instance.setTmdbApiKey('');
    _controller.clear();
    await CatalogBrowseService.clearIndex();
    if (!mounted) return;
    setState(() => _editing = false);
    _snack('Chave removida. O catálogo volta a ser só AniList.');
  }

  /// Testa a chave de verdade contra a API. Sem isto o usuário não tem como
  /// saber se salvou uma chave válida: uma chave inválida só produz busca
  /// vazia, silenciosamente.
  Future<void> _testKey() async {
    setState(() => _busy = true);
    var ok = false;
    var detail = '';
    try {
      // Antes usava `discover` e, como TODO erro não-200 virava lista vazia,
      // respondia "chave inválida" para qualquer problema — inclusive rede
      // quebrada ou limite de requisições. `verifyKey` bate num id fixo e
      // separa "chave recusada" de erro de transporte.
      final r = await TmdbService.verifyKey();
      ok = r.ok;
      detail = r.message;
    } catch (e) {
      detail = 'Falhou: $e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(ok ? detail : '$detail Sem chave, o app segue só com AniList.');
  }

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    return ValueListenableBuilder<String>(
      valueListenable: s.tmdbApiKeyListenable,
      builder: (context, masked, _) {
        final configured = s.tmdbConfigured;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Catálogo TMDB',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: ThemeConstants.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Adiciona dramas, doramas, donghua e novelas ao acervo. Colque '
              'a sua chave v3 (grátis em themoviedb.org → Settings → API). '
              'A chave fica só neste aparelho.',
              style: TextStyle(
                fontSize: 16,
                color: ThemeConstants.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            _StatusLine(
              configured: configured,
              masked: masked,
              enabled: s.tmdbEnabled,
            ),
            const SizedBox(height: 12),
            if (_editing) ...[
              Row(
                children: [
                  Expanded(
                    child: _KeyField(controller: _controller),
                  ),
                  const SizedBox(width: 12),
                  _ActionButton(
                    label: 'Salvar',
                    onTap: _busy ? null : _save,
                  ),
                  const SizedBox(width: 8),
                  _ActionButton(
                    label: 'Cancelar',
                    onTap: () => setState(() {
                      _editing = false;
                      _controller.text = s.tmdbApiKey;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _ActionButton(
                label: 'Remover chave',
                danger: true,
                onTap: _busy ? null : _clear,
              ),
            ] else ...[
              _ActionButton(
                label: s.tmdbApiKey.isEmpty
                    ? 'Adicionar chave'
                    : 'Trocar chave',
                onTap: () => setState(() => _editing = true),
              ),
              if (s.tmdbApiKey.isNotEmpty) ...[
                const SizedBox(width: 10),
                _ActionButton(
                  label: 'Testar chave',
                  onTap: _busy ? null : _testKey,
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}

class _StatusLine extends StatelessWidget {
  final bool configured;
  final String masked;
  final bool enabled;

  const _StatusLine({
    required this.configured,
    required this.masked,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final color = configured ? ThemeConstants.primary : ThemeConstants.textMuted;
    final label = !enabled
        ? 'Desligado'
        : configured
            ? 'Ativo · chave $masked'
            : 'Sem chave — só AniList por enquanto';
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(label,
            style: TextStyle(fontSize: 16, color: color)),
      ],
    );
  }
}

class _KeyField extends StatelessWidget {
  final TextEditingController controller;

  const _KeyField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 32,
      keyboardType: TextInputType.text,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
      ],
      style: const TextStyle(color: ThemeConstants.white, fontSize: 18),
      decoration: InputDecoration(
        hintText: 'cole a chave v3 de 32 caracteres',
        hintStyle:
            const TextStyle(color: ThemeConstants.textMuted, fontSize: 16),
        counterStyle:
            const TextStyle(color: ThemeConstants.textMuted, fontSize: 12),
        filled: true,
        fillColor: ThemeConstants.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// Botão focado por D-pad (o app é 100% controle remoto).
class _ActionButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const _ActionButton({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final base = widget.danger
        ? ThemeConstants.accent
        : ThemeConstants.primary;
    final bg = !enabled
        ? ThemeConstants.surfaceLight
        : (_focused ? base : base.withValues(alpha: 0.22));
    final fg = !enabled
        ? ThemeConstants.textMuted
        : (_focused ? Colors.black : base);
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused ? base : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text(widget.label,
              style: TextStyle(
                  color: fg, fontSize: 17, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}