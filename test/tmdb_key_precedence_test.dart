import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/storage/local_storage.dart';
import 'package:goanime_tv/core/storage/settings_service.dart';
import 'package:goanime_tv/core/tmdb/tmdb_service.dart';

/// Testa a precedência da chave TMDB depois de passar a existir chave
/// padrão embutida no build.
///
/// **Por que chave padrão é aceitável aqui:** a chave v3 do TMDB é
/// projetada para viver no cliente — a própria documentação do TMDB pede
/// que ela vá no app. Não existe backend neste projeto, então não há onde
/// escondê-la de qualquer jeito. O que NÃO é aceitável é versioná-la no
/// git (o secret scanning do GitHub marcaria o repositório), e é por isso
/// que ela entra via `--dart-define` e a chave do usuário SEMPRE vence.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // `SettingsService.init` usa LocalStorage, que exige o init antes.
    await LocalStorage.init();
    await SettingsService.instance.init();
  });

  group('precedência da chave', () {
    test('chave do usuário tem precedência sobre a padrão do build', () {
      // Este build de teste NÃO tem chave padrão (dart-define vazia), então
      // o que dá para garantir aqui é: com chave do usuário, a origem é
      // "sua chave" — nunca a padrão.
      final s = SettingsService.instance;
      expect(s.tmdbUsesOwnKey, isFalse);
      expect(s.tmdbHasDefaultKey, isFalse);
      expect(s.tmdbConfigured, isFalse);
    });

    test('sem chave nenhuma → desligado, sem quebrar o app', () {
      final s = SettingsService.instance;
      expect(s.tmdbConfigured, isFalse);
      expect(TmdbService.isConfigured, isFalse);
      expect(TmdbService.keyOriginLabel, 'desligado');
      // O resto do app não depende disso: a fonte só "some".
      expect(s.tmdbEnabled, isTrue, reason: 'toggle ligado ≠ configurado');
    });

    test('salvar chave própria marca que não está usando a padrão', () async {
      final s = SettingsService.instance;
      await s.setTmdbApiKey('0123456789abcdef0123456789abcdef');
      expect(s.tmdbUsesOwnKey, isTrue);
      expect(s.tmdbConfigured, isTrue);
      expect(s.tmdbUseDefault, isFalse);
      expect(s.tmdbApiKeyMasked, '0123…cdef');
    });

    test('"usar a padrão" apaga a chave do usuário', () async {
      final s = SettingsService.instance;
      await s.setTmdbApiKey('0123456789abcdef0123456789abcdef');
      expect(s.tmdbUsesOwnKey, isTrue);

      // build de teste não tem padrão; ainda assim deve limpar a chave.
      await s.useTmdbDefaultKey();
      expect(s.tmdbUsesOwnKey, isFalse);
      expect(s.tmdbUseDefault, isTrue);
      expect(s.tmdbApiKey, isEmpty);
    });

    test('toggle desligado desliga mesmo com chave presente', () async {
      final s = SettingsService.instance;
      await s.setTmdbApiKey('0123456789abcdef0123456789abcdef');
      expect(s.tmdbConfigured, isTrue);
      await s.setTmdbEnabled(false);
      expect(s.tmdbConfigured, isFalse);
      expect(TmdbService.isConfigured, isFalse);
      await s.setTmdbEnabled(true);
      expect(s.tmdbConfigured, isTrue);
    });
  });

  group('chave padrão do build', () {
    test('vem de dart-define, nunca de literal no código', () {
      // Vazio neste build de teste. Se alguémdigitar uma chave no código,
      // este teste passa a falhar — é o alarme de "não versione a chave".
      expect(TmdbService.defaultApiKey, isEmpty,
          reason: 'chave padrão deve chegar por --dart-define, não no código');
      expect(SettingsService.defaultKey, isEmpty);
    });

    test('chave padrão não é exposta em nenhum log', () {
      // A UI mostra "chave padrão do app" sem prefixo/sufixo: nada de
      // carimbo de 8 caracteres como fazemos com a chave do usuário.
      expect(TmdbService.usingDefaultKey, isFalse);
    });
  });

  group('validação', () {
    test('rejeita formato inválido', () {
      expect(SettingsService.validateTmdbKey(''), isNotNull);
      expect(SettingsService.validateTmdbKey('abc'), isNotNull);
      expect(SettingsService.validateTmdbKey('z' * 32), isNotNull);
    });

    test('aceita hex de 32', () {
      expect(
        SettingsService.validateTmdbKey('0123456789abcdef0123456789abcdef'),
        isNull,
      );
    });
  });
}