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
  // Fase C: token monotônico. Cada `_closeCurrent` incrementa e invalida os
  // `whenComplete` pendentes de diálogos anteriores (race que zerava
  // `_openDialog` depois que um diálogo novo já havia sido aberto).
  int _dialogToken = 0;

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
    // ponytail: garante que um frame seja agendado. Sem isto, quando a UI está
    // totalmente ociosa (nenhuma animação/cursor rodando) o postFrameCallback
    // abaixo fica esperando para sempre e o diálogo nunca abre — sintoma
    // "popup não aparece sozinho" depois da checagem automática.
    WidgetsBinding.instance.ensureVisualUpdate();
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
        _openDialogGuard(
          nav,
          UpdateAvailableDialog(
            release: release,
            onUpdate: () => s.downloadAndInstall(release),
            onLater: s.dismiss,
            onIgnore: () => s.ignore(release),
          ),
        );

      case UpdateState.downloading:
      case UpdateState.installing:
      case UpdateState.done:
      case UpdateState.error:
        if (_openDialog == 'flow') return;
        _closeCurrent(nav);
        _openDialog = 'flow';
        _openDialogGuard(nav, UpdateFlowDialog(release: s.pending));

      case UpdateState.idle:
      case UpdateState.checking:
        // `checking` acontece atrás da UI sem diálogo; folga nada a fazer.
        if (_openDialog != null) {
          _closeCurrent(nav);
        }
    }
  }

  /// Abre um diálogo de update. O `whenComplete` só zera `_openDialog` se o
  /// token não tiver sido incrementado (ou seja, se o diálogo NÃO foi fechado
  /// por `_closeCurrent`). O token é capturado DEPOIS de `_closeCurrent`, que
  /// é quem incrementa — assim um completion stale do diálogo anterior nunca
  /// zera o guard do diálogo novo.
  void _openDialogGuard(NavigatorState nav, Widget dialog) {
    final token = _dialogToken;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => dialog,
    ).whenComplete(() {
      if (token != _dialogToken) return; // completion stale — ignora
      _openDialog = null;
      // Hardening (sintoma C/B/D): se o usuário derrubou o diálogo "available"
      // com Back (sem passar por _closeCurrent), não deixar o estado preso em
      // updateAvailable — senão o próximo check(manual) retorna null sem
      // feedback e o app parece travado.
      if (UpdateService.instance.state.value == UpdateState.updateAvailable) {
        UpdateService.instance.dismiss();
      }
    }));
  }

  void _closeCurrent(NavigatorState nav) {
    if (_openDialog != null) {
      _dialogToken++; // invalida o whenComplete do diálogo atual
      nav.pop();
      _openDialog = null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}