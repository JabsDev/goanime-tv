# Plano de implementação — Legenda IA via **LegendAI** no PC (rede local)

**Data:** 05/10/2026
**Repositórios envolvidos:**
- `goanime-tv-fresh` (app Flutter/Android — TV e celular) — `/home/jabs/work/goanime-tv-fresh`
- `LegendAI` (app desktop Tauri/Rust + Svelte) — `/home/jabs/codes-ai-resgate/LegendAI`

**Status deste documento:** plano de análise/implementação. **Fase 1 (poda local) executada em 05/10/2026 — ver §17. Fase 2 (servidor no LegendAI) executada em 05/10/2026 — ver §18. Fase 3 (cliente no app) executada em 05/10/2026 — ver §19. Fase 4 (QR + polimento) executada em 05/10/2026 — ver §20. Fase 5 (upload de áudio + rota S remota) executada em 05/10/2026 — ver §21.** O plano está concluído.

---

## 0. Resumo executivo

O pipeline local de legenda IA do GoAnime funciona ponta a ponta, mas o custo/qualidade de rodar STT + tradução **no aparelho** é ruim em modelos pequenos (relatórios anexos: LFM/Hy-MT2 pequenos alucinam, auditores pioram a transcrição, modelos JA dedicados são grandes/lentos). A proposta é **reduzir o catálogo local aos tiers altos** e **adicionar uma rota alternativa**: o app envia o episódio (URL do stream + headers) para o **LegendAI** rodando no PC, que usa Whisper + tradução (NLLB/Tower/Hy-MT2) de verdade, e o app baixa o SRT pronto pela rede local.

Decisões confirmadas com o usuário:

| Tema | Decisão |
|---|---|
| Modelos locais | Manter **apenas os tiers altos** de STT e MT (lista concreta no §7) |
| Mídia → PC | App envia **URL do stream + headers**; o PC baixa/extrai com ffmpeg |
| Descoberta | **IP+porta manual + QR code** (sem mDNS obrigatório) |
| Segurança | **Sem auth** (LAN confiável) |
| LegendAI | **Sim, alterar**: servidor HTTP embutido + API de fila |
| Build do PC | **Linux, `--features full,cuda`** |
| Coexistência | **Sim**: usuário escolhe por job ("No aparelho" × "No PC") |
| Fila | **Nos dois, com sincronização** (PC é a fonte de verdade) |

Entregável: dois PRs coordenados — um no rebuild dos modelos locais + cliente/servidor no app, outro no LegendAI (servidor de rede + fonte por URL + UI).

---

## 1. Estado atual — GoAnime TV (app Flutter)

### 1.1 O que já existe

- **Card de legenda IA inline** no picker de qualidade: `lib/features/ai_subtitle/ai_subtitle_card.dart`. Detecta rota automaticamente:
  - **Rota S (traduzir)**: existe candidata de legenda EN/ES embutida → baixa o SRT e traduz.
  - **Rota L1 (transcrever)**: sem candidata → baixa o vídeo, extrai PCM 16 kHz, transcreve (Whisper/SenseVoice/Anime-Whisper), descarrega o STT, carrega MT e traduz.
- **Orquestração de job**: `lib/core/subtitles/subtitle_job_manager.dart` — fila FIFO de 1 job, `JobPhase` (idle/downloadingVideo/extractingAudio/loadingVoice/transcribing/loadingMt/translating/saving/done/failed/cancelled), progresso, cancelamento cooperativo, breadcrumb anti-crash em `.job.json`, e **sanidade** (`_gateCues`, política cue-nunca-perdida).
- **Armazenamento**: `lib/core/subtitles/subtitle_store.dart` — `appSupport/subs/{animeKey}/ep{N}.{tag}.srt` + `.meta.json`, TTL 5 dias, `srcHash` invalida se a fonte mudou. Tags usadas: `en-ai`, `es-ai`, `ja-ai`, `ja-ai-audit`.
- **Fábrica de providers**: `lib/core/subtitles/ai_providers.dart` — mapa tier→modelo (`sttTiers`, `mtTiers`, `auditTiers`) e labels.
- **Catálogo/download**: `lib/core/subtitles/model_manager.dart` — `aiModelCatalog` (HuggingFace), download só Wi-Fi/ethernet, resume por `Range`, validação de GGUF ("GGUF" magic + 95% do tamanho).
- **Serviço de 1º plano Android**: `lib/core/subtitles/subtitle_foreground.dart` + `SubtitleJobService.kt` — mantém o processo vivo e a CPU acordada; botão Cancelar na notificação.
- **Preferências**: `lib/core/storage/settings_service.dart` — `sttModel`, `mtEngine`, `auditKind` com whitelists.

### 1.2 Dificuldades documentadas (base para o pruning)

- `relatorio-teste-legenda-ia-v1.md`: no emulador x86_64 cada fala levou **~12 min** (tradução binária); em aparelho ARM é minutos, mas ainda é **muito** para um episódio. Cues duplicados sem VAD. Fontes mortas.
- `RELATORIO-FINETUNES-HYMT2-2026-09-29.md`: o MT que o app usa (`hymt-ja-pt-iq3m`) deixou **35/158 falas com japonês** e **29 cópias da fonte**; o finetune de mangá (`manga-v3` Q4) ficou **0 japonês / 0 cópia**.
- `asr_eval/RELATORIO-AUDITORIA-LEGENDA.md`: **todos** os auditores pioram (Hy-MT2 21%→125% CER, Heretic 21%→30% o "menos mau"); pós-auditoria por modelo não se sustenta.
- Não há nenhuma rota de rede para computar fora do aparelho hoje. `anilist_pairing_server.dart` é o único precedente de `HttpServer`, mas é **loopback** (127.0.0.1:8090) e só para OAuth — não serve de base direta, porém mostra o padrão de servidor embutido em Dart.

### 1.3 Lacunas para a nova rota

1. Nenhum cliente HTTP de serviço local (só `http` para internet).
2. Nenhum armazenamento de "endereço do PC" em preferências.
3. Nenhuma UI de pareamento (IP/porta/QR) nem leitor de QR (o app não tem câmera no Android TV).
4. `SubtitleJobManager` é **exclusivamente on-device** (recebe `SttProvider`/`MtProvider`); não há abstração de "job remoto".
5. O card não pergunta **onde** gerar; assume sempre aparelho.

---

## 2. Estado atual — LegendAI (PC)

### 2.1 O que já existe (reaproveitável)

- **Pipeline completo** em Rust: `pipeline/stt_pipeline.rs` (extrair WAV → transcrever → formatar) e `commands/pipeline.rs::run_job` (extrair → transcrever → traduzir → formatar → exportar SRT), com progresso e cancelamento (`CancellationToken`).
- **Fila de jobs com pool de workers**: `pipeline/queue.rs` — estados `pending/running/done/error/cancelled`, limite por tier (`Tier1=1`, `Tier2=2`, `Tier3=3`), eventos `queue-updated`/`pipeline-progress`/`pipeline-finished`. **É uma fila em memória** (não persiste em disco).
- **Tradução**: NLLB-200 via ONNX (`ort`) e LLMs via llama.cpp (`llama`: TowerInstruct, Qwen, Hy-MT2). Catálogo em `catalog/models.json` (35+ modelos).
- **Fonte de entrada**: `PipelineSource::Audio { track_index }` ou `Embedded { stream_index }` — **apenas arquivo local** (`input_path` validado com `Path::exists`).
- **Comandos IPC** (Tauri): `inspect_video`, `run_pipeline`, `cancel_pipeline`, `queue_list/enqueue/cancel/remove`, `translate_subtitle`, `export_subtitle`.
- **Config TOML** em `~/.config/legendai/config.toml` (`active_models.stt`, `active_models.translation`, `source_lang`, `target_lang`, `threads`, `translation_engine`).
- **Hardware/tier**: `hardware/detect.rs` (RAM, threads, GPU `nvidia-smi`), `hardware/tier.rs`.
- **QR/i18n/UI Svelte 5**: `src/components/queue/QueueView.svelte`, `src/i18n/pt.json`.

### 2.2 Lacunas para virar "servidor de legendas do celular"

1. **Não existe nenhum servidor HTTP** nem dependência de servidor (`axum`/`hyper`/`tiny_http`/`warp`) no `Cargo.toml`. Confirmado por busca: zero.
2. **Não aceita URL** como entrada — só caminho local. O ffmpeg sidecar é chamado com `-i <path>`.
3. `run_pipeline`/`queue_enqueue` exigem `AppHandle` do Tauri e `input_path` existente — não há entrada "remota".
4. A fila não persiste: se o LegendAI reiniciar, jobs pendentes/em execução somem.
5. A UI não tem aba de rede/pareamento/QR nem distingue jobs locais de remotos.
6. Não há como expor um SRT pronto por HTTP (o `output_path` é um caminho no disco do PC).
7. Estado no disco desta máquina: **sem binário compilado, sem `~/.config/legendai`, sem cache de modelos** — o projeto está em fonte; a fase 0 precisa construir/rodar o LegendAI.

### 2.3 Notas de build

- `Cargo.toml`: `default = ["stt"]` (só Whisper). **Tradução exige `llama` e/ou `ort`**; o usuário escolheu `--features full,cuda`. O CI/release deve usar `full,cuda` (exige CUDA toolkit no PC).
- `src-tauri/binaries/` contém os sidecars ffmpeg/ffprobe (baixados via script); a resolução em dev usa `src-tauri/binaries`, em produção `exe_dir/<name>`.
- Identificador do app: `br.legendai.app`; config em `dirs::config_dir()/legendai/`.

---

## 3. Decisões de arquitetura (a partir das respostas)

1. **Dois modos por job**, escolhidos no card: **No aparelho** (pipeline atual, com catálogo podado) e **No PC** (LegendAI). O usuário escolhe explicitamente; não há "decide sozinho".
2. **PC é a fonte de verdade da fila remota.** O app mantém um espelho local e reconcilia. A fila **do aparelho** (jobs locais) continua sendo gerida pelo `SubtitleJobManager`.
3. **Transporte**: o app **não baixa** o vídeo na rota remota; envia `{url, headers}`. O LegendAI baixa/extrai com ffmpeg. Isso economiza banda do celular e usa a CPU/GPU do PC.
4. **Sem autenticação** — qualquer dispositivo na LAN pode enfileirar/ler SRTs. Aceito conscientemente (LAN confiável); documentado como risco no §13.
5. **Pareamento**: LegendAI mostra um QR com o endereço (`http://<ip>:<porta>`) + digitação manual. No celular o QR é lido pela câmera; no Android TV (sem câmera) digita-se o IP.
6. **Protocolo versionado** (`/v1`), JSON, HTTP em texto claro.

---

## 4. Arquitetura proposta

```
┌──────────────────────────────┐          HTTP (LAN, sem TLS)         ┌─────────────────────────────────────┐
│  GoAnime TV (Flutter)        │  POST /v1/jobs {url, headers, ep,...} │  LegendAI (Tauri/Rust)              │
│                              │ ───────────────────────────────────►  │                                     │
│  AiSubtitleCard              │                                       │  axum HTTP server (0.0.0.0:8765)    │
│   ├─ "No aparelho" (local)   │  GET  /v1/jobs (poll 1-2 s)           │   ├─ /health  /info (QR)            │
│   └─ "No PC (LegendAI)"      │ ◄───────────────────────────────────  │   ├─ /jobs (enqueue/list/cancel/del) │
│        │                     │                                       │   └─ /jobs/{id}/srt                  │
│        ▼                     │  GET  /v1/jobs/{id}/srt               │          │                           │
│  LegendAiClient + QueueSync  │ ◄───────────────────────────────────  │          ▼                           │
│        │                     │                                       │  pipeline/queue.rs (fila existente) │
│        ▼                     │                                       │          │                           │
│  SubtitleStore (salva SRT)   │                                       │  ffmpeg baixa URL → WAV → Whisper   │
│  "Assistir com IA"           │                                       │  → NLLB/Tower/Hy-MT2 → formata SRT  │
└──────────────────────────────┘                                       └─────────────────────────────────────┘
```

