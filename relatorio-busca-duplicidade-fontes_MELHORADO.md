# Relatório Técnico Melhorado — Busca com Duplicidade entre Fontes

**Projeto:** GoAnime TV
**Data:** 2026-08-10
**Base:** `relatorio-busca-duplicidade-fontes.md` (aqui chamado de "plano original")
**Convenção de destino:** `*_MELHORADO.md` (mesma convenção de `.qa/`)
**Escopo:** revisão crítica do plano original + especificação corrigida e executável por outra AI. Nenhuma alteração de código foi feita nesta etapa.

---

## 0. Resumo do que mudou em relação ao plano original

Este documento corrige o plano original nos seguintes pontos (referenciados ao longo do texto como `C<n>`):

| # | Correção | Severidade |
|---|----------|-----------|
| C1 | A Fase 4 do plano (teste unitário com `AnimeRepository(adapters: [...])`) **é impossível**: `searchAnime` é estática, ignora `_adapters` do repositório e usa `SourceRegistry.adapters` (lista `static final`, sem injeção). | Fatal |
| C2 | O helper `animeIdentity` proposto (com `??`) colapsa as duas passadas numa única chave — comportamento **divergente** do planejado; e a passada 1 "antes do enrich" **não existe** no nível `searchAnime` (o enrich já rodou dentro de `_search`). | Alta |
| C3 | O critério de aceite "26 títulos distintos preservados" **está matematicamente errado**: `normalize` funde "One Piece –" com "One Piece" (a contração esperada). Números recalculados por query na seção 5. | Alta |
| C4 | **Gap real não coberto:** o badge "N/A A14" (ex.: "One Piece Film: Red" vs "One Piece Film: Red N/A A14") não é removido por `cleanTitle` nem por `normalize` → duplicata residual garantida no resultado final. | Média |
| C5 | Sem critério de desempate definido para representantes de mesma prioridade (ex.: 2 cards AnimeFire). | Média |
| C6 | Regra de propagação de metadados na fusão por `anilistId` indefinida (o que copiar, de quem, não sobrescrever bom com null, nome final). | Média |
| C7 | Expectativa "naruto → 1 card (com AniList OK)" não é garantida: no probe, `naruto`/`black clover`/`solo leveling` tiveram **0 anilistId** por rate-limit. Deve ser "best effort", não critério duro. | Média |
| C8 | Existem **duas ordens de prioridade diferentes** no repositório (`anime.dart` vs `SourceRegistry.getPriority`). O dedup precisa usar a mesma do sort final (`anime.dart`). | Média |
| C9 | Caminho de arquivo errado no plano: `anime_source_adapter.dart` fica em `lib/core/sources/`, não `lib/core/scraper/`. | Baixa |
| C10 | Racional enganoso: "passada 1 reduz volume para o AniList". Isso só valeria dentro de `_search`, e mesmo lá o `enrich` já deduplica por título limpo (cache + `_enrichInflight`). Redefinir o propósito da passada A. | Baixa |
| C11 | Duas gravações no mesmo cache com valores diferentes (`_search` grava lista plana; `searchAnime` gravaria deduplicada, mesma chave). Especificar local único. | Baixa |
| C12 | `normalize('') = ''` → chave vazia funde tudo. Exigir guarda/fallback. | Baixa |
| C13 | Também afetado: "Naruto Clássico" (Goyabu) é a mesma série de "Naruto" mas não funde por string; e a temporada 2 de "Solo Leveling" aparece em 3 grafias. Documentar como limitação residual, não prometer fusão. | Informativo |

As seções 1–4 reproduzem o diagnóstico correto do plano original (confirmado contra o código). O que foi **corrigido/refinado** começa na seção 5 (números recalculados), e a execução real está nas seções 6–8 (especificação) e 9–10 (plano e verificação).

---

## 1. Resumo Executivo

A busca por "one piece" no **GoAnime TV** retorna **51 resultados** agregados para apenas **26 títulos crus** — a série principal "One Piece" aparece **9×** (AnimeFire ×2, Goyabu ×2, DooPlay ×2, AnimesOnline, AnimeQ, AnimePlayer). Em "black clover": **24 resultados** para 6 títulos. Mesmo comportamento em "naruto" (59) e "solo leveling" (30).

