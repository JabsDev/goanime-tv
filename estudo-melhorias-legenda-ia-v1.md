# Estudo de melhorias — Legenda IA (v1)

Data: 25/09/2026. Escopo: só estudo, **nenhum código alterado**.
Base: código em `main` @ `80fd61f` ("tier mínima (Qwen), layout limpo…") + QA do usuário.

## Sintomas relatados (QA no aparelho)

1. **Falas não transcritas** na transcrição; a legenda final fica vazia ou com
   frases esporádicas.
2. **Tela de seleção de modelos poluída** — e é uma tela separada; o desejo é
   um **card** dentro do picker de fonte/qualidade.

## 1. Mapa do pipeline hoje (onde cada coisa mora)

| Etapa | Arquivo | Ponto-chave |
|---|---|---|
| Download de vídeo / áudio-only (HLS) | `subtitle_job_manager.dart` `_runTranscribe` | `videoUrl` → `.mp4` ou `bestaudio.aac` |
| Extração PCM 16 kHz | `audio_extract.dart` → `AudioExtractChannel.kt` | sem progresso (26% fixo), timeout 10 min |
| STT (Whisper tiny/base/small ou SenseVoice) | `sherpa_stt.dart` | isolate + VAD se `vad.onnx` existir na pasta do modelo |
| Anti-lixo STT | `sherpa_stt.dart:415` | cue com texto vazio = descartada |
| Tradução (Hy-MT2/LFM/Qwen via llama.cpp) | `llm_mt.dart` + `LlmTranslator.kt` + `goanime_llm.cpp` | prompt ChatML fixo, greedy, teto 128 tokens |
| Anti-lixo MT | `llm_mt.dart` (`isJunk`, `isDegenerate`, `pieces`) | peças sem letra ou degeneradas viram `''` |
| Montagem de cues | `subtitle_job_manager.dart:482` | `if (t.trim().isNotEmpty) out.add(...)` |
| Pós-processo | `srt_parser.dart` `postprocess` | rewrap 42×2, split proporcional, shift +150 ms |
| Cache + TTL 5 dias | `subtitle_store.dart` | tag `ja-ai` / `en-ai` |

## 2. Por que falas desaparecem (causas candidatas, com file:line)

### 2.1 VAD nunca ativa — bug de caminho (P0, provável raiz de "várias falas não transcritas")

- `model_manager.dart:74-80`: o VAD opcional baixa para **`models/silero-vad/vad.onnx`**.
- `sherpa_stt.dart:52`: o engine procura **`$modelDir/vad.onnx`** (ex.
  `models/whisper-tiny-ja/vad.onnx`).
- Resultado: o usuário baixa o "VAD silero" e ele **nunca é usado** — o caminho
  não bate. Sem VAD cai em `_segment` com janelas fixas de 30 s
  (`sherpa_stt.dart:326-336`):
  - fala cortada na fronteira da janela = frase pela metade ou perdida;
  - janela com música/silêncio = alucinação do Whisper (entra os filtros
    anti-lixo e vira cue descartada mais adiante);
  - chunks de 30 s com várias falas colapsam em 1 texto só (emenda errada).

Correção de 1 linha de intenção: no download do STT (ou no `SherpaSttEngine.init`),
copiar/linkar `models/silero-vad/vad.onnx` para dentro da pasta do modelo STT
best-effort. Nem precisa de UI nova: um log do `_hasVad` na carga já
confirma o bug no aparelho.

### 2.2 Descarte de cue quando a tradução fica vazia (P0)

`subtitle_job_manager.dart:378` (Rota S) e `:482` (transcribe):

```dart
if (t.trim().isNotEmpty) out.add(cues[i].withText(t));
```

Toda cue cuja tradução saiu vazia é **jogada fora** — sem aviso, sem contagem.
Compunha com:

- `llm_mt.dart:153-165`: peças `isJunk` nem vão pro modelo; `isDegenerate` zera
  a peça; se **todas** as peças forem descartadas, `translate()` retorna `''`;
- timeout/hang nativo (`llm_mt.dart:156-162`): hoje um timeout numa peça
  **aborta o job inteiro** (`StateError` sobe até `_run`) — perde ~15 min de
  transcrição já feita por causa de 1 frase.

Política melhor (lazy, sem refazer o mundo): **cue não se descarta, se marca.**

- Tradução vazia/degenerada → manter a cue com texto reserva (fonte já
  traduzida descarta-se apenas se o texto fonte for lixo puro);
