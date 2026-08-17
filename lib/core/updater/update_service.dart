import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../profile/profile_store.dart';
import 'github_release_api.dart';
import 'update_constants.dart';
import 'version_compare.dart';

enum UpdateState {
  idle,
  checking,
  updateAvailable,
  downloading,
  installing,
  done,
  error,
}

/// Falha de update com causa amigável para a TV.
class UpdateFailure implements Exception {
  final String message;
  final bool canOpenInstaller;
  const UpdateFailure(this.message, {this.canOpenInstaller = false});
  @override
  String toString() => message;
}

class UpdateCanceled implements Exception {}

/// Orquestra o auto-update via GitHub Releases.
///
/// Singleton (padrão `SettingsService`/`ProfileService`). Expõe um único
/// `ValueNotifier<UpdateState>` como âncora dos diálogos de TV.
class UpdateService {
  static final UpdateService instance = UpdateService._();
  UpdateService._();

  /// Test hooks: cliente HTTP mockado (mesmo padrão de `ApiClient`).
  @visibleForTesting
  static http.Client? clientOverride;

  static const _channelName = 'goanime_tv/updater';
  final MethodChannel _channel = const MethodChannel(_channelName);

  static const _kLastCheckAt = 'update_last_check_at';
  static const _kIgnoredTag = 'update_ignored_tag';
  static const _kCheckOnLaunch = 'update_check_on_launch';

  final ValueNotifier<UpdateState> _state = ValueNotifier(UpdateState.idle);
  ValueListenable<UpdateState> get state => _state;

  final ValueNotifier<double?> _progress = ValueNotifier<double?>(null);
  ValueListenable<double?> get progress => _progress;

  ReleaseInfo? get pending => _pending;
  String? get errorMessage => _errorMessage;
  bool get canOpenInstaller => _errorCanOpenInstaller;

  String? _lastCheckNotice;
  /// Mensagem pronta para a UI após `check()`. `null` → nada a mostrar
  /// (erro de rede ou no-op). Definida apenas em checagens válidas.
  String? get lastCheckNotice => _lastCheckNotice;

  String? _errorMessage;
  bool _errorCanOpenInstaller = false;

  int _installedBuild = 0;
  String _installedVersion = '1.0.0';
  bool _checkOnLaunch = true;

  ReleaseInfo? _pending;
  bool _cancelRequested = false;
  File? _apkFile;
  int? _lastCheckAt;
  String? _ignoredTag;

  String get installedVersionLabel {
    if (_installedVersion.contains('+')) return _installedVersion;
    return '$_installedVersion${_installedBuild > 0 ? '+$_installedBuild' : ''}';
  }

  bool get checkOnLaunch => _checkOnLaunch;

  Future<void> init() async {
    try {
      final pi = await PackageInfo.fromPlatform();
      _installedVersion = pi.version;
      _installedBuild = int.tryParse(pi.buildNumber) ?? 0;
    } catch (e) {
      // Fallback seguro (D3): sem device/plugin, assume 1.0.0+0.
      debugPrint('[updater] PackageInfo unavailable: $e');
      _installedVersion = '1.0.0';
      _installedBuild = 0;
    }

    _channel.setMethodCallHandler(_onMethodCall);

    final prefs = await SharedPreferences.getInstance();
    _lastCheckAt = prefs.getInt(_kLastCheckAt);
    _ignoredTag = prefs.getString(_kIgnoredTag);
    _checkOnLaunch = prefs.getBool(_kCheckOnLaunch) ?? true;

    await _cleanOrphans();
    debugPrint('[updater] installed=$installedVersionLabel');
  }

