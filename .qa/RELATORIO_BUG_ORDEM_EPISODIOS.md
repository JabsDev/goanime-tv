# Relatório de Investigação — Episódios em ordem/quantidade erradas (One Piece, Black Clover)

**Data:** 08/08/2026
**Escopo:** Diagnóstico apenas. **Nenhum código foi alterado ou criado** nesta etapa.
**Device:** Fire Stick 4K (`100.66.110.37:5555`) — build instalada = `app-release.apk` (SHA1 `f182948b…`, build 08/08 00:54, HEAD~1). Emulador não foi tocado.
**Objetivo:** dar contexto completo para outra IA corrigir os bugs.

---

## 1. Resumo executivo

Há **dois bugs distintos** no fluxo de episódios:

1. **Grade (catálogo) com contagem errada e ordem embaralhada**
   A grade de episódios é montada exclusivamente pelo AniList (`getEpisodesV2`), que usa o campo `streamingEpisodes` e **numera cada episódio pela POSIÇÃO no array**, não pelo número real do episódio. O AniList devolve esse array **parcial e fora de ordem** (ex.: One Piece → 69 itens, episódios reais 62→130, em ordem **decrescente**). Resultado: a grade mostra “EP 1..69” com títulos/episódios 130→62. É exatamente o sintoma relatado: *“One Piece retornou 69 episódios em ordem aleatória”*.

2. **Black Clover: fonte encontrada, mas nenhum vídeo resolve (0 sources)**
   O matching da fonte (AnimeFire) **funciona** (a página da série principal é achada). O problema é a **extração de vídeo**: as páginas de episódio do Black Clover (1–169) embutem somente um iframe/token `blogger.com/video.g?token=…` (player SPA anti-bot, sem `.mp4/.m3u8` no HTML), e o resolvedor do app não consegue transformar esse token em stream → `getVideoSources` retorna vazio → “Nenhuma fonte disponível”. Só o ep. 170 (recem-indexado) usa a API nova (`animefire.io/video/…`) e funciona. Reproduzido no host, independente da rede do Fire Stick.

O primeiro bug explica “quantidade/ordem erradas”; o segundo explica *“não encontra na fonte, mas manualmente tem”* (a série tem 170 eps; o app só não consegue extrair o stream de quase todos).

---

## 2. Evidência do Bug 1 (grade: contagem + ordem)

### 2.1 Código responsável

- `lib/core/anilist/anilist_service.dart:920-979` — `getEpisodesV2(mediaId)`:
  - **Linha 921-922:** exige token (logado). Deslogado → retorna `[]` e a grade cai no fallback 1..N (por isso o bug só aparece logado).
  - **Linhas 928-940:** query GraphQL `Media(id) { streamingEpisodes { title thumbnail url site } }` — **sem número de episódio**.
  - **Linhas 965-973:** `List.generate(streaming.length, (i) => AniListEpisode(number: '${i + 1}', …))` → **numera por posição do array**. O número real do episódio é ignorado.
- `lib/data/repositories/anime_repository.dart:40-54` — `getCatalogEpisodes` converte em `CatalogEpisode(number: int.parse(e.number))` e ordena por esse número (ordenação estável preserva o array). **Não há validação** contra `anime.episodes` nem fallback quando a lista vem diferente do total.
- `lib/features/detail/detail_screen.dart:111-128` — carrega a grade; `:140-143` e `:726-731` — ao tocar, resolve o vídeo **pelo número do grid** (`resolveProvidersForEpisode(anime, widget.episode.number)`).

### 2.2 Resposta real do AniList (verificada via GraphQL hoje)

`Media(id: 21)` — ONE PIECE:

```
title: ONE PIECE | episodes: null | status: RELEASING
streamingEpisodes: 69 itens
primeiro item: "Episode 130 - Scent of Danger! ..."   ← começa no 130!
último item : "Episode 62 - The First Line of Defense ..."
ordem do array: 130, 129, 128, ..., 62  (DECRESCENTE)
```

O grid renderizado pelo app (simulando `getEpisodesV2` + `getCatalogEpisodes` sobre esse payload):

```
grid# | EP real | título (streamingEpisodes)
  1   |   130   | Episode 130 - Scent of Danger! ...
  2   |   129   | Episode 129 - It All Started On That Day! ...
  3   |   128   | Episode 128 - The Pirates' Banquet ...
  ...
 69   |    62   | Episode 62 - The First Line of Defense ...
```

Enquanto a **fonte real** (AnimeFire `animefire.io/animes/one-piece-todos-os-episodios`) lista **1.172 episódios em ordem crescente** (verificado por scrape).

### 2.3 Consequências

