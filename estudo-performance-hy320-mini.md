# Estudo de performance — GoAnime TV no projetor **HY320 Mini**

**Data:** 05/10/2026
**Escopo:** diagnóstico e plano de estudo. **Nenhum código foi alterado.**
**Objeto:** por que os episódios travam/″não rodam″ num projetor Allwinner fraco (mais fraco que o Fire TV Stick Lite 1ª geração) e quais alavancas existem para melhorar — no app, no player e fora do aparelho.

> Este documento se apoia no código atual (`goanime-tv-fresh`, v1.4.0+1000066) e nos relatórios anteriores do repositório (`relatorio-animefire-*.md`, `plano-legendai-pc-remoto.md`). Onde há incerteza, está marcado como **hipótese a medir no aparelho** — não como fato.

---

## 0. Resumo executivo (TL;DR)

O problema **não é uma causa só**. São três camadas que se somam:

1. **Hardware**: o H713 tem 4× Cortex‑A53 a ~1,3 GHz (vs. 1,7 GHz do Fire Stick Lite), GPU Mali‑G31 MP2 fraca, **1 GB de RAM** e painel **nativo 720p**. O clock, o firmware (Android 11 de fabricante, possivelmente 32 bits) e a RAM são o teto.
2. **O app escolhe o pior caso por padrão**: abre na **melhor qualidade (1080p)**, o que num painel 720p não traz ganho visual e triplica o bitrate/decodificação; no caminho mpv força bitrate, no caminho Exo filtra para 1080p fixo (~8,7 Mbps no probe do AnimeFire).
3. **Codec**: streams AnimeFire podem ser **AV1‑only**; num box sem decoder AV1 de hardware o app cai para **software (dav1d)**, o que num A53 de 1,3 GHz é praticamente impossível de sustentar em tempo real.

**As duas alavancas de maior impacto são:**
- **(A) Reproduzir a mídia certa**: ≤720p, preferencialmente H.264, com default adequado a aparelho fraco. Custa pouco e resolve a maior parte do travamento.
- **(B) Tirar o trabalho do aparelho**: usar o **PC (LegendAI)** como *proxy/transcoder* — baixar o stream e re‑entregar um **H.264 720p de bitrate baixo** (ou ao menos remuxado). É a solução definitiva para AV1, bitrate e CPU, e casa com a arquitetura que já existe (fila + HTTP do LegendAI).

Ganhos rápidos e baratos (app): default de qualidade por aparelho, render target do mpv em 720p, não proxiar segmentos HLS pelo Dart quando o Exo pode buscá‑los direto, e parar de fazer prefetch/probes durante o playback em modo lite.

---

## 1. O hardware: HY320 Mini vs Fire TV Stick Lite

### 1.1 Especificações comparadas

| Item | **HY320 Mini** | **Fire TV Stick Lite (2020)** |
|---|---|---|
| SoC | Allwinner **H713** | MediaTek **MT8695D** |
| CPU | 4× Cortex‑A53 @ **~1,3 GHz** | 4× Cortex‑A53 @ **1,7 GHz** |
| GPU | Mali‑**G31 MP2** | PowerVR **GE8300 MP4** |
| RAM | **1 GB** | 1 GB DDR4 |
| Armazenamento | 8 GB | 8 GB |
| Painel/saída | **1280×720 (720p)** | 1920×1080 (1080p) |
| SO | Android 11 de fabricante (alguns anunciam 13/14) | Fire OS 7 (base Android 9), maduro |
| WiFi | WiFi 6 (2,4/5 GHz) declarado | 802.11ac dual‑band |
| Decode HW (declarado) | H.264, H.265/HEVC, VP9; **AV1 disputado** | H.264, H.265, VP9 (sem AV1) |

