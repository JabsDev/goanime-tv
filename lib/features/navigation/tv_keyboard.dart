import 'package:flutter/material.dart';

/// Teclado na tela navegável por D-pad, no lugar do IME do Android TV (o IME
/// não abre em inputs de WebView focados por JS — validado no hardware).
/// As teclas são [FilledButton] focusable: o foco/Enter nativos do Flutter
/// fazem a navegação D-pad e a ativação, sem código custom de handler.
class TvKeyboard extends StatefulWidget {
  const TvKeyboard({
    super.key,
    required this.onChar,
    required this.onBackspace,
    required this.onClose,
    this.display = '',
  });

  /// Digitar um caractere (letra, número ou símbolo).
  final ValueChanged<String> onChar;

  /// Apagar um caractere do campo focado.
  final VoidCallback onBackspace;

  /// Fechar o teclado (volta o D-pad ao WebView).
  final VoidCallback onClose;

  /// Conteúdo atual do campo focado (já mascarado no JS para senhas) —
  /// exibido na barra superior como preview do que está sendo digitado.
  final String display;

  @override
  State<TvKeyboard> createState() => TvKeyboardState();
}

class TvKeyboardState extends State<TvKeyboard> {
  bool _numeric = false;
  bool _shift = false;
  final FocusNode _firstKeyFocus = FocusNode();
  final FocusScopeNode _scope = FocusScopeNode();

  /// Re-pede foco ao scope do teclado: o D-pad da TV pode variar o foco para
  /// `null` após navegação (validado em hardware); sem isso as teclas ficam
  /// mudas. Chamado pelo host a cada evento de tecla com foco perdido.
  void refocus() {
    if (!mounted) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) {
      _scope.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _firstKeyFocus.requestFocus();
      });
    }
  }

  static const List<List<String>> _letterRows = [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
  ];
  static const List<List<String>> _letterRowsUpper = [
    ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'],
    ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'],
    ['Z', 'X', 'C', 'V', 'B', 'N', 'M'],
  ];
  static const List<String> _numbers = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  static const List<String> _symbols = ['@', '.', '_', '-', '!', '?', '/', ':', ';', '+'];

  static const List<String> _actionRow = ['⇧', '123', 'Espaço', 'Apagar', 'Fechar'];

  List<List<String>> get _rows => _numeric
      ? [_numbers, _symbols]
      : (_shift ? _letterRowsUpper : _letterRows);

  String _actionLabel(String k) {
    switch (k) {
      case '⇧':
        return _shift ? '⇪' : '⇧';
      case '123':
        return _numeric ? 'ABC' : '123';
      default:
        return k;
    }
  }

  void _onKey(String k) {
    if (k.isEmpty) return;
    widget.onChar(k);
    // Shift é one-shot (volta a minúsculas após uma tecla), como o IME da TV.
    if (_shift) {
      setState(() => _shift = false);
    }
  }

  void _onAction(String k) {
    switch (k) {
      case '⇧':
        setState(() => _shift = !_shift);
        _refocusFirstKey();
      case '123':
      case 'ABC':
        setState(() {
          _numeric = !_numeric;
          _shift = false;
        });
        _refocusFirstKey();
      case 'Espaço':
        widget.onChar(' ');
      case 'Apagar':
        widget.onBackspace();
      case 'Fechar':
        widget.onClose();
    }
  }

  // volta o foco para a primeira tecla da grade (modo/grid mudou)
  void _refocusFirstKey() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstKeyFocus.requestFocus();
    });
  }

  @override
  void initState() {
    super.initState();
    // Foco inicial na primeira tecla: o D-pad deve navegar nas teclas.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstKeyFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _firstKeyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.88),
      child: SafeArea(
child: FocusScope(
            node: _scope,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Preview do que está sendo digitado (estilo IME da TV).
                    Container(
                      width: 620,
                      height: 56,
                      margin: const EdgeInsets.only(bottom: 12),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        widget.display.isEmpty ? ' ' : widget.display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22,
                          color: Colors.white,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    for (var i = 0; i < _rows.length; i++)
                      _Row(
                        keys: _rows[i],
                        onKey: _onKey,
                        firstFocus: i == 0 ? _firstKeyFocus : null,
                      ),
                    const SizedBox(height: 10),
                    _Row(
                      wide: const {'Espaço'},
                      keys: _actionRow,
                      labels: _actionLabel,
                      onKey: _onAction,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.keys,
    required this.onKey,
    this.wide = const {},
    this.firstFocus,
    this.labels,
  });

  final List<String> keys;
  final ValueChanged<String> onKey;
  final Set<String> wide;
  final FocusNode? firstFocus;

  /// Mostra [labels] no lugar da tecla (ex.: "⇪" quando shift ativo).
  final String Function(String key)? labels;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < keys.length; i++)
            if (keys[i].isNotEmpty)
              _Key(
                label: labels == null ? keys[i] : labels!(keys[i]),
                wide: wide.contains(keys[i]) || keys[i] == 'Espaço',
                onPressed: () => onKey(keys[i]),
                focusNode: i == 0 ? firstFocus : null,
              ),
        ],
      ),
    );
  }
}

class _Key extends StatefulWidget {
  const _Key({
    required this.label,
    required this.onPressed,
    this.wide = false,
    this.focusNode,
  });

  final String label;
  final VoidCallback onPressed;
  final bool wide;
  final FocusNode? focusNode;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  late final FocusNode _focus = _initFocus();
  bool _focused = false;

  FocusNode _initFocus() {
    final n = widget.focusNode ?? FocusNode();
    n.addListener(_onFocus);
    return n;
  }

  void _onFocus() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: widget.wide ? 160 : 84,
      height: 56,
      child: FilledButton(
        focusNode: _focus,
        onPressed: widget.onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.grey.shade800,
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: _focused ? colors.primary : Colors.white24,
              width: _focused ? 3 : 1,
            ),
          ),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: widget.wide ? 16 : 22,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}