  /// Resultado da instalação vindo do nativo (BroadcastReceiver/PackageInstaller).
  Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method == 'installResult') {
      final success = call.arguments['success'] == true;
      final message = call.arguments['message'] as String?;
      if (_state.value == UpdateState.installing) {
        if (success) {
          _deleteFile(_apkFile);
          _pending = null;
          _state.value = UpdateState.done;
        } else {
          final v = message ?? 'Falha ao instalar o APK.';
          _errorMessage = v;
          _errorCanOpenInstaller = _apkFile != null && _apkFile!.existsSync();
          _state.value = UpdateState.error;
        }
        _apkFile = null;
      }
      return null;
    }
    return null;
  }

  bool wasIgnored(String tagName) => _ignoredTag == tagName;

  Future<void> setCheckOnLaunch(bool v) async {
    _checkOnLaunch = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCheckOnLaunch, v);
  }

  Future<Directory> _ensureUpdatesDir() async {
    final ext = await getExternalStorageDirectory();
    if (ext == null) {
      throw const UpdateFailure(
          'Armazenamento externo indisponível para o download.');
    }
    final dir = Directory('${ext.path}/${UpdateConstants.updatesDir}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Apaga no boot arquivos parciais antigos (processo morto no download).
  Future<void> _cleanOrphans() async {
    try {
      final dir = await _ensureUpdatesDir();
      final cutoff = DateTime.now().subtract(UpdateConstants.orphanAge);
      for (final f in dir.listSync()) {
        if (f is File && f.lastModifiedSync().isBefore(cutoff)) {
          try {
            f.deleteSync();
            debugPrint('[updater] orphan removido: ${f.path}');
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[updater] _cleanOrphans: $e');
    }
  }

  /// Se existe uma release "bloqueada" (docs-only/prerelease) MAIS NOVA que a
  /// instalada e não ignorada pelo usuário, devolve a mensagem de feedback.
  /// Senão null. Evita o falso "você está na versão mais recente" (sintoma D).
  String? _blockedNotice(ReleaseInfo? blocked) {
    if (blocked == null) return null;
    if (wasIgnored(blocked.tagName)) return null;
    if (compareAppVersions(
          installedBuild: _installedBuild,
          installedVersion: _installedVersion,
          tagName: blocked.tagName,
        ) <= 0) {
      return null;
    }
    return 'Existe uma versão nova, mas ela ainda não está disponível '
        'para instalação. Tente novamente mais tarde.';
  }

  /// Checa por atualização. [manual]=true ignora o throttle. 
  /// `true` → update sendo oferecido; `false` → checagem ok, sem update;
  /// `null` → no-op (guarda de concorrência ou throttle automático).
  Future<bool?> check({required bool manual}) async {
    if (_state.value != UpdateState.idle) return null; // guarda D4
    if (!manual) {
      if (!_checkOnLaunch) return null;
      final last = _lastCheckAt;
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last <
              UpdateConstants.checkInterval.inMilliseconds) {
        return null; // throttled (1×/dia)
      }
    }
    _lastCheckNotice = null; // limpa SEMPRE antes de validar

    _state.value = UpdateState.checking;
    _errorMessage = null;
    try {
      final res = await fetchLatestRelease(client: clientOverride);
      if (res.httpOk) {
        // Throttle só em checagem válida (D4): 403/429/erro de rede não
        // "trancam" o app por 24h.
        _lastCheckAt = DateTime.now().millisecondsSinceEpoch;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_kLastCheckAt, _lastCheckAt!);
      }

      if (res.info == null) {
        _state.value = UpdateState.idle;
        if (!res.httpOk) return null; // erro de rede → UI mostra "não foi possível"
        // Checagem válida sem release instalável: distingue blocked de "ok".
        _lastCheckNotice =
            _blockedNotice(res.blockedNewer) ?? 'Você está na versão mais recente.';
        return false;
      }

      final r = res.info!;
      final ignored = wasIgnored(r.tagName);
      final newer = !ignored &&
          compareAppVersions(
            installedBuild: _installedBuild,
            installedVersion: _installedVersion,
            tagName: r.tagName,
          ) > 0;
      if (!newer) {
        _state.value = UpdateState.idle;
        // CAUSA RAIZ do sintoma D: `r` é a última instalável (pode ser igual à
        // instalada) enquanto existe uma docs-only mais nova. A mensagem tem
        // prioridade sobre o falso "versão mais recente".
        _lastCheckNotice = _blockedNotice(res.blockedNewer) ??
            (ignored ? 'Você ignorou esta versão.' : 'Você está na versão mais recente.');
        return res.httpOk ? false : null;
      }

      _pending = r;
      _state.value = UpdateState.updateAvailable;
      return true;
    } catch (e) {
      debugPrint('[updater] check error: $e');
      _state.value = UpdateState.idle;
      _lastCheckNotice = null;
      return null;
    }
  }

  /// Baixa com progresso, verifica o digest, faz flush dos dados e instala.
  Future<void> downloadAndInstall(ReleaseInfo r) async {
    if (_state.value == UpdateState.downloading) return;
    _errorMessage = null;
    _errorCanOpenInstaller = false;
    _cancelRequested = false;
    _pending = r;
    _state.value = UpdateState.downloading;
    _progress.value = null;
    File? apk;
    _apkFile = null;

    try {
      final url = r.apkUrl;
      if (url == null) {
        throw const UpdateFailure('Release sem link de APK.');
      }
      apk = await _download(r, url);
      _apkFile = apk;
      await _verifyDigest(apk, r.apkDigest);

      // I-6: instalação só começa com a persistência gravada.
      await flushData();

      _state.value = UpdateState.installing;
      bool? ok;
      try {
        ok = await _channel.invokeMethod<bool>('installApk', {
          'path': apk.path,
        });
      } on MissingPluginException {
        ok = false;
      } on PlatformException catch (e) {
        // Falha imediata do nativo (ex.: createSession) — mensagem direta.
        _errorMessage = e.message ?? 'Falha ao iniciar a instalação.';
        _state.value = UpdateState.error;
        return;
      }
      if (ok != true) {
        throw UpdateFailure(
          _errorMessage ?? 'Falha ao iniciar a instalação.',
          canOpenInstaller: true,
        );
      }
      // A partir daqui o resultado real vem por `installResult`
      // (o commit do PackageInstaller é assíncrono).
    } on UpdateCanceled {
      _deleteFile(apk);
      _apkFile = null;
      _pending = null;
      debugPrint('[updater] download cancelado');
      _state.value = UpdateState.idle;
    } on UpdateFailure catch (e) {
      _errorMessage = e.message;
      _errorCanOpenInstaller = e.canOpenInstaller;
      _state.value = UpdateState.error;
    } catch (e) {
      _errorMessage =
          'Falha no download. Verifique a conexão, o espaço e tente novamente.';
      debugPrint('[updater] download error: $e');
      _deleteFile(apk);
      _apkFile = null;
      _pending = null;
      _state.value = UpdateState.error;
    } finally {
      _progress.value = null;
    }
  }

  Future<File> _download(ReleaseInfo r, Uri url) async {
    final dir = await _ensureUpdatesDir();
    final file = File('${dir.path}/${UpdateConstants.apkFileName(r.tagName)}');
    if (file.existsSync()) file.deleteSync();

    final client = clientOverride ?? http.Client();
    final out = await file.open(mode: FileMode.write);
    var received = 0;
    try {
      final req = http.Request('GET', url)
        ..headers['User-Agent'] = AppConstants.userAgent;
      final resp = await client.send(req).timeout(AppConstants.requestTimeout);
      final total = resp.contentLength;

      if (total != null && total > 0) {
        final free = await _freeBytes();
        // D5-b: pre-flight de espaço quando o content-length já é conhecido.
        if (free != null && (free * 0.9) < total) {
          throw UpdateFailure(
              'Espaço em disco insuficiente (${_mb(total)} MB necessários). '
              'Libere espaço e tente novamente.');
        }
      }

      await for (final chunk in resp.stream) {
        if (_cancelRequested) throw UpdateCanceled();
        await out.writeFrom(chunk);
        received += chunk.length;
        if (total != null && total > 0) {
          _progress.value = (received / total).clamp(0.0, 1.0);
        }
      }
      await out.flush();
    } finally {
      await out.close();
      if (clientOverride == null) client.close();
    }
    _progress.value = 1.0;
    return file;
  }

  String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  Future<int?> _freeBytes() async {
    try {
      return await _channel.invokeMethod<int>('getFreeBytes');
    } catch (_) {
      return null; // não-Android (testes) → pre-flight ignorado
    }
  }

  /// I-7/D5-a: digest do APK baixado vs. release. 40 hex = SHA-1 (asset),
  /// 64 hex = SHA-256 (body). **Sem digest declarado, segue sem verificar**
  /// (releases antigas podem não publicar).
  Future<void> _verifyDigest(File f, String? digest) async {
    if (digest == null || digest.trim().isEmpty) {
      debugPrint('[updater] release sem digest — pulando verificação');
      return;
    }
    final d = digest.trim().toLowerCase();
    if (d.length != 40 && d.length != 64) {
      debugPrint('[updater] digest com formato inesperado — pulando');
      return;
    }
    final hex = d.length == 40
        ? sha1.convert(await f.readAsBytes()).toString()
        : sha256.convert(await f.readAsBytes()).toString();
    if (hex != d) {
      _deleteFile(f);
      throw const UpdateFailure(
          'O arquivo baixado não passou na verificação de integridade. '
          'Tente novamente.');
    }
    debugPrint('[updater] digest confere');
  }

  /// I-6/I-5: força a persistência de todos os dados antes de instalar.
  Future<void> flushData() async {
    await ProfileStore.instance.flush();
  }

  Future<void> ignore(ReleaseInfo r) async {
    _ignoredTag = r.tagName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIgnoredTag, r.tagName);
    _pending = null;
    if (_state.value == UpdateState.updateAvailable) {
      _state.value = UpdateState.idle;
    }
  }

  Future<void> cancelDownload() async {
    _cancelRequested = true;
  }

  /// Fallback de instalação via `ACTION_VIEW` (instalador do sistema).
  Future<void> openSystemInstaller() async {
    final f = _apkFile;
    if (f == null || !f.existsSync()) return;
    try {
      await _channel.invokeMethod('openInstaller', {'path': f.path});
    } catch (e) {
      debugPrint('[updater] openSystemInstaller error: $e');
    }
  }

  /// Fecha/ignora o fluxo atual. Diálogo de update ignorado ("Agora não") OU
  /// resultado fechado pelo usuário ("Fechar" em done/error): volta ao idle para
  /// que o _sync do UpdateManager derrube o diálogo.
  /// Estados em andamento (downloading/installing) NÃO são abatidos.
  void dismiss() {
    switch (_state.value) {
      case UpdateState.updateAvailable:
      case UpdateState.done:
      case UpdateState.error:
        _state.value = UpdateState.idle;
        break;
      default:
        break; // idle/checking/downloading/installing
    }
  }

  @visibleForTesting
  void debugSetInstalled({int build = 0, String version = '1.0.0'}) {
    _installedBuild = build;
    _installedVersion = version;
  }

  @visibleForTesting
  void debugSetState(UpdateState s) {
    _state.value = s;
  }

  @visibleForTesting
  void debugReset() {
    _ignoredTag = null;
    _lastCheckAt = null;
    _pending = null;
    _errorMessage = null;
    _errorCanOpenInstaller = false;
    _cancelRequested = false;
    _apkFile = null;
    _lastCheckNotice = null;
    _state.value = UpdateState.idle;
    _progress.value = null;
  }

  void _deleteFile(File? f) {
    if (f == null) return;
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}