import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Camada de glossário para o MT: antes de traduzir, termos cadastrados viram
/// placeholders `[T1]`, `[T2]`...; depois da tradução, voltam ao termo alvo.
/// Serve para honoríficos, nomes próprios e jargão de anime saírem iguais (ou
/// com a forma que você escolher), sem o modelo "inventar".
///
/// Arquivo editável: `<appSupport>/glossary.txt`, uma linha por termo no
/// formato `origem => destino`. Destino vazio = mantém a origem (não traduz).
/// Linhas começando com `#` são comentários. O arquivo é criado com um
/// template na primeira execução.
class Glossary {
  /// Pares (origem, destino) na ordem do arquivo.
  final List<MapEntry<String, String>> entries;

  const Glossary(this.entries);

  static const _fileName = 'glossary.txt';

  /// Template criado quando o arquivo não existe. Honoríficos JA + termos que
  /// costumam ficar como estão. Edite à vontade (recarregado a cada job).
  static const defaultText = '''
# Glossário GoAnime TV - "origem => destino"
# - destino vazio  = mantém a origem sem traduzir (ex.: nomes próprios)
# - destino cheio  = força aquele termo na legenda (ex.: honorífico romanizado)
# Recarregado a cada geração de legenda. Linhas com # são ignoradas.
# Honoríficos curtos (さん/ちゃん/くん/君/様) só valem como SUFIXO de nome
# (kanji/katakana antes); evita estragar palavras como "おじさん"/"ちゃんと".

# Honoríficos japoneses (saem romanizados, como se espera em legenda PT)
さん => -san
ちゃん => -chan
くん => -kun
君 => -kun
様 => -sama
先生 => -sensei
先輩 => -senpai
せんぱい => -senpai
後輩 => -kouhai
お姉ちゃん => onee-chan
お兄ちゃん => onii-chan
兄貴 => aniki
姉貴 => aneki
神様 => kami-sama

# Termos de anime/jargão (mantidos ou romanizados)
妖怪 => youkai
式神 => shikigami
鬼 => oni
侍 => samurai
忍者 => ninja
刀 => katana
巫女 => miko
結界 => kekkai
''';

  static Future<Glossary> load({Directory? dirForTest}) async {
    final base = dirForTest ?? await getApplicationSupportDirectory();
    final f = File('${base.path}/$_fileName');
    try {
      if (!await f.exists()) {
        await f.parent.create(recursive: true);
        await f.writeAsString(defaultText);
      }
      return Glossary.parse(await f.readAsString());
    } catch (_) {
      return Glossary.parse(defaultText); // arquivo ilegível: usa o default
    }
  }

  /// Parser tolerante: ignora comentários/linhas vazias; aceita `=>`, `->` ou
  /// `=`. Mantém a ordem (termos longos são aplicados primeiro no protect).
  static Glossary parse(String text) {
    final out = <MapEntry<String, String>>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final m = RegExp(r'^(.+?)\s*(?:=>|->|=)\s*(.*)$').firstMatch(line);
      if (m == null) continue;
      final src = m.group(1)!.trim();
      final dst = m.group(2)!.trim();
      if (src.isEmpty) continue;
      out.add(MapEntry(src, dst.isEmpty ? src : dst));
    }
    return Glossary(out);
  }

  /// Honoríficos curtos que só fazem sentido como sufixo de nome. Sem isto,
  /// `replaceAll` casa dentro de palavras comuns: `おじさん`→`おじ[T1]`,
  /// `ちゃんと`→`[T1]と`, `ばあさん`→`ばあ[T1]`.
  static const _suffixHonorifics = {'さん', 'ちゃん', 'くん', '君', '様'};

  /// Regex que casa `host + honorífico`, capturando o host no grupo 1.
  ///
  /// O host é um nome em kanji ou katakana imediatamente antes do honorífico.
  /// Hiragana é propositalmente excluído: é o que distingue `おじさん`/`ばあさん`
  /// de um sufixo real (`レキさん`, `ラッカちゃん`). Também exclui `お`/`ご` antes
  /// do nome (`お客様`, `お父さん` não são honorífico de nome próprio).
  static RegExp? _suffixRegex(String key) {
    if (!_suffixHonorifics.contains(key)) return null;
    return RegExp('(?<![おご])([\u4e00-\u9fff\u30a0-\u30ff])'
        '${RegExp.escape(key)}');
  }

  /// Troca os termos por placeholders. Retorna o texto protegido + o mapa
  /// placeholder→destino. Termos mais longos primeiro (evita sobreposição).
  Protected protect(String text) {
    final used = <int, String>{};
    var result = text;
    final byLen = [...entries]..sort((a, b) => b.key.length - a.key.length);
    var idx = 0;
    for (final e in byLen) {
      if (!result.contains(e.key)) continue;
      final ph = '[T${++idx}]';
      used[idx] = e.value;
      final re = _suffixRegex(e.key);
      if (re != null) {
        // Só substitui o honorífico, preservando o nome que vem antes.
        result = result.replaceAllMapped(re, (m) => '${m.group(1)}$ph');
      } else {
        result = result.replaceAll(e.key, ph);
      }
    }
    return Protected(result, used);
  }

  /// Volta os placeholders ao destino. Tolerante à forma que o modelo devolve:
  /// `[T1]`, `[T 1]`, `【T1】`, `[T1`, `T1]` ou até `T1` solto (colchetes são
  /// raspados com frequência). Placeholder inventado pelo modelo (índice que
  /// não estava no [Protected.used]) é descartado em vez de vazar "T3".
  String restore(String text, Protected p) {
    return text.replaceAllMapped(_phRe, (m) {
      final raw = m.group(1) ?? m.group(2) ?? m.group(3);
      final i = int.tryParse(raw ?? '');
      return (i != null && p.used.containsKey(i)) ? p.used[i]! : '';
    });
  }

  /// Formas aceitas, na ordem: com colchete de abertura, só com fechamento, ou
  /// placeholder nu (sem colchetes). O nu exige fronteira `\w` para não raspar
  /// "T1" no meio de uma palavra. O número cai em grupo 1, 2 ou 3.
  static final _phRe = RegExp(r'[\[【〖]\s*T\s*(\d+)\s*[\]】〗]?'
      r'|T\s*(\d+)\s*[\]】〗]'
      r'|(?<![\w])T\s*(\d+)(?![\w])');
}

/// Texto protegido + mapa placeholder→destino (ver [Glossary.protect]).
class Protected {
  final String text;
  final Map<int, String> used;
  const Protected(this.text, this.used);
}