**Componentes novos**
- App: `LegendAiClient`, `LegendAiConnection`, `LegendAiQueueSync`, `RemoteJob` (modelo), tela/aba de pareamento e fila remota.
- PC: módulo `net` (servidor axum + DTOs + rotas), `PipelineSource::Url`, `origin` nos itens da fila, persistência opcional da fila, UI de rede/QR.

---

## 5. Protocolo de rede (`/v1`)

- **Base:** `http://<pc-ip>:<porta>` (porta default **8765**, configurável; evitar 8090, que o app usa para OAuth loopback).
- **Content-Type:** `application/json; charset=utf-8`.
- **Versão:** header/campo `protocol: 1`. O app recusa servidor com `protocol` maior que o suportado.
- **Unidades:** tempos em ms; `episode` inteiro; idiomas ISO 639-1.

### 5.1 Endpoints

| Método | Rota | Descrição |
|---|---|---|
| GET | `/v1/health` | status, versão, protocolo, tier, GPU, fila, modelos ativos |
| GET | `/v1/info` | dados de pareamento (host, porta, nome do PC, URL) para o QR |
| GET | `/v1/models` | catálogo de modelos e ativos (para diagnóstico) |
| POST | `/v1/jobs` | cria job (retorna 202 + item) |
| GET | `/v1/jobs?since=<epoch_ms>` | lista itens (reconciliação) |
| GET | `/v1/jobs/{id}` | detalhe do item (progresso/etapa/erro) |
| GET | `/v1/jobs/{id}/srt` | SRT pronto (`text/plain`), 202 se ainda não pronto |
| POST | `/v1/jobs/{id}/cancel` | cancela cooperativamente |
| DELETE | `/v1/jobs/{id}` | remove item terminal (done/error/cancelled) |

### 5.2 Payloads

`POST /v1/jobs`
```json
{
  "client_job_id": "goanime:Bocchi_the_Rock!:1:ja",
  "anime_key": "Bocchi the Rock!",
  "episode": 1,
  "source": {
    "type": "url",
    "url": "https://.../manifest.m3u8",
    "headers": { "Referer": "https://animegg.org/", "User-Agent": "Mozilla/5.0" }
  },
  "source_lang": "auto",
  "target_lang": "pt",
  "translate": true,
  "preferred_stt": "whisper-small-q5",
  "preferred_translation": "hy-mt2-1.8b-q4_k_m",
  "priority": 0
}
```

Resposta `202` (item da fila):
```json
{
  "job_id": "job-1760000000000-3",
  "client_job_id": "goanime:Bocchi_the_Rock!:1:ja",
  "state": "pending",
  "step": null, "pct": 0, "detail": null,
  "created_ms": 1760000000000,
  "origin": "remote"
}
```

Item em execução (via `GET /v1/jobs`):
```json
{
  "job_id": "job-...",
  "client_job_id": "goanime:Bocchi_the_Rock!:1:ja",
  "anime_key": "Bocchi the Rock!",
  "episode": 1,
  "state": "running",
  "step": "transcribe",      // extract|transcribe|translate|format|export
  "pct": 42,
  "detail": "42% do áudio",
  "summary": null,
  "error": null,
  "updated_ms": 1760000000123
}
```

Item concluído:
```json
{
  "job_id": "job-...",
  "state": "done",
  "summary": {
    "duration_secs": 1420.0,
    "segments": 243,
    "source_lang": "ja",
    "target_lang": "pt",
    "srt_bytes": 26112,
    "eta_secs": 96
  },
  "updated_ms": 1760000009999
}
```

Erro:
```json
{ "state": "error", "error": { "code": "no_audio_track", "message": "Vídeo sem faixa de áudio.", "hint": "Tente outra fonte." } }
```

`GET /v1/health`
```json
{
  "app": "legendai", "version": "0.2.0", "protocol": 1,
  "name": "PC-Jabs", "tier": "Tier2", "gpu": true,
  "busy": 1, "queue": 4,
  "models": { "stt": "whisper-small-q5", "translation": "hy-mt2-1.8b-q4_k_m" }
}
```

`GET /v1/info`
```json
{
  "name": "PC-Jabs", "host": "192.168.2.109", "port": 8765,
  "protocol": 1, "version": "0.2.0",
  "url": "http://192.168.2.109:8765"
}
```

### 5.3 Semântica

- **Idempotência:** `client_job_id` é a chave estável. Se já existe item com o mesmo `client_job_id` (em qualquer estado terminal ou ativo), `POST /v1/jobs` **retorna o item existente** em vez de duplicar. Reenvio após queda do app não cria job duplicado.
- **Cancelamento:** `/cancel` seta o `CancellationToken` do item (já suportado por `queue_cancel`); o item vira `cancelled`.
- **Remoção:** só itens terminais; item `running` exige cancelar antes (mesma regra atual do `queue_remove`).
- **SRT:** `GET /srt` devolve `202` enquanto não `done`; em `error` devolve `409` com o `error`; em `done` devolve `200 text/plain`.
- **Reconciliação:** o app chama `GET /v1/jobs` ao reconectar e após cada poll; `since` permite delta no futuro (MVP pode listar tudo).

---

## 6. Transporte de mídia e extração no PC

### 6.1 Fluxo (rota remota)

1. App pega `widget.sources.first` (o mesmo `VideoSource` do player): `{url, quality, headers}`.
2. Envia `source.type = "url"` com `url` + `headers`.
3. LegendAI **baixa/extrai** no PC:
   - `ffprobe`/`ffmpeg` abrem a URL com `-headers "Referer: ...\r\nUser-Agent: ..."` (e `-user_agent` quando necessário).
   - Extrai WAV 16 kHz mono (`audio/ffmpeg_extract.rs`).
   - Segue o pipeline existente (STT → tradução → formatação → SRT).
4. SRT fica em disco no PC (temp/output) e é servido por `/v1/jobs/{id}/srt`.

### 6.2 Riscos por tipo de stream

| Tipo | Como o app entrega | Risco | Mitigação |
|---|---|---|---|
| mp4 direto | URL | baixo | baixar para temp + extrair |
| HLS `.m3u8` | URL (playlist master) | médio (segmentos com tokens) | ffmpeg segue a playlist com os headers; já existe `HlsAudioOnly` no app como referência |
| DASH AnimeFire (`.jpg` servindo `application/dash+xml`) | URL | **alto**: ffmpeg pode não detetar o demuxer pela extensão | o servidor testa o `content-type`; se `dash+xml`, abre com `-f dash` (ou renomeia a URL para um temp `.mpd`); se falhar, **fallback**: o app baixa e envia o áudio |
| URLs com expiração | URL | médio (o PC baixa logo após enfileirar; se a fila demorar, o link expira) | enfileirar já baixa para temp (ou TTL curto); reenviar em caso de 403/404 |

> **Ponto de atenção:** o fallback "app extrai e envia o áudio" não foi a resposta escolhida como principal, mas é a válvula de escape para DASH/tokens. Recomendo implementá-lo como **Fase 3** e não como MVP.

### 6.3 Headers

- O app guarda os headers do `VideoSource` (já existentes para o player) e os envia.
- Limite de tamanho/comprimento: sanitizar chaves para as aceitas pelo ffmpeg; nunca usar shell (o LegendAI já usa `std::process::Command` com args em array).
- Não logar headers completos (podem conter cookies).

---

## 7. Pruning dos modelos locais ("manter só os tiers altos")

> Lista concreta proposta a partir dos relatórios. **Confirmar antes de executar.**

### 7.1 STT

| Tier | id do modelo | Ação | Motivo |
|---|---|---|---|
| `tiny` | `whisper-tiny-ja` | **remover** | tier baixo; traduz ja→en (pipeline duplo) |
| `base` | `whisper-base` | **remover** | tier baixo |
| `small` | `whisper-small` | **remover** | superado pelo destilado de anime |
| `anime-whisper` | `anime-whisper-ja` | **remover** | ~940 MB; CER pior que o jav03 |
| `sensevoice` | `sensevoice-ja` | **manter** | Whisper-small destilado p/ anime (~420 MB), roda em aparelho fraco |
| `jav03` | `whisper-ja-anime-v03` | **manter** | melhor CER medido (~6,5% filtrado), menos deleção (~900 MB) |

### 7.2 MT

| Tier | id do modelo | Ação | Motivo |
|---|---|---|---|
| `minima` | `qwen06-ja-pt-q4` | **remover** | tier baixo |
| `anime` | `qwen06-ja-pt-anime-q4` | **remover** | tier baixo |
| `leve` | `lfm12b-ja-pt-iq3m` | **remover** | 5/6 no gate; sai em japonês em fala de pausa |
| `lmt` | `lmt60-ja-pt-q4km` | **remover** | 5% de PT limpo no holdout |
| `manga` | `hymt-ja-pt-manga-v3` | **manter** | **melhor medido**: 0 japonês / 0 cópia |
| `completa` | `hymt-ja-pt-q4` | **manter** | base Hy-MT2 Q4 (alternativa genérica) |

### 7.3 Auditoria e VAD

- **Auditoria**: remover da UI e do fluxo. `off` passa a ser o único valor. Manter as classes (`auditor.dart`, `seq2seq_audit.dart`) desativadas por ora para não inflar o diff, ou remover num PR de limpeza separado. **Não** apagar sem confirmar (evitar quebrar testes existentes).
- **VAD**: manter `silero-vad` (3 MB) — sem ele a transcrição local degrada.

### 7.4 Impacto no código

- `lib/core/subtitles/ai_providers.dart`: reduzir `sttTiers`, `sttTierOrder`, `sttTierLabels`, `mtTiers`, `mtTierOrder`, `mtTierLabels`; ajustar `makeStt`/`makeMt` defaults.
- `lib/core/subtitles/model_manager.dart`: remover entradas não usadas de `aiModelCatalog`.
- `lib/core/storage/settings_service.dart`: reduzir `_sttTiers`/`_mtTiers`; **migração**: preferência persistida que não está mais na whitelist cai em `sensevoice`/`manga` (não em `tiny`/`leve`).
- `lib/features/settings/settings_screen.dart`: remover a seção "Auditoria de legenda"; listas passam a mostrar só os tiers altos.
- `lib/features/ai_subtitle/ai_subtitle_card.dart`: rótulos/ordem.
- `lib/core/subtitles/subtitle_job_manager.dart`: o bloco de auditoria em `_runTranscribe` passa a nunca executar (pode ficar inerte no MVP).
- Testes a atualizar: `test/ai_settings_test.dart`, `test/ai_subtitle_card_test.dart`, `test/settings_service_test.dart`, `test/model_manager_test.dart`, `test/subtitle_job_test.dart`.

---

## 8. Mudanças no app Flutter

### 8.1 Novos módulos (`lib/core/subtitles/legendai/`)

| Arquivo | Papel |
|---|---|
| `legendai_protocol.dart` | DTOs + serialização JSON + `protocol`/versão |
| `legendai_client.dart` | chamadas HTTP (`/health`, `/info`, `/jobs`, `/jobs/{id}`, `/srt`, `/cancel`, DELETE) com timeouts e erros tipados |
| `legendai_connection.dart` | endereço salvo, teste de conexão, estado online/offline (ValueNotifier), nome/versão/tier do PC |
| `legendai_remote_job.dart` | modelo de item remoto + mapeamento para `JobState` |
| `legendai_queue_sync.dart` | espelho local do `RemoteJob`, reconciliação com `GET /v1/jobs`, polling, download do SRT para `SubtitleStore` |
| `legendai_job_manager.dart` | fachada que a UI consome (parecido com `SubtitleJobManager`, mas para jobs remotos) |

