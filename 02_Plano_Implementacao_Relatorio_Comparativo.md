# Plano de Implementação — Recomendações do Relatório Comparativo GoAnime TV × AnimeCaos

> **Documento de arquitetura** · Flutter / Android TV
> Autor: arquitetura GoAnime TV · Versão 1.0 · Data: 07/08/2026
> Base: [`06_Relatorio_Comparativo_AnimeCaos.md`](06_Relatorio_Comparativo_AnimeCaos.md)
> Escopo confirmado com o usuário (Q&A): **itens 1–6** como fases executáveis;
> itens 7–8 (preview no foco, downloads) como **roadmap anexo**.
> Nenhuma mudança de código nesta etapa — apenas o plano.

---

## Sumário

- [0. Decisões de escopo](#0-decisões-de-escopo)
- [Fase 0 — Spike: live probe do AnimesOnlineCC](#fase-0--spike-live-probe-do-animesonlinecc)
- [Fase 1 — Busca com variantes de query (item 2)](#fase-1--busca-com-variantes-de-query-item-2)
- [Fase 2 — Adapter AnimesOnlineCC (item 1)](#fase-2--adapter-animesonlinecc-item-1)
- [Fase 3 — Melhor qualidade automática (item 4)](#fase-3--melhor-qualidade-automática-item-4)
- [Fase 4 — Prefetch do próximo episódio (item 3)](#fase-4--prefetch-do-próximo-episódio-item-3)
- [Fase 5 — Rate limiter único do AniList (item 6)](#fase-5--rate-limiter-único-do-anilist-item-6)
- [Fase 6 — Status/erro AniList no UI + cache em disco (item 5)](#fase-6--statuserro-anilist-no-ui--cache-em-disco-item-5)
- [Fase 7 — Integração e regressão](#fase-7--integração-e-regressão)
- [Roadmap — itens 7 e 8](#roadmap--itens-7-e-8)
- [Ordem de execução e dependências](#ordem-de-execução-e-dependências)
- [Lacunas conhecidas e aberturas](#lacunas-conhecidas-e-aberturas)

---

## 0. Decisões de escopo

Confirmadas com o usuário:

1. **AnimesOnlineCC:** só implementar após um **spike de validação live** (Fase 0),
   porque o diagnóstico `.qa/RELATORIO_DIAGNOSTICO_PROVIDERS.md` mostra que
   Goyabu/DooPlay/AnimePlayer morreram por stream entregue só via token
   `blogger.com/video.g?token=...` recuperável apenas por SPA JS anti-bot. Se o
   spike provar que o iframe do AnimesOnlineCC também cai nesse muro, o adapter é
   **descartado com evidência** (decisão de não-implementar), não assumido.
2. **Escopo:** itens 1–6 são fases ativas; 7–8 ficam no roadmap anexo.
3. **Variantes de busca:** disparar **somente quando o fan-out original (query
   limpa) retornar vazio**, limitando custo de rede (cada variante ≈ 5 requests).

### Contexto do estado atual relevante para as fases

| Área | Estado real no HEAD |
|---|---|
| Fontes de vídeo ativas | Apenas `AnimeFireAdapter` entregando vídeo de fato; `Goyabu`, `DooPlay`/`BetterAnime`/`AnimesROLL`, `AnimePlayer` com busca/episódios OK mas `resolveVideo` retornando `[]` (token Blogger SPA). `AllAnime` desativado (`implemented=false`). |
| Catálogo | 100% AniList (`AniListService._catalog`), sem status tipado, cache só em memória (`AppCaches`). |
| Busca | `AnimeScraper.searchAnime` faz um único fan-out com a query limpa; sem variantes. |
| Enriquecimento | `searchAnime` faz `Future.wait` de `AniListService.enrich` por título (rajada sem pacing — raiz do rate-limit, ver Fase 5). |
| Player | `PlayerScreen` inicia em `initialIndex` (default 0 = primeira fonte da lista, não necessariamente a melhor qualidade); autoplay com countdown 10s; `_playNextEpisode` re-resolve fontes do ep seguinte (lento). |
| Persistência | `SharedPreferences` via `LocalStorage`/`AnilistAuthService`; cache de listas AniList já em disco (`lists_cache`); catálogo trending/season **não** persiste. |

---

## Fase 0 — Spike: live probe do AnimesOnlineCC

**Objetivo:** responder com evidência se `animesonlinecc.to` é implementável
com `http` + `html` apenas (como afirma o relatório) ou se cai no mesmo muro
Blogger/SPA dos outros 3 adapters. **Gate de entrada da Fase 2.**

### Passos

1. Criar `test/live_animesonlinecc_probe_test.dart`, espelhando o padrão de
   `test/live_sources_probe_test.dart` (requer `--dart-define=LIVE=1`, roda do
   host). O probe deve, para 3 animes (ex.: "One Piece", "Naruto", "Re:Zero"):
   - `GET https://animesonlinecc.to/search/<termo com +>` → **confirmar o seletor**
     do resultado. O relatório diz `div.data > h3 > a`; validar no HTML real
     (pode ser `.data > h3 > a` ou `.data h3 a`).
   - Abrir a página do anime → localizar `<ul.episodios>` e validar o agrupamento
     por temporada (T1/T2/T3).
   - Abrir a página de um episódio → listar todos `iframe[src]` e classificar o
     host de cada um:
     - `blogger.com/video` (ou `blogspot`) → **não reproduzível** (mesmo muro).
     - **mp4/m3u8 direto** no HTML ou em página-iframe acessível por HTTP
       estático (com Referer) → **reproduzível**.
     - Player JS (JWPlayer etc.) com token preenchido por script → **não
       reproduzível**.
2. Registrar o resultado em `.qa/` (padrão `RELATORIO_DIAGNOSTICO_PROVIDERS.md`).

### Critérios de decisão

| Resultado do spike | Decisão |
|---|---|
| ≥1 stream direto (mp4/m3u8) via HTTP estático | Implementar Fase 2 completa |
| Só Blogger/JS-token (irrecuperável sem browser) | **Não implementar**; registrar em README como "descartada: mesma causa dos 3 adapters" |
| Site fora do ar / DNS | Não implementar; registrar |

### Verificação

`flutter test --dart-define=LIVE=1 test/live_animesonlinecc_probe_test.dart`

---

## Fase 1 — Busca com variantes de query (item 2)

**Objetivo:** reduzir "não achei" para títulos cujo site indexa por outro nome
("Re:Zero" vs "re zero", romaji vs EN), reusando a busca existente.

### Decisão de arquitetura

Variantes **só** quando o fan-out original retornar vazio (decisão Q&A). A ordem
das tentativas segue o relatório (`_search_with_translation` do AnimeCaos):
1. Query original limpa (comportamento atual).
2. **Expansão de palavras agregadas:** `"rezero" → "re zero"`, `"re zero" →
   "rezero"`, e variantes de concatenar/dividir pares de tokens adjacentes.
3. **Variantes via AniList:** buscar o Media por título e usar os títulos
   `romaji`/`english`/`native` como novas queries.
4. **Primeiro token** quando o título contém `:` (ex.: `"Re:Zero kara..."`).

### Implementação

**Novo: `lib/core/scraper/search_variants.dart`**
- `List<String> generateVariants(String query)` — puro e testável:
  - se `query` não tem espaço: para cada posição, `query.substring(0,i) + ' ' +
    query.substring(i)` (reject dividir em vogal/consoante ruidosa se trivial);
    cap de ~8 variantes.
  - `removeColonToken(query)`: se contém `:`, retorna o segmento antes do `:`.
- `List<String> anilistVariants(String query)` — chama
  `AniListService.getTitleVariants(query)` (nova API, ver abaixo) e retorna os
  títulos distintos ≠ query. **Somente se o AniList estiver saudável** (respeita
  o gate da Fase 5; não disparar quando `AniListService.lastErrorStatus` for
  erro — senão a variante derruba o rate limit).

**Editar `AniListService` (`lib/core/anilist/anilist_service.dart`)**
- Nova `static Future<List<String>> getTitleVariants(String query)`:
  GraphQL `Media(search: $query, type: ANIME) { title { romaji english native } }`,
  reusando `_catalog`-like helper sem token, cache em `AppCaches.enrichment`.
  Sem `anilistId` novo — só títulos para gerar queries.

**Editar `AnimeScraper.searchAnime` (`lib/core/scraper/anime_scraper.dart:18`)**
- Após o fan-out atual (linhas 26–78), se `allAnimes` ficar vazio:
  1. `final variants = [...generateVariants(query), ...anilistVariants(query)]`
     (dedup, máx. 5 tentativas extras).
  2. Para cada variante: chamar um refactor do corpo atual em
     `Future<List<Anime>> _searchOnce(String q)` (o corpo dos passos atuais
     extraído), com `AppCaches.search` chaveado pela variante.
  3. Parar na primeira variante que retorne resultados não vazios.
  4. Merge final: dedup por `url`/nome e ordenação por prioridade (comportamento
     atual preservado).

> **Ponytail:** o corpo de `searchAnime` é extraído uma única vez para
> `_searchOnce`; a busca por variantes é um loop sobre ele. Não criar abstração
> de "SearchStrategy" — um `for` resolve.

### Riscos e limites

- Rajada extra de rede: mitigada pelo gate "só em vazio" + cap de tentativas.
- Variante AniList pode disparar GraphQL em cenário já degradado: guard por
  `AniListService.lastErrorStatus` (da Fase 6) e pelo throttle da Fase 5.
- `AnimeScraper.bestMatch` (`lib/core/sources/anime_source_adapter.dart:98`) já
  ranqueia candidatos; reutilizar como critério de "variante boa" (escolher a
  variante cujos resultados têm melhor bestMatch) só se custar < 10 linhas.

### Testes

- `test/search_variants_test.dart`: `generateVariants("rezero")` contém
  `"re zero"`; `removeColonToken("Re:Zero")` → `"Re"`; dedup e cap.
- `test/search_variants_test.dart` (mocked, padrão `ptbr_adapters_test.dart`):
  `searchAnime` com adapter fake que devolve vazio para `"rezero"` e resultados
  para `"re zero"` → resultado final não vazio; e que **não** chama variantes
  quando a primeira busca retorna resultados.

### Critérios de conclusão

- `searchAnime("rezero")` para um título indexado como "re zero" retorna
  resultados sem interação do usuário.
- Buscas com resultado normal não disparam variantes (zero requests extras).

---

## Fase 2 — Adapter AnimesOnlineCC (item 1)

**Pré-requisito:** Fase 0 com veredito "implementar".

### Implementação

**Novo: `lib/core/sources/animesonlinecc_adapter.dart`** (espelho da estrutura
do `dooplay_adapter.dart`/`anime_fire_adapter.dart`):
- `baseUrl = 'https://animesonlinecc.to'`, `_httpGet` via `apiClient` singleton
  (reuso do cache/retry/429 da `ApiClient`), `implemented => true`.
- `search(query)`: `GET /search/<TextUtils.treatName(query).replaceAll('-', '+')>`
  (validar separador `+` no spike); parsear o seletor confirmado na Fase 0
  (relatório: `div.data > h3 > a`), montando `Anime(name, url, source)`.
- `getEpisodes(anime)`:
  - Parsear `<ul.episodios>` **da temporada atual** (T1).
  - **Saltar temporadas retroativamente** (paradigma do relatório, seção 4):
    depois de carregar a página, registrar T2/T3 apenas se presentes no DOM —
    sem round-trips extras durante a busca.
  - Números de episódio: usar `Episódio N` do slug quando disponível (como o
    DooPlay faz com regex em `_episodeNumber`).
- `getVideoSources(episode, anime)`:
  - Abrir a página do episódio, pegar `iframe[src]`.
  - **Rejeitar** iframe `blogger.com/video` (não reproduzível — mesmo muro dos 3).
  - Para o(s) iframe(s) restante(s): seguir o padrão validado na Fase 0
    (mp4/m3u8 direto no HTML, ou 1–2 hops HTTP com `Referer`).
  - Retornar `List<VideoSource>` com `headers: {User-Agent, Referer: baseUrl}`.
- **`isEpisodePlayable` barato** (heurística do relatório, seção 4): um
  `Future<bool> isEpisodePlayable(Episode)` que faz um `GET` leve na página do
  episódio e devolve `false` se o HTML contém `blogger.com/video`. Opcional no
  v1 — usar dentro de `getEpisodes` para **não listar** episódio morto, com
  cache de 10 min por URL (`AppCaches.httpResponses`).

**Editar `lib/data/models/anime.dart`**
- Adicionar `AnimeSource.animesOnlineCC` ao enum (após `animePlayer`).
- Atualizar os switches exaustivos:
  - `sourceName` → `'AnimesOnlineCC'`.
  - `isPtBr` → incluir o novo valor.
  - `priority` → decidir na Fase 2 (proposta: `2`, entre `goyabu` e
    `betterAnime`; subir após validação em campo — knob de um valor).

**Editar `lib/core/sources/source_registry.dart`**
- Registrar o adapter em `_adapters` (após `AnimePlayerAdapter()`).
- Adicionar caso em `forSource` e em `getPriority`.
- `fallbackOrder`: incluir `AnimeSource.animesOnlineCC` (ordem conforme
  `priority` decidida).

**Editar `lib/core/scraper/anime_scraper.dart:63`** — `hasValidId`: novo case
`AnimeSource.animesOnlineCC` → `a.url.isNotEmpty` (como as outras fontes de URL).

**Editar `lib/features/detail/detail_screen.dart`**
- Mensagens de estado vazio (linhas ~407–446 e ~896–947): incluir
  "AnimesOnlineCC" na lista de fontes de stream.

### Riscos

- **Mesmo muro Blogger/SPA** (por isso a Fase 0 gate). Se o stream direto for
  raro, o adapter fica com baixa taxa de sucesso — reavaliar `implemented`.
- Markup instável (seletor da busca/temporadas): coberto por testes mocked com
  HTML capturado no spike.

### Testes

- `test/animesonlinecc_adapter_test.dart` (mocked, padrão `ptbr_adapters_test.dart`):
  - busca parseia cards; `getEpisodes` parseia temporadas T1+T2 e salta
    retroativas; `getVideoSources` rejeita iframe `blogger.com/video` e extrai
    mp4 direto; `isEpisodePlayable` false para página com `blogger.com/video`.

### Critérios de conclusão

- Spike verde (Fase 0) + adapters registrado com busca/episódios/stream
  cobertos por teste mocked + `flutter analyze` limpo.
- Pelo menos 1 anime resolvido de ponta a ponta via AnimesOnlineCC no
  `test/live_sources_probe_test.dart` estendido.

---

## Fase 3 — Melhor qualidade automática (item 4)

**Objetivo:** no fluxo automático (autoplay/auto-next/abrir episódio), tocar a
melhor qualidade por padrão; manter o seletor para troca manual.

### Implementação

**Novo helper: `lib/core/utils/quality_picker.dart`**
```dart
/// Rank: 1080 > 720 > 540/480 > 360 > 240 > Auto/outros.
int qualityRank(String q);            // parseia "1080p"/"720p"/"Auto"/"360p"...
int pickBestQualityIndex(List<VideoSource> sources); // índice da melhor
```
- Qualidade ausente (label vazio/"Auto"): tratado como último recurso — nunca
  fica na frente de uma qualidade rotulada (mesma filosofia do
  `_pick_best_source` do AnimeCaos).

**Editar `lib/features/player/player_screen.dart`**
- `_initPlayer` (linha 110): quando `initialIndex` não for passado
  explicitamente pelo usuário (autoplay/`pushReplacement`), usar
  `pickBestQualityIndex(sources)` em vez de `0`.
- `_showQualitySelector` (linha 897): continua listando tudo; nenhuma mudança.

**Editar `lib/features/detail/detail_screen.dart`** — `_ProviderQualityDialog`
- A seleção automática do provider já pega o de melhor prioridade
  (`_resolveProviders`, linha 733). Para a qualidade: default da lista passa a
  `pickBestQualityIndex(sources)` quando o usuário apenas confirma
  (auto-seleção visual marca a melhor, sem trocar o fluxo de tap-para-escolher).

### `--hls-bitrate=max` (mpv) — verificação, não promessa

- O relatório sugere repassar `--hls-bitrate=max` ao media_kit. **Verificar no
  dia 1** se o `media_kit`/`libmpv` deste projeto permite injetar opções mpv por
  media/player (`PlayerConfiguration`/builder). Se não houver API estável:
  **não implementar** e documentar o motivo (a seleção por URL já cobre o caso
  PT-BR, onde cada qualidade é uma URL distinta; e o mpv já prefere a maior
  banda em HLS variante por default).
- Marcar no README/plan: pendência de verificação, não bloqueante das demais
  fases.

### Testes

- `test/quality_picker_test.dart`: `pickBestQualityIndex([720p, 1080p, Auto])` →
  índice do `1080p`; lista só `Auto` → índice 0; ordem reversa também funciona.
- Player: o autoplay abre no índice da melhor qualidade (teste de widget, se
  custar pouco; senão assert no helper e QA manual).

### Critérios de conclusão

- Autoplay/auto-next inicia na melhor qualidade sem clique extra.
- Seletor de qualidade intacto para troca manual.

---

## Fase 4 — Prefetch do próximo episódio (item 3)

**Objetivo:** enquanto o episódio atual toca, resolver em background os streams
do próximo; autoplay fica instantâneo (URL já em cache).

### Implementação

**Editar `lib/features/player/player_screen.dart`**
- Novo campo `Future<Map<AnimeSource, List<VideoSource>>>? _nextPrefetch;` e
  `Map<AnimeSource, List<VideoSource>>? _prefetchedNext;`.
- Disparar o prefetch quando o episódio **estiver pronto** (`_videoReady` em
  `_listenStreams`, linha 227) OU no início do countdown de autoplay
  (`_triggerAutoNext`, linha 383), se `episodeIndex + 1` existir:
  ```dart
  _prefetchNext() async {
    if (_prefetchedNext != null) return;
    final f = _repo.resolveProvidersForEpisode(widget.anime, widget.episodeIndex + 2);
    _prefetchedNext = await f; // results já cacheados em AppCaches.resolutions
  }
  ```
  Fire-and-forget com try/catch (não acoplar rede ao playback).
- `_playNextEpisode` (linha 400): passar ao novo `PlayerScreen`:
  - `initialSources: _prefetchedNext?[widget.provider] ?? null` — o player novo
    pula o re-resolve (a `resolveProvidersForEpisode` do ep seguinte também é
    deduped pelo cache de 30 min de `AppCaches.resolutions`, então o autoplay
    nunca re-busca).
  - `initialIndex: -1` marcando "autopick" (ver Fase 3).

> **Ponytail:** o ganho real vem do cache `AppCaches.resolutions` + do
> `ProviderMatchStore` persistido — o prefetch apenas **adianta** o trabalho que
> o pushReplacement faria, sem novo armazenamento.

### Riscos

- Prefetch de um ep que o provider não tem → retorna vazio, sem efeito colateral
  (mesmo caminho do fluxo normal).
- Concorrência com o `_loadTimeout` do ep atual: prefetch usa a mesma
  `resolveProvidersForEpisode`, já isolada por try/catch.

### Testes

- Teste unitário: `_prefetchNext` popula `_prefetchedNext` com o resultado
  cached de `resolveProvidersForEpisode` (mock do repo) e `_playNextEpisode`
  repassa `initialSources` do provider escolhido.
- QA manual no emulador: autoplay abre o ep seguinte sem o dialogo de carregar
  fontes (sem "Procurando fontes...").

### Critérios de conclusão

- Autoplay ep+1 inicia a reprodução sem re-resolução de rede visível.
- Nenhuma mudança de comportamento quando `_prefetchedNext` é nulo (fallback).

---

## Fase 5 — Rate limiter único do AniList (item 6)

**Objetivo:** uma única fonte de verdade de pacing para chamadas a
`graphql.anilist.co`, para que um `enrich` em lote (ou a home) não derrube o
`updateProgress`/login com rate-limit.

### Contexto do problema no nosso código

Há **4 call sites** separados para `graphql.anilist.co`, sem pacing comum:
- `_graphQL` (autenticado: listas, progresso, login) — `anilist_service.dart:354`
- `_catalog` (trending/season) — `:441`
- `_fetchDetail` (enrich por título) — `:548`
- `getEpisodesV2` — `:595`

E a rajada concreta: `AnimeScraper.searchAnime` faz
`Future.wait(allAnimes.map((a) => AniListService.enrich(a)))`
(`anime_scraper.dart:82`) — até ~50 chamadas paralelas numa busca. É a
equivalência exata do bug descrito no relatório ("a busca de sinopses de ~50
cards derrubava o login").

### Implementação

**Editar `lib/core/anilist/anilist_service.dart`**
1. **Gate de pacing global** (espelho do `_throttle` do AnimeFire):
   ```dart
   static DateTime _lastGraphqlAt = DateTime.fromMillisecondsSinceEpoch(0);
   static const anilistRequestGap = Duration(milliseconds: 800); // 75/min < 90/min
   static Future<void> _gateAnilist() async { ... espera o gap ... }
   ```
   Chamar `_gateAnilist()` no **início** de `_graphQL`, `_catalog`,
   `_fetchDetail` e `getEpisodesV2` (uma única linha por call site; o helper é
   compartilhado — corrige a causa na origem, não por tela).
2. **Cap de concorrência para lote de enrich**:
   - Novos `static Future<void> enrichBatch(List<Anime>)` que roda `enrich` com
     pool de **6 em 6** (sem dep nova — micro-semáforo de ~10 linhas com lista
     de futures, `dart:async` já importado).
   - `AnimeScraper.searchAnime` linha 82 passa a chamar `enrichBatch` no lugar de
     `Future.wait`.
   - `HomeScreen._loadAnimeListsFromScrapers` (`home_screen.dart:123-134`) também
     usa `enrichBatch` indiretamente via `searchAnime` (o fan-out de
     `_defaultQueries` chama `_repo.searchAnime`, que por sua vez enriquece).

> **Ponytail:** gate + pool de 6. Sem fila distribuída, sem classe "RateLimiter",
> sem dependência nova. O gate é o pacing; o pool impede a rajada paralela.

### Tradeoff documentado

- O relatório sugere 0.8s **globais** (AnimeCaos faz exatamente isso). Efeito
  colateral: o enrich de uma busca agora é serializado/dividido, aumentando a
  latência de telas que enriquecem muitos títulos. **Mitigações:**
  - `SettingsService.anilistEnrichInSearch` (modo lite) já pula enrich — mantido.
  - Constante `anilistRequestGap` única = **knob de calibração** (comentar o
    ceiling no código: "global, per-account/por-tipo se throughput importar").
  - Se a latência incomodar, revisar o gap para ~0.4s **depois** de medir com o
    pool de 6 (o pool sozinho já reduz o burst).

### Testes

- `test/anilist_rate_limit_test.dart`: dois call sites concorrentes
  (`_catalog` + `enrich`) não disparam juntos — com `clientOverride` do
  `ApiClient` ou um `http` fake, verificar que o segundo request só inicia após
  o gap (timestamps de entrada registrados por um stub).
- `enrichBatch` com 12 títulos não dispara > 6 `_fetchDetail` simultâneos
  (contador no mock).

### Critérios de conclusão

- Nenhum lote dispara rajada > 6 no AniList; nenhuma chamada começa antes do gap
  configurado; `updateProgress`/login não são derrubados por enrich de busca.

---

## Fase 6 — Status/erro AniList no UI + cache em disco (item 5)

**Objetivo:** dar feedback categorizado no home quando o AniList falha
(offline/rate-limit/bloqueio) e persistir trending/temporada em disco para o
catálogo continuar funcional **offline** (cache de 4h, por janela).

### Implementação

**Editar `lib/core/anilist/anilist_service.dart`**
1. Novo enum + estado:
   ```dart
   enum AniListStatus { ok, offline, ipBlocked, rateLimited, authError, serverError }
   static AniListStatus lastErrorStatus = AniListStatus.ok;
   ```
2. Mapear falhas nos 4 call sites (uma função `_classifyFailure(res/exception)`):
   - Timeout/SocketException/`http` unreachable → `offline`
   - status `429` → `rateLimited`
   - status `403`/Cloudflare 1020 (corpo `"1020"`) → `ipBlocked`
   - status `401`/`400` → `authError` (já dispara `logout()` em `_graphQL`)
   - `5xx`/JSON `errors` → `serverError`
   - Sucesso → reset `AniListStatus.ok`.
   Setar `lastErrorStatus` no catch de `_catalog`/`_fetchDetail`/`_graphQL`/
   `getEpisodesV2` (reusar o mesmo ponto onde hoje só há `debugPrint`).
3. **Cache em disco do catálogo** (padrão do `lists_cache` já existente em
   `AnilistAuthService`):
   - Em `_catalog` (linha 441): no sucesso, persistir o JSON dos animes em
     `SharedPreferences` chave `anilist_catalog:<hash das variables>` com
     timestamp; no **erro**, ler o cache de disco se tiver < 4h
     (`AppConstants.requestTimeout` e a constante `catalogDiskTtl = 4h`).
   - Chave por janela (trending ≠ season) para o refresh da home não misturar.

**Editar `lib/features/home/home_screen.dart`**
- Banner de status: entre o top bar e o conteúdo, se
  `AniListService.lastErrorStatus != ok` (verificado em `_loadAnimeLists` e
  `_checkAnilist`), mostrar um banner com mensagem por tipo:
  - `offline` → "Sem conexão com o AniList — usando catálogo em cache."
  - `rateLimited` → "AniList limitou requisições — tentaremos de novo em breve."
  - `ipBlocked` → "AniList bloqueou este IP — catálogo segue do cache."
  - `authError` → "Sessão do AniList expirou — faça login novamente."
  - `serverError` → "AniList instável no momento."
  - Estilo do `AnilistBanner`/`AnimatedContainer` já existente (gradiente/borda),
    com botão de dismiss opcional.
- Nada de new dependency: `SharedPreferences` e os widgets atuais bastam.

> **Ponytail:** o banner é UMA condição no build do home; o cache de disco são
> duas linhas no `_catalog`. Não criar um "health monitor" com timer — o status
> é um efeito colateral das chamadas existentes.

### Testes

- `test/anilist_catalog_cache_test.dart`: `_catalog` com erro escreve nada e lê
  do disco; sucesso persiste; TTL de 4h respeitado (usar `shared_preferences`
  mock/`SharedPreferences.setMockInitialValues`).
- `test/anilist_status_test.dart`: classificação de 429/403/401/timeout/5xx
  (mock de `http.Client`).

### Critérios de conclusão

- Home mostra banner correto por tipo de falha; catálogo trending/season
  funciona offline com dados ≤ 4h.
- `lastErrorStatus` é resetado para `ok` em qualquer sucesso subsequente.

---

## Fase 7 — Integração e regressão

Rodar no fim de cada fase (e uma vez ao final):

1. `flutter analyze` — cobre os switches exaustivos do enum (Fase 2) e refactors.
2. `flutter test` — suíte completa; especialmente `bestmatch_test.dart`,
   `catalog_resolver_test.dart`, `resolve_anime_regression_test.dart`,
   `sources_corrections_test.dart`, `ptbr_adapters_test.dart`.
3. `flutter test --dart-define=LIVE=1 test/live_sources_probe_test.dart` —
   confirmar que as fontes ativas seguem OK e que o AnimesOnlineCC (se
   aprovado) resolve ≥1 anime de ponta a ponta.
4. QA emulador/Fire Stick (padrão `.qa/emu_*`): busca vazia → variantes;
   autoplay instantâneo; qualidade default = melhor; banner AniList offline
   (desligar rede).

---

## Roadmap — itens 7 e 8

> Não incluídos nesta rodada (decisão Q&A). Documentados para desenho futuro.

### Item 7 — Preview no foco TV (equivalente ao hover do AnimeCaos)

- **Objetivo:** ao focar um card (D-pad), mostrar nota + sinopse num painel
  lateral (TV não tem mouse).
- **Abordagem lazy proposta:** reusar `AniListService.enrich` **sob demanda no
  foco** (1 chamada por card, nunca pré-buscar a fila — lição do AnimeCaos);
  exibir num overlay/painel fixo da Home ou num `Dialog` tipo "Ficha rápida".
- **Pendência de design:** posição do painel vs rolagem horizontal; não fazer
  até que o enrich já esteja protegido pelo gate da Fase 5.

### Item 8 — Downloads offline

- **Objetivo:** "assistir offline" (streaming falha em rede fraca é caso real).
- **Abordagem no Android (sem yt-dlp):** reusar `resolveProvidersForEpisode` →
  escolher a melhor URL **mp4** (HLS m3u8 exigiria montar segmentos; escopo
  maior) → `http.get(...)` em streaming para `path_provider` → biblioteca local
  que lista por anime e permite deletar (espelho do `downloads_service.py`).
- **Pendências de decisão:** UI de fila + progresso com D-pad; limpeza de
  espaço; comportamento de m3u8 (aceitar só mp4 no v1 ou montar segments).
- **Esforço:** feature de produto (dias), não um diff.

---

## Ordem de execução e dependências

```
Fase 0 (spike AnimesOnlineCC)  ──→  Fase 2 (adapter)   [se spike verde]
Fase 1 (variantes busca)          ── independente ──→  Fase 5 (rate limiter) ──→  Fase 6 (status+cache)
Fase 3 (auto-qualidade)           ── independente ──
Fase 4 (prefetch)                 ── depende só do player ──
Fase 7 (regressão)                ── ao final de tudo
```

Sugestão de lote para **PR 1** (independentes e de menor risco):
Fases 3 + 4 (player: auto-qualidade + prefetch) e Fase 1 (variantes).
**PR 2:** Fase 5 (gate AniList) antes de 6 — o rate limiter é pré-requisito para
qualquer rajada nova (variantes com AniList já usam o gate).
**PR 3:** Fase 0 → 2 (AnimesOnlineCC, contingente ao spike).
**PR 4:** Fase 6 (banner status + cache em disco).

---

## Lacunas conhecidas e aberturas

| # | Lacuna | Status | Quem resolve |
|---|---|---|---|
| 1 | Markup real do AnimesOnlineCC (busca, temporadas, iframe) | Aberta — **Fase 0** decide | Spike live (host) |
| 2 | Capacidade de injetar `--hls-bitrate=max` no media_kit | Aberta — **Fase 3** verifica; se inviável, drop documentado | Verificação no dia 1 |
| 3 | Prioridade final de `animesOnlineCC` no fallback | Default `2`; revisar após validação em campo | Decisão pós-PR3 |
| 4 | Latência do enrich com gate 0.8s global | Medir; knob `anilistRequestGap` | Pós-PR2, com pool de 6 |
| 5 | Base URL/estado atual de `animesonlinecc.to` | Spike confirma site no ar e seletor | Fase 0 |

> Nenhuma suposição vaga foi embutida: as decisões de escopo, disparo de
> variantes e a contingência do AnimesOnlineCC foram confirmadas com o usuário
> antes de escrever este plano.

---

_Fim do plano. Implementar por fase; cada fase termina com seus critérios de
conclusão verdes antes de avançar. Ao final de cada PR, seguir `agents/git.md`._
