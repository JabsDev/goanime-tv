import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/tmdb/tmdb_service.dart';

/// Regressão do diagnóstico de chave. Antes, `discover` transformava QUALQUER
/// erro não-200 em `[]` e o botão "Testar chave" respondia "chave inválida"
/// — o usuário passou a acreditar que tinha feito algo errado quando o
/// problema era outro (rede, 429, 403).
void main() {
  // `SettingsService` usa SharedPreferences, que exige o binding + mock.
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    TmdbService.httpOverride = null;
  });

  group('verifyKey — distingue causa real', () {
    const key = '0123456789abcdef0123456789abcdef';

    test('verifyKey usa a chave padrão quando não há chave do usuário', () async {
      // Com a chave embutida, um "verify" sem chave do usuário tem que dar
      // OK contra a API — o botão Testar chave na UI usa este caminho.
      final r = await TmdbService.verifyKey();
      // Sem rede no sandbox de teste o resultado varia; o que não pode
      // acontecer é ele accuse "chave inválida" por falta de chave.
      expect(r.message, isNot(contains('Nenhuma chave configurada')));
    });

    test('401 do TMDB é reportado como chave recusada, com a mensagem dele',
        () async {
      SettingsService.instance.setTmdbApiKey(key);
      TmdbService.httpOverride = MockClient((_) async => http.Response(
            jsonEncode({
              'status_code': 7,
              'status_message': 'Invalid API key: You must be granted a valid key.',
              'success': false,
            }),
            401,
          ));
      final r = await TmdbService.verifyKey();
      expect(r.ok, isFalse);
      expect(r.message, contains('Chave recusada'));
      expect(r.message, contains('Invalid API key'),
          reason: 'a mensagem real do TMDB não pode ser engolida');
      expect(TmdbService.lastStatusCode, 401);
      expect(TmdbService.lastErrorMessage, contains('status_code 7'));
      await SettingsService.instance.setTmdbApiKey('');
    });

    test('200 é chave válida', () async {
      SettingsService.instance.setTmdbApiKey(key);
      TmdbService.httpOverride =
          MockClient((_) async => http.Response(jsonEncode({'id': 550}), 200));
      final r = await TmdbService.verifyKey();
      expect(r.ok, isTrue);
      expect(r.message, contains('válida'));
      await SettingsService.instance.setTmdbApiKey('');
    });

    test('429 NÃO é reportado como chave inválida', () async {
      SettingsService.instance.setTmdbApiKey(key);
      TmdbService.httpOverride = MockClient((_) async => http.Response(
            jsonEncode({'status_message': 'Too many requests'}),
            429,
          ));
      final r = await TmdbService.verifyKey();
      expect(r.ok, isFalse);
      expect(r.message, contains('Limite de requisições'));
      expect(r.message, isNot(contains('Chave recusada')));
      await SettingsService.instance.setTmdbApiKey('');
    });

    test('erro de rede não é reportado como chave inválida', () async {
      SettingsService.instance.setTmdbApiKey(key);
      TmdbService.httpOverride =
          MockClient((_) async => throw _Boom());
      final r = await TmdbService.verifyKey();
      expect(r.ok, isFalse);
      expect(r.message, contains('rede'));
      expect(r.message, isNot(contains('Chave recusada')));
      await SettingsService.instance.setTmdbApiKey('');
    });

    test('403 é acesso negado, não chave recusada', () async {
      SettingsService.instance.setTmdbApiKey(key);
      TmdbService.httpOverride = MockClient((_) async => http.Response(
            jsonEncode({'status_message': 'blocked'}),
            403,
          ));
      final r = await TmdbService.verifyKey();
      expect(r.message, contains('Acesso negado'));
      await SettingsService.instance.setTmdbApiKey('');
    });

    test('a URL de verificação é a esperada (id fixo, pt-BR, api_key)',
        () async {
      SettingsService.instance.setTmdbApiKey(key);
      Uri? seen;
      TmdbService.httpOverride = MockClient((req) async {
        seen = req.url;
        return http.Response(jsonEncode({'id': 550}), 200);
      });
      await TmdbService.verifyKey();
      expect(seen, isNotNull);
      expect(seen!.path, '/3/movie/550');
      expect(seen!.queryParameters['api_key'], key);
      expect(seen!.queryParameters['language'], 'pt-BR');
      await SettingsService.instance.setTmdbApiKey('');
    });
  });
}

class _Boom implements Exception {
  _Boom();
}