- Usar o pacote `http` já presente (ou `HttpClient`); **não** adicionar dependência pesada.
- Persistir o espelho em `SharedPreferences` (JSON) e/ou um arquivo em `appSupport/legendai_queue.json`.
- Ao receber `done`: baixar `/srt`, gravar via `SubtitleStore.put(animeKey, ep, tag: 'ja-ai', srt, srcHash: url)` (ou `en-ai`/`es-ai` conforme a rota). Reaproveitar `srcHash` para invalidar quando a fonte muda.

### 8.2 UI

1. **Card de legenda IA** (`ai_subtitle_card.dart`):
   - Seletor "Onde gerar": **No aparelho** | **No PC (LegendAI)**.
   - Status da conexão no topo (bolinha + "PC conectado · Tier2 · GPU" / "PC não encontrado").
   - Em "No PC": botão **"Gerar no PC"** e, após enfileirar, mini-card de progresso (etapa + %) com cancelar.
   - Botão **"Assistir com IA"** aparece quando o SRT chega (mesma UX de hoje).
   - Se o PC estiver offline, "No PC" fica desabilitado com dica ("Verifique o LegendAI e o IP nas Configurações").
2. **Tela/aba de pareamento** (`legendai_pair_screen.dart`):
   - Campo IP + porta, botão "Testar conexão", botão "Ler QR code" (câmera).
   - Mostra o PC conectado (nome/versão/tier/GPU) e botão "Desconectar".
3. **Fila** (sincronizada):
   - Uma lista que mostra jobs **locais** (do `SubtitleJobManager`) e **remotos** (do PC), com estado/progresso, cancelar, remover e "Assistir" quando pronto.
   - Pode ser um card dentro do picker (MVP) e evoluir para tela própria.
4. **Configurações**: nova seção "LegendAI (PC)":
   - Endereço salvo, status, "Ler QR", "Testar conexão".
   - Preferência "Modelo de legenda padrão: No aparelho / No PC".

### 8.3 Pareamento (IP + QR)

- **QR (no LegendAI)**: o PC renderiza `http://<ip>:<porta>` (e, opcionalmente, um `legendai://v1/pair?host=...&porta=...`). Sem token (sem auth).
- **Leitura (no app)**: adicionar `mobile_scanner` (câmera). Requer `android.permission.CAMERA` no manifesto. Em Android TV sem câmera, esconder o botão e usar só a digitação manual.
- **Descoberta de IP do PC**: o LegendAI descobre o próprio IP local (`sysinfo`/`local-ip-address` ou varredura das interfaces) para montar o QR. O app **não** faz mDNS no MVP (permitir IP manual é o fallback universal).

### 8.4 Permissões e rede Android

- `INTERNET` e `ACCESS_NETWORK_STATE` já existem.
- `usesCleartextTraffic="true"` já está no manifesto → HTTP em LAN funciona. **Recomendado** trocar por `network_security_config.xml` liberando apenas faixas privadas (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `127.0.0.1`) para não permitir cleartext global em produção.
- `CAMERA` (nova) para o QR.
- O serviço de 1º plano atual (`dataSync`) pode ser reutilizado para o polling remoto, com notificação "Gerando legenda no PC…". O isolate Dart já sobrevive ao app em segundo plano (engine cacheada em `GoAnimeApp.kt`).

### 8.5 Mapeamento de fases

| Etapa do servidor | `JobPhase` no app | UI |
|---|---|---|
| `extract` (download) | `downloadingVideo` / `extractingAudio` | "Baixando no PC…" / "Extraindo áudio…" |
| `transcribe` | `transcribing` | "Transcrevendo no PC… X%" |
| `translate` | `translating` | "Traduzindo no PC… X%" |
| `format`/`export` | `saving` | "Salvando…" |
| `done` | `done` | "Legenda pronta" (baixar + salvar) |
| `error` | `failed` | erro amigável (mesmo `friendlyError`) |
| `cancelled` | `cancelled` | "Cancelado" |

### 8.6 Reconciliação e resiliência

- **Ao abrir o app / reconectar:** `GET /v1/jobs`; para cada item remoto não terminado, atualizar o espelho; para `done` ainda não baixado, baixar e salvar.
- **Reenvio idempotente:** se o app caiu antes do `202`, reenviar com o mesmo `client_job_id` devolve o item existente (não duplica).
- **PC reiniciou:** a fila em memória some. O app detecta itens "desaparecidos" e pode **reenfileirar** os que ainda não têm SRT (com aviso). Ideal: persistir a fila no PC (§9.4).
- **Polling:** 1–2 s enquanto a fila tiver itens ativos e o app estiver em 1º plano/serviço ativo; parar quando vazia.

---

## 9. Mudanças no LegendAI (Rust + Svelte)

### 9.1 Dependências (`src-tauri/Cargo.toml`)

- Adicionar `axum` (rotas) + `tokio` com features `net`/`rt-multi-thread`/`sync`/`macros`. O Tauri já embute um runtime async; pode-se subir o servidor com `tauri::async_runtime::spawn`. Alternativa sem async: `tiny_http` (mais simples, mas menos ergonômico). **Recomendo axum.**
- Provavelmente `tower-http` (CORS/logging) e `local-ip-address` (ou varrer `sysinfo`/`if-addrs`) para o host do QR.
- Manter `serde_json` (já presente) para os DTOs.

### 9.2 Novo módulo `src-tauri/src/net/`

| Arquivo | Papel |
|---|---|
| `mod.rs` | estado do servidor, bind, shutdown, geração do `ServerInfo` (IP:porta) |
| `routes.rs` | handlers axum (`health`, `info`, `models`, `create_job`, `list_jobs`, `get_job`, `get_srt`, `cancel_job`, `delete_job`) |
| `dto.rs` | `CreateJobRequest`, `JobView`, `HealthView`, `InfoView`, `ApiError` (reusa `ErrorDetail`/`code` estáveis) |
| `auth.rs` | **vazio no MVP** (sem auth) — ponto de extensão p/ token futuro |

- **Bind:** `0.0.0.0:<porta>` (default 8765). Porta configurável em `AppConfig` (`net.port`, novo campo com `#[serde(default)]`).
- **CORS:** o app é cliente nativo (não navegador); CORS não é necessário, mas habilitar `*` apenas em rotas de leitura não custa.
- **Erros:** sempre JSON `{code, message, hint}` com HTTP coerente (400/404/409/202).

### 9.3 Fonte por URL (`PipelineSource::Url`)

- Estender o enum:
  ```rust
  pub enum PipelineSource {
      Audio { track_index: usize },
      Embedded { stream_index: u32 },
      Url { url: String, headers: Vec<(String,String)> },   // NOVO
  }
  ```
- Em `run_job`: para `Url`, **baixar** o stream para um arquivo temporário do job (ou abrir direto no ffmpeg). Estratégia recomendada:
  1. `reqwest` com headers → descobre se é mídia direta; se grande, baixa para `temp_dir/video.<ext>`.
  2. `ffprobe` para listar trilhas; escolher a melhor de áudio (`track_index`).
  3. Extrair WAV normalmente (`ffmpeg_extract::extract_wav` passa a aceitar headers/URL).
  4. Segue igual.
- **DASH `.jpg`:** se o `content-type` for `application/dash+xml`, abrir com `-f dash` no ffmpeg (ou salvar como `.mpd`). Se falhar, retornar `error.code = "unsupported_stream"` para o app cair no fallback.
- **Headers no ffmpeg:** `-headers "Key: Value\r\n..."`; `-user_agent` quando houver `User-Agent`. Nunca shell.

### 9.4 Fila (`pipeline/queue.rs`)

- Adicionar `origin: JobOrigin { Local, Remote }` e `client_job_id: Option<String>` ao `QueueItem` (ou um mapa separado).
- `queue_enqueue` ganha um caminho sem `AppHandle` obrigatório? Hoje ele emite eventos; o servidor HTTP pode chamar uma versão interna `enqueue_internal(app, ...)` (o `AppHandle` está disponível no estado do Tauri).
- **Idempotência:** buscar por `client_job_id` antes de criar.
- **Persistência (recomendada):** snapshot da fila em `config_dir/legendai/queue.json` a cada transição; ao subir, recarregar itens `pending` e re-enfileirar (os `running` viram `pending`). Sem isso, reiniciar o PC perde a fila.
- **Expor snapshot serializável:** uma função `pub fn snapshot() -> Vec<JobView>` para as rotas HTTP.

### 9.5 Comandos/UI Tauri

- Novos comandos: `net_info()` (IP:porta/versão), `net_status()`, `net_set_port(port)`.
- `lib.rs`: registrar o módulo `net`, subir o servidor no `setup`, e adicionar os comandos ao `generate_handler!`.
- **UI Svelte**: nova aba **"Rede"**:
  - Estado do servidor (ligado/porta), botão copiar endereço.
  - **QR code** com o endereço (adicionar `qrcode` ao `package.json`).
  - Lista de jobs remotos (reusar `QueueView.svelte`/`JobDetails.svelte`, marcando `origin`).
- i18n: novas chaves em `src/i18n/pt.json` e `en.json`.

---

## 10. Fluxo do usuário (passo a passo)

1. **No PC:** abre o LegendAI → aba **Rede** → anota/mostra `http://192.168.x.y:8765` (QR). Garante que os modelos STT/MT estão baixados e ativos.
2. **No app:** Configurações → **LegendAI (PC)** → lê o QR (celular) ou digita o IP (TV) → "Testar conexão" → mostra "PC conectado · Tier2 · GPU".
3. **No app:** busca anime → episódio → escolhe fonte/qualidade → card **Legenda IA** → modo **No PC** → **Gerar no PC**.
4. O app envia `POST /v1/jobs` com a URL do stream; o PC baixa, transcreve, traduz e formata.
5. O app acompanha via `GET /v1/jobs` (progresso por etapa).
6. Ao concluir, o app baixa `/v1/jobs/{id}/srt`, salva em `SubtitleStore` e habilita **"Assistir com IA"**.
7. Se o PC estiver desligado, o usuário escolhe **No aparelho** e gera localmente com os tiers altos.

---

## 11. Casos de erro e bordas

| Caso | Comportamento |
|---|---|
| PC offline / IP errado | "No PC" desabilitado ou erro claro; modo local disponível |
| URL expirada / 403 | `error.code` propagado; sugerir outra fonte/qualidade |
| DASH não suportado | `unsupported_stream`; fallback futuro de upload de áudio |
| Vídeo sem áudio | `no_audio_track` (já existe no LegendAI) |
| Fala vazia (`NoSpeech`) | `no_speech` (já existe) |
| Modelo do PC não baixado | `stt_model_unavailable`/erro de tradução; instruir na UI do PC |
| App fechado durante o job | Ao reabrir, reconcilia e baixa o SRT se pronto |
| PC reiniciou | Fila perdida (se não persistida); app detecta e oferece reenviar |
| Duas tentativas do mesmo ep | `client_job_id` idempotente evita duplicata |
| Mudança da fonte (URL/hash) | `srcHash` invalida o SRT antigo em `SubtitleStore` |
| Cancelar | `/cancel` no PC + estado `cancelled` no app |

---

## 12. Testes

### 12.1 App (Dart)

- **Protocolo**: serialização/desserialização de todos os DTOs (incl. campos ausentes e desconhecidos).
- **Cliente**: `HttpServer` local de mock (mesmo padrão dos testes existentes) para `health`, `POST /jobs` (201/202 e idempotência), `list`, `srt` 202→200, `cancel`, erros.
- **Sync**: reconciliação (item novo, item removido, `done` baixado uma única vez, reenvio idempotente).
- **Store**: salvar SRT remoto com tag correta e `srcHash`.
- **UI**: card mostra/oculta "No PC" conforme conexão; botão "Assistir com IA" após `done` (widget tests).
- **Pruning**: testes de `ai_providers`/`settings_service` garantem que tiers removidos caem no default novo.
- Atualizar os testes citados no §7.4.

### 12.2 LegendAI (Rust)