**Causa raiz (confirmada):** `AnimeScraper._search` (`anime_scraper.dart:86-97`) concatena as `List<Anime>` de cada provedor **sem deduplicação**. Nenhuma chave de identidade é comparada para remover cards; o único "dedup" existente é o do `AniListService.enrich` (cache por título limpo), que só evita chamadas duplicadas à API, não remove cards.

**O que torna o dedup SEGURO (confirmado):** o grid de episódios não pertence ao provider — `DetailScreen` usa `getCatalogEpisodes` (grade canônica, `anime_repository.dart:56`) e `resolveProvidersForEpisode` (`anime_repository.dart:146`, fan-out em **todas** as fontes com `ProviderMatchStore`). O `anime.source` do card escolhido **não restringe** fontes de vídeo. Logo, um card representante por anime mantém o playback agregado intacto.

---

## 2. Metodologia

### 2.1 Arquivos revisados (caminhos corrigidos)

| Arquivo | Papel |
|---|---|
| `lib/core/scraper/anime_scraper.dart` | Agregação (`_search` fan-out), merge de variantes, `enrichBatch`, sort por prioridade, cache. **Sem dedup de cards.** |
| `lib/core/sources/anime_source_adapter.dart` | **Correção C9:** fica em `lib/core/sources/`, não `lib/core/scraper/`. Contém `normalize()` (dobra acentos, remove `dublado/legendado/dub/sub/todos os episodios`, pontuação) e `bestMatch()`. |
| `lib/core/sources/source_registry.dart` | `SourceRegistry.adapters` = lista `static final` (sem injeção). **C1.** |
| `lib/core/anilist/anilist_service.dart` | `enrich`/`enrichBatch` (pool de 6, gate de 800ms) anexam `anilistId`+metadados; dedup in-flight por título limpo. `httpOverride` existe (hook de teste). |
| `lib/core/cache/app_caches.dart` + `ttl_cache.dart` | Caches **em memória** (TTL 30 min para busca) — sem risco de cache persistido entre deploys. |
| `lib/data/models/anime.dart` | Modelo `Anime` (sem `==`), enum `AnimeSource` com `priority` (aqui: animeFire=0 ….. anilist=1 ….. allAnime=11). **C8.** |
| `lib/core/utils/text_utils.dart` | `cleanTitle`/`cleanSearchQuery`. `cleanTitle` **não** remove travessão "–" e **não** dobra o acento de "Episódios"; **não** remove badge "N/A A14". |
| `lib/data/repositories/anime_repository.dart` | `_adapters` só alimenta `resolveProvidersForEpisode`/`_episodeCountFromProviders`. `searchAnime` delega a `AnimeScraper.searchAnime` (estática). **C1.** |
| `lib/features/search/search_screen.dart` | Renderiza lista plana; contador `${_results.length} resultado(s)`. |

### 2.2 Probes

Dado real capturado em 2026-08-10: `.qa/dup_probe.txt`. Probes live ficam fora do CI e exigem `--dart-define=LIVE=1`.

---

## 3. Evidências (dados reais)

### 3.1 Agregados vs. distintos

| Query | Agregados | Títulos crus | Título principal (repetições) |
|---|---|---|---|
| `one piece` | 51 | 26 | "One Piece" — 9× (6 fontes) |
| `naruto` | 59 | 21 | "Naruto" — 7× (6 fontes) |
| `black clover` | 24 | 6 | "Black Clover" — 15× (8 fontes) |
| `solo leveling` | 30 | 7 | "Solo Leveling" — 12× (7 fontes) |

### 3.2 Caso "One Piece" (anilistId 21)

| Fonte | URLs | Qtd |
|---|---|---|
| AnimeFire | `/one-piece-dublado-todos-os-episodios`, `/one-piece-todos-os-episodios` | 2 |
| Goyabu | `/one-piece-dublado-online-hd-4`, `/one-piece-online-hd-3` | 2 |
| DooPlay | `/animes/one-piece-dublado-online-hd/`, `/animes/one-piece/` | 2 |
| AnimesOnline | `/anime/one-piece-dublado` | 1 |
| AnimeQ | `/anime/one-piece-dublado` | 1 |
| AnimePlayer | `/animes/one-piece/` | 1 |

**Fato novo (cobre C3):** o cluster também devolve "One Piece –" com **anilistId 171630** (6×: animesOnlineCloud, animesDrive ×2, animeQ, animePlay ×2 — URLs são as páginas principais `/anime/one-piece` do cluster). `normalize(cleanTitle("One Piece –")) == "one piece"` → sob a chave proposta, **estes 6 fundem com o "One Piece" (id 21)**. Ou seja, o plano original que promete "51 → 26 distintos preservados" está errado: espera-se 51 → ≈ 24–25. Decisão documentada na seção 6.