- **Contagem errada:** 69 cards em vez de ~1.172.
- **Ordem errada:** card “EP 1” é na verdade o episódio 130; “EP 69” é o 62.
- **Mismatch label × playback:** o card mostra o título do episódio real X, mas o toque resolve o vídeo do episódio **do número do grid** (número da posição). Ou seja, o usuário pode tocar num card com título “Episode 130” e o player abrir o episódio 1 da fonte.
- **Progresso corrompido:** `_reconcileWithAnilist` (`detail_screen.dart:73-109`) e `updateProgress` (`anilist_service.dart:458-482`) mapeiam índices de uma grade embaralhada → progresso do AniList pode subir/descer episódios errados.

### 2.4 Por que Black Clover (ordem) pode ter aparecido errado também

Para `Media(id: 97940)` (Black Clover, FINISHED) o `streamingEpisodes` **hoje** está completo e crescente (170, 1→170) — por isso o *bug de ordem* do BC não reproduz no momento:

```
streamingEpisodes: 170 itens | ordem: 1,2,3,...,170 | cobertura 1–170
```

Conclusão: o campo `streamingEpisodes` do AniList é **não-autoritativo e mutável** (lista parcial de “episódios em streaming”, na ordem em que o site parceiro entrega). Quando ele é completo e ordenado (BC agora) a grade sai certa por sorte; quando é parcial/desordenado (One Piece agora, e BC em algum momento anterior/outro estado), a grade quebra. O cache em memória da grade tem **TTL de 24h** (`lib/core/cache/app_caches.dart:33-36`), então um grid quebrado fica “colado” por até um dia.

---

## 3. Evidência do Bug 2 (Black Clover: fonte achada, vídeo não)

### 3.1 Código responsável

- `lib/core/sources/anime_source_adapter.dart:48-60` (`resolveAnime`) e `:96-153` (`bestMatch`) — acham a página da série. **Funcionam**.
- `lib/core/sources/anime_fire_adapter.dart:240-261` (`getVideoSources` → `_extractFromAnimeFire`):
  - Método 1 (`[data-video-src]`) linha 302 — não existe no HTML do BC.
  - Método 3/5 Blogger (`_extractFromBlogger`) linhas 318-330 / 349-353 e 433-595 — não extrai nada do SPA do Blogger.
- `lib/data/repositories/anime_repository.dart:65-90` (`resolveVideo`) → `resolveProvidersForEpisode` retorna mapa vazio → UI “Nenhuma fonte disponível”.

### 3.2 Probe live no host (Linux, mesmas libs do app)

```
==== Black Clover ====
  search OK 5 results
     Black Clover: Mahou Tei no Ken -> .../black-clover-mahou-tei-no-ken-dublado-todos-os-episodios
     Black Clover: Mahou Tei no Ken N/A A14 -> .../black-clover-mahou-tei-no-ken-todos-os-episodios
     Black Clover -> .../black-clover-dublado-todos-os-episodios
     Mugyutto! Black Clover -> .../mugyutto-black-clover-todos-os-episodios
     Black Clover -> .../black-clover-todos-os-episodios
  bestMatch -> Black Clover (https://animefire.io/animes/black-clover-todos-os-episodios)
  resolveAnime -> https://animefire.io/animes/black-clover-todos-os-episodios
  EP1  video: 0 sources
  EP2  video: 0 sources
  EP62 video: 0 sources
  EP130 video: 0 sources
```

Comparação — **One Piece** no mesmo probe: `bestMatch` correto e **EP1/2/62/130 → 1 source cada** (a página usa a API nova).

### 3.3 Inspeção direta do HTML das páginas de episódio

| Página | `animefire.io/video/…` (API) | `data-video-src` | iframe Blogger `video.g?token=` | mp4/m3u8 no HTML |
|---|---|---|---|---|
| BC ep 1  | 0 | 0 | **1** | 0 |
| BC ep 50 | 0 | 0 | **1** | 0 |
| BC ep 100| 0 | 0 | **1** | 0 |
| BC ep 170| **1** | **1** | 0 | 0 |
| OP ep 130| **1** | **1** | 0 | 0 |

Resposta do `blogger.com/video.g?token=…` (curl, mesmo UA/Referer do app): HTTP 200, **HTML do player SPA (`/_/BloggerVideoPlayerUi`)** com **zero** `.mp4`, `.m3u8`, `googlevideo.com`, `videoplayback` ou redirect → o `_extractFromBlogger` não tem o que extrair.

### 3.4 Conclusão do Bug 2

- **Não é** Cloudflare, rede, timeout ou falha de matching.
- É **defasagem do resolvedor de vídeo** com o markup do AnimeFire para séries hospedadas em Blogger (Google). O BC (1–169) está nesse backend; o OP, na API nova.
- Isso já havia sido registrado em `.qa/RELATORIO_DIAGNOSTICO_PROVIDERS.md` (seção final): tokens `video.g` só recuperáveis via browser headless (SPA anti-bot).

