import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:goanime_tv/core/profile/profile_store.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String docs;
  _FakePathProvider(this.docs);
  @override
  Future<String?> getApplicationDocumentsPath() async => docs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('profile_data_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
  });

  tearDown(() async {
    ProfileStore.instance.resetForTest();
    await tmp.delete(recursive: true);
  });

  File profileFile() {
    final id = ProfileStore.instance.currentProfile!.id;
    return File('${tmp.path}/profiles/$id/favorites.json');
  }

  test('escrita atômica: gera .bak da versão anterior', () async {
    final p = ProfileStore.instance.createLocalProfile('A');
    await ProfileStore.instance.switchProfile(p.id);

    await ProfileStore.instance.setFavorites([
      {'key': 'one piece', 'title': 'One Piece'}
    ]);
    expect(profileFile().existsSync(), isTrue);
    expect(File('${profileFile().path}.bak').existsSync(), isFalse);

    await ProfileStore.instance.setFavorites([
      {'key': 'dragon ball', 'title': 'Dragon Ball'},
      {'key': 'one piece', 'title': 'One Piece'},
    ]);
    final bak = File('${profileFile().path}.bak');
    expect(bak.existsSync(), isTrue);
    final bakList =
        (jsonDecode(bak.readAsStringSync()) as List).cast<Map<String, dynamic>>();
    expect(bakList.single['key'], 'one piece');
  });

  test('I-4: arquivo ilegível com .bak íntegro → lê do .bak, preserva o arquivo',
      () async {
    final p = ProfileStore.instance.createLocalProfile('A');
    await ProfileStore.instance.switchProfile(p.id);
    await ProfileStore.instance.setFavorites([
      {'key': 'naruto', 'title': 'Naruto'}
    ]);
    final f = profileFile();
    final g = File('${f.path}.bak');
    g.writeAsStringSync('{"não é lista": true}'); // bak inválido também
    f.writeAsStringSync('{truncado!!!');

    // reinicia o store (recarrega do disco)
    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
    expect(ProfileStore.instance.getFavorites(), isEmpty);
    // arquivo ilegível preservado (não sobrescrito)
    expect(f.readAsStringSync(), '{truncado!!!');
  });

  test('I-4: .bak válido recupera dados após corrupção do principal', () async {
    final p = ProfileStore.instance.createLocalProfile('A');
    await ProfileStore.instance.switchProfile(p.id);
    await ProfileStore.instance.setFavorites([
      {'key': 'jujutsu', 'title': 'Jujutsu Kaisen'}
    ]);
    final f = profileFile();
    // backup da versão boa em .bak
    File('${f.path}.bak').writeAsStringSync(f.readAsStringSync());
    f.writeAsStringSync('{"x": [}');

    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
    final favs = ProfileStore.instance.getFavorites();
    expect(favs.single['key'], 'jujutsu');
  });

  test('schema legado (sem o campo) é lido — migração compatível', () async {
    final p = ProfileStore.instance.createLocalProfile('A');
    // regrava profile.json no formato antigo (sem schema)
    final pf = File('${tmp.path}/profiles/${p.id}/profile.json');
    final json = jsonDecode(pf.readAsStringSync()) as Map<String, dynamic>;
    json.remove('schema');
    pf.writeAsStringSync(jsonEncode(json));

    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
    expect(ProfileStore.instance.currentProfile?.displayName, 'A');
    expect(ProfileStore.instance.profiles, hasLength(1));
  });

  test('flush() grava todos os arquivos do perfil atual em disco', () async {
    final p = ProfileStore.instance.createLocalProfile('A');
    await ProfileStore.instance.switchProfile(p.id);
    await ProfileStore.instance.setHistory([
      {'key': 'h', 'title': 'Hist'}
    ]);
    await ProfileStore.instance.setProgress('chave', {
      'episode': 5,
      'position': 1000,
    });

    final dir = Directory('${tmp.path}/profiles/${p.id}');
    // confere que os arquivos existem após flush
    await ProfileStore.instance.flush();
    for (final name in ['profile.json', 'history.json', 'favorites.json', 'progress.json']) {
      expect(File('${dir.path}/$name').existsSync(), isTrue, reason: name);
    }

    // relê de um store novo
    ProfileStore.instance.resetForTest();
    await ProfileStore.instance.init();
    final pr = ProfileStore.instance.getProgress('chave');
    expect(pr?['episode'], 5);
    expect(ProfileStore.instance.getHistory().single['key'], 'h');
  });
}