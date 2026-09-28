# Relatório de Teste E2E — Legenda IA (v1)

**Data:** 25/09/2026 · **Build:** debug APK com correção de ethernet · **Dispositivo:** emulador AVD `GoAnime_TV` (API 36, x86_64, 1920×1080)
**Escopo:** validar os 7 itens do `plano-acao-legenda-ia-v1.md` + fluxo completo de geração de legenda IA em anime sem legenda (Bocchi the Rock! EP1, fonte AnimeGG, áudio japonês → rota transcrever+traduzir).

## 1. Resultado por item do plano

| # | Item | Status | Evidência |
|---|------|--------|-----------|
| 1 | Cópia do VAD p/ dir do modelo (`ensureVadInModelDir`) | ✅ Implementado + testes | `test/vad_path_test.dart`; log `[SherpaStt] VAD: false (…/whisper-tiny-ja)` correto p/ instalação nova (silero-vad ainda não baixado — fallback janelas fixas de 30 s por design) |
| 2 | Fala nunca perdida (`_resolveCues` + `_translatePiece` c/ retry) | ✅ Implementado + testes | `test/subtitle_job_test.dart`, `test/llm_mt_test.dart` |
| 3 | Portão de sanidade (`_gateCues`, `_finish(yieldLabel:)`) | ✅ Implementado + testes | `test/subtitle_job_test.dart` |
| 4 | Whlists de tier nas configurações | ✅ Implementado + testes | `test/settings_service_test.dart`, `test/settings_screen_test.dart` |
| 5 | `strip_think()` nativo + `/no_think` | ✅ Implementado | `goanime_llm.cpp` (utf8-clean + strip), `LlmTranslator.kt` |
| 6 | Cancelamento por fatia (`SttProvider.transcribe(isCancelled)`) | ✅ Implementado + testes | `test/stt_l1_test.dart` |
| 7 | Unificação de UI (`ai_providers.dart`, `ai_model_row.dart`, `ai_subtitle_card.dart`, card inline no picker, linhas nas configurações) | ✅ Implementado + testes | `test/ai_subtitle_card_test.dart` |

`flutter analyze` limpo · **417 testes verdes** (baseline 399).

## 2. Correção de ethernet (fora do plano, bloqueador real)

`ModelManager.downloadModel` aceitava apenas Wi-Fi/metered-allowlist e abortava em ethernet com `ModelDownloadException`. Corrigido p/ aceitar ethernet (`test/model_manager_test.dart`, 8 testes).

**Verificação ao vivo:** download do Whisper tiny exibiu "Baixando… 29%" com barra de progresso em ethernet (antes da correção: erro imediato).

## 3. Fluxo E2E ao vivo (screenshots scr39–49)

| Etapa | Resultado |
|-------|-----------|
| Busca "bocchi" → card → EP1 → picker de qualidade | ✅ AnimeGG resolvido; "Nenhuma candidata EN/ES · rota: gerar do áudio japonês" |
| 480p selecionado → "Legenda IA…" | ✅ Card inline abriu: rota transcrever, 2 modelos "faltando" |
| Download Whisper tiny (110 MB) | ✅ Progresso na UI → "instalado · 110 MB"; 3 arquivos conferidos via `run-as` (encoder 12,9 MB / decoder 89,8 MB / tokens 0,8 MB) |
| Download LFM 1.2B IQ3_M (541 MB) | ✅ "instalado"; `model.gguf` = 566.796.448 B no disco |
| "Gerar legenda" | ✅ Job iniciou: "Baixando vídeo… 1/58 MB" |
| Transcrição (Whisper tiny JP) | ✅ `[SherpaStt] VAD: false` (esperado); áudio 67% / geral 58%; concluiu |
| Descarrego de memória | ✅ "Carregando tradução… voz liberada da memória" 73% — STT descarregado antes do LFM |
| Tradução (LFM 1.2B) | ✅ "Traduzindo… 1/48" → 48/48 em ~9 h no emulador (~12 min/fala; 3-4 threads de inferência a 100% CPU confirmadas via `/proc`/task ticks). Zero falha de VM, zero erro no log; política cue-nunca-perdida nunca precisou agir (48 de 48 traduzidas de primeira). |
| Portão de sanidade + finalização | ✅ `[SubtitleJob] falas traduzidas 48/48` + UI "**Legenda pronta (+48 de 48 falas)**" com botões "Assistir com IA" / "Apagar" e aviso "Legenda gerada por IA, pode conter erros" |
| Saída em disco | ✅ `files/subs/Bocchi_the_Rock_/ep1.ja-ai.srt` — 26 KB, 243 cues, timestamps válidos, texto em PT-BR real |
| Playback com legenda IA | ✅ "Assistir com IA" → player mpv renderizando a legenda traduzida sobre o vídeo |

