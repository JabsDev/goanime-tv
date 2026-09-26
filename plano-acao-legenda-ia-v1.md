# Plano de Ação — Legenda IA v1: falas preservadas, sanity gate, card no picker

Data: 25/09/2026. Executor: agente de implantação (AI). Nenhum comportamento fora do escopo listado.
Base: `main` @ `80fd61f` ("tier mínima (Qwen), layout limpo, quants no nome, anti-lixo").
Fonte: `estudo-melhorias-legenda-ia-v1.md` (sintomas de QA + causas com file:line conferidas neste commit).

## 0. Como usar este plano

- Trabalhe na ordem dos PRs (§11-§12). Cada item é independente do anterior, salvo onde marcado.
- Após cada item: `flutter analyze` + `flutter test` (tudo verde) antes de considerar concluído.
- Sem dependências novas. Siga o estilo do repo: comentários PT-BR curtos explicando o "por quê",
  ganchos de teste com `@visibleForTesting` / `ForTest` (ex.: `SubtitleStore.setClockForTest`,
  `jobsDirForTest`), fakes em vez de nativo (padrão: `test/subtitle_job_test.dart`).
- Referências `file:line` valem para o commit `80fd61f`; se houver drift, localize pelo símbolo citado.
- Novos textos de UI em PT-BR, no tom existente ("falas", "Legenda pronta", "Baixar", "Tentar de novo").

### Validação de hipóteses ANTES do patch (1 rodada de logcat no aparelho)

Duas causas do estudo são hipóteses (§2.1 e §2.5 do estudo) e exigem evidência antes do código nativo:

1. **H1 — VAD nunca ativa (bug de caminho).** Checar com o item 2 instalado (o log é parte do patch):
   `adb logcat | grep SherpaStt` durante um job de transcrição com "VAD silero" instalado.
   - `VAD: false` com VAD instalado = bug confirmado → aplicar o item 2 na íntegra.
   - `VAD: true` = caminho já resolve → item 2 vira só teste de regressão.
2. **H2 — Qwen3-0.6B "thinking" come o teto de 128 tokens.** Com tier `minima` ativo, transcrever
   ~10 cues curtas e contar os logs `[LlmMt]` (introduzidos pelo item 3). Se ≥4 cues simples saírem
   vazias → confirmado → aplicar 6.x. LFM2.5 (`leve`) usa o mesmo prompt ChatML — observar também;
   o gate 5/6 do catálogo sugere que funciona.

Sem aparelho: implemente os itens P0 (2, 3, 4) + testes; os nativos (6.x) ficam bloqueados até a validação.

## 1. Sintomas-alvo

| Hoje (QA) | Alvo |
|---|---|
| Legenda final vazia ou com frases esporádicas | Cue preservada com texto reserva quando a tradução falha |
| "Legenda pronta" com 0 cues | Falha alta acionável, ou aviso "poucas falas: X/Y" |
| Tela full-screen poluída p/ escolher modelos | Card de 2 linhas (Voz/Tradução) dentro do picker |
| "Cancelar" não interrompe a transcrição | Encerra na fronteira da fatia de 60 s |

## 2. Item 1 — VAD: caminho do modelo (P0, ~meio dia)

**Problema.** O download do VAD grava em `models/silero-vad/vad.onnx`
(`lib/core/subtitles/model_manager.dart:74-80`), mas o engine procura `$modelDir/vad.onnx`
DENTRO da pasta do modelo STT (`lib/core/subtitles/sherpa_stt.dart:52`, ex.:
`models/whisper-tiny-ja/vad.onnx`). O VAD baixado nunca é usado. Sem VAD caem janelas
fixas de 30 s (`sherpa_stt.dart:326-336`): fala cortada na fronteira, alucinação com
música/efeito (filtrada depois), falas perdidas.

**Mudança.**

1. Em `sherpa_stt.dart`, método estático best-effort:

