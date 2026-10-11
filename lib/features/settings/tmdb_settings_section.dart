import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/catalog/catalog_browse_service.dart';
import '../../core/constants/theme_constants.dart';
import '../../core/storage/settings_service.dart';
import '../../core/tmdb/tmdb_service.dart';

/// Seção "Catálogo TMDB": liga o catálogo de drama/dorama/donghua/novela.
///
/// **Chave padrão no app.** A chave v3 do TMDB é feita para viver no
/// cliente — a própria documentação do TMDB pede isso — então embuti-la no
/// APK não é vazar segredo, é o desenho da API. O que não pode é deixá-la
/// no repositório git (o secret scanning do GitHub marcaria o repo). Ela
/// entra no build por `--dart-define=TMDB_API_KEY_DEFAULT=...`, injetada
/// pelo CI a partir do secret `TMDB_API_KEY_DEFAULT`.
///
/// Consequênciashonestas, ditas na tela em vez de escondidas:
///  - a chave padrão é **compartilhada**: se alguém abusar, a cota de todo
///    mundo cai. Por isso existe "usar a minha chave", que tem precedência;
///  - o rim de troca é rápido (trocar a define e republicar).
///
/// Sem chave nenhuma (build local sem a define), o app segue funcionando
/// só com AniList e o campo manual continua disponível.
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
    // Índice precisa ser reconstruído: ele foi populado com outra origem.
    await CatalogBrowseService.clearIndex();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _editing = false;
    });
    _snack('Chave salva. Reindexando o catálogo…');
    CatalogBrowseService.warmUpInBackground();
  }

  Future<void> _useDefault() async {
    if (!SettingsService.tmdbHasDefaultKey) {
      _snack('Este build não traz chave padrão — cole a sua abaixo.');
      return;
    }
    setState(() => _busy = true);
    await SettingsService.instance.useTmdbDefaultKey();
    _controller.clear();
    await CatalogBrowseService.clearIndex();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _editing = false;
    });
    _snack('Usando a chave padrão do app. Reindexando…');
    CatalogBrowseService.warmUpInBackground();
  }

  Future<void> _clear() async {
    await SettingsService.instance.setTmdbApiKey('');
    _controller.clear();
    await CatalogBrowseService.clearIndex();
    if (!mounted) return;
    setState(() => _editing = false);
    _snack('Chave removida.');
    CatalogBrowseService.warmUpInBackground();
  }

  /// Testa a chave de verdade contra a API.
  Future<void> _testKey() async {
    setState(() => _busy = true);
    var ok = false;
    var detail = '';
    try {
      // Diagnóstico completo: valida a chave E faz uma descoberta real sem
      // filtro, para separar "chave recusada" de "chave ok mas filtro sem
      // resultado" — que antes chegavam iguais à tela.
      final r = await TmdbService.diagnose();
      ok = r.ok;
      detail = r.message;
    } catch (e) {
      detail = 'Falhou: $e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(ok ? detail : '$detail Sem chave, o app segue só com AniList.');
  }

  /// Abre a página de API do TMDB no navegador. Reusa o canal nativo do
  /// updater (Intent VIEW) em vez de trazer `url_launcher` — menos uma
  /// dependência e nada de `<queries>` no manifest. Se não conseguir abrir,
  /// copia o link: o usuário ainda consegue colar no celular.
  Future<void> _openTmdbSignup() async {
    // themoviedb.org/settings/api fica DENTRO da conta: quem não tem conta
    // precisa criar antes. Mandamos direto pra lá e o texto explica.
    const url = 'https://www.themoviedb.org/settings/api';
    var opened = false;
    try {
      opened = await const MethodChannel('goanime_tv/updater')
          .invokeMethod<bool>('openUrl', {'url': url}) ??
          false;
    } catch (_) {
      opened = false;
    }
    if (opened) return;
    await Clipboard.setData(const ClipboardData(text: url));
    _snack('Não consegui abrir o navegador — link copiado: $url');
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
              'Adiciona dramas, doramas, donghua e novelas ao acervo. O app já '
              'traz uma chave padrão — use a sua se preferir (tem precedência) '
              'ou para não depender da cota compartilhada.',
              style: TextStyle(
                fontSize: 16,
                color: ThemeConstants.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            _StatusLine(
              configured: configured,
              usingDefault: TmdbService.usingDefaultKey,
              masked: masked,
              hasDefault: SettingsService.tmdbHasDefaultKey,
              enabled: s.tmdbEnabled,
            ),
            const SizedBox(height: 14),
            if (_editing) ...[
              Row(
                children: [
                  Expanded(child: _KeyField(controller: _controller)),
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
                label: 'Obter chave grátis no TMDB',
                onTap: _busy ? null : _openTmdbSignup,
              ),
            ] else ...[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _ActionButton(
                    label: 'Testar chave',
                    onTap: (_busy || !configured) ? null : _testKey,
                  ),
                  _ActionButton(
                    label: s.tmdbUsesOwnKey ? 'Trocar minha chave' : 'Usar a minha chave',
                    onTap: _busy ? null : () => setState(() => _editing = true),
                  ),
                  if (s.tmdbUsesOwnKey)
                    _ActionButton(
                      label: 'Voltar à chave padrão',
                      onTap: (_busy || !SettingsService.tmdbHasDefaultKey) ? null : _useDefault,
                    )
                  else
                    _ActionButton(
                      label: 'Obter chave grátis',
                      onTap: _busy ? null : _openTmdbSignup,
                    ),
                ],
              ),
              if (s.tmdbUsesOwnKey) ...[
                const SizedBox(height: 10),
                _ActionButton(
                  label: 'Remover minha chave',
                  danger: true,
                  onTap: _busy ? null : _clear,
                ),
              ],
            ],
            const SizedBox(height: 12),
            _Note(text: _noteFor(s)),
          ],
        );
      },
    );
  }

  String _noteFor(SettingsService s) {
    if (!SettingsService.tmdbHasDefaultKey) {
      return 'Este build não traz chave padrão. Pegue a sua em '
          'themoviedb.org → Settings → API (crie conta grátis) e cole acima. '
          'Ela fica só neste aparelho.';
    }
    if (s.tmdbUsesOwnKey) {
      return 'Usando a sua chave. Ela fica só neste aparelho.';
    }
    return 'Usando a chave padrão do app, compartilhada por todos. Se '
        'algum dia o catálogo vier vazio ou com erro, pode ser cota '
        'compartilhada esgotada — nesse caso use a sua.';
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 15,
        color: ThemeConstants.textMuted,
        height: 1.4,
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final bool configured;
  final bool usingDefault;
  final String masked;
  final bool hasDefault;
  final bool enabled;

  const _StatusLine({
    required this.configured,
    required this.usingDefault,
    required this.masked,
    required this.hasDefault,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final color = configured ? ThemeConstants.primary : ThemeConstants.textMuted;
    final String label;
    if (!enabled) {
      label = 'Desligado';
    } else if (!configured) {
      label = hasDefault ? 'Sem chave — só AniList' : 'Sem chave — só AniList';
    } else if (usingDefault) {
      label = 'Ativo · chave padrão do app';
    } else {
      label = 'Ativo · sua chave $masked';
    }
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: TextStyle(fontSize: 16, color: color))),
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