- **Rotas** (handler-level ou com `axum::Router` + `tower::ServiceExt::oneshot`): health/info/jobs/srt/cancel/delete, códigos HTTP e JSON.
- **Idempotência** de `client_job_id`.
- **`PipelineSource::Url`**: parsing de headers; mapeamento de `content-type` → demuxer; erro `unsupported_stream` para DASH desconhecido (sem rede nos testes, usando `wiremock`/mock do reqwest ou injeção).
- **Persistência da fila**: round-trip do snapshot; itens `running` viram `pending` no reload.
- **`cargo clippy --all-targets --features full -- -D warnings`** e `cargo fmt --check` limpos.

---

## 13. Fases de implementação

### Fase 0 — Preparação
- Construir o LegendAI no PC: `cargo build --release --features full,cuda` (ou rodar em dev), garantir sidecars ffmpeg/ffprobe e baixar os modelos STT/MT.
- Definir porta default (8765) e nome do PC.

### Fase 1 — Pruning local (app) — ✅ executada (ver §17)
- Reduzir `ai_providers.dart`, `model_manager.dart`, `settings_service.dart` e a tela de configurações aos tiers altos.
- Migração de preferências + atualização de testes.
- **Entregável:** app só oferece STT `sensevoice`/`jav03` e MT `manga`/`completa`; sem auditoria.
- **Risco baixo, isolado.**

### Fase 2 — Servidor no LegendAI — ✅ executada (ver §18)
- `net/` com axum, `/health`, `/info`, `/models`, `/jobs` (CRUD/cancel/srt).
- `PipelineSource::Url` + headers + deteção de DASH.
- `origin`/`client_job_id` na fila + idempotência.
- Persistência da fila (**se aprovado**).
- Testes Rust.
- **Entregável:** dá para criar job e baixar SRT via `curl`.

### Fase 3 — Cliente no app — ✅ executada (ver §19)
- `legendai/*` (client, connection, remote job, queue sync).
- Tela de pareamento (IP manual; QR na fase 4).
- Card com "No aparelho/No PC", progresso, download e "Assistir".
- Fila unificada (local + remoto).
- Testes Dart + mocks.
- **Entregável:** fluxo ponta a ponta por IP manual.

### Fase 4 — QR + polimento — ✅ executada (ver §20)
- QR no LegendAI (crate Rust `qrcode`, no lugar do npm) e leitura no app (`mobile_scanner` + permissão de câmera).
- `network_security_config` (cleartext centralizado; restrição a faixas privadas é inviável no Android — ver §20.6) + guarda de IP público.
- Foreground service com notificação "Gerando no PC…".
- UI da aba Rede no LegendAI com jobs remotos.
- i18n.

### Fase 5 — (Opcional) Fallback de upload de áudio
- Para DASH/tokens que o PC não consegue baixar: app extrai o áudio e faz `PUT`/upload multipart; o PC recebe em `PipelineSource::Upload`.
- Rota S remota (traduzir SRT EN/ES): `PipelineSource::InlineSrt`.

---

## 14. Riscos e mitigações

| Risco | Prob. | Impacto | Mitigação |
|---|---|---|---|
| DASH `.jpg` não abre no ffmpeg do PC | média | alto | `-f dash` por content-type; fallback de upload de áudio (fase 5) |
| URL expira antes de processar | média | médio | baixar para temp imediatamente ao enfileirar; TTL curto |
| Fila em memória perdida no restart | alta | médio | persistir `queue.json`; app reenvia |
| PC sem `llama`/`ort` no build | média | alto | release `--features full`; `/health` mostra modelos ativos |
| Firewall do PC bloqueia 8765 | média | alto | documentar regra; botão "Testar conexão"; talvez UPnP não |
| Sem auth: terceiro na LAN enfileira/baixa SRT | baixa (LAN) | médio | aceito; ponto de extensão de token já previsto |
| Android TV sem câmera | alta | baixo | digitação manual sempre disponível |
| Polling drena bateria/CPU | média | baixo | só enquanto há itens ativos; intervalo 1–2 s |
| Divergência de versão do protocolo | baixa | médio | `protocol` no `/health`; app recusa mismatch |
| Modelos locais removidos ainda persistidos | alta | baixo | migração de preferências na whitelist |

---

## 15. Perguntas em aberto / pontos a confirmar

1. **Lista exata dos "tiers altos"** do §7: confirmar se `sensevoice` (STT) e `completa` (MT) entram, ou se o objetivo é só o topo absoluto (`jav03` + `manga`).
2. **Persistência da fila no PC**: implementar `queue.json` já na Fase 2 ou aceitar perder a fila no restart (com reenvio automático pelo app)?
3. **Porta default** 8765 ou outra preferida?
4. **Fallback de upload de áudio** (DASH) entra no MVP ou fica para a Fase 5?
5. **Rota S remota** (traduzir legenda EN/ES existente no PC) entra no escopo agora ou depois?
6. **Nome/apelido do PC** exibido no app (ex.: "PC-Jabs") — de onde vem: hostname, config?
7. **Formato de exibição da fila**: card no picker (MVP) e depois tela dedicada, ou já tela dedicada?
8. O LegendAI deve **manter a fila local mesmo com jobs remotos** (concorrência pelo pool por tier) — sim por padrão; confirmar prioridade.

---

## 16. Anexos — referência rápida

### 16.1 Arquivos-chave

**GoAnime**
- `lib/features/ai_subtitle/ai_subtitle_card.dart` — card (rota S/L1, download, job)
- `lib/core/subtitles/subtitle_job_manager.dart` — orquestração + `JobState`/`friendlyError`
- `lib/core/subtitles/subtitle_store.dart` — cache SRT (TTL 5 dias, `srcHash`)
- `lib/core/subtitles/ai_providers.dart` — tiers/labels
- `lib/core/subtitles/model_manager.dart` — catálogo/download
- `lib/core/storage/settings_service.dart` — preferências
- `lib/features/settings/settings_screen.dart` — UI de modelos
- `lib/features/detail/detail_screen.dart` — picker que embute o card
- `lib/core/subtitles/subtitle_foreground.dart` + `android/.../SubtitleJobService.kt` — 1º plano
- `android/app/src/main/AndroidManifest.xml` — permissões/cleartext
- `lib/core/anilist/anilist_pairing_server.dart` — precedente de `HttpServer` (loopback)

**LegendAI**
- `src-tauri/src/commands/pipeline.rs` — `run_job`, `PipelineSource`, `PipelineOptions`
- `src-tauri/src/pipeline/queue.rs` — fila + pool por tier
- `src-tauri/src/pipeline/stt_pipeline.rs` / `translate_pipeline.rs`
- `src-tauri/src/audio/ffmpeg_extract.rs` / `ffprobe.rs`
- `src-tauri/src/config.rs` — `AppConfig`
- `src-tauri/src/lib.rs` — setup, `generate_handler!`
- `src-tauri/Cargo.toml` — features (`stt`/`llama`/`ort`/`cuda`/`full`)
- `src/components/queue/QueueView.svelte`, `src/components/layout/Sidebar.svelte`
- `catalog/models.json` — catálogo de modelos

### 16.2 Protocolo — cola de referência

```
GET    /v1/health
GET    /v1/info
GET    /v1/models
POST   /v1/jobs
GET    /v1/jobs?since=ms
GET    /v1/jobs/{id}
GET    /v1/jobs/{id}/srt
POST   /v1/jobs/{id}/cancel
DELETE /v1/jobs/{id}
```

### 16.3 Relatórios usados como base

- `relatorio-teste-legenda-ia-v1.md`
- `relatorio-animefire-revisao-critica.md`
- `relatorio-animefire-qualidade-nao-carrega.md`
- `relatorio-bugs-episodios-animefire.md`
- `/home/jabs/work/RELATORIO-FINETUNES-HYMT2-2026-09-29.md`
- `/home/jabs/work/asr_eval/RELATORIO-AUDITORIA-LEGENDA.md`

---

## 17. Relatório de execução — Fase 1 (poda local)

**Data:** 05/10/2026 · **Status:** ✅ concluída · **Escopo:** `goanime-tv-fresh` (app Flutter). LegendAI não foi tocado.

### 17.1 Resultado

O app agora oferece **apenas os tiers altos**: STT `sensevoice` (Whisper destilado de anime) e `jav03` (Whisper-ja-anime-v0.3); MT `manga` (Hy-MT2 v3 fine-tune de mangá) e `completa` (Hy-MT2 Q4 base). A **auditoria saiu da UI e do fluxo** (o job não gera mais a variante `ja-ai-audit`). Qualquer preferência persistida de um tier removido migra para `sensevoice`/`manga`.

Decisão da pergunta em aberto **§15.1**: `sensevoice` e `completa` **entram** (não é só o topo absoluto). `sensevoice` é o único STT que roda em aparelho fraco; `completa` é a alternativa genérica ao fine-tune de mangá.

### 17.2 Arquivos alterados

| Arquivo | Mudança |
|---|---|
| `lib/core/subtitles/ai_providers.dart` | `sttTiers`/`sttTierOrder`/`sttTierLabels` → `sensevoice`,`jav03`; `mtTiers`/`mtTierOrder`/`mtTierLabels` → `manga`,`completa`; defaults de `makeStt`/`makeMt`/`makeMtForSrc` ajustados. |
| `lib/core/storage/settings_service.dart` | `_sttTiers`/`_mtTiers` reduzidos; default `sensevoice`/`manga`; migração no `init`; auditoria sempre `off` no boot; removido o hook `lowEndOverrideForTest`/`_defaultStt` (default deixou de depender do aparelho). |
| `lib/core/subtitles/model_manager.dart` | Removidas 9 entradas não usadas do `aiModelCatalog` (tiny/base/small/anime-whisper, q3km, LFM IQ3, Qwen 0.6B, Qwen anime, LMT-60). Mantidos os auditors (usados pelos testes de integração) e o VAD. |
| `lib/core/subtitles/llm_mt.dart` | Removido `modelIdQ3` (apontava para o Q3_K_M retirado). |
| `lib/core/subtitles/subtitle_job_manager.dart` | Bloco de auditoria removido de `_runTranscribe`; `_finish` sem variante auditada; `mtSrc` fixo em `ja`; mensagens sem `tiny`. |
| `lib/features/settings/settings_screen.dart` | Seção "Auditoria de legenda" e `_AuditOffRow` removidas; probe de status sem auditors; texto da seção atualizado. |
| `lib/features/ai_subtitle/ai_subtitle_card.dart` | Comentários de tier atualizados (a UI já deriva os tiers de `AiProviders`). |
| `test/settings_service_test.dart` | Novos defaults; migração `tiny`/`leve`→`sensevoice`/`manga`; setter rejeita tier removido; ordem publicada. |
| `test/ai_settings_test.dart` | Readiness de `sensevoice`/`jav03`/`manga`/`completa`; default do `makeMt`; testes de tiny/base/small/minima/leve removidos. |
| `test/settings_screen_test.dart` | UI mostra 2 tiers de voz e 2 de tradução; garante ausência dos antigos e de "Auditoria". |
| `test/ai_subtitle_card_test.dart` | Labels novos no card. |
| `test/model_manager_test.dart` | Catálogo podado (assert de ausência) e ids atualizados. |

### 17.3 Migração de preferências

- `stored` fora da whitelist → `sensevoice` (STT) / `manga` (MT), tanto no `init()` quanto no `setSttModel`/`setMtEngine`.
- O default deixou de ser escolhido por `DeviceCapability`: como a migração manda cair em `sensevoice` e a UI nova não oferece `tiny` como fallback, um default variável por aparelho criaria divergência. Removi `lowEndOverrideForTest`/`_defaultStt` (o `DeviceCapability` continua no `init` para o modo lite).
- **Auditoria:** no boot o valor é forçado a `off` (o persistido é ignorado). A API `setAuditKind`/`makeAudit` e as classes (`auditor.dart`, `seq2seq_audit.dart`, `audit_engine.dart`) foram **mantidas** — o §7.3 pede para não apagar sem confirmar, e os testes de integração de auditoria dependem delas.