```dart
/// Copia `models/silero-vad/vad.onnx` para dentro da pasta do modelo STT
/// (o download grava em silero-vad/, o engine procura na pasta do modelo
/// de voz — caminhos divergentes, estudo §2.1). Best-effort: falha =
/// janelas fixas de 30 s. `rootForTest` para teste.
/// Retorna true se `$modelDir/vad.onnx` existir ao final.
static Future<bool> ensureVadInModelDir(String modelDir, {Directory? rootForTest})
```

   Lógica: se `File('$modelDir/vad.onnx')` existe → true. Senão procurar
   `$(root)/silero-vad/vad.onnx` (root = `rootForTest` ?? `const ModelManager().modelsDir()`).
   Se existir: `File.copy` para `$modelDir/vad.onnx.tmp` + `rename` (cópia atômica). Qualquer
   exceção → false (nunca falhar o job por causa do VAD; o fallback já é seguro).
2. `SherpaSttEngine.init` (linha ~52), antes do `_hasVad`:

```dart
_hasVad = await ensureVadInModelDir(modelDir);
debugPrint('[SherpaStt] VAD: $_hasVad ($modelDir)');
```

   (Este log é a evidência de H1 no aparelho — mantê-lo permanente.)
   `sherpa_stt.dart` passa a importar `model_manager.dart` (mesmo pacote `core/subtitles`, sem ciclo).

**Testes** (novo `test/vad_path_test.dart`): dir temp com
`whisper-tiny-ja/{encoder.int8.onnx,decoder.int8.onnx,tokens.txt}` e `silero-vad/vad.onnx` (bytes dummy):
- cópia cria o arquivo na pasta do STT e retorna true;
- idempotente (chamar 2×, arquivo intacto);
- sem VAD na raiz → false, sem exceção, nada criado;
- (regressão 2.1) após `ensureVadInModelDir`, o path `$modelDir/vad.onnx` passa no mesmo teste de
  existência que o `SherpaSttEngine.init` usa.

**Aceite:** com VAD instalado, log `VAD: true`; transcrição segmenta por fala (sem janelas fixas de 30 s).

## 3. Item 2 — Cue não some: fallback à fonte + retry por peça (P0, ~2 dias)

**Problema (3 causas compostas).**

- `subtitle_job_manager.dart:378` (`_runTranslate`) e `:482` (`_runTranscribe`):
  `if (t.trim().isNotEmpty) out.add(...)` — toda cue com tradução vazia é descartada, sem
  aviso nem contagem.
- `llm_mt.dart:153-165`: peças `isJunk` nem vão ao modelo; `isDegenerate` zera a peça; se
  TODAS as peças saírem → `translate()` retorna `''` → cue descartada.
- `llm_mt.dart:156-162`: timeout numa peça lança `StateError` que sobe até `_run` e **mata o
  job inteiro** — perde ~15 min de transcrição por 1 frase.

**Política (estudo §2.2): "cue não se descarta, se marca."**

1. **`LlmMtProvider.translate` (llm_mt.dart:144-166) — retry 1× e timeout não-propagado.**
   Extrair o corpo do loop para `_translatePiece(String p)`:
   - chamar o canal com `.timeout(translateTimeout)`;
   - em timeout OU qualquer exceção do canal: 1 retry imediato;
   - persistindo: retornar `''` (peça falha ≠ exceção propagada);
   - `debugPrint('[LlmMt] peça falhou (retry tb) — cue terá fallback')` na falha dupla.
   - `translate()` continua lançando apenas erros de estado (`load()` antes) e par inválido.
2. **Resolução da cue — helper único no `SubtitleJobManager`, usado pelas 2 rotas:**

```dart
/// Política anti-perda (estudo §2.2): tradução vazia/degenerada NÃO descarta
/// a cue — fallback ao texto fonte quando a fonte tem conteúdo
/// (LlmMtProvider.isJunk == false); fonte-lixo puro descarta (junk).
/// Retorna (out, traduzidas, total) p/ o sanity gate do item 4.
static (List<SrtCue>, int, int) _resolveCues(List<SrtCue> src, List<String> translations)
```

   Os dois loops de tradução passam a acumular `translations` (sem filtro no momento) e chamam
   `_resolveCues` no fim. `out.add(cues[i].withText(t))` condicional some dos dois lugares.
3. **Defesa em profundidade no job:** envolver cada `mt.translate(...)` das rotas em
   `try/catch → translations[i] = ''` (erro residual do provider nunca mais propaga ao job).
4. **Diagnóstico:** `debugPrint('[SubtitleJob] falas traduzidas X/Y')` antes do `_finish`.