Fontes: linux-sunxi (H713 = núcleo tipo H616, Cortex‑A53, Mali‑G31 MP2), GadgetVersus (~1,3 GHz), listagens de projetor H713 (1 GB+8 GB, 720p) e ficha técnica do Fire Stick Lite (MT8695D @1,7 GHz, PowerVR GE8300, 1 GB). Ver Anexo B.

### 1.2 Veredito sobre "é mais fraco?"

**Sim, é mais fraco** — e não só pelo clock:
- **CPU ~25% mais lenta** por núcleo (afeta decodificação por software, parsing, e o próprio Flutter/Dart).
- **GPU mais fraca** (composição da UI + render do vídeo).
- **Firmware de fabricante** (Android 11 chinês, pouco otimizado, com bloat) vs. Fire OS enxuto e maduro.
- **Painel 720p** (bom, na verdade: significa que 1080p é desperdício).
- **1 GB de RAM** é o muro mais duro: Flutter + libmpv + imagens + buffers têm que caber.

### 1.3 O ponto crítico: codecs

- **H.264 (AVC)** e **H.265 (HEVC)** e **VP9**: decodificação por hardware esperada. É o terreno seguro.
- **AV1**: as fontes se contradizem. O núcleo é derivado do H616 (que **não** tem AV1 em HW); algumas lojas do H713 anunciam "AV1 1080p/60". **Não dá para confiar em marketing.** O app já consulta isso em runtime (`DeviceCodecs.supportsAv1()` → `MediaCodecList`, `android/.../CodecsChannel.kt`).
- **Se o H713 não tiver AV1 em HW**, todo stream AV1 cai no fallback de software do app e trava. Esse é o cenário mais provável de "episódios não rodam".

### 1.4 Possibilidade de Android 32 bits

Muitos boxes Allwinner de 1 GB rodam **userspace 32 bits** (`armeabi-v7a`) mesmo com CPU 64 bits. Isso (a) deixa o app mais lento, (b) faz o llama/sherpa nativos (só compilados para arm64) virarem stub (Anexo A — `CMakeLists.txt`). **Não afeta o playback diretamente, mas afeta a sensação geral.** Confirmar com `getprop ro.product.cpu.abi` (ver §5).

---

## 2. Como o app reproduz hoje (mapa do caminho de vídeo)

### 2.1 Dois players, escolhidos por provedor

| Provedor | Player | Tecnologia | Demux |
|---|---|---|---|
| **AnimeFire** | `ExoDashPlayerScreen` | `video_player` (ExoPlayer) | DASH nativo (via proxy local `.mpd`/`.m3u8`) |
| **Todos os outros** | `PlayerScreen` | `media_kit` (libmpv) | mpv/ffmpeg direto |

Decisão em `lib/features/detail/detail_screen.dart:1343-1372`. O card de legenda IA repete a escolha (`ai_subtitle_card.dart:316-333`).

### 2.2 Resolução de qualidade e o "melhor primeiro"

- `AnimeFireAdapter.getVideoSources` gera **1 `VideoSource` por qualidade** (mesma URL, `dashHeight` distinto) **+ `Auto`** quando há mais de uma (`anime_fire_adapter.dart:412-451`).
- Os dois players aplicam `sortBestFirst(sources)` e abrem no índice 0 (`player_screen.dart:225`; `exo_dash_player_screen.dart:156`). `sortBestFirst` ordena por `qualityScore`, e `Auto` pontua **0** (`quality_picker.dart:10-42`). **Resultado: o padrão é 1080p, não `Auto`.**
- No caminho Exo, escolher 1080p é uma escolha *real*: o proxy local filtra o manifesto para aquela representação (`dash_manifest_proxy.dart:59-88, 248-293`).
- No caminho mpv, o app tenta `hls-bitrate=highest` e `dash-bitrate=highest` (`player_screen.dart:284-288`). **`dash-bitrate` não é propriedade do mpv**; `media_kit` ignora o código de retorno de `mpv_set_property_string` (`media_kit .../real.dart:1239-1245`), então é um **no‑op silencioso** — como já apontado em `relatorio-animefire-revisao-critica.md` §4.1.