### 17.4 Testes

- `flutter analyze --no-pub`: **0 erros**. Resta 1 warning pré-existente e fora do escopo (`_recoverMissedSpeech` não referenciado em `sherpa_stt.dart`, em trabalho não commitado).
- Suite afetada: **49 testes passando** (`settings_service_test`, `ai_settings_test`, `settings_screen_test`, `ai_subtitle_card_test`, `model_manager_test`, `subtitle_job_test`), mais 35 passando em `stt_l1_test`/`vad_path_test`/`stt_noise_test`/`stt_worker_regression_test`/`glossary_test`.

### 17.5 Desafios e decisões

1. **Não quebrar o trabalho de auditoria existente.** O repo tinha (não commitado) classes e testes de integração de auditoria. Optei por desligar a auditoria no boot e remover o bloco do job, sem apagar classes/catálogo/API. Isso satisfaz "off é o único valor" sem destruir os testes de integração do recurso.
2. **Defaults e migração.** O pedido de migrar para `sensevoice`/`manga` conflitava com o default por aparelho existente (`fatia forte → tiny`). Resolvido fixando o default e removendo o hook de teste.
3. **Poda do catálogo sem quebrar o build.** Várias entradas só eram usadas pela UI/tiers removidos, mas os **auditors** são indexados por `makeAudit(_ready)` e pelos testes de integração — mantidos. `hymt-ja-pt-q3km` era órfão (fora de tiers) e saiu, junto do getter `modelIdQ3`.
4. **Código morto deixado de propósito.** O ramo `SherpaSttProvider` em `makeStt` (nenhum tier usa `kind: 'whisper'` agora) e `_recoverMissedSpeech` seguem no repo — remoção fica para um PR de limpeza separado, para não inflar o diff da Fase 1.
5. **Falhas pré-existentes adjacentes.** `test/llm_mt_test.dart` (7 testes) falha no ambiente por `Glossary.load()` chamar `path_provider` sem `TestWidgetsFlutterBinding.ensureInitialized()` — isso vem da integração de glossário em andamento (arquivo `lib/core/subtitles/glossary.dart` não rastreado), **não** da Fase 1. Nenhum arquivo dessa feature foi tocado aqui.

### 17.6 Pendências / próximos passos

- **Fase 2** (servidor no LegendAI) não iniciada — depende do repo `LegendAI`.
- PR de limpeza (opcional, separado): remover `sherpa_stt` ramo whisper + `_recoverMissedSpeech`, classes de auditoria, `makeAudit`, campos `_auditKind`/`setAuditKind` e `test/llm_mt_test` binding.
- Os testes de integração de auditoria (`integration_test/audit_*`, `seq2seq_audit_test.dart`) continuam compilando, mas não fazem mais parte do fluxo do app.

---

## 18. Relatório de execução — Fase 2 (servidor no LegendAI)

**Data:** 05/10/2026 · **Status:** ✅ concluída · **Escopo:** `LegendAI` (Tauri/Rust). O app `goanime-tv-fresh` não foi tocado.
**Observação de processo:** o LegendAI **não é um repositório git** nesta máquina (não há `.git`), então não foi possível abrir PR: as mudanças foram aplicadas diretamente na árvore de trabalho.

### 18.1 Resultado

O LegendAI agora sobe um **servidor HTTP embutido** (`axum`, `0.0.0.0:<porta>`, default **8765**) no `setup` do Tauri, com o protocolo `/v1` completo e o teste ponta a ponta que equivale aos `curl`: cria job, lista, consulta `/srt` (202 enquanto não pronto) e baixa o SRT. A fila ganhou **origem** (`local`/`remote`), **idempotência por `client_job_id`** e **persistência** (`queue.json`). A origem `PipelineSource::Url` permite que o ffmpeg **abra a URL do stream direto com os cabeçalhos HTTP do job**, incluindo fallback `-f dash` para o caso AnimeFire (`.jpg` servindo `application/dash+xml`).

Comandos IPC novos (para a UI da Fase 4): `net_info`, `net_status`, `net_set_port`. O endereço de pareamento é logado no boot (`LegendAI disponível para o app remoto em http://<ip>:8765`).

### 18.2 Decisões sobre as perguntas em aberto (§15)

| # | Pergunta | Decisão |
|---|---|---|
| 2 | Persistência da fila na Fase 2? | **Sim.** Implementada (`config_dir/legendai/queue.json`): só itens `pending`/`running` são salvos; ao subir, `running` vira `pending` e re-enfileira. |
| 3 | Porta default | **8765** (configurável em `[net].port`; evita a 8090 do OAuth loopback do app). |
| 4 | Fallback de upload (DASH) | **Fica para a Fase 5** (`PipelineSource::Upload`). O MVP resolve DASH por `-f dash`. |
| 5 | Rota S remota (traduzir SRT) | **Fica para a Fase 5** (`PipelineSource::InlineSrt`). |
| 6 | Nome do PC | `[net].name` da config; `None` → **hostname** (`sysinfo::System::host_name()`). |
| 8 | Fila local coexistindo com remota | **Sim** — mesma fila; `origin` distingue. Sem prioridade diferenciada no MVP (ordem FIFO). |
| 1 | Tiers altos | já resolvido na Fase 1 (§17.1). |

Extras de decisão: `[net].enabled` (default **true**) para desligar o servidor; `preferred_stt`/`preferred_translation`/`priority` são **aceitos no contrato mas ignorados** (os modelos ativos da config do PC prevalecem) — registrados no log.

### 18.3 Arquivos alterados/criados (LegendAI)

| Arquivo | Mudança |
|---|---|
| `src-tauri/Cargo.toml` | +`axum = "0.8"`, +`tokio` (net/rt-multi-thread/sync/macros); dev-dep `tower` (`util`) para os testes de rota. |
| `src-tauri/src/net/mod.rs` | **novo** — `start()` (bind + `axum::serve` no runtime Tauri), `ServerInfo`, descoberta de IP local sem enviar pacote, `server_name`/hostname; comandos `net_info`/`net_status`/`net_set_port`. |
| `src-tauri/src/net/routes.rs` | **novo** — rotas `/v1`, `ApiState`/`QueueApi` (abstração testável), `AppQueue` (fila real) e handlers. |
| `src-tauri/src/net/dto.rs` | **novo** — DTOs do protocolo (`CreateJobRequest`, `JobView`, `HealthView`, `InfoView`, `ModelsView`) e `ApiError` (HTTP coerente). |
| `src-tauri/src/config.rs` | +`NetConfig { enabled, port, name }` com `#[serde(default)]`; defaults (true/8765/hostname) + testes de migração. |
| `src-tauri/src/commands/pipeline.rs` | +`PipelineSource::Url { url, headers }`; `PipelineOptions` agora `Serialize`; `run_job` resolve saída remota (`remote_out_path`) e extrai de URL (`extract_audio_source`: probe → escolhe trilha default/primeira → extrai com headers → fallback `-f dash`); não polui "recentes" com URLs. |
| `src-tauri/src/audio/ffmpeg_extract.rs` | +`url_input_options` (sanitiza headers, `-user_agent`, `-headers`, `-f`), +`extract_wav_url`, refator de finalização comum; testes de headers/format/sanitização. |
| `src-tauri/src/audio/ffprobe.rs` | +`probe_remote_tracks` (auto-detect → retry `-f dash`) e `run_probe`/`parse_audio_tracks` reutilizáveis; testes. |
| `src-tauri/src/pipeline/queue.rs` | +`JobOrigin`, campos `origin`/`client_job_id`/`anime_key`/`episode`/`created_ms`/`updated_ms`; `enqueue_internal` com **idempotência**; `queue_get`; persistência (`snapshot_active`/`save_snapshot`/`restored_item`/`restore`); testes. |
| `src-tauri/src/lib.rs` | `pub mod net` (gated `stt`); no `setup`: `queue::restore` + `net::start`; comandos `net_*` no `generate_handler!`. |
| `src-tauri/Cargo.lock` | Atualizado (`cargo generate-lockfile`) — inclui `axum`/deps. |

### 18.4 Protocolo implementado

`GET /v1/health`, `GET /v1/info`, `GET /v1/models`, `POST /v1/jobs` (202 + item), `GET /v1/jobs?since=`, `GET /v1/jobs/{id}`, `GET /v1/jobs/{id}/srt` (202/200/409), `POST /v1/jobs/{id}/cancel`, `DELETE /v1/jobs/{id}`. Erros sempre JSON `{ code, message, hint }`. Mapeamento `/srt`: `done`→`200 text/plain`, `error`→`409` com o `ErrorDetail`, `cancelled`→`409`, `pending`/`running`→`202`.

### 18.5 Testes

- Ambiente: instalei o toolchain Rust **stable 1.99** (`rustup`, sem partição de sistema) e um `cmake` portátil (exigido pelo `whisper-rs`/`llama-cpp-sys`), pois a máquina não tinha Rust nem cmake.
- `cargo clippy --all-targets -- -D warnings`: **0 warnings**.
- `cargo fmt -- --check`: **limpo**.
- `cargo test` (features default = `stt`): **342 passando, 0 falhando, 4 ignorados** (os 4 ignorados são pré-existentes: exigem modelo Whisper real).
  - Novos: 13 testes em `net::routes` (health/info/models, idempotência de rota via `FakeQueue`, 400/404/409/202/204, `/srt` nos 4 estados, `since`) — incluindo um **teste de servidor real** (`axum::serve` num socket efêmero + cliente `reqwest`) que cria job e faz polling do SRT.
  - Novos unitários: headers/format/sanitização (`ffmpeg_extract`), `parse_audio_tracks` (`ffprobe`), serialização `PipelineSource::Url`, `choose_audio_track` (`pipeline`), idempotência/snapshot/restore (`queue`), `NetConfig` (`config`).

### 18.6 Desafios e decisões técnicas

1. **Headers HTTP sem abrir buraco.** O app envia `{url, headers}`; para não depender de `reqwest blocking` nem de shell, o **ffprobe/ffmpeg abrem a URL direto**. Headers viram `-headers "K: V\r\n"` + `-user_agent`; chaves/valores com `CR/LF`/`:` inválidos são **descartados** (proteção contra header injection, args em array — nunca shell). Testado.
2. **DASH `.jpg` (AnimeFire).** Em vez de confiar no `content-type` via HTTP, o probe tenta auto-detecção e, se falhar, repete com `-f dash`; a extração faz o mesmo fallback. Menos uma dependência e cobre o caso real.
3. **`AppHandle` vs. testabilidade das rotas.** Os handlers do axum não podem receber um `AppHandle` falso. Abstraí a fila numa trait `QueueApi` (`AppQueue` em produção, `FakeQueue` nos testes) — as rotas ficam testáveis por `oneshot` e por HTTP real.
4. **Persistência sem `Deserialize` no `ErrorDetail`.** `ErrorDetail` usa `code: &'static str` (não desserializável trivialmente). Em vez de mudar o tipo, o snapshot persistido guarda **só os itens ativos** (`id/input_path/source/options/origin/client_job_id/...`) — `running` vira `pending` no reload. Itens terminais não são recarregados (o app já baixou o SRT).
5. **`net` gated em `stt`.** O servidor enfileira no pipeline (que depende de `stt`); gatear em `stt` mantém o build sem a feature íntegro. CI (default = `stt`) compila e testa tudo.
6. **Saída do job remoto fora do temp dir.** O `run_job` apaga o temp dir ao terminar; por isso o SRT remoto vai para `config_dir/legendai/remote/<job_id>.srt` (persistente e legível por `GET /srt`), e URLs não entram na lista de "recentes".
7. **Lockfile.** `Cargo.lock` regerado com `cargo generate-lockfile` (sem `--locked` no CI, mas assim já sai consistente para build local/CI).

### 18.7 Limitações conhecidas / pendências

