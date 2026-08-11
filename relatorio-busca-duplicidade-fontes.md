# Relatório Técnico — Busca com Duplicidade entre Fontes

**Projeto:** GoAnime TV
**Data:** 2026-08-10
**Escopo:** Análise e plano de implementação para eliminar a repetição do mesmo anime vindo de fontes diferentes na tela de busca. Nenhuma alteração de código foi feita nesta etapa.

---

## 1. Resumo Executivo

A busca por "one piece" no **GoAnime TV** retorna **51 resultados** agregados, mas apenas **26 títulos distintos** — a série principal "One Piece" aparece **9 vezes** (AnimeFire ×2, Goyabu ×2, DooPlay ×2, AnimesOnline, AnimeQ, AnimePlayer). Em "black clover" a situação é pior: **24 resultados** para **6 títulos**, com "Black Clover" aparecendo **15 vezes** em 8 fontes.

**Causa raiz:** o pipeline de agregação (`AnimeScraper.searchAnime`) concatena a lista plana de cada provedor **sem nenhuma etapa de deduplicação**. Cada fonte retorna o mesmo anime com seu próprio objeto `Anime` (título/URL daquela fonte), e o grid da busca exibe todos eles lado a lado, indistinguíveis.

O problema tem **4 categorias** distintas, cada uma exigindo tratamento próprio:
1. **Mesmo título, fontes diferentes** (o caso relatado) — "One Piece" em 6 fontes.
2. **Mesmo título, mesma fonte, variante dublado/legendado** — AnimeFire serve `...-dublado-todos-os-episodios` e `...-todos-os-episodios` como cards separados.
3. **Drift de título entre fontes** — "Naruto Shippuden" (Goyabu/DooPlay/AnimePlayer) vs "Naruto Shippuuden" (cluster AnimesOnline) são o MESMO anime escrito de formas diferentes.
4. **Sufixo não normalizado " – Todos os Episódios"** — o cluster AnimesOnline rotula sob `nome – Todos os Episódios`, e o `cleanTitle` atual não funde com o título base porque não remove o travessão nem resolve acento na palavra "Episódios".

---

## 2. Metodologia

### 2.1 Análise de código (arquivos revisados)

| Arquivo | Papel |
|---|---|
| `lib/core/scraper/anime_scraper.dart` | Agregação da busca: fan-out paralelo por fonte, enriquecimento AniList, ordenação por prioridade. **Sem dedup.** |
| `lib/data/repositories/anime_repository.dart` | Porta da UI; delega a busca a `AnimeScraper` (`searchAnime`), resolve episódios sob demanda. |
| `lib/features/search/search_screen.dart` | Renderiza a lista plana retornada; contador "N resultado(s)". |
| `lib/core/sources/*_adapter.dart` | Cada provedor scrapeia seu catálogo e devolve `List<Anime>` com título/URL da própria fonte. |
| `lib/core/anilist/anilist_service.dart` | `enrichBatch`/`enrich` anexam `anilistId` + metadados; cache por título limpo. |
| `lib/data/models/anime.dart` | Modelo `Anime` (sem `==`), enum `AnimeSource` com `priority`. |
| `lib/core/utils/text_utils.dart` | `cleanTitle`/`cleanSearchQuery`; normalização parcial de títulos (não remove travessão; `caseSensitive:false` não dobra acentos). |
| `lib/core/scraper/anime_source_adapter.dart` | Contém `normalize()` (dobra acentos, remove `dublado/legendado/dub/sub/todos os episodios`, pontuação) e `bestMatch()`. |

### 2.2 Teste ao vivo (probe de rede real)

Reproduzi o comportamento do usuário contra as fontes reais com um probe temporário (removido ao final da análise) executado via:

```bash
flutter test test/tmp_dup_probe_test.dart --dart-define=LIVE=1
```

O dump completo está em `.qa/dup_probe.txt` (mesma convenção dos demais probes do repositório).

> **Importante (convenção do repo):** probes de rede ao vivo ficam fora do CI e exigem `--dart-define=LIVE=1`; os testes sem a flag viram no-op.

---