### 2.3 Manifest proxy (AnimeFire)

`lib/features/player/dash_manifest_proxy.dart` existe por dois motivos: (1) o CDN serve o manifesto como `.jpg` e os players farejam por extensão; (2) um manifesto carrega todas as qualidades.

- **DASH**: só **o manifesto** passa pelo loopback; **os segmentos vão direto do CDN** (`serveManifest` ramo `!lastIsHls`, `l.75-79`). Ótimo.
- **HLS**: o proxy reescreve **master → variantes → todos os segmentos** para o loopback e **repassa cada byte pelo isolate Dart** (`_swapToLoopback`, `l.83-87, 96-139`; handler `_serve`, `l.149-212`). O comentário explica que isso foi necessário porque o cliente ffmpeg do mpv foi recusado pelo CDN.

### 2.4 Caminho AV1

- Exo: se o manifesto é AV1‑only e `supportsAv1()` é falso → `_openSoftwareFallback()` reabre no **mpv** (`exo_dash_player_screen.dart:218-225, 725-745`).
- mpv: se AV1‑only, o app **força `hwdec=no`** (`player_screen.dart:312-320`) → dav1d por software.

### 2.5 Modo lite

- Detecção automática por `/proc/meminfo` < 1500 MB (`device_capability.dart:9-11`). Num aparelho de 1 GB isso liga **sozinho**.
- Levers atuais: animações, sombras, glow, `cacheExtent`, enriquecimento AniList na busca, nº de queries de fallback (`settings_service.dart:241-257`).
- **Importante: o modo lite não toca em nada do playback.** Toda a economia de recursos para na UI.

---

## 3. Onde o desempenho se perde (diagnóstico por causa)

Ordenado por suspeita de impacto. Cada item diz **se é fato de código** ou **hipótese a medir**.

### 3.1 Codec AV1 → decodificação por software (fato do código; impacto altíssimo)
A lógica de fallback está clara no código §2.4. Um A53 @1,3 GHz com 1 GB **não decodifica AV1 720p/1080p por software em tempo real**. Sintoma: áudio toca, vídeo engasga/fica em slow‑motion, ou tela preta com áudio. Este é o candidato nº 1 para "episódio travado" em AnimeFire.

### 3.2 Qualidade padrão = 1080p num painel 720p (fato do código; impacto alto)
`sortBestFirst` + índice 0 ⇒ 1080p. No probe do AnimeFire, a representação 1080p é **~8,7 Mbps**; 720p ~3,6 Mbps; 480p ~2,1 Mbps. Mais bitrate = mais buffer, mais rede, mais decodificação. Num projetor 720p o ganho visual de 1080p é **zero** (é downscalado). O default está exatamente errado para este aparelho.

### 3.3 Proxy HLS com chain completo no Dart (fato do código; impacto alto quando ocorre)
Quando o AnimeFire serve HLS, **cada segmento é baixado pelo Dart e reentregue**. Isso soma: TLS no isolate do app, cópia de memória, tráfego pelo loopback, pressão no GC — competindo com o decode. Episódios HLS do AnimeFire tendem a travar mais que os DASH. **Hipótese de mitigação**: o Exo já recebe os headers (`httpHeaders`, `exo_dash_player_screen.dart:226-230`), então talvez ele consiga buscar variantes/segmentos **direto do CDN**, deixando o proxy só para reescrever o manifesto (como já faz no DASH). Precisa de teste em device.

### 3.4 Render target do mpv em tamanho cheio (fato da API; impacto médio)
`VideoController(_player)` sem configuração (`player_screen.dart:154`). A própria `media_kit_video` documenta que fixar `width`/`height` pequenos "pode trazer ganhos substanciais" (`android_video_controller/real.dart:214-215`; `platform_video_controller.dart:97-107`). Como o painel é 720p, um render target de **1280×720** (ou menor) evita escalar uma textura 1080p na GPU fraca.