- **UI da aba Rede/QR, i18n, `network_security_config`, foreground service no app**: são da Fase 4; os comandos `net_*` já existem para a UI consumir.
- **URL expira antes de processar**: o ffmpeg abre a URL quando o job **começa**; se ficar muito tempo na fila, 403/404 do CDN viram `error` do job. Mitigação futura (baixar no enqueue) ou reenvio pelo app.
- **`preferred_stt`/`preferred_translation`/`priority`** sem efeito no MVP (aceitos e logados).
- **Sem autenticação**: qualquer dispositivo da LAN pode enfileirar/ler SRT (aceito no §3.4); `net.enabled` permite desligar.
- **`net_set_port` exige reiniciar** o LegendAI (não reinicia o listener em quente).
- **Fila local não foi revertida para o app** — nada do GoAnime foi alterado nesta fase.

---

## 19. Relatório de execução — Fase 3 (cliente no app)

**Data:** 05/10/2026 · **Status:** ✅ concluída · **Escopo:** `goanime-tv-fresh` (app Flutter). O LegendAI (Rust) não foi alterado.
**Observação de processo:** o repo do app **está sob git**, mas as mudanças ficaram na árvore de trabalho (sem commit/PR) para você revisar; os arquivos novos estão em `lib/core/subtitles/legendai/`, `lib/features/ai_subtitle/legendai_job_card.dart`, `lib/features/settings/legendai_{pair_screen,queue_card}.dart` e `test/legendai_*_test.dart`.

### 19.1 Resultado

O app agora tem a **rota remota completa por IP manual** (entregável da Fase 3):

1. **Pareamento**: tela `LegendAiPairScreen` (IP/porta + "Testar conexão"/"Salvar e conectar"/"Desconectar"), status ao vivo (PC conectado · Tier · GPU · versão) e nota de que o QR chega na Fase 4.
2. **Cliente HTTP** `LegendAiClient` cobre todo o `/v1` (`health`, `info`, `models` via health, `jobs` POST/GET/since, `{id}`, `{id}/srt`, `cancel`, DELETE) com timeout, erro tipado (`LegendAiException`/`LegendAiProtocolException`) e recusa de protocolo maior.
3. **Card do episódio**: seletor **"Onde gerar: No aparelho | No PC (LegendAI)"** com status de conexão. Em "No PC" o botão vira **"Gerar no PC"**, acompanha o progresso por etapa (Baixando/Transcrevendo/Traduzindo/Salvando) e habilita **"Assistir com IA"** quando o SRT chega — a rota local continua idêntica (default).
4. **Fila unificada** (seção Configurações → LegendAI (PC)): job local em execução + jobs remotos com estado/progresso, **cancelar** e **remover**; botão Atualizar.
5. **Persistência/reconciliação**: espelho em `appSupport/legendai_queue.json`; ao abrir o app (`main`) ou o card, faz `GET /v1/jobs`, funde os itens remotos (por `client_job_id`), baixa SRTs `done` ainda não salvos para o `SubtitleStore` e marca como reenviável o que sumiu do PC (restart sem snapshot).

### 19.2 Decisões sobre as perguntas em aberto (§15)

| # | Pergunta | Decisão na Fase 3 |
|---|---|---|
| 7 | Formato da fila | **Card na seção de Configurações** (local + remoto). "Assistir" fica no card do episódio, único lugar com provider/fontes; a fila oferece cancelar/remover + status. |
| 4 | Fallback de upload (DASH) | Segue na Fase 5. A rota remota envia **só URL**; DASH cai em `unsupported_stream`, com mensagem apontando "gere no aparelho". |
| 5 | Rota S remota (traduzir EN/ES) | Segue na Fase 5. Mesmo quando há candidata EN/ES, a rota remota manda a URL e o PC transcreve o áudio (JA→PT) — o SRT é salvo na tag `ja-ai`. |
| — | Modo padrão | Nova preferência `settings_subtitle_source` (`device`/`pc`), default **`device`**; o card abre no último escolhido. |

### 19.3 Arquivos criados (`lib/core/subtitles/legendai/`)

| Arquivo | Papel |
|---|---|
| `legendai_protocol.dart` | DTOs + JSON + `kLegendAiProtocol = 1`; enums `LegendAiState`/`LegendAiStep` com **`unknown`** forward-compat (estado desconhecido = terminal, evita polling eterno). |
| `legendai_client.dart` | `package:http` (injetável p/ `MockClient`), timeout, `LegendAiException`/`LegendAiProtocolException`, `friendlyLegendAiError`. |
| `legendai_connection.dart` | endereço salvo, `status` (unconfigured/checking/online/offline), `health`/`info`, `healthLabel`, `test`/`saveAndConnect`/`disconnect`; `debugUseClient` p/ testes. |
| `legendai_remote_job.dart` | modelo do espelho + `merge` (preserva campos locais) + `toDisplayState()` mapeando etapa→`JobState`/`JobPhase` (§8.5). |
| `legendai_queue_sync.dart` | submit idempotente, `refresh`/reconciliação, polling 1,5 s, download do SRT p/ `SubtitleStore`, cancelar/remover, persistência em `legendai_queue.json` (cadeia `flush()`). |
| `legendai_job_manager.dart` | fachada singleton (`jobs`, `generate`, `cancel`, `remove`, `jobFor`) consumida pela UI. |

### 19.4 Arquivos do app alterados

| Arquivo | Mudança |
|---|---|
| `lib/core/storage/settings_service.dart` | +`legendAiHost`/`legendAiPort`/`legendAiConfigured`/`legendAiAddressListenable`; +`subtitleSource` (default `device`) com persistência e migração implícita (ausência = device). |
| `lib/features/ai_subtitle/ai_subtitle_card.dart` | seletor "Onde gerar"; seção "No PC" (`LegendAiJobCard`, `_startRemote`); `_buildCachedActions()` compartilhado; init do manager/refresh. Rota local inalterada. |
| `lib/features/ai_subtitle/legendai_job_card.dart` | **novo** — card de status remoto + `LegendAiQueueRow`. |
| `lib/features/settings/settings_screen.dart` | seção **"LegendAI (PC)"** (status, parear/testar/desconectar, modo padrão, fila unificada). |
| `lib/features/settings/legendai_pair_screen.dart` | **novo** — tela de pareamento por IP (QR fica p/ Fase 4). |
| `lib/features/settings/legendai_queue_card.dart` | **novo** — fila unificada (local + remota). |
| `lib/main.dart` | no boot: `LegendAiJobManager.init()` + `connection.refresh()` se pareado (best-effort). |

### 19.5 Protocolo — cobertura no cliente

`GET /v1/health`, `GET /v1/info`, `POST /v1/jobs` (202 + item), `GET /v1/jobs?since=`, `GET /v1/jobs/{id}`, `GET /v1/jobs/{id}/srt` (200 texto / 202 item / 409 erro), `POST /v1/jobs/{id}/cancel`, `DELETE /v1/jobs/{id}`. A lista remota é filtrada por `client_job_id` iniciando em `goanime:` (o `/v1/jobs` também devolve jobs locais do PC). Idempotência por `client_job_id = "goanime:<anime sans ':'>:<ep>"`. Tag do SRT por rota (`ja-ai`; `en-ai`/`es-ai` prontas para a Fase 5) e `srcHash = sha256(url)`.

### 19.6 Testes

- `flutter analyze --no-pub`: **0 erros**; resta 1 warning pré-existente e fora do escopo (`_recoverMissedSpeech` em `sherpa_stt.dart`, trabalho não commitado).
- **38 testes novos, todos passando**:
  - `legendai_protocol_test` (7): payloads, defaults, state/step desconhecidos, request, health/info.
  - `legendai_client_test` (7): health/protocolo, erro com code/hint, createJob, listJobs (since), `/srt` 200/202/409, inalcançável.
  - `legendai_remote_job_test` (10): mapeamento §8.5 (pending→…→cancelled), round-trip e `merge` preservando locais.
  - `legendai_connection_test` (5): unconfigured, online/offline, persistência e disconnect.
  - `legendai_queue_sync_test` (6): idempotência (1 POST), running→done + download ao `SubtitleStore`, job perdido→erro reenviável, cancel via `/cancel`, persistência/reload, `clientJobIdFor`.
  - `legendai_card_test` (3): default aparelho, "No PC" desabilitado sem PC, troca para "No PC" com PC conectado.
- **Suites existentes revalidadas**: `ai_subtitle_card_test`, `settings_screen_test`, `settings_service_test`, `subtitle_job_test`, `ai_settings_test`, `model_manager_test`, `subtitle_store_test` — **56 passando**.

### 19.7 Desafios e decisões técnicas

1. **Testabilidade sem AppHandle/servidor real.** O cliente recebe um `http.Client` injetável e a conexão tem `debugUseClient`; os testes usam `MockClient` (idempotência, `/srt`, cancel) — sem abrir socket. O servidor real já era coberto pelos testes Rust da Fase 2.
2. **`getSrt` 409 × `_decode`.** O `_decode` original lançava para qualquer não-2xx, então o `409` (erro do job) virava exceção em vez de `LegendAiSrtResult.failed`. Separei `_tryDecode` (sem lançar) do `_decode` (erro do servidor).
3. **Cancelar item `pending` não é suportado pelo PC.** O `queue_cancel` do LegendAI só cancela o item **em execução**; para pendente o `POST /cancel` devolve 409. Implementei fallback: running → `/cancel`; pendente → `DELETE` (remoção). Documentado como limitação abaixo.
4. **Reuso do `JobState`/`JobPhase` locais.** Em vez de criar um estado paralelo, o item remoto projeta no mesmo `JobState` — a UI e os widgets de progresso são os mesmos, e a "fila unificada" compara maçãs com maçãs.
5. **Reconciliação × restart do PC.** `refresh` marca como `lost_on_pc` (erro reenviável) o item ativo que desapareceu do `/v1/jobs`. Como a Fase 2 já persiste a fila no PC, o caso normal é o item voltar como `pending`; o fallback cobre o cenário de snapshot perdido.
6. **Isolamento do singleton nos testes.** `LegendAiConnection` é singleton; `setUp`/`tearDown` fazem `disconnect()` + `debugUseClient(null)` para não vazar `online` entre testes.
7. **Persistência determinística.** O `_notifyAndPersist`/`_upsert` encadeiam as escritas (`_persistChain`) e expus `flush()` para o teste esperar o write e não correr com o `tearDown` (que apaga o temp dir).
8. **Forward-compat do protocolo.** Enums ganharam `unknown`: estado novo do servidor vira terminal (não deixa a UI presa em "processando") e o protocolo `> 1` é recusado com mensagem pedindo atualização do app.
9. **Diff grande no card.** Para manter a rota local **byte a byte** e só acrescentar a remota, o bloco local ficou dentro de um spread `else`, o que fez o `dart format` reindentar ~500 linhas. É ruído de whitespace, não mudança de comportamento (a rota local segue coberta pelos testes existentes).

### 19.8 Limitações conhecidas / pendências (Fase 4/5)

- **QR + câmera, `network_security_config`, foreground service com notificação "Gerando no PC…", i18n e UI da aba Rede no PC** são da Fase 4. O `usesCleartextTraffic="true"` **já existe** no manifesto, então o HTTP na LAN funciona hoje.
- **Cancelar item `pending` no PC** depende de `DELETE` (o servidor não cancela pendentes). Evolução natural: o LegendAI aceitar `/cancel` também para `pending`.
- **Rota S remota (traduzir EN/ES) e upload de áudio (DASH/token)** permanecem na Fase 5 (`InlineSrt`/`Upload`). Hoje "No PC" sempre transcreve o áudio da URL; DASH cujo probe falha vira `unsupported_stream` com dica para gerar no aparelho.
- **`preferred_stt`/`preferred_translation`** viajam no request mas o PC os ignora (Fase 2); a UI ainda não os expõe.
- **URL expirada**: o PC abre a URL ao **começar** o job; se demorar na fila, 403/404 viram erro do job e o card mostra "Tentar de novo" (reenvio idempotente).
- **"Assistir" na fila unificada**: fica no card do episódio (contexto de player); a fila mostra prontidão/cancelar/remover.