**Manter:** `isJunk`/`isDegenerate`/`pieces` como estão (cobertura em `test/llm_mt_test.dart`);
o `continue` do lado STT (`sherpa_stt.dart:415`, decode vazio = não-cue = sem timestamp falso);
tempos e pós-processo.

**Testes:**
- `test/subtitle_job_test.dart` (base do fake `_PrefixMt`):
  1. `tradução vazia preserva a cue com o texto fonte`: fake MT que retorna `''` para 1 texto-alvo
     e traduz o resto → cue 1 com o texto fonte, cue 2 traduzida; X=1, Y=2.
  2. `fonte-lixo puro é descartado`: src com só `'!!!'` (sem letra) → não vira cue.
  3. `erro do MT não mata o job`: fake MT lança `StateError` em 1 cue → job termina `done`, 1 cue
     com fallback.
- `test/llm_mt_test.dart`:
  4. `timeout na peça: retry 1× e usa a resposta do retry` (fake channel falha 1ª chamada, responde 2ª).
  5. `timeout duplo: peça vira '' sem exceção` (fake channel falha sempre) — cobre o "não propaga".

**Aceite:** job sob falha de 1 peça termina com legenda X/Y visível, nunca abortado na fase Traduzindo.

## 4. Item 3 — Sanity gate: "legenda com 0 cues não termina done" (P0, ~1 dia)

**Problema.** `_finish` (subtitle_job_manager.dart:351-365) grava `SrtParser.format([])` e anuncia
"Legenda pronta"; o `.srt` vazio é cacheado como `ja-ai`/`en-ai` por 5 dias e o player não mostra nada.

**Mudança (nas 2 rotas, antes de `_finish`):** gate mínimo honesto:

```dart
// fim de _runTranslate e _runTranscribe (out, translated, total) do item 2:
if (!_gateCues(job, translated, total)) return; // falhou alto, nada salvo
// senão _finish(..., yieldLabel: 'X de Y') — done com rótulo de escassez
```

Lógica do `_gateCues`:
- `out.isEmpty` (cobre `total == 0`, fonte vazia, 100% lixo/falha):
  `throw StateError('0 falas traduzidas — troque o modelo de voz (tiny→sensevoice/base) e tente de novo.')`
  → job **falha** e NÃO grava `.srt`.
- `translated/total < 30 %`: grava normal, `_finish` recebe `yieldLabel` e o estado `done` passa a
  `message: 'Legenda pronta — gerada com poucas falas: X de Y'`.
- demais: `message: 'Legenda pronta (+X de Y falas)'`.
- `friendlyError` (subtitle_job_manager.dart:151-214): nova entrada
  `if (s.contains('0 falas traduzidas')) return s;` (mensagem já é acionável; sem stack).
- O job file/breadcrumb não muda (a falha acontece na fase `translating`; `_phaseLabel` intocado).

**Testes (`test/subtitle_job_test.dart`):**
1. `0 cues não termina done`: fonte toda lixo (fake MT traduz tudo mas `isJunk` elimina as cues)
   ou fonte vazia (`srcSrt: ''`) → fase `failed` com `0 falas` no erro e NADA em `SubtitleStore.get`.
2. `<30 % grava e avisa`: 2 de 10 traduzidas → `done`, message contém `poucas falas: 2 de 10`.
3. `≥30 % grava sem aviso`: 8 de 10 → message contém `8 de 10`, sem `poucas`.

**Aceite:** impossível terminar "Pronto" com 0 cues; aviso de poucas falas aparece no card/tela.

## 5. Item 4 — SenseVoice default em aparelho fraco + strongOnly (P0/P2, ~1 h)

**Problema.** `SettingsService.setSttModel` (`lib/core/storage/settings_service.dart:120-125`) só
aceita `'base'|'small'|'tiny'` — `'sensevoice'` é **descartado no setter** (persistência quebrada).
Nenhum lugar usa `DeviceCapability.isLowEnd()` (`lib/core/utils/device_capability.dart:16`) p/ gating,
embora `AiModelSpec.strongOnly` já exista (`model_manager.dart:17`, true só em `whisper-small:60`).

