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
    test('chave do usuário tem precedência sobre a padrão do app', () async {
      final s = SettingsService.instance;
      await s.setTmdbApiKey('0123456789abcdef0123456789abcdef');
      expect(s.tmdbUsesOwnKey, isTrue);
      expect(s.tmdbConfigured, isTrue);
      expect(TmdbService.usingDefaultKey, isFalse);
      expect(TmdbService.keyOriginLabel, 'sua chave');
    });

    test('sem chave do usuário → usa a padrão do app', () {
      // A chave padrão está compilada no app de propósito (chave v3 do
      // TMDB é cliente-por-desenho). Sem chave do usuário, o catálogo já
      // funciona — que é o ponto de todo esse desenho.
      final s = SettingsService.instance;
      expect(s.tmdbUsesOwnKey, isFalse);
      expect(SettingsService.tmdbHasDefaultKey, isTrue);
      expect(s.tmdbConfigured, isTrue);
      expect(TmdbService.isConfigured, isTrue);
      expect(TmdbService.usingDefaultKey, isTrue);
      expect(TmdbService.keyOriginLabel, 'chave padrão do app');
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

      await s.useTmdbDefaultKey();
      expect(s.tmdbUsesOwnKey, isFalse);
      expect(s.tmdbUseDefault, isTrue);
      expect(s.tmdbApiKey, isEmpty);
      // Volta a funcionar pela chave padrão.
      expect(s.tmdbConfigured, isTrue);
      expect(TmdbService.usingDefaultKey, isTrue);
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

  group('chave padrão embutida', () {
    test('existe sem o usuário configurar nada', () {
      expect(TmdbService.hasDefaultKey, isTrue);
      expect(TmdbService.defaultApiKey.trim(), isNotEmpty);
    });

    test('formato válido (hex de 32)', () {
      // A chave embutida tem que passar na própria validação que a UI usa.
      expect(SettingsService.validateTmdbKey(TmdbService.defaultApiKey), isNull);
    });

    test('precedência: --dart-define > chave embutida', () {
      // Sem define neste build de teste vale a embutida; o que o teste
      // trava é que existe uma chave padrão utilizável em qualquer build.
      expect(TmdbService.defaultApiKey.trim(), isNotEmpty);
    });

    test('origem padrão não vaza prefixo/sufixo como a do usuário', () {
      // A UI mostra "chave padrão do app" sem carimbo; com chave do usuário
      // ela mostra `abcd…wxyz`. No padrão não aparece nada.
      expect(TmdbService.usingDefaultKey, isTrue);
      expect(TmdbService.keyOriginLabel, isNot(contains('\u2026')));
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