---

## 20. Relatório de execução — Fase 4 (QR + polimento)

**Data:** 05/10/2026 · **Status:** ✅ concluída · **Escopo:** os **dois** repositórios — `goanime-tv-fresh` (app Flutter) e `LegendAI` (Tauri/Rust + Svelte).
**Observação de processo:** nenhum dos dois repos recebeu commit/PR — as mudanças ficaram na árvore de trabalho para revisão. O `LegendAI` continua **sem `.git`** nesta máquina.

### 20.1 Resultado

Os cinco itens da Fase 4 foram implementados:

1. **QR de pareamento**: o LegendAI gera o QR da URL `http://<ip>:<porta>` na nova aba **Rede**; o app lê o QR pela câmera (`mobile_scanner`) e preenche/conecta automaticamente. No Android TV (sem câmera) o botão é escondido e a digitação manual segue.
2. **`network_security_config`**: cleartext centralizado em `res/xml/network_security_config.xml` (substitui `android:usesCleartextTraffic="true"`) + guarda em código que recusa IP **público literal** no pareamento.
3. **Foreground service remoto**: o `SubtitleForeground` passa a ser dirigido também pelo `LegendAiQueueSync`; a notificação mostra "Na fila do PC… / Baixando no PC… / Transcrevendo no PC… / …" e o botão **Cancelar** da notificação cancela o job **remoto** (roteamento por dono).
4. **Aba Rede no LegendAI**: status do servidor, endereço copiável, QR, edição de porta e **lista de jobs remotos** (`origin = remote`) com progresso, cancelar e remover.
5. **i18n**: novas chaves `app.network` e bloco `net.*` em `pt.json`/`en.json`.

### 20.2 Decisões e desvios do plano

| Tema | Plano original | O que foi feito | Motivo |
|---|---|---|---|
| QR no PC | npm `qrcode` | crate Rust **`qrcode`** (feature `svg`) + comando IPC `net_qr_svg` | Não havia Node/npm na máquina e o frontend não precisa carregar uma dependência de QR; o SVG é gerado no backend (mesma tecnologia do resto do protocolo). O frontend só embute o SVG como `data:` URI em `<img>` (evita `{@html}`/XSS). |
| `network_security_config` "faixas privadas" | CIDR 10/8, 172.16/12, 192.168/16 | base `cleartextTrafficPermitted="true"` + entradas `localhost`/`127.0.0.1` + **validação de host privado em código** | O `network-security-config` do Android **não aceita CIDR nem curinga de IP** — só hosts exatos. Como o IP do PC é escolhido em runtime, não é possível pré-listar "só faixas privadas". Ver §20.6. |
| Leitura do QR | `mobile_scanner` | `mobile_scanner ^7.4.2` | Conforme o plano. |

Perguntas em aberto (§15): nenhuma nova — as da Fase 4 já estavam decididas (§19.2/§18.2). A pergunta 4 (fallback de upload) e a 5 (rota S remota) permanecem na Fase 5.

### 20.3 Arquivos criados/alterados — LegendAI

| Arquivo | Mudança |
|---|---|
| `src-tauri/Cargo.toml` / `Cargo.lock` | +`qrcode = "0.14.1"` (`default-features = false`, feature `svg`). |
| `src-tauri/src/net/mod.rs` | **novo comando** `net_qr_svg()` (QR da URL de pareamento) e `qr_svg()` reutilizável; testes `qr_svg_gera_svg_valido`/`qr_svg_aceita_url_legendai`. |
| `src-tauri/src/lib.rs` | registra `net::net_qr_svg` no `generate_handler!`. |
| `src/components/net/NetworkView.svelte` | **novo** — aba Rede: status/endereço/copiar, QR (`net_qr_svg` → `data:` URI), porta (`net_set_port`), jobs remotos (`queue_list` filtrado por `origin==="remote"`) com cancelar/remover. |
| `src/App.svelte` | rota `network` + `<NetworkView />`. |
| `src/components/layout/Sidebar.svelte` | item **"Rede"**. |
| `src/i18n/pt.json`, `en.json` | +`app.network` e bloco `net.*`. |

### 20.4 Arquivos criados/alterados — app Flutter

| Arquivo | Mudança |
|---|---|
| `pubspec.yaml` / `pubspec.lock` / `.flutter-plugins-dependencies` | +`mobile_scanner: ^7.4.2`. |
| `android/app/src/main/AndroidManifest.xml` | +`CAMERA`; `uses-feature` de câmera/autofoco `required="false"`; `android:networkSecurityConfig` no lugar de `usesCleartextTraffic="true"`. |
| `android/app/src/main/res/xml/network_security_config.xml` | **novo** — cleartext centralizado (ver §20.6). |
| `lib/core/subtitles/legendai/legendai_pairing.dart` | **novo** — `parseLegendAiQr` (aceita `http(s)://`, `legendai://v1/pair?...`, `host:porta`, `host`) e `isPrivateLanHost` (guarda de IP público). |
| `lib/features/settings/legendai_qr_scan_screen.dart` | **novo** — leitor `MobileScanner` que devolve `LegendAiAddress`; mensagem amigável se a câmera falhar. |
| `lib/features/settings/legendai_pair_screen.dart` | botão **"Ler QR code"** (escondido na TV via `DeviceType.isTelevision()`), `_scanQr` que preenche e conecta; guarda `_guardPrivateHost`; texto atualizado. |
| `lib/core/subtitles/subtitle_foreground.dart` | `notify(JobState, {bool remote})` + `remoteCancelHandler`; o "Cancelar" da notificação roteia para o dono certo; fallback de mensagem "Gerando legenda no PC…". |
| `lib/core/subtitles/legendai/legendai_queue_sync.dart` | dirige o FGS remoto (`_notifyForeground`/`_cancelActive`), registra o handler no `init`, `_upsert` notifica/persiste. |
| `test/legendai_pairing_test.dart` | **novo** — 14 testes (parser + host privado). |

### 20.5 QR e protocolo

- **Conteúdo do QR**: a URL do `/v1/info` (`http://<ip>:<porta>`). O app também entende o esquema `legendai://v1/pair?host=...&port=...` (forward-compat) e o formato manual `host:porta`.
- **Porta**: 1024–65535 (mesma faixa validada no servidor); porta default 8765.
- O comando `net_qr_svg` exige o servidor ativo (devolve erro claro se `net.enabled=false` ou se o bind falhou).

### 20.6 `network_security_config` — limitação real do Android

O plano pedia "restringir cleartext às faixas privadas". O Android **não suporta CIDR/curinga** em `<domain>` (só host exato; ver documentação e o StackOverflow clássico). Como o IP do PC é definido pelo usuário em runtime, não existe config estática que cubra `192.168.x.y` arbitrário. Decisão:

- `network_security_config.xml` mantém a base com cleartext **permitido** (senão a rota remota quebra), mas centraliza a política (em vez do atributo no manifesto) e já deixa `localhost`/`127.0.0.1` explícitos; o comentário no arquivo mostra como travar um IP fixo (base `false` + `<domain-config>`).
- Em código, `isPrivateLanHost()` recusa **IP público literal** no pareamento (o LegendAI é LAN sem auth). Hostnames (ex.: `pc-jabs.local`) são aceitos — a resolução de rede decide.

### 20.7 Foreground service remoto

- `LegendAiQueueSync` chama `SubtitleForeground.notify(state, remote: true)` a cada mudança relevante. `pending` (que mapeia para `idle`) é anunciado como "na fila" para o processo não ser morto antes do job começar.
- O handler do canal Kotlin (`cancelRequested`) agora consulta `SubtitleForeground._remote`: se o dono é o remoto, chama `remoteCancelHandler` (registrado pelo sync) e cancela o job ativo; senão, mantém o `SubtitleJobManager` local.
- **Limite conhecido**: a notificação é única; se um job local e um remoto rodarem juntos, o último a notificar vira o dono do botão Cancelar. Aceitável (o uso normal é um job por vez) e documentado.

### 20.8 Testes

**LegendAI (Rust + frontend):**
- `cargo test --lib`: **344 passando, 0 falhando, 4 ignorados** (eram 342; +2 dos testes de QR). Os 4 ignorados são pré-existentes (exigem modelo Whisper real).
- `cargo clippy --all-targets -- -D warnings`: **0 warnings**. `cargo fmt -- --check`: **limpo**.
- `npm run check` (`svelte-check`): **0 erros, 0 warnings**; `npm run lint` (eslint): **limpo**; `npm run format` (prettier): **limpo**; `npm run build` (vite): **ok** (169 módulos).
- Para isso foi preciso baixar um Node portátil (v22.14.0 em `/tmp/opencode`) e rodar `npm ci` — a máquina não tinha Node/npm.

**App (Dart):**
- `flutter analyze --no-pub`: **1 warning pré-existente** e fora do escopo (`_recoverMissedSpeech` em `sherpa_stt.dart`, trabalho não commitado).
- **14 testes novos** (`legendai_pairing_test`), todos passando.
- Suíte LegendAI do app (7 arquivos, incl. os novos): **52 passando**.
- Suítes afetadas/regressão (`settings_screen_test`, `ai_subtitle_card_test`, `settings_service_test`, `subtitle_job_test`, `ai_settings_test`, `model_manager_test`, `subtitle_store_test`): **56 passando**.
- `flutter build apk --debug`: **ok** — `build/app/outputs/flutter-apk/app-debug.apk` gerado (valida o merge do manifesto com a câmera e a compilação nativa do `mobile_scanner`).

### 20.9 Desafios e decisões técnicas

1. **Sem Node/npm no ambiente.** O plano pedia `qrcode` via npm; optei por gerar o QR no Rust (`qrcode` crate, feature `svg`), que é mais barato e testável. Para validar o Svelte baixei um Node portátil e rodei `npm ci`/`check`/`lint`/`format`/`build`.
2. **`{@html}` × XSS.** O eslint do Svelte reprova `{@html}`. Em vez de silenciar a regra, o SVG é embutido como `data:image/svg+xml,...` em `<img>` — sem HTML cru injetado.
3. **CIDR no Android.** Descoberta de que `network-security-config` não suporta faixas de IP; implementada a parte viável (config centralizada + guarda de IP público em código) e documentada a lacuna (§20.6).
4. **Roteamento do Cancelar da notificação.** O canal Kotlin sempre chamava o manager local; adicionei um dono (`remote`) e um handler registrado pelo sync. Sem isso, cancelar um job remoto pela notificação cancelaria (ou não faria nada em) o job errado.
5. **`pending` não iniciava o FGS.** `SubtitleForeground` ignora `idle` (comportamento correto para o job local). Para o remoto, `pending` é promovido a um estado ativo só na notificação, mantendo o processo vivo enquanto o PC está na fila.
6. **`mobile_scanner` em Android TV.** O plugin exige câmera; o botão é escondido quando `DeviceType.isTelevision()` é true e as `uses-feature` de câmera ficam `required="false"` para o app continuar instalável na TV.
7. **Testabilidade do QR.** O parser e a heurística de host privado são funções puras, cobertas por 14 testes; a tela de câmera em si não é testável em widget test (plugin nativo).

### 20.10 Limitações conhecidas / pendências (Fase 5)