- perceber no fim `X/Y falas` e falhar alto se `X==0` (ver 2.4);
- timeout da peça → retry 1× e, persistindo, cue marcada como falha, **não**
  morte do job.

### 2.3 Whisper tiny com `task=translate` alucina mais (P1)

`ai_providers.dart:35-40`: tiny roda `task=translate` ja→en (depois MT en→pt);
base/small/sensevoice transcrevem ja. Tiny multilíngue é o mais fraco para
JA — em música/efeito o texto vira lixo, os filtros cortam, e a fala some.
Já existe o mitigador: **SenseVoice-JA** (encoder direto, rápido, próprio para
JA). Melhorias:

- tornar sensevoice o **default** de transcrição em aparelho fraco
  (`mtSrc='ja'` já funciona — id `sensevoice-ja`);
- `DeviceCapability.isLowEnd()` já existe — usar para **gating honesto**:
  `strongOnly` (`whisper-small`, `completa`) com aviso/lock no fraco.

### 2.4 Job "Pronto" com legenda de 0 cues (P0 — o sintoma "ficou vazia")

`_finish` salva `SrtParser.format([])` sem reclamar: um `.srt` sem nenhuma cue
é gravado como `ja-ai`, a UI mostra "Legenda pronta", e o player não exibe
nada. Gate mínimo no fim do job:

- `0 cues` → **falhar** com mensagem acionável ("0 falas traduzidas — troque o
  modelo de voz (tiny→sensevoice/base) e tente de novo");
- `<30% das falas traduzidas → salvar igual, mas avisar no card ("gerada com
  poucas falas: X/Y") em vez de celebrar.

### 2.5 Hipótese a validar: Qwen 0.6B "thinking" comendo o teto de 128 tokens (P1)

O prompt em `LlmTranslator.kt:101-106` é ChatML user-only, validado no spike
**contra o Hy-MT2**. Os tiers `minima` (Qwen3-0.6B) e `leve` (LFM2.5) usam o
**mesmo prompt hardcode** com modelos de template diferente:
- Qwen3 vem por padrão com modo *thinking* (blocos `<tool_call>think>`). Se o fine-tune
  JAPT não amortece isso, o raciocínio estoura o teto
  (`goanime_llm.cpp:142-174`, cap 128), a tradução real nunca sai → `''` →
  cue descartada (2.2) → "frases esporáticas". Teste de 5 min no aparelho:
  gerar 10 cues com tier mínima e contar vazias; se confirmar, usar
  `/no_think` no prompt Qwen ou aparar `<tool_call>think>…<tool_call>/think>` antes do
  `utf8_clean` (`goanime_llm.cpp:43-64`).
- LFM2.5: template próprio do Liquid — checar se `<|im_start|>` não só "não
  falha", mas **funciona** (gate 5/6 no catálogo já sugere que sim).

### 2.6 Cancelar não interrompe transcrição/tradução em andamento (P1)

`SubtitleJobManager.cancelCurrent` (`subtitle_job_manager.dart:525-530`) só
seta flag + cancela extração. No loop de cues (STT/MT) o flag é checado
**entre** itens; transcrevendo uma fatia de 60 s não há cancelamento fino
(`SherpaSttProvider.transcribe` não recebe sinal). Curar: checar cancelamento
por fatia; cancelar tradução já fica decente com o retry 2.2.

## 3. Tela de modelos — poluição × card

### 3.1 Problemas concretos (código)

1. **Duplicação de 3 componentes de linha**: `_ModeOption`
   (settings_screen.dart:902), `_ModelOptionRow` (ai_subtitle_screen.dart:538)
   e `_ModelRow` (settings_screen.dart:373) fazem quase a mesma coisa com
   visual diferente.
2. **Duas listas de modelos em settings**: os "radios" de engine (Voz tiny/
   base/small + Tradução mínima/leve/…) **e** logo abaixo uma lista separada
   de downloads com os mesmos modelos — o usuário cruza mentalmente linha a
   linha.
3. **Falta de sincronia entre as telas**: settings não lista sensevoice
   (só tiny/base/small), mas a tela IA sim; settings lista
   `hymt-ja-pt-q3km` (907 MB) que **nenhum tier mapeia mais** (`ai_providers.dart:61-66`)
   — entrada morta que induz download inútil.
4. **MT só tem 1 linha que cicla** (ai_subtitle_screen.dart:313-327): cada
   toque troca mínima→leve→média→completa; não se vê status dos outros 3
   modelos, e só o selecionado pode ser baixado. Com D-pad é invisível.
5. **Probe de disco por linha**: cada `_ModelOptionRow`/`_ModelRow` roda
   `FutureBuilder(isReady())` próprio (IO por linha a cada build).
6. **Tela cheia para uma decisão pequena**: navegação por scroll longo com
   ~10 paradas de foco até "Gerar legenda"; o usuário perde o contexto do
   picker de fonte/qualidade (é um `Navigator.push` em cima do dialog).

### 3.2 Proposta: card dentro do picker (substitui a tela)

O picker já é um diálogo passo a passo (`detail_screen.dart:1730-1763`:
Fonte → Áudio → Qualidade → **Legenda**). O card IA encaixa como a etapa
Legenda:

```
┌ Legenda IA ────────────────────────────────────────┐
│ 3 candidata(s) EN/ES na fonte · ou gerar do áudio  │
│                                                     │
│ Voz      [ SenseVoice ↻ ]   instalado · 240 MB      │  ← 1 linha cicla os 4
│ Tradução [ Hy-MT2 IQ3_M ↻ ] instalado · 859 MB      │  ↻ cicla; baixa o escolhido
│                                                     │
│ [ Gerar legenda ]         (progresso inline + erro) │
│ → "Assistir com IA" | "Apagar"                      │
└────────────────────────────────────────────────────────┘
```

- **Rota** deixa de ser escolha manual: candidata EN/ES → Rota S; senão
  transcrição (a heurística já existe no `initState`).
- Estado do card = `ValueNotifier`s do `SubtitleJobManager` (já existem) + 1
  Future assíncrono único para status dos modelos (resolve o item 5).
- O `AiSubtitleScreen` vira **widget de card reutilizável**
  (`AiSubtitleCard`) incluído no dialog; a tela full-screen vira fallback
  opcional (ou é removida).
- Modelos: os 4 tiers visíveis no ciclar, **com status de cada um no texto**
  ("Hy-MT2 Q4 — faltando") e download do selecionado com barra inline.

### 3.3 Higienização (sem mudança de comportamento)

- **Fonte única de verdade** para tier↔id: mapa em `AiProviders` (já tem
  `_sttKinds`/`_mtIds`) exportado; telas consomem, nunca copiam
  (hoje `ai_subtitle_screen.dart:55-76` e `settings_screen.dart:198-310`
  repetem os mapas à mão).
- Apagar/adaptar a linha `hymt-ja-pt-q3km` do settings ("descontinuado — use
  IQ3_M"), mantendo o catálogo para quem já o tem.
- Settings lista sensevoice junto; unificar nos 4 tiers de voz.
- Um único componente `_ModelRow` (status+download+ciclar) usado por ambas.

## 4. Testes que existem × gaps

Boa cobertura atual: `test/llm_mt_test.dart` (junk/degenerate/split/timeout),
`test/stt_l1_test.dart` (sequência STT→MT, fases, breadcrumb), `srt_postprocess`.
Gaps que travam os bugs acima:

1. **política de cue rejeitada**: tradução vazia não/sim preserva cue (hoje só
   existe o `''` do fake — nada testa a política do `out.add`).
2. **legenda com 0 cues não deve terminar done** (sanity gate).
3. **timeout numa peça não mata o job** (resiliência por cue).
4. **caminho do VAD**: engine acha `vad.onnx` na pasta do STT (regressão 2.1).

## 5. Ordem sugerida (com esforço)

| # | Item | Área | Esforço |
|---|---|---|---|
| P0 | VAD na pasta certa (cópia no download/init + log) | núcleo | ~meio dia |
| P0 | Sanity gate "0 falas" + relatar X/Y no card | núcleo+UI | ~1 dia |
| P0 | Cue não some: fallback à fonte/retry,failures por peça | núcleo | ~2 dias |
| P1 | Qwen/LFM prompt (thinking) — validar no aparelho | nativo/Kotlin | ~meio dia |
| P1 | Cancelamento por fatia do STT | núcleo | ~1 dia |
| P1 | Card no picker + unificar `_ModelRow`/mapas | UI | ~2 dias |
| P2 | Gating `strongOnly` via `DeviceCapability` | UI | ~1 hora |
| P2 | `progress` real da extração (opção: EventChannel) | nativo | ~2 dias |

Números de file:line conferidos no commit `80fd61f`. Hipóteses (2.1, 2.5)
precisam de 1 rodada de logcat no aparelho antes de virar patch.