**Mudança.**
1. `setSttModel`: whitelist → `'tiny'|'base'|'small'|'sensevoice'` (inválido ⇒ `'tiny'`).
2. Default por aparelho: no load (onde `prefs.getString(_kSttModel)`), com preferência AUSENTE e
   `DeviceCapability.isLowEnd() == true` → default `'sensevoice'`; senão `'tiny'` (hoje).
   Hook de teste: `@visibleForTesting static bool? lowEndOverrideForTest;` lido pela chamada
   default (padrão `setClockForTest`). Isso executa o 2.3 do estudo ("sensevoice default no fraco")
   e alimenta o gating honesto.
3. `strongOnly` gating (estudo §2.3): linha `whisper-small` com `isLowEnd && !instalado` → visível
   mas com seleção/download desabilitados, texto `'só aparelho forte'` (aplica tanto no
   novo card (item 7) quanto nos radios de settings (item 8)).

**Testes (`test/settings_service_test.dart`):** setter aceita `sensevoice`; lixo cai para `tiny`;
default em low-end é `sensevoice` (com override) e `tiny` em aparelho forte.

**Aceite:** stick fraco pré-marca SenseVoice; `whisper-small` bloqueado com texto explicativo.

## 6. Item 5 — Qwen thinking: aparar `<tool_call>think>` (P1, ~meio dia, depende de H2)

**Problema.** Prompt ChatML user-only fixo em `LlmTranslator.kt:101-106` (validado contra Hy-MT2).
Tiers `minima` (Qwen3-0.6B) e `leve` (LFM2.5) usam o MESMO prompt com templates diferentes. Qwen3
abre modo *thinking* (`<tool_call>think>`); o raciocínio estoura o teto de 128 tokens (`goanime_llm.cpp`
`nativeGenerate`), a tradução real nunca sai → `''` → (antes do item 2) cue descartada.

**Medidas (1 e 2 baratos e independentes; 3 só se evidência):**
1. **Strip no C++ (preferido — robusto para qualquer template):** em
   `android/app/src/main/cpp/goanime_llm.cpp`, ANTES de `utf8_clean(out)` no retorno de
   `nativeGenerate`, remover blocos `<tool_call>think>...<tool_call>/think>`:
   - helper `static std::string strip_think(const std::string & s)`: enquanto existir `<tool_call>think>`,
     remover do `<think>` até `<tool_call>/think>` (ou até o fim, se não fechar — resposta truncada);
     aplicar antes do `utf8_clean`.
   - `__android_log_print(ANDROID_LOG_INFO, "GoAnimeLLM", ...)` apenas quando remover algo
     (evidência no logcat p/ H2).
2. **`/no_think` no prompt Qwen (Kotlin):** em `LlmTranslator.kt`,
   `val qwen = modelPath.contains("qwen", ignoreCase = true)` → sufixo `" /no_think "` no corpo
   user (antes de `<|im_end|>`). Risco zero para os demais (Hy-MT2/LFM não reagem).
3. **Não mexer** no cap 128 / n_ctx 1024 / KV Q8_0 (proteção de RAM documentada em
   goanime_llm.cpp) sem evidência adicional.

**Teste:** nativo fora do test-dart; validação = logcat (H2) + os contadores do item 2 (cues vazias).
Critério: tier `minima` gera ≤1 vazia em 10 cues simples, sem truncamento multibyte novo (o
`utf8_clean` e o teste existente de EP3 continuam passando).

## 7. Item 6 — Cancelamento por fatia do STT (P1, ~1 dia)

**Problema.** `cancelCurrent` (subtitle_job_manager.dart:525-530) só seta flag + `AudioExtract.cancel()`.
O flag é checado ENTRE cues/fases; dentro de `SherpaSttProvider.transcribe`
(`sherpa_stt.dart:391-432`) não há sinal — cada fatia de 60 s roda até o fim (até ~60 s de atraso).

**Mudança.**
1. `SttProvider.transcribe` (`lib/core/subtitles/mt_provider.dart:36-42`): novo parâmetro opcional
   `bool Function()? isCancelled` (default `null` = nunca cancela; assinatura compatível).
2. `SherpaSttProvider.transcribe`: checar `isCancelled?.call() ?? false` no início de cada fatia
   (e entre os decodes dos chunks da fatia) → retornar `cues` parciais SEM throw; o job manager vê
   `job.cancelled` logo depois e cai em `JobPhase.cancelled`.