**Fato novo (cobre C4):** dois pares reais que não fundem nem com `cleanTitle` nem com `normalize`, por causa do badge "N/A A14":
- "One Piece Film: Red" (id 141902, URL `...-dublado-...`) vs "One Piece Film: Red N/A A14" (id null, URL `...-todos-os-episodios`) — o mesmo filme em 2 cards;
- "Black Clover: Mahou Tei no Ken" (2×) vs "Black Clover: Mahou Tei no Ken N/A A14" (1×) — o mesmo filme.

`cleanTitle` só remove rating+faixa etária na forma `\d(\.\d+)? A\d+` ("7.93 A14"); o "N/A A14" (alfa antes do A14) não bate no regex. Necessária regra extra na chave (C4, seção 6.1).

### 3.3 Caso "Naruto" (drift de título)

- "Naruto" — 7× (6 fontes).
- "Naruto Shippuden" — 9× (Goyabu/DooPlay/cluster/AnimePlayer).
- "Naruto: Shippuuden" (AnimeFire, 2×) + "Naruto Shippuuden" (cluster, 4×) — grafia "Shippuuden".
- **"Naruto Shippuden" ≠ "Naruto Shippuuden" sob `normalize`** (strings diferentes). Só o `anilistId` funde. **No probe, todos os ids de `naruto` vieram null** (rate-limit) → a fusão NÃO ocorre no ambiente observado. Ver C7.
- **Novo (C13):** "Naruto Clássico" (Goyabu, 2×) é a série principal "clássica" (mesmo anilistId real 1735) mas **não funde por string** com "Naruto". Resíduo esperado.

### 3.4 Caso "Black Clover" (sufixo " – Todos os Episódios")

"Black Clover – Todos os Episódios" (2×: AnimesDrive, AnimePlay) é a mesma série sob o rótulo do cluster. Verificação com `normalize(cleanTitle(x))`:
- `cleanTitle("Black Clover – Todos os Episódios")` → **inalterado** (o regex "todos os episodios" não casa "Episódios" acentuado; travessão fica);
- `normalize(...)` → dobra "ó", remove "todos os episodios" **depois** da dobra, remove o travessão → **"black clover"**. **Funde corretamente.**

Conclusão: o plano original estava certo na MECÂNICA para a categoria D, desde que a chave seja `normalize(cleanTitle(x))` (não `cleanTitle` sozinho).

### 3.5 Ruído (fora do escopo do dedup)

Cluster devolve animes não relacionados ("Cike Wu Liuqi –", "Fuufu Ijou…", "Love Live…", etc.) e lixo do AnimePlayer ("Naruto Hentai", "Naruto Alternativo Rsrs", "Solo Leveling Hentai"). Os duplicados do cluster (4× cada) serão naturalmente colapsados a 1 card pelo dedup — melhoria colateral **permitida**, mas a remoção ativa desses títulos fica **fora do escopo**.

---

## 4. Análise de Causa Raiz (atualizada com as linhas reais)

```
SearchScreen._performSearch
  └─ AnimeRepository.searchAnime            (anime_repository.dart:45)
       └─ AnimeScraper.searchAnime          (anime_scraper.dart:18)
            ├─ cacheKey = query.toLowerCase()        (:22)
            ├─ cached?  → retorna (mesma chave usada por _search!)   (:23-24)
            ├─ allAnimes = _search(query)            (:26)
            │    └─ _search: fan-out paralelo por adapter (:70-84)
            │        allAnimes.addAll(result)        (:86-97)  ← SEM DEDUP
            │        removeWhere(!hasValidId)        (:102-121)
            │        AniListService.enrichBatch       (:126)    ← já enriquece aqui
            │        AppCaches.search.set(cacheKey,…) (:128)    ← grava lista PLANA
            ├─ Fase 1: variantes do AniList só se vazio (:32-45, dedup interno por cleanTitle)
            ├─ AniListService.enrichBatch(allAnimes)  (:49)     ← 2ª vez (cache hit na maioria)
            ├─ sort por source.priority (estável)     (:52)
            └─ cache.set(cacheKey, allAnimes)         (:54)     ← sobrescreve com dedup (após a mudança)
```