- **`network_security_config` sem CIDR** (§20.6): o cleartext segue permitido na base; a restrição real a faixas privadas não é expressável estaticamente no Android. Mitigação parcial em código (IP público literal bloqueado no pareamento).
- **Fallback de upload de áudio (DASH/token)** e **rota S remota (traduzir EN/ES)** permanecem na Fase 5 (`PipelineSource::Upload`/`InlineSrt`).
- **Cancelar item `pending` no PC** continua via `DELETE` (o servidor não cancela pendentes).
- **Notificação única** para job local + remoto (§20.7).
- **`preferred_stt`/`preferred_translation`** seguem ignorados pelo PC; a UI não os expõe.
- **Build Android**: `flutter build apk --debug` **passou** (47 s de Gradle), gerando `build/app/outputs/flutter-apk/app-debug.apk`. Isso valida o merge do manifesto (permissão/`uses-feature` de câmera + `networkSecurityConfig`) e a compilação nativa do `mobile_scanner`. Ainda assim, **não** foi feito build de release `full,cuda` nem teste em aparelho real.

---

## 21. Relatório de execução — Fase 5 (upload de áudio + rota S remota)

**Data:** 05/10/2026 · **Status:** ✅ concluída · **Escopo:** os **dois** repositórios — `LegendAI` (Tauri/Rust) e `goanime-tv-fresh` (app Flutter).
**Observação de processo:** nenhum dos dois repos recebeu commit/PR — as mudanças ficaram na árvore de trabalho para revisão. O `LegendAI` continua **sem `.git`** nesta máquina.

### 21.1 Resultado

As duas válvulas de escape da Fase 5 foram implementadas:

1. **Fallback de upload de áudio** (`PipelineSource::Upload`): quando o ffmpeg do PC não consegue abrir o stream (DASH servido como `.jpg`, token), o app extrai o áudio **no aparelho** (PCM cru 16 kHz mono, o mesmo `AudioExtract` da rota local), envia por `POST /v1/uploads` e enfileira um job com `source.type = "upload"`. O PC recebe, converte para WAV com ffmpeg (`-f s16le -ar 16000 -ac 1`), transcreve e traduz.
2. **Rota S remota** (`PipelineSource::InlineSrt`): quando a fonte tem candidata EN/ES, o app baixa o SRT e envia o **texto** para o PC (`source.type = "srt"`), que pula extração e STT e só traduz (EN/ES→PT), devolvendo o SRT na tag `en-ai`/`es-ai`.

A falha ao abrir uma URL agora tem **código estável `unsupported_stream`** (antes só existia no mapeamento do cliente, nunca era emitido), o que faz o card oferecer o botão de upload.

### 21.2 Decisões e desvios do plano

| Tema | Plano original | O que foi feito | Motivo |
|---|---|---|---|
| Transporte do upload | `PUT`/multipart | `POST /v1/uploads` com **corpo binário cru** | Evita dependência de multipart (`axum` feature/`multer`) e é trivial de testar; o app transmite o arquivo em stream. |
| Formato do áudio | não especificado | **PCM cru `s16le` 16 kHz mono** | É exatamente o que o `AudioExtract.extractPcm16k` já produz no aparelho; o PC declara o formato no `-f s16le` e não precisa demuxar. |
| Rota S remota | `PipelineSource::InlineSrt` | `PipelineSource::InlineSrt` + `source.type = "srt"` no protocolo | O PC parseia o SRT (`parse_srt`) e reaproveita o pipeline de tradução 3.10. |
| Idempotência | `client_job_id` por episódio | Id ganha **sufixo de rota** opcional (`:srt-en`/`:upload`); o id histórico (URL) fica **inalterado** | URL, rota S e upload do mesmo episódio são jobs distintos; o sufixo evita o PC devolver um job de outra rota. `jobForEpisode` casa por prefixo. |
| Trigger do fallback | implícito no DASH | Código `unsupported_stream` + botão explícito "Enviar áudio do aparelho" | O PC não distingue com segurança "DASH" de "403"; o código cobre os dois e o botão fica sempre disponível na rota L1 (aviso de uso de dados). |
| Retenção dos uploads | não especificado | Arquivo é **de uso único**: apagado quando o job chega a estado terminal; varredura de órfãos (>24 h) no boot | Evita encher o disco do PC (LAN sem auth). |

### 21.3 Arquivos alterados/criados — LegendAI

| Arquivo | Mudança |
|---|---|
| `src-tauri/src/commands/pipeline.rs` | +`PipelineSource::Upload { path, format }` e `InlineSrt { srt, source_lang }`; `run_job` com `is_remote` (URL/upload/SRT), etapa de SRT inline (parse → idioma → duração, sem STT) e extração de upload; `extract_audio_source` cobre `Upload`; novo `stream_detail` (código `unsupported_stream`); testes de serialização. |
| `src-tauri/src/audio/ffmpeg_extract.rs` | **novo** `extract_wav_upload` (PCM cru `s16le` ou container) + teste com fixture PCM. |
| `src-tauri/src/pipeline/queue.rs` | `source_needs_local_file` (Audio/Embedded/Upload validam caminho; URL/SRT não); o worker apaga o arquivo de upload ao terminal; testes de validação e round-trip do snapshot. |
| `src-tauri/src/net/dto.rs` | `SourceRequest::{Upload{upload_id,format}, Srt{srt,source_lang}}`; `UploadView`. |
| `src-tauri/src/net/routes.rs` | `POST /v1/uploads` (corpo binário, `DefaultBodyLimit` de 512 MiB só nesta rota), `uploads_dir`/`next_upload_id`/`upload_path` (anti-traversal)/`sweep_uploads`; `create_job` resolve URL/upload/SRT; `EnqueueRequest` passa a carregar `PipelineSource`; testes (upload, vazio 400, upload/SRT 202, vazio 400, inexistente 404, traversal). |
| `src-tauri/src/net/mod.rs` | `sweep_uploads()` no boot do servidor. |

### 21.4 Arquivos alterados — app Flutter

| Arquivo | Mudança |
|---|---|
| `lib/core/subtitles/legendai/legendai_protocol.dart` | `LegendAiJobRequest` ganha `srt`/`uploadId`/`uploadFormat` e `sourceJson` por rota; novo `LegendAiUpload`. |
| `lib/core/subtitles/legendai/legendai_client.dart` | `uploadAudio(File, onProgress)` via `http.StreamedRequest` (progresso por bytes). |
| `lib/core/subtitles/legendai/legendai_queue_sync.dart` | `jobForEpisode` (qualquer rota), `submitSrt`, `submitUpload` (notifica o 1º plano durante o envio), `clientJobIdFor(..., kind:)`. |
| `lib/core/subtitles/legendai/legendai_job_manager.dart` | `jobForEpisode`, `generateSrt`, `generateUpload`. |
| `lib/features/ai_subtitle/ai_subtitle_card.dart` | Rota S remota (`_startRemoteSrt`: baixa a candidata e envia o texto), rota L1 (`_startRemoteUrl`), fallback `_startRemoteUpload` (extrai PCM e envia), botão "Enviar áudio do aparelho" (rota L1 ou erro `unsupported_stream`), uso de `jobForEpisode`. |

### 21.5 Protocolo — o que a Fase 5 acrescentou

- `POST /v1/uploads` (binário) → `201 { upload_id, bytes }`.
- `POST /v1/jobs` aceita `source: { type: "upload", upload_id, format? }` e `source: { type: "srt", srt, source_lang? }`, além de `url`.
- Novo código de erro estável `unsupported_stream` (URL/DASH/token que o PC não abre), com `hint` para usar o fallback.

### 21.6 Testes

**LegendAI (Rust):**
- `cargo test --lib`: **352 passando, 0 falhando, 4 ignorados** (eram 344; **+8**): 4 de rota (upload/upload vazio/create_job upload+SRT/traversal), 2 de fila (validação de origem + round-trip do snapshot), 1 de `PipelineSource` (upload/SRT), 1 de `extract_wav_upload` (PCM cru → WAV 16 kHz mono, roda com o sidecar ffmpeg presente).
- `cargo clippy --all-targets -- -D warnings`: **0 warnings**. `cargo fmt -- --check`: **limpo**.

**App (Dart):**
- `flutter analyze --no-pub`: **1 warning pré-existente** e fora do escopo (`_recoverMissedSpeech` em `sherpa_stt.dart`, trabalho não commitado).
- Suíte LegendAI (7 arquivos): **61 passando** (eram 52; **+9**): protocolo +3 (srt/upload/`LegendAiUpload`), cliente +1 (`uploadAudio` binário + progresso), queue sync +3 (`submitSrt`/`submitUpload`/`jobForEpisode`/kind), card +2 (rota S e ausência do fallback na rota S).
- Suítes de regressão (`ai_subtitle_card_test`, `settings_screen_test`, `settings_service_test`, `subtitle_job_test`, `ai_settings_test`, `model_manager_test`, `subtitle_store_test`): **56 passando**.

### 21.7 Desafios e decisões técnicas

1. **Multipart sem dependência nova.** O plano sugeria `PUT`/multipart; com axum, `Bytes` + `DefaultBodyLimit::max` por rota resolve sem puxar a feature `multipart`. O limite é elevado **só** em `/v1/uploads` (o JSON das outras rotas segue no default de 2 MB).
2. **Progresso de upload com `MockClient`.** `uploadAudio` usa `http.StreamedRequest` e alimenta o sink com `file.openRead().forEach`; o `MockClient` finaliza o corpo em `bodyBytes`, então os testes veem os bytes reais. Sem isso não haveria como mostrar progresso no 1º plano.
3. **`unsupported_stream` inexistente no servidor.** O cliente já o tratava, mas o Rust só emitia `pipeline_failed`/`corrupted_file`. Como `ErrorDetail.code` é `&'static str` e `LegendaiError` tem testes de códigos estáveis, criei o código num helper local (`stream_detail`) em vez de mexer no enum.
4. **`is_url` → `is_remote`.** `run_job` decidia saída remota e "recentes" por `is_url`; com upload e SRT, virou `is_remote` e a extração ganhou ramos novos, mantendo Audio/Embedded idênticos.
5. **Idioma do SRT inline.** `parse_srt` devolve `Language::auto`; sem setar o idioma nos blocos/segmentos a partir de `source_lang`, `resolve_source_lang` cairia na config (ou erro). O SRT agora carrega o idioma real (EN/ES).
6. **Idempotência por rota sem quebrar compatibilidade.** O id histórico `goanime:<anime>:<ep>` foi mantido para a rota URL; rota S/upload usam sufixo. `jobForEpisode` casa por prefixo e prefere item ativo, então o card acha o job certo mesmo com jobs antigos de outras rotas.
7. **Isolamento dos testes de upload.** O handler grava no diretório de config real; os testes removem o arquivo criado (`uploads_dir().join(id)`) para não poluir a máquina.
8. **Upload de uso único.** Apagar o arquivo no fim do job (worker) em vez de na extração preserva o resume após restart do PC (o snapshot restaurado ainda aponta para o arquivo); a varredura de 24 h cobre órfãos.

### 21.8 Limitações conhecidas / pendências

- **DASH/token que nem o ffmpeg do PC nem o `MediaExtractor` do Android leem** continuam sem rota: o fallback cobre o caso em que o aparelho consegue extrair; se o app também não extrai, resta gerar localmente/trocar de qualidade.
- **Sem upload retomável**: uma queda no meio do envio reinicia do zero (o app re-extrai e reenvia). Não há `Range` no upload.
- **Sem UI nova no PC**: o job de upload aparece na lista de jobs remotos já existente (aba Rede); não há indicador "veio por upload".
- **`preferred_stt`/`preferred_translation`** seguem aceitos e ignorados; a rota S/upload usa os modelos ativos da config do PC.
- **Cancelar item `pending`** continua via `DELETE` (§20.10); a notificação única para job local+remoto permanece.
- **Sem teste em aparelho real**: validação por `flutter analyze` + suíte de testes; não foi feito `flutter build apk` nem job real de upload/SRT num PC com `full,cuda`.

### 21.9 Conclusão

O plano `plano-legendai-pc-remoto.md` está **concluído nas 5 fases**: poda local, servidor HTTP no LegendAI, cliente no app, QR/polimento e, agora, as duas válvulas de escape (upload de áudio e rota S remota). O fluxo remoto cobre URL direta, rota S (EN/ES→PT) e o fallback de upload; o local segue intacto com os tiers altos.
