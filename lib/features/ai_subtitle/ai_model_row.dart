import 'package:flutter/material.dart';

import '../../core/constants/theme_constants.dart';
import '../../core/subtitles/model_manager.dart';
import '../../shared/widgets/focus_key_handler.dart';
import '../../shared/widgets/tv_button.dart';

/// Linha única de modelo: label do tier ativo + status ("instalado · N MB",
/// "faltando · N MB", "Baixando… %") + tap cicla o tier (1 tier = seleciona)
/// + botão Baixar do tier ativo (barra inline). strongOnly bloqueia em
/// aparelho fraco ("só aparelho forte"). `statuses` = 1 Future único
/// (AiProviders.readyMap) — NÃO FutureBuilder por linha (antes: IO por
/// linha a cada build, estudo §3.1.5). D-pad: tap = ciclar; Baixar = botão
/// focável.
class AiModelRow extends StatefulWidget {
  final String heading; // 'Voz' | 'Tradução' | 'Áudio'
  final List<String> tiers; // ordem de ciclo (ou 1 tier fixo)
  final Map<String, String> tierIds; // tier → modelId (catálogo)
  final Map<String, String> tierLabels; // tier → label curto
  final String selected;
  final ValueChanged<String> onSelect;
  final Future<Map<String, bool>> statuses; // modelId → instalado?
  final Map<String, double> downloading; // modelId → progresso (0..1)
  final ValueChanged<String> onDownload;
  final bool lowEnd;

  /// Marca visual de "em uso" (radios do settings); o card não usa.
  final bool marked;

  const AiModelRow({
    super.key,
    required this.heading,
    required this.tiers,
    required this.tierIds,
    required this.tierLabels,
    required this.selected,
    required this.onSelect,
    required this.statuses,
    required this.downloading,
    required this.onDownload,
    this.lowEnd = false,
    this.marked = false,
  });

  @override
  State<AiModelRow> createState() => _AiModelRowState();
}

class _AiModelRowState extends State<AiModelRow> {
  bool _focused = false;

  void _cycle() {
    if (widget.tiers.length <= 1) {
      // Modo radio: 1 tier = seleciona ele mesmo.
      widget.onSelect(widget.selected);
      return;
    }
    final i = widget.tiers.indexOf(widget.selected);
    widget.onSelect(widget.tiers[(i + 1) % widget.tiers.length]);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.tierIds[widget.selected] ?? '';
    final spec = aiModelCatalog[id];
    if (spec == null) return const SizedBox.shrink();
    final downloading = widget.downloading[id];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: FutureBuilder<Map<String, bool>>(
        future: widget.statuses,
        builder: (context, snap) {
          // Map não tem operador null-aware de índice: checa o mapa antes.
          final map = snap.data;
          final ready = map != null && map[id] == true;
          // strongOnly (item 4): visível, mas seleção/download travados
          // no fraco até o modelo estar instalado.
          final strongBlocked = spec.strongOnly && widget.lowEnd && !ready;
          final String status;
          if (downloading != null) {
            status = 'Baixando… ${(downloading * 100).toInt()}%';
          } else if (strongBlocked) {
            status = 'só aparelho forte · ${spec.mb} MB';
          } else {
            status =
                '${ready ? 'instalado' : 'faltando'} · ${spec.mb} MB';
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _rowContainer(status: status),
              if (!ready && downloading == null && !strongBlocked)
                _downloadButton(id),
              if (downloading != null) _progressBar(downloading),
            ],
          );
        },
      ),
    );
  }

  Widget _rowContainer({required String status}) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (n, e) => FocusKeyHandler.handle(n, e, _cycle),
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: _cycle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: widget.marked
                  ? ThemeConstants.primary.withValues(alpha: 0.25)
                  : _focused
                      ? ThemeConstants.primary.withValues(alpha: 0.15)
                      : ThemeConstants.surfaceLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _focused ? ThemeConstants.primary : Colors.transparent,
                width: _focused ? 3 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.heading} '
                  '${widget.tierLabels[widget.selected] ?? ''}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  status,
                  style: const TextStyle(
                    color: ThemeConstants.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _downloadButton(String id) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TVButton(
        label: 'Baixar',
        onPressed: () => widget.onDownload(id),
      ),
    );
  }

  Widget _progressBar(double p) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: LinearProgressIndicator(
        value: p,
        backgroundColor: Colors.white24,
        valueColor: const AlwaysStoppedAnimation(ThemeConstants.primary),
      ),
    );
  }
}
