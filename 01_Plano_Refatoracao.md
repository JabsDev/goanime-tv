# 01 — Plano de Refatoração: Desacoplamento do Catálogo dos Providers

**Data:** 06/08/2026
**Papel:** Arquitetura de Software (apenas análise e planejamento — nenhum código foi alterado)
**Escopo:** eliminar a dependência entre a *lista de episódios* e o *provider selecionado*, fazendo com que o provider seja responsável apenas por fornecer vídeo.

---

## 1. Resumo da arquitetura atual

O app GoAnime TV é um Flutter/Android TV que agrega múltiplos sites de anime em PT-BR
(AnimeFire, Goyabu, DooPlay/BetterAnime, AnimePlayer) via *scraping* de HTML + APIs HLS,
e usa o **AniList GraphQL** como fonte de metadados, catálogo de discovery e integração de
watchlist/progresso (login opcional).

Camadas principais:

- **Models** — `lib/data/models/anime.dart` (`Anime`, enum `AnimeSource`), `episode.dart`
  (`Episode`, `VideoSource`, `EpisodesResult`, `AnimeSourceAdapter`).
- **Providers (adapters)** — `lib/core/sources/*_adapter.dart`. Cada adapter implementa a
  interface `AnimeSourceAdapter` (`lib/core/sources/anime_source_adapter.dart`) com 4 verbos:
  `search`, `getEpisodes`, `getVideoSources`, `checkAvailability`. Registrados em
  `SourceRegistry`.
- **Orquestração** — `lib/core/scraper/anime_scraper.dart` agrega busca, enriquecimento AniList,
  e **merge de episódios de múltiplos providers**. `lib/data/repositories/anime_repository.dart`
  é a porta do UI: `getEpisodes` → delega ao `AnimeScraper`; `getVideoSources` → faz fan-out de fallback.
- **UI** — `features/home` (discovery AniList + histório/favoritos), `features/search`,
  `features/detail/detail_screen.dart` (grade de episódios + seletor de fonte + dialog de qualidade),
  `features/player/player_screen.dart` (media_kit).
- **Cache** — `lib/core/cache/app_caches.dart` (search/episodes/enrichment/http).

**Fluxo atual relevante (detalhe).** Em `AnimeScraper.getEpisodes(anime)` (`anime_scraper.dart:95`):
1. Resolve o contexto de *cada* provider (AnimeFire e Goyabu) para o anime (usa o próprio anime
   quando ele carrega a url, senão `_findBySource` faz uma **busca extra por nome** para descobrir
   a página do provider).
2. `getEpisodes` de cada provider retorna a lista própria do provider.
3. Episódios são marcados com `source` + `owner` (provider de origem).
4. Metadados AniList (títulos/thumbnails via `getEpisodesV2`) são **merged** sobre os episódios,
   mantendo o provider de vídeo como dono.
5. Monta `EpisodesResult(episodes, sourceOptions)` onde `sourceOptions` é um `Map<String, List<Episode>>`
   **chaveado por provider** ("AnimeFire", "Goyabu", ...).

Na UI (`detail_screen.dart:118-131, 143-151, 471-474, 525-531`), quando `sourceOptions` tem mais de um
provider, o app **exibe um seletor de fonte** (`_SourceSelector`) que troca a **grade inteira de
episódios** ao mudar de provider — a lista exibida muda conforme o provider escolhido.

O `PlayerScreen` recebe a lista de eps + dados do provider e pode re-resolver fontes do ep atual.

---

## 2. Diagnóstico dos problemas

A dependência "episódios ← provider" gera, no código atual:

1. **Lista de episódios varia por provider.** A mesma obra (ex.: One Piece) tem quantidades
   ≠ em AnimeFire, Goyabu, BetterAnime, de acordo com o que cada um indexou. O usuário que troca
   de fonte "perde"/"ganha" episódios; a numeração e títulos divergem.
2. **Provider com menos episódios esconde a obra.** Se a fonte no padrão (AnimeFire) tem menos eps
   que outra, o app sub-exibe. (UI passa a "entender" que o anime tem só o que a fonte tem.)