## 3. Evidências do Problema (dados reais de 2026-08-10)

### 3.1 Agregados vs. distintos

| Query | Resultados agregados | Títulos distintos | Título principal (repetições) |
|---|---|---|---|
| `one piece` | 51 | 26 | "One Piece" — **9×** (6 fontes) |
| `naruto` | 59 | 21 | "Naruto" — **7×** (6 fontes) |
| `black clover` | 24 | 6 | "Black Clover" — **15×** (8 fontes) |
| `solo leveling` | 30 | 7 | "Solo Leveling" — **12×** (7 fontes) |

### 3.2 Caso concreto — "One Piece"

A série principal (anilistId **21**) vira **9 cards** idênticos na busca:

| Fonte | URLs | Qtd |
|---|---|---|
| AnimeFire | `/one-piece-dublado-todos-os-episodios`, `/one-piece-todos-os-episodios` | 2 |
| Goyabu | `/one-piece-dublado-online-hd-4`, `/one-piece-online-hd-3` | 2 |
| DooPlay | `/animes/one-piece-dublado-online-hd/`, `/animes/one-piece/` | 2 |
| AnimesOnline | `/anime/one-piece-dublado` | 1 |
| AnimeQ | `/anime/one-piece-dublado` | 1 |
| AnimePlayer | `/animes/one-piece/` | 1 |

Filmes/speciais ("One Piece: Gyojin Tou-hen" **4×**, "One Piece: Heroines" **5×**, "One Piece Film: Red", "One Piece Movie 14", etc.) também repetem entre fontes — constituem as **variações legítimas** que o usuário quer manter visíveis, apenas sem duplicar fonte a fonte.

### 3.3 Caso concreto — "Naruto" (drift de título)

- "Naruto" — **7×** em 6 fontes (caso simples de dedup por título).
- "Naruto Shippuden" — **9×** em 6 fontes (Goyabu/DooPlay/AnimesOnline/AnimePlayer).
- "Naruto Shippuuden" — **4×** no cluster AnimesOnline (clones usam a grafia "Shippuuden").

**"Naruto Shippuden" e "Naruto Shippuuden" são o mesmo anime.** Nenhuma normalização textual existente os funde — só o `anilistId` do AniList resolve este caso (quando o enriquecimento consegue responder sem rate-limit).

### 3.4 Caso concreto — "Black Clover" (sufixo " – Todos os Episódios")

- "Black Clover" — **15×** (8 fontes).
- "Black Clover – Todos os Episódios" — **2×** (AnimesDrive, AnimePlay) é a **mesma** série principal sob o rótulo do cluster, mas `cleanTitle` não funde: o travessão "–" (U+2013) não é removido e `caseSensitive: false` não dobra o "Ó" acentuado de "Episódios".

### 3.5 Ruído (fora do escopo, mas observado)

- `naruto` retornou 4 animes **não relacionados** do cluster AnimesOnline ("Cike Wu Liuqi –", "Fuufu Ijou, Koibito Miman – Todos os Episódios", "Love Live! Superstar!! 3 – Todos os Episódios", "Negative Positive Angler – Todos os Episódios") e lixo do AnimePlayer ("Solo Leveling Hentai", "Naruto Alternativo Rsrs"). Não é duplicação, mas polui o resultado. Fora do escopo desta entrega.

---

## 4. Análise de Causa Raiz

O fluxo completo da busca:

```
SearchScreen._performSearch
  └─ AnimeRepository.searchAnime            (anime_repository.dart:45)
       └─ AnimeScraper.searchAnime          (anime_scraper.dart:18)
            ├─ cache check (AppCaches.search, key = query minúscula)
            ├─ _search(query): fan-out paralelo por adapter →
            │    agrega TODAS as List<Anime> em uma lista plana allAnimes
            ├─ Fase 1: variantes de título do AniList (só se vazio)
            ├─ AniListService.enrichBatch(allAnimes)   → anexa anilistId
            ├─ sort por source.priority (estável)
            └─ cache.set(cacheKey, allAnimes)          → devolve A LISTA PLANA
```