### 3.5 Caminho mpv com `vo=gpu` + OpenGL ES (fato/arquitetura; impacto médio)
O mpv Android do media_kit usa `vo=gpu`, `gpu-context=android`, `opengl-es=yes`, `hwdec=auto-safe` (`android_video_controller/real.dart:187-207`). Isso renderiza via GL e copia para a superfície do Flutter. Em GPU Mali‑G31 a alternativa `mediacodec_embed` (superfície direta do MediaCodec, sem cópia GL) seria mais leve — mas o media_kit depende de `vo=gpu` para o widget `Texture`. **Hipótese estrutural**, não trivial.

### 3.6 ExoDash refaz `setState` da tela inteira a 2 Hz (fato do código; impacto baixo/médio)
O `ExoDashPlayerScreen` tem um `Timer.periodic(500 ms)` que chama `setState` no build inteiro (`exo_dash_player_screen.dart:309-343`), enquanto o `PlayerScreen` foi otimizado para `ValueNotifier` de posição/duração (`player_screen.dart:62-65, 382-396`). Em GPU fraca, reconstruir gradientes/overlay a 2 Hz custa. (O comentário do `PlayerScreen` registra exatamente esse bug histórico.)

### 3.7 Trabalho paralelo durante o playback (fato do código; impacto baixo/médio)
Durante o episódio o app ainda dispara: **prefetch do próximo episódio** (`resolveProvidersForEpisode`, que faz fan‑out em várias fontes), **AniSkip**, e no picker **ping TCP de cada fonte** e **probe de legendas HLS** (`detail_screen.dart:1305-1333`). Em 1 GB / 4 núcleos, isso rouba CPU/rede exatamente na fase sensível (abertura e primeiros segundos).

### 3.8 Memória: engine residente + libmpv + imagens (fato/arquitetura; impacto médio)
- A `FlutterEngine` é **cacheada no `Application`** e nunca é destruída de propósito (`GoAnimeApp.kt`) — bom para o job de legenda, mas significa consumo residente permanente.
- `MediaKit.ensureInitialized()` carrega o libmpv no boot (`main.dart:25`).
- `imageCache` já é limitado a 60 MB / 250 imagens (`main.dart:20-23`) — bem pensado.
- Hipótese: em 1 GB, qualquer pico (WebView de login AniList, download de modelo IA) pode empurrar o player para swap/reload. Medir `dumpsys meminfo`.

### 3.9 `hls-bitrate/dash-bitrate` não entregam o que prometem (fato do código + docs)
Ver §2.2. O app **acha** que força a melhor bitrate; para DASH nativo do ffmpeg isso é no‑op. Não é a causa do travamento, mas mostra que não há controle efetivo de bitrate no caminho mpv — o que importa para o plano.

### 3.10 Rede e firmware (ambiente; hipótese)
O H713 com WiFi 6 nominal pode ter antena/Throughput fracos; 5 GHz congestionado ou 2,4 GHz lento fazem buffer underrun mesmo com decode ok. Firmware de fabricante costuma ter menos buffering/TCP tuning. Medir com teste de banda no aparelho.

### 3.11 32 bits / thermals (ambiente; hipótese)
Userspace 32 bits e throttling térmico do projetor (lâmpada + SoC no mesmo corpo) reduzem clock sustentado. Medir `getprop` e clock sob carga.

---

## 4. Estratégias de melhoria (ordenadas por impacto × esforço)

### Camada A — Tirar o trabalho do aparelho (maior ganho, encaixa na arquitetura existente)