3. **Acoplamento catálogo↔reprodução.** `EpisodesResult.sourceOptions` (estrutura de *catálogo*)
   conhece a *reprodução* (carrega urls/owners de stream). O `AnimeScraper` decide a lista e ao mesmo
   tempo a fonte de vídeo.
4. **Buscas extras espalhadas.** Para popular a grade por provider, o fluxo faz `_findBySource`
   (busca por nome) por provider — chamadas de rede "asincronizadas" que não existiriam se o catálogo
   fosse único.
5. **Difícil de expandir providers.** Adicionar um provider exige garantir busca, página de anime,
   e merge coerente de episódios — o custo/árvores cresce quadraticamente com nº de fontes.
6. **Fronteiras de cache ambíguos.** O cache de episódios é chaveado por `fonte:url:allAnimeId`
   (`anime_scraper.dart:96`), então o mesmo anime tem múltiplos caches e o cache é inválido quando a
   fonte muda — não compartilhável entre telas/fluxos.
7. **UI com conceito de "fonte" vazado.** O topo da página mostra `anime.sourceName`; o seletor de
   fonte decide a real lista. A **fonte é um detalhe de infraestrutura**, não uma propriedade do anime
   — vaza até o header da página.
8. **Experiência inconsistente** (a lista muda ao trocar fonte, botão "fonte" no card).

> Obs. de contexto: este projeto já fez um movimento nessa direção — AniList foi reclassificado
> como metadata-only e `AniListService._mediaToAnime` devolve `url: ''` e sem fornecedor de vídeo
> (`anilist_service.dart:401-425`); os episódios vêm apenas dos providers. A refatoração proposta
> leva essa ideia ao limite: **o catálogo deixa de consultar providers para montar a lista**.

---

## 3. Análise do fluxo atual

```
Abrir anime
  └─ $_loadEpisodes → AnimeRepository.getEpisodes(anime)
        └─ AnimeScraper.getEpisodes
             ├─ resolve context per provider (próprio url OU _findBySource → NET search)
             ├─ getEpisodes(providerAF), getEpisodes(providerGY)  [NET por provider]
             ├─ merge AniList meta por número (getEpisodesV2)      [NET, precisa login]
             └─ EpisodesResult(episodes, sourceOptions{provider: lista})
        └─ Detail UI:
             ├─ usa sourceOptions (se >1) → mostra _SourceSelector
             ├─ _selectedSource = primeiro provider; _episodes = lista daquele
             └─ trocar provider → set _selectedSource/_episodes (grade muda)
Tap episódio
  └─ _QualityDialog._loadSources → AnimeRepository.getVideoSources(episode, source, anime)
        ├─ adapter fonte do episódio (owner/source) → getVideoSources(episode.url)
        └─ se vazio → fallback em todos os outros adapters (fan-out)
  └─ lista VideoSource → escolhe qualidade → PlayerScreen
```

Ponto-chave: **quem define os episódios é o `AnimeScraper` escavando os providers** e a UI,
via `sourceOptions`/`_SourceSelector`, **decide qual provider é a "verdade" do anime**.

---

## 4. Análise do fluxo desejado

```
Abrir anime
  └─► Catálogo Central (AniList):
        ├─ rich: anime.metadados (episódios totais, títulos, capas, sinopse, status)
        ├─ se login + episodesV2 → títulos/thumbnails por episódio
        └─ constrói lista única 1..N   (catálogo NÃO conhece providers)
  └─ Detail UI:
        └─ sempre visa a lista única/numérica (sem _SourceSelector de grade)

Tap episódio N
  └─ Resolver por episódio (sob demanda, NÃO ao abrir o anime):
        ├─ consulta TODOS os providers em paralelo
        ├─ para cada provider: "você tem o ep N deste anime?" → resolve URL do provider
        └─ retorna apenas providers que possuem o ep
  └─ UI: escolher provider (ex.: "AnimeFire ✔", "Goyabu ✔", "Superflix ✖ oculto")
  └─ Escolher resolução (360p/720p/1080p) do provider escolhido
  └─ Player
```

O provider só participa **depois** que o usuário escolhe um episódio.

---

## 5. Comparação entre ambos