3. `_runTranscribe`: passar `() => job.cancelled` ao `stt.transcribe`.
4. Tradução: já coberta pelo item 2 (peça falhada não mata; flag checada por cue no laço existente).
   Chamada nativa única do MT (até 10 min) por fatia fica fora (melhoria futura).

**Teste (`test/stt_l1_test.dart`):** pcm sintético de 3 fatias com fake engine lento: cancel
passa a true após a 1ª fatia → provider devolve cues da 1ª, sem erro e sem ler as demais.

**Aceite:** "Cancelar" durante "Transcrevendo…" encerra em ≤ ~1 fatia, sem recursos pendentes.

## 8. Item 7 — Card IA no picker + unificar linhas de modelos e mapas (P1, ~2 dias)

**Problema (estudo §3).**
- 3 componentes de linha quase iguais: `_ModeOption` (settings_screen.dart:902), `_ModelOptionRow`
  (ai_subtitle_screen.dart:538), `_ModelRow` (settings_screen.dart:373).
- 2 listas dessincronizadas: mapas à mão em `ai_subtitle_screen.dart:55-76` e radios à mão em
  `settings_screen.dart:198-310`, vs a fonte-of-truth privada `AiProviders._sttKinds`/_mtIds
  (ai_providers.dart:35-40, 61-66). Settings não lista sensevoice; lista `hymt-ja-pt-q3km`
  (907 MB) que nenhum tier mapeia mais (entrada morta — catálogo mantém p/ quem já baixou).
- MT em 1 linha que só cicla (ai_subtitle_screen.dart:313-327): sem status dos demais tiers,
  D-pad invisível; só o selecionado é baixável.
- Probe de disco por linha: `FutureBuilder(isReady())` em cada `_ModelOptionRow`/`_ModelRow`
  (ai_subtitle_screen.dart:559-561, settings_screen.dart:425) — IO a cada build.
- Tela full-screen (`detail_screen.dart:1800-1819` `Navigator.push` → `AiSubtitleScreen`) para
  decisão pequena; o picker é passo a passo (detail_screen.dart:1733-1762: Fonte → Áudio →
  Qualidade → Legenda).

**Mudanças.**

1. **Fonte única de verdade dos tiers (API mínima em `AiProviders`, ai_providers.dart):**

```dart
/// Mapa de tiers publicado (telas consomem, nunca copiam).
static const sttTierOrder = ['tiny', 'sensevoice', 'base', 'small'];
static const sttTiers = {
  'tiny':       (id: 'whisper-tiny-ja', task: 'translate',  kind: 'whisper'),
  'sensevoice': (id: 'sensevoice-ja',   task: 'transcribe', kind: 'sensevoice'),
  'base':       (id: 'whisper-base',    task: 'transcribe', kind: 'whisper'),
  'small':      (id: 'whisper-small',   task: 'transcribe', kind: 'whisper'),
};
static const mtTierOrder = ['minima', 'leve', 'media', 'completa'];
static const mtTiers = {
  'minima': 'qwen06-ja-pt-q4', 'leve': 'lfm12b-ja-pt-iq3m',
  'media': 'hymt-ja-pt-iq3m', 'completa': 'hymt-ja-pt-q4',
};
/// 1 único probe p/ todos os tiers (tela e card não re-probam por linha).
static Future<Map<String, bool>> readyMap(Iterable<String> ids)
```

   Refatorar `makeStt`/`makeMt`/`_ready` para usar esses mapas (comportamento idêntico).

2. **Widget único de linha** — novo `lib/features/ai_subtitle/ai_model_row.dart`:

```dart
/// Linha única de modelo: label do tier ativo + status ("instalado · N MB",
/// "faltando · N MB", "Baixando… %") + tap cicla o tier + botão Baixar do
/// tier ativo (barra inline). strongOnly bloqueia em low-end (item 4).
/// statuses = 1 Future único (readyMap) — NÃO FutureBuilder por linha.
class AiModelRow extends StatefulWidget { ... }
```

   Doc D-pad: tap = ciclar (toque único); baixar = botão focável; texto do subtitle inclui
   "só aparelho forte" quando strongBlocked.