---

## 4. Caminho de verificação executado

1. **Código:** `anime_repository.dart`, `anilist_service.dart` (`getEpisodesV2`), `anime_source_adapter.dart` (`resolveAnime`/`bestMatch`/`resolveVideo`), `anime_fire_adapter.dart`, `detail_screen.dart`, `home_navigation.dart`, `app_caches.dart`, `provider_match_store.dart`.
2. **AniList GraphQL (live):** `Media(id:21)` e `Media(id:97940)` → `streamingEpisodes` (conteúdo + ordem). Payloads salvos em `/tmp/opencode/{op,bc}_result.json`.
3. **Fontes (live, host):** search AnimeFire para “Black Clover” e “One Piece”; páginas `todos-os-episodios` (contagem/ordem: BC 170, OP 1172, ambos crescentes); páginas de episódio (backends de vídeo).
4. **Probe Flutter temporário (removido após a execução)** no host reproduzindo `search`→`bestMatch`→`resolveAnime`→`resolveVideo` — BC 0 sources, OP 1 source.
5. **Fire Stick:** build instalada identificada (SHA1 == release 08/08 00:54); app logado (lista de “Continue assistindo” populada via AniList); telas capturadas via adb (análise visual limitada pelo modelo de visão, por isso a evidência dura veio do host + API).

---

## 5. Impacto / achados secundários

- O bug 1 só ocorre **logado** (sem token, `getEpisodesV2` retorna `[]` e o fallback 1..N é correto).
- Não há validação/healing: se `streamingEpisodes` vier não-vazio, ele **vence** a grade, mesmo com 69 itens para uma obra de 1.172 (a caída `_episodeCountFromProviders` de `anime_repository.dart:66-71` só roda quando a lista vem **vazia**).
- `AnimeFireAdapter.getEpisodes` (`anime_fire_adapter.dart:196-204`) também numera por posição (`entry.key + 1`), mas hoje o site lista em ordem crescente — frágil por construção, mas correto no estado atual.
- `getEpisodesV2` guarda o `site` no campo `description` do `AniListEpisode` (`anilist_service.dart:970`) — detalhe cosmético/atípico.
- Goyabu/DooPlay/AnimePlayer já estavam documentados como não-resolvedores de vídeo (tokens blogger/jwplayer) — fonte efetiva é só AnimeFire (ver `.qa/RELATORIO_DIAGNOSTICO_PROVIDERS.md`).

---

## 6. Direções de correção (NÃO aplicadas — apenas orientação)

### Bug 1 — grade (recomendado: resolver na fonte do grid)
1. **Parar de numerar `streamingEpisodes` por posição.** Se o título carrega o número (“Episode N - …”), extraí-lo e montar `CatalogEpisode(number: N)` de verdade (e filtrar os que não casam).
2. **Validar contra o total:** quando `anime.episodes` é conhecido e diferente do tamanho da lista v2, usar o range 1..N (fallback já existente) e usar o streaming apenas para decorar títulos/thumbs por número.
3. **Ordernar por número real** e **deduplicar** (um episódio não pode aparecer 2×).
4. **Grid nunca deve vir de um campo não-autoritativo** (streamingEpisodes é “disponibilidade de streaming”, não catálogo canônico); a fonte de contagem confiável é `anime.episodes`/fallback provider.
5. Reavaliar `_reconcileWithAnilist`/`updateProgress` para trabalharem com o **número real** do episódio, não índice do grid.

### Bug 2 — Black Clover / séries em Blogger
1. Resolver o token `video.g` via **browser headless / serviço de proxy** (recuperação real do stream), ou
2. Sinalizar essas séries como “episódio indisponível nesta fonte” com mensagem clara em vez de “Nenhuma fonte disponível”, e
3. Idealmente: tentar os adapters restantes (goyabu/dooplay/animePlayer) para essas séries após consertar os resolvedores deles (que estão defasados do markup atual).

### Regressão
- Testes com payload real (op/bc_result.json) cobrindo: lista parcial, lista decrescente, lista com números não-sequenciais e série RELEASING (`episodes:null`).

---

## 7. Repro – passo a passo (para validar a correção depois)

1. Host (sem device): rodar `getEpisodesV2` contra o payload de One Piece → a grade deve sair **correta** (1..N com títulos casados por número real), nunca 69 itens descendentes.
2. Host: `search('Black Clover')` → `bestMatch` → `resolveVideo(match, 1)` → deve retornar ≥1 source (ou mensagem tratada), nunca 0 silencioso.
3. Fire Stick (logado): abrir One Piece na lista de “Continue assistindo” → grade deve listar de “EP 1” (título real ep 1) em diante com total correto (~1.172).
