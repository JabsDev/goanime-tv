import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/updater/update_service.dart';
import 'update_available_dialog.dart';
import 'update_flow_dialog.dart';

/// Âncora discreta do auto-update, montada na raiz do app.
///
/// Dispara a checagem automática pós-frame (não-bloqueante, respeitando o
/// toggle "Verificar no início") e apresenta os diálogos de TV de acordo com
/// o único `UpdateState` do serviço. Os diálogos vão para o navigator raiz —
/// ficam visíveis acima de qualquer rota (busca, detalhe, player).
class UpdateManager extends StatefulWidget {
  final Widget child;
  const UpdateManager({super.key, required this.child});

  @override
  State<UpdateManager> createState() => _UpdateManagerState();
}

class _UpdateManagerState extends State<UpdateManager> {
  String? _openDialog;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    UpdateService.instance.state.addListener(_onState);
  }

  @override
  void dispose() {
    UpdateService.instance.state.removeListener(_onState);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // D4: checagem automática fora do boot. Primeiro frame da Home pintado.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(UpdateService.instance.check(manual: false));
    });
  }

  void _onState() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    final s = UpdateService.instance;
    final st = s.state.value;
    final nav = Navigator.of(context, rootNavigator: true);
    switch (st) {
      case UpdateState.updateAvailable:
        final release = s.pending;
        if (release == null || _openDialog == 'available') return;
        _closeCurrent(nav);
        _openDialog = 'available';
        unawaited(showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => UpdateAvailableDialog(
            release: release,
            onUpdate: () => s.downloadAndInstall(release),
            onLater: s.dismiss,
            onIgnore: () => s.ignore(release),
          ),
        ).whenComplete(() => _openDialog = null));

      case UpdateState.downloading:
      case UpdateState.installing:
      case UpdateState.done:
      case UpdateState.error:
        if (_openDialog == 'flow') return;
        _closeCurrent(nav);
        _openDialog = 'flow';
        unawaited(showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => UpdateFlowDialog(release: s.pending),
        ).whenComplete(() => _openDialog = null));

      case UpdateState.idle:
      case UpdateState.checking:
        // `checking` acontece atrás da UI sem diálogo; folga nada a fazer.
        if (_openDialog != null) {
          _closeCurrent(nav);
        }
    }
  }

  void _closeCurrent(NavigatorState nav) {
    if (_openDialog != null) {
      nav.pop();
      _openDialog = null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}