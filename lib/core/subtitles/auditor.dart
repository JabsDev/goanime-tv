import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audit_engine.dart';
import 'model_manager.dart';
import 'srt_parser.dart';

/// Auditor de legenda: Modelo LLM leve (llama.cpp nativo) e um MODELO
/// DIFERENTE do tradutor (o tradutor concorda consigo mesmo; auditor é o
/// segundo par de olhos).
///
/// Dois passes, ambos obrigatórios no workflow:
///   - [auditJa] PRÉ-tradução: conserta a transcrição JA (partícula apagada,
///     kanji errado para a leitura, laço de STT) ANTES do tradutor — a
///     tradução amplifica o erro da fonte.
///   - [auditPt] PÓS-tradução: gate de porta (PT parece PT? sem resíduo
///     japonês? sem mojibake?) — é aqui que s detecta a falha silenciosa
///     (eufemização/recusa) que o espectador não nota.
///
/// Disciplina do prompt (o que desqualifica um auditor — medido em
/// audit_gate.py): reescrever estilo, inventar correção em linha certa.
/// Por isso: diferença mínima, "OK" para não mexer, temp 0.
abstract class AuditChannel {
  /// Prompt cru → resposta do modelo (llama.cpp nativo, GGUF do auditor).
  Future<String> generate(String modelPath, String prompt, int maxTokens);
  Future<void> dispose();
}

class MethodAuditChannel implements AuditChannel {
  static const _ch = MethodChannel('goanime_tv/llm');

  @override
  Future<String> generate(String modelPath, String prompt, int maxTokens) async {
    final out = await _ch.invokeMethod<String>('audit', {
      'modelPath': modelPath,
      'prompt': prompt,
      'maxTokens': maxTokens,
    });
    return out ?? '';
  }

  @override
  Future<void> dispose() => _ch.invokeMethod('dispose');
}

/// Provider de auditoria. Um modelo por vez (carga sequencial: sobe
/// [load], audita as cues todas, [dispose] antes do MT subir).
class AuditProvider implements AuditEngine {
  final String modelPath;
  final AuditChannel? channelForTest;
  AuditChannel? _ch;
  bool _loaded = false;

  AuditProvider(this.modelPath, {this.channelForTest});

  static const _sysJa = 'Você é verificador de transcrição de legenda em '
      'japonês. O texto vem de um STT e pode ter erros pequenos. Corrija '
      'APENAS: (1) partícula faltando ou errada; (2) kanji escrito errado '
      'para a leitura óbvia; (3) trecho duplicado/repetido (laço). NÃO '
      'reescreva o estilo, NÃO acrescente palavras além da correção mínima, '
      'NÃO explique. Responda SOMENTE o texto corrigido. Se estiver correto, '
      'responda exatamente: OK';

  static const _sysPt = 'Você revisa legendas em português do Brasil '
      'traduzidas de japonês. Cheque APENAS: (1) a linha é portuguesa '
      '(sem resíduo japonês/mojibake)? (2) no máximo 2 linhas curtas? '
      'NÃO melhore o texto, NÃO reescreva, NÃO explique. Se a linha está '
      'correta, responda exatamente: OK. Senão, responda só a correção.';

  String _prompt(String line, String sys) => '$sys\n\nlinha: $line';

  Future<void> load() async {
    final f = File(modelPath);
    if (await f.exists()) {
      final spec = aiModelCatalog[f.parent.path.split('/').last];
      if (spec != null &&
          !await ModelManager.isValidGguf(f, spec.mb)) {
        throw StateError('LLM_CORRUPT: $modelPath');
      }
    }
    _ch = channelForTest ?? MethodAuditChannel();
    _loaded = true;
  }

  Future<String> _ask(String line, String sys, int max) async {
    if (!_loaded) throw StateError('AuditProvider.load() antes');
    var rep = '';
    try {
      rep = await _ch!.generate(modelPath, _prompt(line, sys), max);
    } catch (e) {
      debugPrint('[Audit] falhou na linha: $e');
      return line; // linha pode pior? NÃO: devolve a original.
    }
    rep = rep.trim();
    if (rep.isEmpty || rep.toUpperCase() == 'OK' || rep == line.trim()) {
      return line;
    }
    return rep;
  }

  /// PRÉ: conserta as cues JA (fonte do MT).
  Future<List<SrtCue>> auditJa(List<SrtCue> cues,
      {bool Function()? isCancelled}) async {
    final out = <SrtCue>[];
    for (var i = 0; i < cues.length; i++) {
      if (isCancelled?.call() ?? false) return cues;
      final t = await _ask(cues[i].text, _sysJa, 200);
      out.add(cues[i].withText(t));
    }
    return out;
  }

  /// PÓS: gate de porta em PT (tradução).
  Future<List<SrtCue>> auditPt(List<SrtCue> cues,
      {bool Function()? isCancelled}) async {
    final out = <SrtCue>[];
    for (var i = 0; i < cues.length; i++) {
      if (isCancelled?.call() ?? false) return cues;
      final t = await _ask(cues[i].text.replaceAll('\n', ' '), _sysPt, 160);
      out.add(cues[i].withText(t));
    }
    return out;
  }

  Future<void> dispose() async {
    await _ch?.dispose();
    _ch = _ch == null ? null : null;
    _loaded = false;
  }
}