**A1. PC como proxy de mídia / transcoder (estender o LegendAI).**
Réplica do que já se fez para legenda IA (`plano-legendai-pc-remoto.md`): o app já sabe parear com o PC e enfileirar. Um endpoint novo `/v1/proxy` (ou `/v1/stream`) poderia:
- **Variante "remux"** (barata): baixar a representação escolhida (ex.: 720p H.264) e re‑servir como **MP4 progressivo** de variante única na LAN. Elimina do aparelho: DASH/HLS, ABR, parsing de manifesto, e — no caso HLS — o proxy Dart. Não resolve AV1 (o codec continua o mesmo).
- **Variante "transcode"** (definitiva): re‑encodar para **H.264 720p ~1,5–2,5 Mbps** (o plano do LegendAI já assume build `full,cuda`, com GPU no PC). O aparelho só decodifica H.264 de baixo bitrate — trivial para o H713. **Resolve AV1 + bitrate + CPU de uma vez.**
- Custo: banda na LAN (PC→projetor) e CPU/GPU do PC. No PC com NVENC, transcodificar 720p é mais rápido que tempo real.
- Encaixe: o app já tem `LegendAiConnection`, fila, e o servidor axum. É uma **Fase 6** natural.

**A2. Download antecipado (offline) para o aparelho.**
Reproduzir arquivo local elimina rede/adaptação. O app **não tem hoje** download de episódio (o "download" existente é de modelos/IA e do updater). Num 8 GB com 720p H.264 (~150–400 MB/ep) cabem alguns episódios. No aparelho fraco, ainda assim é melhor que streaming — e o PC pode fazer o download/transcode e o app baixar pela LAN.

### Camada B — Reproduzir a mídia certa (app; alto impacto, esforço baixo/médio)

**B1. Default de qualidade ciente do aparelho.** Em low‑end (ou quando o painel é 720p), abrir em **720p** ou **`Auto`** — nunca em 1080p. Fato de código: hoje é 1080p (§3.2). Implementação provável: um "teto de qualidade" no `sortBestFirst`/seleção inicial, lido de `SettingsService` (que já conhece `liteModeActive`). Também corrigir o caminho de legenda IA, que fixa `initialIndex: 0`.

**B2. Preferir H.264 e evitar AV1.** Quando houver escolha, ordenar/rotular para favorecer AVC/HEVC ≤720p e avisar sobre AV1. O app já detecta AV1 (`DashManifestProxy.videoCodecs`/`isAv1Only`, `dash_manifest_proxy.dart:361-392`); falta **usar isso para escolher a fonte** e não só para cair em software.

**B3. Transparência + "Modo econômico".** Mostrar codec/resolução/bitrate estimado no seletor de qualidade e oferecer um modo que **trava a qualidade máxima** (480p/720p). Isso dá ao usuário o controle que hoje o app esconde.

### Camada C — Remover overhead do app no playback (médio impacto, baixo risco)

**C1. HLS: não proxiar segmentos quando o Exo pode buscá‑los.** Manter o proxy só para o manifesto; deixar variantes/segmentos irem ao CDN com os `httpHeaders` do Exo. Testar em device — se o CDN aceitar o cliente do Exo, é ganho grande e barato (§3.3).

**C2. Render target do mpv em 720p.** `VideoControllerConfiguration(width: 1280, height: 720)` (ou menor) no `PlayerScreen` (§3.4). A própria lib recomenda para performance.

**C3. Alinhar o ExoDash ao padrão do PlayerScreen.** Trocar o `setState` de 2 Hz por `ValueNotifier` de posição/progresso, reconstruindo só a subárvore de progresso (§3.6).

**C4. Segurar prefetch/probes durante o playback em low‑end.** Adiar `_prefetchNextEpisode`, AniSkip e probes para depois do vídeo estabilizado, ou limitar concorrência (§3.7).

**C5. Reduzir trabalho de UI no player.** Overlays com gradiente/animacões já têm lever no modo lite para a UI geral; estender ao player ajuda pouco, mas é barato.

### Camada D — Ajustes de player (médio impacto, exige teste em device)