| Dimensão | Fluxo atual | Fluxo desejado |
|---|---|---|
| Quem define a lista de episódios | O provider (merge no `AnimeScraper`) | O catálogo AniList |
| Variação ao trocar provider | A grade inteira muda | Grade fixa (canônica) |
| Seleção de fonte | Seletor de fonte global (topo) muda a lista | Seleção de fonte **por episódio**, após o tap |
| Rede ao abrir o anime | `getEpisodes` de vários providers + merges | Só AniList (metadados), sem fan-out a providers |
| Rede ao tocar um ep | Resolução de um provider + fallback | Resolução de todos os providers (só naquele ep) |
| Acoplamento catálogo↔reprodução | `Episodes.sourceOptions` carrega urls/owners | Catálogo puro; provider isolado em resolvers |
| Novo provider | Precisa implementar lista de episódios coerente | Implementa apenas "resolver vídeo do ep N" |
| Cache | Por `fonte:url` (múltiplos, por provider) | Por anime + por (anime, ep, provider) |
| Experiência | Lista muda; anime.ts chama "fonte" | Lista estável; provider é só alternativa de vídeo |

Detalhe importante: o fluxo desejado faz **mais** chamadas de rede por tap de episódio (consultar N
providers), mas **menos** ao abrir o anime. Isso é um trade-off aceitável se o cache para os
(anime, ep, provider) e as consultas forem condensadas com timeouts curtos e fins rápidos.

---

## 6. Componentes afetados

1. **`AnimeScraper` (orquestração de episódios)** — deixa de vender lista a partir de providers;
   passa a gerar a lista canônica via AniList. Estratégia de `_find_BySource`/merge de providers
   removida ou movida.
2. **Adaptadores (`AnimeSourceAdapter`)** — mudança de contato: de `getEpisodes(anime)` para
   `resolveEpisode(animeRef, episodeNumber)` (+ opcional `hasEpisode`). `getEpisodes` para deixar
   de ser usado pelo fluxo principal de catálogo.
3. **`SourceRegistry`** — passa a expor a lista de providers para o resolvest em episódio; incultura
   caches/prioridade de resolução por episódio.
4. **`SourceRegistry` / `SourceRegistry.fallbackOrder`** — reescrito para o novo fluxo (todos os
   providers por episódio).
5. **UI `DetailScreen`** — remove `_SourceSelector` (seleção de fonte de *grade*); passa a exibir
   sempre a lista canônica; nova interação "episódio → provider → resolução".
6. **`_QualityDialog`** — hoje resolve fontes do provider do ep com fallback; novo um estágio de
   seleção de provider ANTES da resolução (ou integra-se o provider list em um único dialog
   em dois passos).
7. **`PlayerScreen`** — recebe `(anime, episodeNumber, provider, list)`; mantém fallback de re-resolução
   do provider escolhido.
8. **Cache** — novos cache chaves por (anime id / título + episodeNumber) e por (provider + ep).
9. **AniListService** — reforçar queries: total episodes + (opcional) episódiosV2; novos endpoints
   auxiliares para catálogo local.

---

## 7. Arquivos afetados

**Modificados (núcleo):**
- `lib/core/scraper/anime_scraper.dart` — reescrever `getEpisodes` para catálogo canônico;
  remover lógica de merge provider.
- `lib/core/sources/anime_source_adapter.dart` — nova interface (resolver vídeo por ep), e novas
  responsabilidades (`resolveEpisode`); retirar/∠.
- `lib/core/sources/source_registry.dart` — expor `all` para resolução por episódio; novos métodos.
- `lib/data/repositories/anime_repository.dart` — novos: `getCatalogEpisodes(anime)` (canônico),
  `resolveProvidersForEpisode(anime, n)` (paridade+`  availability`), `getVideoSources(provider, ...)`.
- `lib/data/models/episode.dart` — `EpisodesResult` pode ficar `canônica`; `sourceOptions` é questão
  a remover/mover para providers/`remove`.
- `lib/data/models/anime.dart` — garantir `episodes` (total) + `anilistId` sempre preenchidos pelo
  catálogo.

**Modificações (UI):**
- `lib/features/detail/detail_screen.dart` — remover `_SourceSelector`; novo fluxo de "episódio →
  provider → resolução".
- `lib/features/player/player_screen.dart` — adaptar a recibir provider/lista.