3. **Card no picker** — novo `lib/features/ai_subtitle/ai_subtitle_card.dart` (converter a tela
   em widget reutilizável; o estado da tela é portado quase integral):

   - Props: `anime`, `episode`, `sources` (visíveis), `provider`, `episodeIndex`, `episodeList`.
   - Subtítulo: `'$n candidata(s) EN/ES na fonte · ou gerar do áudio'` (lógica `detectLang` do
     `initState` da tela). Rota não é escolha manual: candidata EN/ES ⇒ `translate`; senão
     `transcribe` (exibida como info).
   - Linha Voz (ciclar os 4 tiers, escondida na rota translate) e Linha Tradução (ciclar 4 tiers)
     com o `AiModelRow`.
   - Botão `Gerar legenda` + progresso inline + erro + `Cancelar` (portar `_JobCard` da tela
     para o card; `ValueListenableBuilder` sobre `SubtitleJobManager.instance.state` como hoje).
   - Estado `done` → botões `Assistir com IA` | `Apagar` (portar `_refreshCached`/`_findCached`
     e `_playWithSub`, incluindo os branches animeFire (ExoDash) vs demais (PlayerScreen)).
   - Fallback de crash hint (`consumeCrashHint` + `lastCrashHint`) portado igualmente.
   - **Navegação:** exibir este card inline como etapa `Legenda IA…` do dialog do picker
     (detail_screen.dart:1733): sem `Navigator.push`. `Voltar`/back volta para os passos do picker.
     Se o card não caber no dialog (altura), a regra é: rolagem interna; nunca nova rota.

4. **Higienização na mesma PR:**
   - Remover `_ModelRow(modelId: 'hymt-ja-pt-q3km')` (settings_screen.dart:306-307); catálogo fica.
   - Radios de settings: substituir os 3 `_ModeOption` de STT (tiny/base/small) por loop dos 4
     tiers com o `AiModelRow` (status + download no mesmo widget), matando a segunda lista de
     downloads (290-312). Radios de MT idem.
   - `_OptionRow`/`_SubTitle`/`_JobCard` de `ai_subtitle_screen.dart` movidos ao arquivo do card
     (compartilhados pela tela e pelo card); deletar duplicações.
   - `AiSubtitleScreen full-screen` fica como fallback TEMPORÁRIO no push original, até o card
     ser validado; aí se remove (nota no arquivo: `ponytail: remover após QA do card`).

**Testes.**
- Novo `test/ai_tiers_test.dart`: `sttTierOrder`/`mtTierOrder` e ids batem com `aiModelCatalog`;
  `q3km` fora dos mapas publicados; `readyMap` marca faltando/instalado em dirs fake.
- `test/settings_screen_test.dart`: settings renderiza 4 tiers STT e NÃO renderiza `q3km`.
- Widget-test do card: 0 candidatas → rota transcribe (hint correta); 1 EN → translate; tap
  `Gerar` chama callbacks (injetar fakes — o `_JobCard` atual já aceita onStart/onCancel/onRetry).

**Aceite:** decisão completa (rota + Voz + Tradução + Gerar + Resultado) sem sair do picker com
≤ 2 stops de foco até "Gerar legenda"; zero duplicação de mapa/componente de linha no projeto.

## 9. Item 8 — Progresso real da extração (P2 ~2 dias, opcional)

**Estado.** `AudioExtract.extractPcm16k` (`lib/core/subtitles/audio_extract.dart:22-29`) não
reporta progresso; `subtitle_job_manager.dart:433` fixa 0.26 (timeout 10 min atrás).

**Mudança.**
1. `AudioExtractChannel.kt`: emitir EventChannel `goanime_tv/audio_extract/progress` com
   `{outPath: String, progress: Double}` do MediaExtractor (presentationTimeUs/durationUs),
   throttled ~1 Hz.
2. Dart: `AudioExtract.progressFor(outPath)` (Stream) + subscrição no `_runTranscribe` para
   mapear `_set(extractingAudio, 0.25 + 0.05*p, ...)`. Nota: o cancel atual (`AudioExtract.cancel`)
   permanece.

**Aceite:** % anda na fase Extraindo; clamp [0,1]; falha no stream nunca mata o job (catch best-effort).

## 10. Testes consolidados (fecha as 4 lacunas do estudo §4)

