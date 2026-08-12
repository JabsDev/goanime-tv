import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/updater/version_compare.dart';

void main() {
  group('compareAppVersions (chave = build number)', () {
    test('tag igual ao instalado → 0 (sem update)', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v1.0.0+1000000',
      ), 0);
    });

    test('build maior → atualiza', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v1.0.1+1000001',
      ), greaterThan(0));
    });

    test('build menor mesmo com semver maior → NÃO atualiza (chave é build)',
        () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v1.2.0+999999',
      ), lessThan(0));
    });

    test('mesmo build, semver maior → NÃO atualiza (decisão de design)', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v2.0.0+1000000',
      ), 0);
    });
  });

  group('fallback semver (tag sem +N)', () {
    test('semver maior → atualiza', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v1.1.0',
      ), greaterThan(0));
    });

    test('semver igual → não atualiza', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v1.0.0',
      ), 0);
    });

    test('semver menor → não atualiza', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v0.9.1',
      ), lessThan(0));
    });

    test('patch ausente vira 0 (v1.2 → 1.2.0)', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.2.0',
        tagName: 'v1.2',
      ), 0);
    });
  });

  group('malformadas (nunca lançam)', () {
    test('tag não numérica → 0', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'zzz',
      ), 0);
    });

    test('tag vazia → 0', () {
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: '',
      ), 0);
    });

    test('build não numérico cai no semver', () {
      // "v1.0.0+a": build inválido → semver 1.0.0 → igual
      expect(compareAppVersions(
        installedBuild: 1000000,
        installedVersion: '1.0.0',
        tagName: 'v1.0.0+a',
      ), 0);
    });
  });

  group('parseBuildNumber / versionLabelFromTag', () {
    test('extrai +N', () {
      expect(parseBuildNumber('v1.0.1+1000001'), 1000001);
      expect(parseBuildNumber('v1.2.0+999999'), 999999);
    });

    test('sem +N → null', () {
      expect(parseBuildNumber('v1.0.1'), isNull);
      expect(parseBuildNumber('xyz'), isNull);
      expect(parseBuildNumber('v1.0.1+'), isNull);
    });

    test('label do diálogo sem o prefixo v', () {
      expect(versionLabelFromTag('v1.0.1+1000001'), '1.0.1');
      expect(versionLabelFromTag('v1.1.0'), '1.1.0');
    });
  });
}