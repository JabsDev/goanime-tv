import 'package:flutter_test/flutter_test.dart';
import 'package:goanime_tv/core/subtitles/glossary.dart';

void main() {
  test('parse ignora comentários e destino vazio mantém a origem', () {
    final g = Glossary.parse('''
# comentário
さん => -san
レキ =>
''');
    expect(g.entries.length, 2);
    expect(g.entries[0].key, 'さん');
    expect(g.entries[0].value, '-san');
    expect(g.entries[1].value, 'レキ'); // vazio -> não traduz
  });

  test('protect tira os termos e restore devolve o destino', () {
    final g = Glossary.parse('さん => -san\n先輩 => -senpai\n');
    final p = g.protect('レキさんと先輩');
    expect(p.text.contains('さん'), isFalse);
    expect(p.text.contains('先輩'), isFalse);
    // simula o modelo trocando o "と"
    final translated = p.text.replaceAll('と', ' e ');
    expect(g.restore(translated, p), 'レキ-san e -senpai');
  });

  test('restore tolera espaços no placeholder', () {
    final g = Glossary.parse('さん => -san\n');
    final p = g.protect('レキさん');
    expect(g.restore('[T 1]', p), '-san');
  });

  test('termo longo tem prioridade', () {
    final g = Glossary.parse('さん => -san\nお姉ちゃん => onee-chan\n');
    final p = g.protect('お姉ちゃんとレキさん');
    expect(g.restore(p.text.replaceAll('と', ' e '), p),
        'onee-chan e レキ-san');
  });

  test('honorífico só vale como sufixo de nome (não estraga palavras)', () {
    final g = Glossary.parse('さん => -san\nちゃん => -chan\nくん => -kun\n');
    // palavras comuns com さん/ちゃん/くん dentro NÃO devem ser tocadas
    final p = g.protect('おじさんとばあさんとちゃんと');
    expect(p.text, 'おじさんとばあさんとちゃんと');
    expect(g.restore(p.text, p), 'おじさんとばあさんとちゃんと');
    // sufixo real em katakana/kanji é preservado com o nome
    final q = g.protect('レキさんとラッカちゃんとリュウくん');
    expect(g.restore(q.text, q), 'レキ-sanとラッカ-chanとリュウ-kun');
  });

  test('não troca お/ご antes do nome (お客様, お父さん)', () {
    final g = Glossary.parse('様 => -sama\nさん => -san\n');
    final p = g.protect('お客様とお父さん');
    expect(g.restore(p.text, p), 'お客様とお父さん');
  });

  test('restore aceita placeholder sem colchetes (modelo raspa)', () {
    final g = Glossary.parse('さん => -san\n');
    final p = g.protect('レキさん');
    expect(g.restore('レキT1', p), 'レキ-san');
    expect(g.restore('レキT 1', p), 'レキ-san');
    expect(g.restore('レキ[ T1 ]', p), 'レキ-san');
    expect(g.restore('レキ【T1】', p), 'レキ-san');
  });

  test('placeholder inventado pelo modelo é descartado (não vaza T#)', () {
    final g = Glossary.parse('さん => -san\n');
    final p = g.protect('レキさん');
    final out = g.restore('o T1 que tinha um T5 e um cachorro', p);
    expect(out.contains('T1'), isFalse);
    expect(out.contains('T5'), isFalse);
    expect(out, 'o -san que tinha um  e um cachorro');
  });
}
