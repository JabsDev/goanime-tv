import 'package:flutter/widgets.dart';

/// ponytail: RouteObserver global p/ a tela de detalhes ser notificada ao
/// voltar do player (didPopNext) e re-casar local × AniList. Singleton móvel:
/// MaterialApp o registra em navigatorObservers; DetailScreen se inscreve.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();