**Constraint (C2/C11):** `_search` **já executou `enrichBatch` e gravou no mesmo `cacheKey`** antes de `searchAnime` retornar. Portanto: (a) a "passada 1 antes do enrich" do plano original **não é possível** no ponto descrito; o dedup real vai operar sobre dados já enriquecidos (o objetivo "diminuir chamadas ao AniList" já é atendido pelo cache por título do `enrich` — C10); (b) o local único e determinístico é em `searchAnime`, **antes do sort e da gravação do cache**, com as passadas A (título) e B (`anilistId`) sequenciais.

---

## 5. Números recalculados (critério de aceite correto)

Recalculei as previsões **usando a própria chave proposta** (`normalize(cleanTitle(nome))`, com strip do badge "N/A A14" — C4), item a item, sobre o dump de `.qa/dup_probe.txt`. **Não** usar "títulos crus distintos" como alvo; usar estas tabelas.

### 5.1 `one piece` — 51 → **≈ 24** cards (passada A)

| Chave (normalizada) | Cards fundidos | Champion provável |
|---|---|---|
| `one piece` | 9 ("One Piece") + 6 ("One Piece –", id 171630) = 15 → 1 | AnimeFire (prio 0, id 21) |
| `one piece gyojin tou hen` | 4 ("…Tou-hen") + 4 ("…Tou-hen – Todos os Episódios") = 8 → 1 | AnimeFire (id 183423) |
| `one piece heroines` | 5 → 1 | Goyabu (id 197178) |
| `one piece movie 8 episode of alabasta …` | 2 → 1 | AnimeFire |
| `one piece a serie` | 2 → 1 | Goyabu |
| `one piece film red` | 1 | AnimeFire (id 141902) |
| `one piece film red n a a14` | 1 ← **resíduo sem C4** | AnimeFire (id null) |
| demais títulos | 1 cada (3D2Y, Luffy-Hand 2, Z, Gold, Stampede, Taose, Nebulandia, Nami, Sorajima, Merry, Movie 6/7/9/4, Strong World, Heart of Gold, Koisuru) | — |

> Com a correção C4 (badge "N/A A14" na chave), `one piece film red n a a14` funde com `one piece film red` → **23 cards**. A passada B pode fundir `one piece a serie` (se enrich der id 21) → 22–24. Aceite: **22–24 distinct**, jamais 26.

### 5.2 `naruto` — 59 → **≈ 19** cards (passada A)

| Chave | Fundidos | Resíduo |
|---|---|---|
| `naruto` | 7 → 1 | — |
| `naruto shippuuden` | AnimeFire 2 ("Naruto: Shippuuden") + cluster 4 ("Naruto Shippuuden") = 6 → 1 | **gêmeo com `naruto shippuden` abaixo** |
| `naruto shippuden` | Goyabu 2 + DooPlay 2 + cluster 4 = 9 → 1 | idem |
| `naruto classico` | 2 → 1 | mesma série de `naruto` (id real 1735), **não funde por string** |
| `boruto naruto next generations` | 4 + 4 ("… – Todos os Episódios") = 8 → 1 | — |
| `boruto naruto the movie` | 2 → 1 | — |
| filmes/specials | 1 cada (Rock Lee SD, Shippuuden Movies 4/2/6/3, Naruto Movie 2, The Last) | — |
| ruído cluster | `cike wu liuqi`, `fuufu ijou koibito miman`, `love live superstar 3`, `negative positive angler` → 1 cada | colateral aceitável |
| lixo | `naruto hentai`, `naruto alternativo rsrs` → 1 cada | mantido (fora do escopo) |

> Só se a passada B conseguir anilistId **nos dois** "Shippuden/Shippuuden" (id 1735) é que eles fundem → **18 cards**. No probe (rate-limit), ficam 19. **Não prometer fusão como critério duro** (C7).

### 5.3 `black clover` — 24 → **5** cards (passada A) / **4** com C4

| Chave | Fundidos |
|---|---|
| `black clover` | 15 + 2 ("– Todos os Episódios") = 17 → 1 |
| `black clover mahou tei no ken` | 2 → 1; + 1 ("…N/A A14") **se C4 aplicado** |
| `mugyutto black clover` | 3 → 1 |
| `black clover a espada do rei mago` | 1 → 1 |

### 5.4 `solo leveling` — 30 → **7** cards