## 4. Observações / limitações

- **Velocidade no emulador:** os `.so` arm64 rodam sob tradução binária no emulador x86_64 → cada fala levou ~12 min (em aparelho ARM real, o mesmo caminho é minutos). Pipeline comprovado por inteiro; throughput real requer aparelho físico.
- **Cues duplicados (sem VAD):** sem silero-vad o STT usa janelas fixas de 30 s com sobreposição → texto repetido em cues consecutivos (visível no SRT e no player). Com silero-vad baixado, `ensureVadInModelDir` copia `vad.onnx` e o log muda para `[SherpaStt] VAD: true` (cópia unit-testada; regeneração ao vivo não foi feita nesta rodada por custo — o job completo levou 9 h).
- **Fontes mortas** (sem correção planejada): AnimeFire (NXDOMAIN), Goyabu/animeplayer (403), DooPlay (TLS do emulador), AnimesOnline (migração de player). AnimeGG é a única fonte funcional.

## 5. Veredicto

**Pipeline end-to-end aprovado** (busca → AnimeGG → rota transcrever → Whisper → LFM → legenda PT-BR → playback). Publicação: release `v1.3.0+1000063`.

---

# Rodada 2 — relato do usuário: Haibane Renmei EP3 "várias falas sem legenda" (Moto G7 Play, Android 10/API 29)

## 1. O que o aparelho tinha

- App instalado era **1.0.21 (10/09)** — duas semanas desatualizado, **anterior a todas as correções do plano** (que entraram em 1.3.0). O relato foi feito com build sem *cue-nunca-perdida*, sem cópia do VAD, sem timeouts por fatia e sem portão de sanidade.
- Episódio sem legenda nas fontes (só "JA cru"): archiveJp (archive.org) como fonte vencedora; AnimeGG sem candidatos. Rota = gerar do áudio japonês, igual ao Bocchi.

## 2. Bugs achados testando no aparelho real (não apareceram no emulador)

| # | Bug | Sintoma | Correção |
|---|-----|---------|----------|
| 1 | Queda de conexão no meio do corpo HTTP matava o download | `HttpException: Connection closed while receiving data` **sem tratamento** (Unhandled Exception no VM): SenseVoice e LFM voltavam a "faltando" **sem mensagem nenhuma** na tela | `fetchFile` com loop de 4 tentativas (backoff) + resume por `Range` já existente; `HttpException`/`SocketException`/`Download incompleto` viram `ModelDownloadException` com dica curta e acionável |
| 2 | Erro de download exibia o erro cru | Tela mostrava "Falhou: Connection closed while receiving data, uri = https://ia601407.us.archive.org/…mp4" (regex guloso `^.*Exception: ` cortava até o último "Exception: " dentro da mensagem) | `friendlyError`: `ModelDownloadException` devolve a mensagem PT-BR direto, e sem stack |
| 3 | Parcial do vídeo apagado na falha | 131 MB de vídeo caem sempre no 4G/Wi-Fi; cada toque em "Gerar" **recomeçava do zero** → o job nunca terminava (na prática, "ficava sem legenda") | O `finally` de `_runTranscribe` só apaga o vídeo no sucesso; na falha o parcial fica p/ a retomada por `Range` |

**Validação ao vivo dos downloads:** SenseVoice 240 MB e LFM 541 MB instalaram no celular **depois** da correção (antes ambos voltavam a "faltando"); o vídeo de 131 MB do EP3 baixou e a transcrição começou (`[SherpaStt] VAD: false (…/sensevoice-ja)`).

## 3. Cobertura das falas (o relato original)

Rodada em andamento no Moto G7 Play: SenseVoice transcrevendo o EP3 inteiro (thread de inferência do onnx a 100% de um core), depois LFM traduzindo. Resultado da contagem de cues e do SRT: ver seção abaixo (atualizada ao fim do job).

## 4. Nota de ambiente

O cabo USB do aparelho desconecta a cada ~30–60 min (`adb` offline); reconectar com `adb kill-server && adb start-server` funciona, e o job em background segue rodando. Também: o source archiveJp é lento/fragmentado por natureza — a retomada por `Range` é obrigatório nesse caminho.
