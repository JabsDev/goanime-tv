import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ponte para o canal nativo `goanime_tv/hardware` (Android).
///
/// Devolve o mapa cru do [HardwareChannel.kt]; a modelagem fica em
/// `device_profile.dart`. Em desktop/testes o canal não existe e o retorno é
/// `null` — o chamador decide o fallback (nunca derruba o boot).
class DeviceHardware {
  DeviceHardware._();

  @visibleForTesting
  static const channel = MethodChannel('goanime_tv/hardware');

  static Future<Map<String, dynamic>?> readProfile() async {
    try {
      // `invokeMapMethod<String, dynamic>` pode falhar o cast porque o codec
      // padrão devolve Map<Object?, Object?>; normaliza manualmente.
      final raw = await channel.invokeMethod<Object?>('profile');
      if (raw is! Map) return null;
      final out = <String, dynamic>{};
      raw.forEach((key, value) {
        out[key.toString()] = value;
      });
      return out;
    } on MissingPluginException {
      debugPrint('[DeviceHardware] canal ausente (desktop/teste)');
      return null;
    } on PlatformException catch (e) {
      debugPrint('[DeviceHardware] falha ao ler perfil: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[DeviceHardware] erro inesperado: $e');
      return null;
    }
  }
}