**Ponto de inserção da falha:** `AnimeScraper._search` (`anime_scraper.dart:86-97`) faz `allAnimes.addAll(animes)` de cada provedor sem deduplicação. Nenhuma chave de identidade é comparada; o único "dedup" existente é o interno do `enrich` (cache por título limpo, que só evita chamadas duplicadas ao AniList, não remove cards).

**Fatos que tornam o dedup SEGURO:** o grid de episódios não pertence ao provider — `DetailScreen` chama `getCatalogEpisodes` (grade canônica do AniList) e `resolveProvidersForEpisode` (fan-out em **todas** as fontes, com `ProviderMatchStore` persistido). O `anime.source` do objeto escolhido **não restringe** quais fontes servem vídeo. Logo, pode-se manter **um representante por anime** e o playback continua agregando todas as fontes.

---

## 5. Categorias de Correspondência (chaves de dedup)

O dedup precisa de uma **identidade canônica** aplicada em **duas passadas** (a chave mais forte primeiro, título como fallback):

| Categoria | Exemplo | Chave | Passada |
|---|---|---|---|
| A. Mesmo anime, fontes diferentes | "One Piece" (6 fontes) | `anilistId` **ou** título normalizado | 2ª e 1ª |
| B. Variante dublado/legendado (mesma fonte) | `/one-piece-dublado-...` e `/one-piece-...` | título normalizado (`normalize()` já remove `dublado/legendado`) | 1ª |
| C. Drift de título entre fontes | "Shippuden" vs "Shippuuden" | **só `anilistId`** | 2ª |
| D. Sufixo " – Todos os Episódios" | "Black Clover – Todos os Episódios" | título normalizado (`normalize()` remove travessão + acento) | 1ª |
| E. Clones do cluster AnimesOnline (mesmo acervo) | `animesOnlineCloud, animesDrive, animeQ, animePlay` | mesma chave das categorias A–D | 1ª/2ª |

**Chaves propostas:**
1. `anilistId` (quando presente, após `enrichBatch`) — resolve A, C, E de forma robusta.
2. `AnimeSourceAdapter.normalize(cleanTitle(name))` — resolve A, B, D, E mesmo com AniList indisponível (`normalize` já dobra acentos, remove `dublado/legendado/dub/sub/todos os episodios` e quebra pontuação, incluindo o travessão).

> Observação de campo monitorada: no probe, o enriquecimento falhou por rate-limit do AniList em `naruto`/`black clover`/`solo leveling` (todos os `anilistId` vieram `null`). Ou seja, **o dedup não pode depender apenas do `anilistId`** — a passada por título normalizado é obrigatória.

---

## 6. Plano de Implementação (proposto)

> Nenhuma alteração foi feita nesta etapa. O plano abaixo é a recomendação para a próxima.

### Fase 1 — Identidade canônica (helper de dedup)

**Arquivo:** `lib/core/scraper/anime_scraper.dart` (ou `lib/core/utils/text_utils.dart` para reuso).

Criar uma função pura de identidade:

```dart
String animeIdentity(Anime a) =>
    a.anilistId?.toString() ??
    AnimeSourceAdapter.normalize(TextUtils.cleanTitle(a.name));
```

- `normalize()` (já existente em `anime_source_adapter.dart`) dobra acentos, remove `dublado/legendado/dub/sub/todos os episodios` e toda pontuação. Cobre as categorias B, D e parte de A/E.
- Detalhe testável: verificar que `normalize(cleanTitle("Black Clover – Todos os Episódios"))` == `normalize("black clover")` (travessão e acento) — o divisor atual é que `cleanTitle` sozinho não funde (seção 3.4).

### Fase 2 — Dedup na agregação

**Arquivo:** `lib/core/scraper/anime_scraper.dart`, método `searchAnime` (após o merge de variantes e o `enrichBatch`, antes do `sort`/`cache.set`).

Duas passadas:

1. **Passada por título normalizado (antes do enrich opcional):** agrupar por `normalize(cleanTitle(name))`, mantendo o de **maior prioridade** (`source.priority`) como representante. Reduz o volume que vai para o AniList e remove B/D/E.
2. **Passada por `anilistId` (após `enrichBatch`):** agrupar por `anilistId` quando não-null, mantendo o representante de maior prioridade; quando o grupo tem `anilistId` e o representante escolhido ficou sem, propagar o `anilistId`/metadata do grupo. Resolve A/C.

Regras do representante:
- Maior prioridade via `source.priority` (AnimeFire > Goyabu > ... ) — o sort existente já ordena assim; o dedup deve usar a mesma métrica para ser estável.
- Sempre manter um `Anime` com `url` não-vazia (a filtração `hasValidId` já garante isso).
- **Não** tocar no `_search` per-query: o dedup no nível `searchAnime` também funde o resultado das variantes da Fase 1 (já há um dedup parcial de título nesse laço em `anime_scraper.dart:37-41`, que pode ser substituído pelo helper da Fase 1).

### Fase 3 — UI (opcional, baixo esforço)

- O contador "N resultado(s)" passa a refletir o número **distinto** automaticamente.
- Opcional: nenhuma mudança exigida em `SearchScreen`/`DetailScreen` — o representante abre o detalhe e o playback continua agregando todas as fontes via `resolveProvidersForEpisode`. Se quiser dar visibilidade, exibir no card o número de fontes em que o título existe (ex.: selo "6 fontes") reaproveitando o grupo da Fase 2.

### Fase 4 — Verificação

**Teste unitário (offline, mockado):** usar `MockClient` + adapters injetados que devolvem o mesmo anime com variantes dublado/legendado e títulos "Shippuden/Shippuuden":
- construir `AnimeRepository(adapters: [...])` ou chamar o dedup diretamente;
- assertar `resultados.length == 1` por anime, representante = maior prioridade;
- assertar a fusão de título com travessão/acento (`Black Clover – Todos os Episódios`).

**Probe live (fora do CI):** re-rodar o probe com `--dart-define=LIVE=1` e validar:
- `one piece` → 9→1 card para a série principal (26 títulos distintos preservados);
- `naruto` → "Naruto Shippuden"+"Naruto Shippuuden" → 1 card (com AniList OK);
- `black clover` → 15→1 card; `black clover – todos os episodios` fundido;
- sem alterar o contador para `solo leveling` quando o AniList está em rate-limit (fallback por título).

---

## 7. Riscos e Considerações

1. **Rate-limit do AniList invalida o `anilistId` como chave única** (observado no probe). A passada por título normalizado é o fallback obrigatório; a passada por id melhora os casos de drift (C) quando a rede responde.
2. **Drift de título sem AniList** ("Shippuden/Shippuuden") não é fundível por string. Se quiser cobrir offline, seria preciso um pequeno mapa de sinônimos/canonicalização — **fora do escopo**, documentado como melhoria futura.
3. **`AnimeSourceAdapter.normalize` é `static` e dependente do arquivo** — reuso direto não introduz nova dependência nem acoplamento; alternativa é movê-la para `TextUtils` (uma mudança de local, sem mudança de comportamento).
4. **Ruído de resultados** (hentai, animes não relacionados no search do cluster, seção 3.5) **não** é duplicação e está explicitamente fora do escopo desta entrega; o dedup não deve tentar "limpar" isso sem requisito próprio.
5. **Cache existente** (`AppCaches.search`) passa a reter a lista **deduplicada** naturalmente após a mudança; nenhuma estratégia de invalidação nova é necessária.
6. **Ordem de prioridade como critério de desempate** segue a métrica já usada pelo app (`source.priority`), então o resultado permanece estável entre execuções.

---

## 8. Conclusão

O defeito é pontual e de baixo risco: **falta uma etapa de dedup na agregação** em `AnimeScraper.searchAnime`. A correção recomendada é um helper de identidade canônica (anilistId → título normalizado) aplicado em duas passadas, com o representante de maior prioridade mantendo a URL, e **zero mudanças** na resolução de episódios (que já é multi-fonte e não depende do card escolhido). O resultado esperado é a busca mostrar "One Piece e suas variações" — um card por título — sem repetições por fonte.