**Caches:**
- `lib/core/cache/app_caches.dart` — novos instâncias/campos para ephemeris por episódio/provider.

**Tests/QA:**
- `test/ptbr_adapters_test.dart`, `test/sources_corrections_test.dart`, `test/live_sources_probe_test.dart`.

**Adapters (ajuste de interface):**
- `lib/core/sources/{anime_fire,goyabu,dooplay,animeplayer,all_anime,anilist}_adapter.dart`
  — implementar o novo método de resolver episódio; `getEpisodes`/search mantidos para compat durante a
  migração (ou desativados se eliminados).

> Novo arquivo sugerido (etapa tardia): `lib/core/catalog/anime_catalog.dart` (fonte da verdade de
> episódios canônicos), desacoplando o "quem define episódios" do "quem serve vídeo".

---

## 8. Arquitetura proposta

### 8.1 Separação de responsabilidades

```
      ┌──────────────────────────  CATÁLOGO  ──────────────────────────┐
      │  AnimeCatalog (AniList)  — fonte única da verdade:            │
      │    · metadados do anime (id, título, capa, sinopse, status)   │
      │    · total de episódios (episodes)                            │
      │    · nº de episódios 1..N                                  │
      │    · (login+) títulos/thumbs por episódio (episodesV2)      │
      │  NÃO conhece nenhum provider.                                │
      └──────────────────────────────────────────────────────────────┘
                                │  episode N
                                ▼
      ┌──────────────────────  PLAYER (reprodução)  ───────────────────┐
      │  ResolverEpisódioService (orquestra providers):               │
      │    · para período ep N: consulta cada provider em paralelo    │
      │    · provider responde "tenho? → resoluções → url do vídeo"   │
      │    · retorna providers com o ep + resoluções                  │
      │    · cache (animeId, ep) + (provider, ep)                     │
      │                                                               │
      │  Deviders (AnimeFire, Goyabu, DooPlay, AnimePlayer...):       │
      │    · SÓ vídeo: resolve episódio N (mapa ep -> url)            │
      │    · nunca define a lista de episódios                        │
      └───────────────────────────────────────────────────────────────┘
                                │  url + headers
                                ▼
      ┌────────────────────────  PLAYER  ──────────────────────────────┐
      │  apenas reproduz o vídeo recebido; não conhece catálogo.      │
      └───────────────────────────────────────────────────────────────┘
```

### 8.2 Novos contratos

**Catálogo (novo/estilos):**
```
class AnimeCatalog {
  Future<CatalogAnime> // ou reuso de Anime enriquecido
  Future<List<Episode>> getEpisodes(Anime anime);   // canônico 1..N (AniList)
  // episódios carregam number/title/thumb, NÃO source/owner de vídeo
}
```

**Provider (adaptado):**
```dart
abstract class AnimeSourceAdapter {
  AnimeSource get source;
  /// Resolve as resoluções de vídeo do ep N de [animeRef] neste provider.
  /// [animeRef] traz título + ids de catálogo (não urls do provider).
  Future<ScraperResult<List<VideoSource>>> resolveEpisode(
    Anime animeRef, int episodeNumber);
  // (opcional durante migração) manter getEpisodes apenas como fallback compatibility.
}
```

O provider internamente:
1. localiza sua página do anime (via url do catálogo mapeada OU busca interna por título — **cacheada**);
2. faz lookup do índice de episódios (seu `allEpisodes`/links) para o nº N;
3. extrai resoluções (`VideoSource`) do ep N — reusando o código já existente de
   `AnimeFireAdapter._extractFromAnimeFire`, `Goyabu._extractFromGoyabu`, `DooPlay._extractFromDooPlay`.

### 8.3 Orquestração (`ResolveEpisode`)
- `Future<List<ProviderEpisodeResult>> resolveEpisode(Anime anime, int n)`:
  itera `SourceRegistry.adapters` (só `implemented`), `Future.wait` com isolamento de erro por future,
  timeout curto por provider, e consenso: para cada provider, sucesso→resoluções; falha/EmptyResult→"não
  tem o ep".