**D1. mpv mais leve.** Avaliar `profile=fast`, `hwdec=mediacodec`/`auto-safe`, `vd-lavc-threads` adequado, `video-sync=audio`, ajuste de `cache`/`demuxer-max-bytes` (default do media_kit = 32 MB, `platform_player.dart:530`), e `scale/dscale` (já `bilinear`, `real.dart:2397-2399`). **Medir**; não aplicar às cegas.

**D2. ExoPlayer.** O `video_player` expõe pouco; o que dá para controlar é o que o app já faz (filtrar o manifesto por altura) e o default de qualidade. Considerar unificar os provedores num único caminho com hardware decode confiável.

**D3. Não prometer `dash-bitrate`.** É no‑op (§3.9). A documentação interna já aponta isso; manter.

### Camada E — Sistema / ambiente (fora do app)

- **Desbloat**: congelar/remover apps de fabricante, desligar animações, reduzir serviços em segundo plano.
- **WiFi**: usar 5 GHz, testar banda; considerar adaptador **Ethernet USB** se o box suportar.
- **Térmico**: dar espaço/ventilação ao projetor (throttling reduz clock).
- **Verificar ABI** (32 vs 64 bits) e versão real do Android.
- Opcional/arriscado: ROM/AOSP customizada para H713 (fora de escopo; só citar).

### Camada F — O que já existe e deve ser preservado

- Modo lite automático por RAM (§2.5) — hoje só UI.
- Cap do `imageCache` (§3.8).
- Engine cacheada (bom para legenda IA, mas monitorar RAM).

---

## 5. Como medir e provar o gargalo (antes de mexer)

Sem medir, as recomendações são hipóteses. Checklist:

**5.1 Identidade e ABI**
```bash
adb shell getprop ro.product.cpu.abi      # 32 ou 64 bits?
adb shell getprop ro.build.version.release
adb shell getprop ro.product.model
```

**5.2 AV1 (o ponto decisivo)**
```bash
adb shell dumpsys media.codec | grep -i av01
# ou um app de teste / o próprio log do CodecsChannel
```
Se **não** aparecer `video/av01`, todo AV1 é software → prioridade máxima para A/B.

**5.3 CPU/RAM durante o playback**
```bash
adb shell top -m 10 -s cpu
adb shell dumpsys meminfo com.example.goanime_tv
```
Observar: processo do app a 300–400% de CPU = decode por software/peso; memória perto do limite = reload/engasgo.

**5.4 Isolar aparelho de rede/app**
- Reproduzir o **mesmo arquivo** com um player externo (VLC/Just Player/MX) a partir de um arquivo local 720p H.264. Se travar, o problema é o aparelho (decode/GPU/RAM); se rodar, é o app/rede/codec do stream.
- Testar o mesmo stream do app no VLC do aparelho: separa "stream ruim" de "player ruim".

**5.5 Logs do app**
```bash
adb logcat | grep -E "\[Player\]|\[ExoDash\]|\[DashProxy\]|videoParams|Duration|Completed|Loading timeout|Av1|hwdec"
```
- `videoParams`/`Duration` ausentes + `Loading timeout` (20 s) = falha de demux/rede.
- `Multicast`/`cache-buffering-state` alto = rede/bitrate.
- Uso de CPU alto com `hwdec` software = codec.

**5.6 Experimento controlado de qualidade**
No player, forçar **480p → 720p → 1080p** e comparar travamento/CPU. Se 480p/720p rodam e 1080p não, a Camada B resolve a maior parte.

**5.7 Experimento de rede**
Medir banda real (`iperf3` na LAN, speedtest no aparelho). Abaixo de ~5–6 Mbps estáveis, AnimeFire 720p já fica no limite.

---

## 6. Matriz de priorização