| Lacuna | Teste | Item |
|---|---|---|
| política de cue rejeitada | `test/subtitle_job_test.dart` 1-3 + `test/llm_mt_test.dart` 4-5 | 2 |
| 0 cues não termina done | `test/subtitle_job_test.dart` (gate) | 3 |
| timeout numa peça não mata o job | `test/llm_mt_test.dart` + `test/subtitle_job_test.dart` | 2 |
| caminho do VAD | `test/vad_path_test.dart` | 1 |

TDD: testes novos primeiro (vermelhos) → patch → suite completa + analyze.

## 11. Ordem de execução

| # | Item | Área | Esforço | Bloqueio |
|---|---|---|---|---|
| 1 | VAD na pasta certa (+log H1) | núcleo | ~meio dia | — |
| 2 | Sanity gate 0 falas + X/Y | núcleo+UI | ~1 dia | — |
| 3 | Cue não some (fallback/retry) | núcleo | ~2 dias | — |
| 4 | SenseVoice default + strongOnly | núcleo+UI | ~1 h | — |
| 5 | strip think (`<tool_call>think>`/no_think) | nativo | ~meio dia | H2 validada |
| 6 | Cancelamento por fatia | núcleo | ~1 dia | — |
| 7 | Card no picker + unificar | UI | ~2 dias | após PR1 |
| 8 | Progresso extração | nativo | ~2 dias | opcional |

## 12. Quebra de PRs

- **PR1 (P0)**: itens 1, 2, 3, 4 — nú.Todos os testes do §10; sem UI nova. Entrega o fix de falas desaparecidas e do ".srt vazio = Pronto".
- **PR2 (nativo)**: itens 5 e 6 — após QA H1/H2 no aparelho.
- **PR3 (UI)**: item 7 — depois do PR1 (o card usa as mensagens X/Y/done novas).
- **PR4 (opcional)**: item 8.

## 13. QA manual no aparelho (checklist pós PR1+PR2)

1. `adb logcat | grep -E "SubtitleJob|SherpaStt|LlmMt|GoAnimeLLM"` num EP inteiro.
2. `VAD: true` com VAD instalado (H1 fechado) e `VAD: false` sem VAD (fallback ok).
3. Cancelar na fase Transcrevendo ≤63 s (1 fatia) → "Cancelado" limpo.
4. Tier `minima` + 10 cues simples: ≤1 vazia (H2 fechado) e `done (10 de 10)`.
5. Remover a tradução / usar fonte só-lixo: falha acionável "0 falas traduzidas…", sem cache sujo.
6. SenseVoice + VAD: OP/ED sem cortes errados (VAD), diálogos completos.
7. whisper-small `strongOnly` bloqueado no stick; sensevoice pré-marcado no fraco.
8. `q3km` ausente no settings; `Assistir com IA` funciona de dentro do picker.

## 14. Fora de escopo (não fazer)

- Trocar modelos/repositórios no catálogo (`model_manager.dart`), pós-processo SRT
  (`srt_parser.dart postprocess`), cache/TTL (`subtitle_store.dart`), fluxo de download
  (resume/Wi-Fi-only), prompts validados do Hy-MT2 (exceto o sufixo do item 5.2), cap 128/n_ctx 1024
  sem evidência, player, qualquer dependência Nova.

## 15. Riscos e notas

- Whisper tiny translate segue mais alucinado que SenseVoice (estudo §2.3): o default no fraco
  (item 4) mitiga; não trocar rotas sem evidência.
- Tier `minima` tem gate 4/6 (trocas de palavra): com o fallback do item 2, EP sem legenda não é
  possível; a mensagem honesta é trocar tier nos avisos.
- Natas y ignorância de detalhes: itens nativos (5 e 8) exigem build gradle (llama.cpp) — checar
  `android/app/src/main/cpp/CMakeLists.txt` para comitar strip_think no alvo certo (goanime_llm).
- `X/Y` e o gate dependem de `_resolveCues` (item 2); implementar na mesma PR (o estudo os lista
  juntos — 2.2 e 2.4 compõem um mesmo sono).

Sem aparelho disponível §*, PR1 (itens 1-3 e 4) implementável imediatamente; PR2/PR3 seguem quando
o QA do logcat entregar H1/H2.