Todos os agrupamentos internos colapsam para 1 cada. Resíduos **familiares** (não são duplicatas por fonte, são grafias de obras distintas): "Ore dake Level Up na Ken" (AF), "Ore dake … Season 2: Arise…" (AF), "Solo Leveling 2" (Goyabu), "Solo Leveling 2 Arise from the Shadow" (cluster), "Solo Leveling Segundo Despertar" (filme). **Não** tentar fundir por string (C13).

---

## 6. Especificação corrigida do dedup (executável)

### 6.1 Chave de identidade por título (função pura, no `TextUtils` ou `AnimeScraper`)

```dart
// Passo 1 (chave forte por título). Sem `??` com anilistId — ver C2.
// Corrige C4: remove badge "N/A A14"/"N A14" no FIM do título.
String titleIdentityKey(Anime a) {
  var t = AnimeSourceAdapter.normalize(TextUtils.cleanTitle(a.name));

  // C4: badge de faixa etária com rating ausente ("One Piece Film: Red N/A A14").
  // Depois do normalize, "N/A A14" virou "n a a14". Remover sufixo "n a? a? <digits>".
  t = t.replaceAll(RegExp(r'\bn\s*a\s*a?\s*\d+\s*$'), '').trim();

  // C12: chave vazia (nome só com pontuação/símbolos) fundiria tudo.
  if (t.isEmpty) t = a.name.trim().toLowerCase();
  if (t.isEmpty) t = a.url; // último recurso; nunca colidir em ''
  return t;
}

// Chave para a passada B (fusão por id).
int? anilistIdentityKey(Anime a) => a.anilistId;
```

Regras de implementação:
- **Reusar `AnimeSourceAdapter.normalize`** (import de `lib/core/sources/anime_source_adapter.dart` em `anime_scraper.dart` é aceitável; esse arquivo já importa `sources/source_registry.dart`). **Não** mover `normalize` para `TextUtils` nesta entrega — é mudança de comportamento sem necessidade (o plano original deixou essa dúvida, risco 3; decisão: manter onde está).
- O regex "N/A A14" é um parâmetro; validar com os dois pares reais da seção 3.2 (C4) num teste puro.

### 6.2 Passadas (local único: `AnimeScraper.searchAnime`, antes do sort)

Fluxo corrigido **após** a obtenção de `allAnimes` (linha 26–45 do código atual):

```
1. Passada A (por título):  agrupar por titleIdentityKey;
       representante = min(source.priority); empate → primeiro no array
       (índice menor). Manter sempre um Anime com url válida.
2. enrichBatch(survivors)   (cache hits na maioria; mantém paridade de metadata)
3. Passada B (por anilistId): entre os SURVIVORES da A,
       agrupar por anilistId não-nulo; fundir grupos >1 no representante
       de menor priority; propagar metadados (6.3).
4. sort por source.priority (já existe, linha 52)
5. cache.set (já existe, linha 54) → grava a lista DEDUPLICADA
```

Por quê **esse** ponto (C2/C11):
- `_search` **não é alterado** (nem seu cache de lista plana) — evita duas fontes de verdade.
- A passada A *pré-enriquecimento* do plano original é descartada de propósito (C10): o ganho de "menos chamadas ao AniList" já vem do cache por título limpo do `enrich` + `_enrichInflight`; rodar A antes só complicaria.
- **Decisão C3 (importante para o executor):** "One Piece –" (id 171630) **deve fundir** com "One Piece" (id 21). A passada A roda primeiro e colapsa pelo título; o champion recebe o id do próprio título (21). O id 171630 do membro descartado é **descartado de propósito** — não tentar "preservá-lo" na passada B. Se isso um dia se provar errado (obras de fato distintas com mesmo título normalizado), o ajuste é na chave, não na passada B.

### 6.3 Representante e propagação de metadados (C5, C6)

- Escolha do representante (passada A e B): `(url válida) → menor source.priority → menor índice no array de entrada`. O sort da linha 52 usa `source.priority` de `anime.dart`; **usar exatamente essa ordem** (C8) — atenção: `SourceRegistry.getPriority` tem outra ordem e **não** deve ser usado aqui.
- Sempre manter a `url` do próprio representante (não pegar de um membro qualquer do grupo).
- Fusão B: para o representante `S` com duplicata `D` de mesmo `anilistId`:
  - `S.anilistId ??= D.anilistId`
  - `S.englishName ??= D.englishName`
  - `S.bannerImage ??= D.bannerImage`
  - `S.description ??= D.description`
  - `S.fallbackImageUrl ??= D.fallbackImageUrl`
  - `S.episodes ??= D.episodes`
  - `S.status ??= D.status`
  - `S.averageScore ??= D.averageScore`
  - `S.genres = D.genres.isNotEmpty ? D.genres : S.genres`
  - **Regra:** usam `??=` (nunca sobrescrever valor bom com null). `genres` trata lista vazia como "faltando".