- Cache: por `(animeId,n)` guarda a disponibilidade dos providers; por `(provider, animeId, n)` guarda
  as resoluções resolvidas (intervalo de minutos).

### 8.4 UI (dois níveis)
- Grade de episódios = lista canônica de catálogo (sem seletor de grade).
- Tap episódio N → passo 1: **escolher provider** entre os que retornaram resoluções (paralelo, mostra
  spinner "procurando em AnimeFire, Goyabu, ..."); passo 2: **escolher resolução** (qualidades).
- Design alternativo (mais simples): um único dialog `ProviderQualidadeDialog` onde a primeira aba é
  "fonte" (só as que tem o ep ok) e ao escolher fonte mostra as qualidades — o que o UX atual de
  `_QualityDialog` já antecipa (mas hoje só tem qualidade de um provider).

---

## 9. Estratégia de migração

**Princípio:** manter compatibilidade com os adapters atuais, sem quebrar funcionalidades já em uso.
Migração em 4 períodos (não-destrutiva):

1. **Convergência de contrato (additive):** acrescentar `resolveEpisode(...)` à interface
   `AnimeSourceAdapter` com implementação default que delega ao `getEpisodes`+`getVideoSources` atuais
   (para a camera antiga continuar funcionando). Nenhum comportamento muda ainda.
2. **Suprio no catálogo canônico:** criar `AnimeCatalog.getEpisodes(anime)` 100% via AniList
   (fallback para `anime.episodes`/1..N). **Em paralelo**, manter o antigo `getEpisodes` apenas para
   degração (feature flag / comparação).
3. **Nova orquestração por episódio:** `repo.resolveProvidersForEpisode` começa a ser chamado no tap
   de episódio; exibe novos providers de resolve (paralelo). O `_QualityDialog` passa a várias de
   `resolveProvidesForEpisode` em vez de `getVideoSources`+fallback.
4. **Remoção / renovação:** deleting `anime_scraper.getEpisodes` merged e `_SourceSelector`; remover
   `sourceOptions` do `EpisodesResult`; finalizar o contrato de provider (`getEpisodes` isolado do
   fluxo de catálogo — pode ficar como fallback interno do provider p/ `resolveEpisode`).
5. **Limpeza/cache/textos:** atualizar mensagens "nenhuma resolução" e "fontes"; cache chaveado por
   (animeId, ep, provider).

Cada etapa termina em `flutter analyze` + `flutter test` verde antes de avançar.

---

## 10. Riscos

1. **Episódios canônicos podem não ter releases disponíveis ainda.** Durante o AIRING, AniList
   `episodes` = total planejado → a lista canônica incluirá eps ainda não lançados por nenhum provider.
   **Mitigação:** o agregador de providers trata "nenhum provider tem o ep N" como estado legítimo
   (mostra ✗ / desabilitado), iguaal ao fluxo pedido (asksExample: Superflix ✖).
2. **AniList sem login não expõe `episodesV2`.** Para não-logged, só temos `anime.episodes`
   (sem título/thumb por ep). **Mitigação:** lista canônica de eps com números (`Episódio N`) —
   títulos/thumbs são opcionais e preenchidos quando autenticado.
3. **Perdas possíveis: episódios 0/movies/specials.** Providers enumeram `Special`, filmes e
   `episódio 0` que não existem na numeração 1..N do AniList. **Risco de regressão UX.**
   **Aberto:** como representar extras na lista canônica? (ver §13).
4. **Custo/otividade: consultar N providers por tap.** Com cache e Deus aceitável; sem cache viraria
   lento. **Mitigação:** cache por (anime,ep,provider) `]`+ timeouts (2–3s) + UI de "estado de loading
   com lista de providers tentados".
5. **Rate-limit/429 do AnimeFire** ao chamar vários eps concorrentes. precisa throtle serial p/
   AnimeFire (já documentado em `.qa`). Manter o serializador/re-try existente.
6. **Matching por título entre catálogo e provider** continua frágil (título ≠). Ainda é necessário
   um "encontrar anime na fonte X" quando o catálogo não guarda id de provider. **Mitigação:** manter
   o mapeamento (url do provider) obtido por busca e **cacheá-lo por anime** para não re-buscar a cada
   ep; reusar `bestMatch` existente.