| # | Ação | Impacto | Esforço | Risco | Depende de device |
|---|---|---|---|---|---|
| A1 | PC proxy/transcoder H.264 720p | **Altíssimo** | Alto | Médio | Sim |
| A2 | Download offline de episódio | Alto | Médio/Alto | Baixo | Não |
| B1 | Default de qualidade ≤720p/Auto em low‑end | **Alto** | Baixo | Baixo | Recomendado |
| B2 | Preferir H.264 / evitar AV1 | Alto | Médio | Médio | Sim |
| C1 | HLS: não proxiar segmentos no Exo | Médio/Alto | Médio | Médio | Sim |
| C2 | Render target mpv 720p | Médio | Baixo | Baixo | Sim |
| C3 | ExoDash com ValueNotifier | Baixo/Médio | Baixo | Baixo | Não |
| C4 | Adiar prefetch/probes no playback | Baixo/Médio | Baixo | Baixo | Não |
| D1 | Tuning mpv (profile/hwdec/cache) | Médio | Médio | Médio | Sim |
| E | Desbloat/WiFi/ethernet/térmico | Médio | Baixo | Baixo | Sim |

---

## 7. Riscos e "não fazer"

- **Não** assumir que o H713 tem AV1 em HW — medir. Um fallback de software "que funciona" na verdade não sustenta 720p num A53.
- **Não** forçar `hwdec=no` globalmente: só faz sentido no AV1‑only. Para H.264/HEVC, hardware é o que salva.
- **Não** confiar em `dash-bitrate`/`hls-bitrate` para controlar bitrate (§3.9). O controle real, no Exo, é filtrar o manifesto por altura — e no PC, transcodar.
- **Não** remover o proxy de manifesto do AnimeFire sem teste: ele resolve o `.jpg` vs extensão e o filtro por qualidade.
- **Não** trocar `vo=gpu` por `mediacodec_embed` sem entender a dependência do `Texture` do Flutter (§3.5).
- **Não** baixar qualidade às cegas para todos os aparelhos: o teto deve ser por **capacidade** (modo lite/painel), não global.

---

## 8. Recomendação final (roadmap sugerido)

1. **Fase 0 — Medição (sem código).** §5, especialmente AV1 e o teste de qualidade 480/720/1080 no AnimeFire. Isso diz se o problema dominante é codec, bitrate ou rede.
2. **Fase 1 — Ganhos rápidos no app (baixo risco).** B1 (default de qualidade em low‑end), C2 (render target 720p), C3 (polling do ExoDash), C4 (adiar prefetch). Deve resolver boa parte do travamento em fontes H.264.
3. **Fase 2 — C1 (HLS direto no Exo) + B3 (transparência/modo econômico).** Reduz overhead e dá controle ao usuário.
4. **Fase 3 — PC proxy "remux 720p".** Reaproveita LegendAI; elimina adaptação ideal e simplifica o pipeline no aparelho.
5. **Fase 4 — PC transcode H.264 720p.** Solução definitiva para AV1/bitrate/CPU; habilita um "assistir pelo PC" que roda liso.
6. **Fase 5 — Download offline** (PC→aparelho ou direto), para quem quer garantia total.
7. **Paralelo — Sistema:** desbloat, 5 GHz/ethernet, ventilação.

**Resumo de uma frase:** o HY320 Mini é fraco, mas o app hoje o trata como se fosse forte (1080p por padrão, AV1 via software, segmentos HLS passando pelo Dart). O maior ganho vem de (1) **reproduzir ≤720p H.264** e (2) **deixar o PC entregar essa mídia pronta** — o resto é polimento.

---

## Anexo A — Pontos de código citados

**Players**
- `lib/features/player/player_screen.dart` — `Player()`/`VideoController` sem config (`153-154`); `sortBestFirst` e índice inicial (`225`); timeout 20 s (`270`); `hls/dash-bitrate` no‑op (`284-288`); AV1 `hwdec=no` (`312-320`); `demuxer-lavf-format=dash` (`325-331`); `ValueNotifier` de posição/duração (`62-65`, `382-396`).
- `lib/features/player/exo_dash_player_screen.dart` — proxy de manifesto (`205-211`); fallback AV1 → mpv (`218-225`, `725-745`); `networkUrl(httpHeaders:)` (`226-233`); polling `setState` 500 ms (`309-343`).
- `lib/features/player/dash_manifest_proxy.dart` — `serveManifest` (`59-88`); HLS full‑chain no loopback (`83-87`, `96-139`); handler (`149-212`); detecção de codec/AV1 (`361-392`).