- **Nome exibido (C6):** manter `S.name` do representante (maior prioridade). **Não** reescrever nomes — favoritos e progresso são chaveados por `anime.name` (`LocalStorage.isFavorite`/`getWatchProgress` em `detail_screen.dart`); renomear quebraria consistência. Efeito colateral (aceito): favoritos antigos gravados sob o nome de uma fonte que "perdeu" (ex.: favoritar via card do cluster "Naruto Shippuuden" e depois ver o card "Naruto Shippuden") continuam existindo no storage, mas não aparecem como "favoritado" no novo card. Documentar, não corrigir nesta entrega.

### 6.4 Guardas adicionais

- C12: `titleIdentityKey` nunca pode retornar `''`.
- Não deduplicar por `animesOnlineCloud` vs `animesDrive` como um grupo à parte — a chave de título já os funde naturalmente via `AnimesOnlineAdapter` repetido no `SourceRegistry` (4 instâncias).
- Não remover os itens de ruído/hentai (3.5) — só o que o dedup por chave colapsar.

---

## 7. Alternativa considerada e descartada (memória de decisão)

- **Dedup só na UI (SearchScreen):** descartado — vazaria duplicata pelo cache de busca e não centralizaria a regra; o cache passaria a guardar state visual.
- **Chave única `anilistId ?? titleIdentityKey` (função `animeIdentity` do plano original, C2):** descartado — impossibilita a propagação de metadados entre grupos e o caso "mesmo título, ids diferentes" fica inconsistente; o comportamento deixa de ser o das duas passadas documentadas.
- **Mover `normalize` para `TextUtils` (risco 3 do plano original):** descartado nesta entrega — sem ganho, com risco de regressão em `bestMatch`.

---

## 8. Riscos e considerações (corrigido)

1. **Rate-limit do AniList invalida `anilistId` como chave única (C7, observado no probe: 0 ids em `naruto`/`black clover`/`solo leveling`).** A passada A é obrigatória e é quem entrega o impacto principal; a B é best-effort. Critério de aceite **não** pode exigir a fusão "Shippuden/Shippuuden".
2. **Drift de título sem AniList** ("Shippuden/Shippuuden", "Naruto" vs "Naruto Clássico", "Solo Leveling 2" vs "…2 Arise from the Shadow") não funde por string. Solução futura: mapa de sinônimos/canonicalização — **fora do escopo**, documentado.
3. **Over-merge por título (C3):** obras distintas que compartilham nome normalizado colapsam (ex.: "One Piece" + "One Piece –"). Aceito para grid de busca; paralelismo a evitar está documentado em 6.2.
4. **Badge "N/A A14" (C4):** requer a regra extra da seção 6.1; sem ela há resíduo garantido (seção 5.1/5.3).
5. **Cache (C11):** `AppCaches.search` é em memória (TTL 30 min) — sem risco de cache persistido entre deploys. Depois da mudança, a entrada do cache passa a ser a lista deduplicada (escrita por `searchAnime` 6.2-passo5). `_search` mantém o cache por consulta interna inalterado.
6. **Determinismo (C5/C6/C8):** representante por `(priority, índice)`, ordem estável, e `source.priority` de `anime.dart` (não `SourceRegistry.getPriority`).
7. **Ruído (3.5):** colapsado pela chave quando for duplicata; remoção ativa fora do escopo.
8. **Testes (C1):** dedup como função pura testável (seção 9); o pipeline agregador continua sem injeção de adapters — não prometer teste de integração unitário.

---

## 9. Plano de Implementação (corrigido — para outra AI executar)

### Fase 1 — Função pura de identidade

Implementar `titleIdentityKey(Anime)` e `anilistIdentityKey(Anime)` (seção 6.1), com:
- chave por título: `normalize(cleanTitle(nome))` + strip "N/A A14" + guarda de vazio (C12);
- **sem** `??` com anilistId (C2);
- decisão de local: função `static` em `AnimeScraper` (ou `TextUtils`), reusando `AnimeSourceAdapter.normalize` via import (decisão 6.1).