7. **Coexistência temporária (etapas 1-3)** pode duplicar chamadas na fase de transição. Necessário
   remover o caminho antigo ao final.
8. **Testes live/QA dependentes da rede** tornam a validação frágil (429, Cloudflare). Usar mocks
   para o contrato novo + testes mock de `resolveEpisode`.

---

## 11. Impactos

- **UX:** lista de episódios estável e igual para qualquer anime; fonte não é mais "a verdade do
  anime"; usuario escolhe fonte **por episódio** (qualidade por source).
- **Manutenção:** adicionar um novo provider = implementar `resolveEpisode(name, n)` e registrar;
  sem duplicação de "lista".
- **Cache:** mais granular e compartilhado; chave por (animeId, ep) e (provider, ep).
- **Testes:** interface menor e mais focal (resolver vídeo) → mais fáceis de unit-testar com mocks;
  catálogo canônico parte de AniList (mockável, estável).
- **Performance perceived:** abaixar rede ao abrir o anime (só AniList); pequeno custo extra ao tocar
  um ep (busca de providers), amortizado por cache.
- **Custo de implementação:** maior nas camadas provider/UI (contrato novo + dois passos de seleção);
  baixo no catálogo (reusa AniList).

---

## 12. Plano detalhado de implementação em etapas

> Cada etapa termina com `flutter analyze` + `flutter test` verdes e, idealmente, um commit.

### Etapa 0 — Preparação / base
- Adicionar testes-mock que capturam o contrato **atual** (para detectar regressões durante a mudança):
  `episodes` do `AnimeScraper`, `getVideoSources`/fallback.
- Documentar no README a filosofia nova (catálogo define episódios; provider só vídeo).

### Etapa 1 — Contrato de provider evoluído (aditivo)
- Em `AnimeSourceAdapter` adiciona `resolveEpisode(Anime, int)` cuja implementação default reutiliza
  `getEpisodes`+`getVideoSources` (sem quebrar nenhum adapter existente).
- Adapter `implemented=false` (AllAnime, AniList) seguem sem resolver vídeo.
- **Verificar:** nenhum teste quebra; comportamento igual ao atual.

### Etapa 2 — Catálogo canônico (AniList)
- Criar `lib/core/anilist/anime_catalog.dart` (ou adicionar métodos em `AniListService`):
  - `Future<List<Anime>> catalogAnime(...)` (reusa `_catalogQuery` — já existe).
  - `Future<List<Episode>> getEpisodes(Anime anime)` → canônico 1..`anime.episodes`,
    **sem** `source`/`owner` de vídeo; enriquece títulos/thumbs com `getEpisodesV2` quando logado.
  - Fallback: se `anime.episodes` nulo, usa um valor conservador e permite preencher após
    `AniListService.enrich`.
- Cache por `animeId`.
- **Novo teste:** dados mock → `getEpisodes` gera 1..N, sem nenhum `source` de provider nos eps.

### Etapa 3 — Orquestração por episódio (novo caminho de vídeo)
- Em `AnimeRepository`, novo `resolveProvidersForEpisode(Anime, int)` → retorna
  `Map<AnimeSource, List<VideoSource>>` (provider → resoluções) usando `SourceRegistry.adapters`
  (paralelo, isolado por erro, timeout, cache `(animeId, ep)`).
- Empirar `_extractFrom*` dos adapters pelo caminho novo (sem regressão na interface antiga).
- Teste mock: dado adapter que responde, retorna o provider; adapter que falha → excluído.

### Etapa 4 — UI: novo fluxo de seleção (substituição)
- `DetailScreen._loadEpisodes` passa a usar o catálogo canônico; remover `_sourceOptions` /
  `_SourceSelector` / `_selectedSource` da grade.
- Substituir `_loadEpisodes` de merge antigo.
- Novo dialog de um passo `EpsSelectProviderQualityDialog`:
  1. on tap ep → `resolveProvidersForEpisode` (spinner "procurando em fonts…").
  2. mostra providers que possuem (com `✔`); ✖ ocultos ou desabilitados.
  3. escolher provider → lista de resoluções do provider; escolher resolução → Player.