**Resolução de qualidade/fonte**
- `lib/core/utils/quality_picker.dart` — `bestQualityIndex`/`sortBestFirst`/`qualityScore` (`10-42`).
- `lib/core/sources/anime_fire_adapter.dart` — emissão por qualidade + `Auto` (`412-451`); temporadas via `first_episode_number` (`225-276`, `296-362`).
- `lib/features/detail/detail_screen.dart` — escolha do player (`1343-1372`); ping de fontes (`1326-1333`); probe de legenda HLS (`1305-1321`).

**Modo lite / dispositivo**
- `lib/core/utils/device_capability.dart` — limiar 1,5 GB de `MemAvailable` (`9-11`, `16-41`).
- `lib/core/storage/settings_service.dart` — init lite (`89-128`); levers (`241-257`).
- `lib/main.dart` — cap de `imageCache` (`20-23`); `MediaKit.ensureInitialized` (`25`).
- `android/.../GoAnimeApp.kt` — engine cacheada no `Application`.

**Nativo**
- `android/app/src/main/cpp/CMakeLists.txt` — llama/STT só arm64/x86_64 (`18-51`).
- `android/app/src/main/kotlin/.../CodecsChannel.kt` — `supportsAv1` via `MediaCodecList` (`22-37`).

**Bibliotecas (pub-cache)**
- `media_kit_video-2.0.1/.../android_video_controller/real.dart` — `vo=gpu`, `hwdec=auto-safe`, `hwdec-codecs` inclui `av1` (`187-207`); ganho de render target pequeno (`214-215`).
- `media_kit_video-2.0.1/.../platform_video_controller.dart` — `VideoControllerConfiguration` (`76-133`).
- `media_kit-1.2.6/.../native/player/real.dart` — defaults (`cache-on-disk`, `hr-seek`, `scale=bilinear`) (`2388-2416`); `setProperty` ignora retorno (`1239-1245`).
- `media_kit-1.2.6/.../platform_player.dart` — `bufferSize` default 32 MB (`530`).

## Anexo B — Fontes de hardware

- linux-sunxi — H713 (Cortex‑A53, Mali‑G31 MP2, núcleo tipo H616): <https://linux-sunxi.org/H713>
- GadgetVersus — Allwinner H713 (~1,3 GHz): <https://gadgetversus.com/processor/allwinner-h713-specs/>
- Fichas de projetor H713 (1 GB+8 GB, 720p, Android 11, WiFi 6) — ex.: <http://www.kswtek.com/products/h5-allwinner-h713-projector>
- Fire TV Stick Lite (MT8695D @1,7 GHz, PowerVR GE8300, 1 GB, 1080p) — AndroidPCtv: <https://androidpctv.com/amazon-fire-tv-stick-lite-price-opinion/>; Canaltech ficha técnica.
- Relatórios internos: `relatorio-animefire-qualidade-nao-carrega.md` (probe do manifesto AnimeFire: 480p ~2,1 / 720p ~3,6 / 1080p ~8,7 Mbps), `relatorio-animefire-revisao-critica.md` §4.1 (`dash-bitrate` inexistente), `plano-legendai-pc-remoto.md` (arquitetura de PC/HTTP já existente).

> **Nota de método:** os números de bitrate vêm de probes de 10/09/2026 registrados nos relatórios; podem variar por episódio. As conclusões de hardware marcadas como "disputado" (AV1) devem ser confirmadas com o passo §5.2 neste aparelho específico.