### Fase 2 — Dedup na agregação (local único)

No `AnimeScraper.searchAnime`, **após** o fluxo atual das linhas 26–45 e **antes** do `sort`/`cache.set` (linhas 52/54), aplicar passada A + B conforme 6.2/6.3. **Não** tocar em `_search` (excepto, opcional, trocar o dedup interno das variantes — linhas 37–41 — para usar `titleIdentityKey` por consistência).

Estrutura de retorno: `List<Anime>` pura (representantes). Se a Fase 3 (selo "N fontes") for feita, retornar um wrapper `Anime` + `sourceCount` (mapa fora do `Anime` — não adicionar campo no modelo para não mudar estrutura serializada do cache sem necessidade).

### Fase 3 — UI (opcional, baixo esforço)

- Contador da busca passa a refletir o número deduplicado automaticamente (nenhuma mudança em `SearchScreen`).
- Selo "N fontes": requer preservar o grupo da Fase 2 (conjunto de `AnimeSource` por chave). Se adotado, fazer junto da Fase 2 (estrutura de retorno); senão, marcar fora do escopo desta entrega.

### Fase 4 — Verificação (corrigida — C1)

**4a. Testes de função pura (offline, sem rede) — obrigatórios.** Montar `Anime` à mão e assertar sobre `titleIdentityKey`/dedup:
- B: dois `Anime` AnimeFire — dublado e legendado — com nomes já limpos → mesma chave → 1 representante (maior prioridade, índice menor);
- D: `"Black Clover – Todos os Episódios"` e `"black clover"` → mesma chave (travessão + acento, 3.4);
- C4: `"One Piece Film: Red N/A A14"` == `"One Piece Film: Red"`; `"Black Clover: Mahou Tei no Ken N/A A14"` == `"Black Clover: Mahou Tei no Ken"`;
- C3: `"One Piece –"` == `"One Piece"` → 6+9 cards → 1;
- Drift offline: `"Naruto Shippuden"` ≠ `"Naruto Shippuuden"` (chaves distintas) — assertar que **não** fundem por string;
- Fusão B: dois representantes com `anilistId` igual e títulos diferentes → 1 card, metadados propagados com `??=` (não null sobre bom);
- Desempate: mesmo `source.priority` → vence índice menor;
- Guarda: nome só com pontuação → chave não-vazia.

**Não** implementar o teste que o plano original descrevia (`AnimeRepository(adapters: [...])` + `searchAnime`): `searchAnime` ignora `_adapters` do repositório e `SourceRegistry.adapters` é `static final` (C1). O teste de pipeline unitário exigiria refatorar injeção — **fora do escopo desta entrega**.

**4b. Probe live (fora do CI, `--dart-define=LIVE=1`).** Re-rodar o probe e validar contra os números da seção 5 (não contra "distinct raw"):
- `one piece` → 51 → entre 22 e 24 (23 esperado com C4 e passada B ok);
- `black clover` → 24 → 4–5 ("Mahou Tei no Ken" + "N/A A14" fundidos se C4 ativo);
- `naruto` → 59 → 18–19 (**não** exigir fusão Shippuden/Shippuuden — C7);
- `solo leveling` → 30 → 7;
- regressão de playback: abrir o representante e validar que `resolveProvidersForEpisode` segue agregando todas as fontes (backend está fora da busca; não deve haver mudança).

---

## 10. Conclusão

O diagnóstico original está correto (falta dedup na agregação em `AnimeScraper`), mas o plano de execução tinha um erro fatal de testabilidade (C1), uma ambiguidade de design na chave única (C2), critérios de aceite matematicamente errados (C3), um gap real de normalização de badge (C4) e várias regras indefinidas (C5–C8). Este relatório reespecifica:

- uma chave pura por título + uma chave por `anilistId` (sem `??`);
- duas passadas sequenciais e **local único** em `searchAnime` (antes do `sort`/`cache.set`);
- regras exatas de representante, desempate e propagação de metadados;
- números de aceite recalculados a partir do `.qa/dup_probe.txt` (22–24 / 18–19 / 4–5 / 7);
- teste offline **da função pura** (viável) em vez do teste impossível do pipeline, mais o probe live.

Resultado esperado: a busca mostra um card por título real de cada série (e suas variações legítimas), sem repetições por fonte, com zero mudanças na resolução de episódios (que já é multi-fonte e independe do card escolhido).