- `PlayerScreen`: receber `(anime, episode# Nº, provider, List<VideoSource>)`,
  reusar lógica de re-resolução do provider escolhido.

### Etapa 5 — Remoção / limpeza
- Remover `anime_scraper.getEpisodes` com merge de providers (Substituído pelo catálogo).
- Remover `EpisodesResult.sourceOptions` (e ajustar quem consumia).
- Remover `_findBySource`/`bestMatch` do fluxo de anime (só permutation para `resolveEpisode` interno)
  — ou consolidar no provider/catálogo-id mapping.
- Atualizar mensagens de "nenhuma fonte/resolução" na UI com a lista real de providers.
- Revisar `pubspec`/dead code (ex.: `anilist_adapter` se não mais usado — manter `implemented=false`).

### Etapa 6 — Cache final
- `AppCaches`: `catalogEpisodes` (por animeId), `episodeProviders` (por (animeId, ep)),
  `episodeResolutions` (por (provider, animeId, ep)).
- TTLs: catálogo 1h-24h; providers/resoluções 10–30min (urls expiram).

### Etapa 7 — Verificação / QA
- `flutter analyze`, `flutter test`.
- Reaproveitar/expandir `test/ptbr_adapters_test.dart` para `resolveEpisode`.
- Regenerar `relatorio_teste_sources.md`/QA para: ao abrir anime sem fan-out de providers;
  ao tocar ep, providers consultam e o AniList não aparece como vídeo.

---

## 13. Questões abertas (validar antes de implementar)

1. **Lista canônica e séries em lançamento (AIRING).** Usar `anime.episodes` (total planejado) cria
   episódios futuros que nenhum provider tem. Aplicar apenas `1..N` total, ou exibir alcançado+
   "Próximos lançamentos"? (Sugestão: exibir 1..N e marcar os sem provider como "em breve".)
2. **Espaço para caminhos de episódios especiais (filmes, OVAs, Speciais, splash).** A numeração
   1..N ignorada perde `Movie`/`Special`. Como expor na lista canônica sem duplicar? (Sugestão abrir
   sessão "Extras" opcional composta por peço dos providers, se algum provider os tiver.)
3. **Provider que não tem numeração contígua (faltando um ep no meio).** O que acontece quando
   provider/olhaAnimeFire tem 1..110 mas Goyabu 1..108 com um missing? A lista canônica é 1..N;
   o provider sem o 109 fica `✖` no ep 109, e `✔` no 1..108. Confirmar comportamento.
4. **Identidade do anime cruzada entre AniList e providers.** O catálogo é AniList; a resolução
   interna precisa da url/id de cada provider. Sem um "id mapping", a busca por nome (frágil) acontece
   por ep. Aceitar quea en 1ª resolução de um ep seja mais lenta e cacheie o provider-id por anime?
5. **AniList `episodesV2` exige login?** Confirmar se para não-logado é zero. Em caso positivo, a
   questão de test 2 sai por tráfego os títulos. Definir fallback mostrando só "Episódio N".
6. **Qualidade do merge de título por episódio.** `episodesV2` aos às vezes tem duração/holes.
   Tratar número ausente.
7. **Retro-compatibilidade dos adapters de 3º? (se algum é privado/externo).** A mudança de
   `AnimeSourceAdapter` (novo método) vai quebrar implementações externas; a default implementation
   (Etapa 1) minimiza o impacto.
8. **Performance real da resolução de todos os providers por tap.** Validar em device Fire TV o
   tempo de resolução com N=4–5 providers + cache; sefor insuportável, reduzir concurrency ou
   pré-resolver (durante idle) de `episódios mais* próximos ao atual (last`, incluindo o atual) sem.
9. **Ordem/prioridade de providers na exibição "qual tem o ep".** Manter a prioridade já
   definida ("AnimeFire → Goyabu → DooPlay → AnimePlayer") ou permitir o usuário ordenar?
10. **DoO o fallback atual (_QualityDialog faz fallback ao owner do ep) se perder?** Com a nova
    resolução por provider, o fallback multicomponente fica correto (não precisa mais).
    Confirmar/mantir a estratégia de auto-avançar de fonte morta do player por pr`resolve` provider.

---

*Fim do documento. Nenhum código foi modificado nesta fase.*