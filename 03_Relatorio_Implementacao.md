# 03 — Relatório de Implementação

**Fase 3 — Desacoplamento do catálogo (AniList) dos providers**
**Status:** Implementado · `flutter analyze` e `flutter test` verdes
**Base:** `01_Plano_Refatoracao.md` (estratégico) + `02_Review_Arquitetura.md` (autoritativo — prevalece em caso de conflito)

---

## 1. Resumo

O catálogo canônico de episódios agora pertence exclusivamente ao AniList e a
cada anime aberto na tela de detalhes. Os providers deixaram de definir a lista
canônica de episódios (`EpisodesResult.sourceOptions`, `getEpisodes` no
`AnimeScraper`, `AniListAdapter` e o seletor de fontes da UI foram removidos).

O provider passou a ser **só um resolvedor de vídeo**: dado um anime do
catálogo, ele localiza a própria página (`resolveAnime`) e, dado o número do
episódio, resolve os streams (`resolveVideo`). A descoberta da página do anime
por provider é **persistida** (`ProviderMatchStore`, shared_preferences,
keyed por `anilistId ?? titulo limpo`) — ver decisão D4 da review — e os caches
TTL em memória apenas complementam, não substituem.

Fluxo final ao tocar em um episódio:
`Episódio → Provider → Qualidade`, com o provider de melhor prioridade
pré-selecionado e a resolução dos providers feita em paralelo com cache.

## 2. Arquitetura implementada

```
┌─────────────────────────────────────────────────────────────────────┐
│ CATÁLOGO (canônico)                    │ RESOLUÇÃO DE VÍDEO (on-demand)│
│                                        │                              │
│ AniListService.getEpisodesV2 ──────────┼─► AnimeRepository            │
│   (ou 1..N quando sem id/listagem)     │   .resolveProvidersForEpisode│
│   ──► CatalogEpisode (number/title/    │      ── fan-out paralelo     │
│        thumbnail/description)          │      ── ProviderMatchStore   │
│   ──► grade 100% provider-free         │      ── AppCaches.resolutions│
│                                        │   ──► ProviderMatchStore     │
│ Anime (AniList)                        │        anilistId→provider.url│
└────────────────────────────────────────┴──────────────────────────────┘
                    ▲
        AnimeSourceAdapter (contrato em 2 verbos)
        ├─ resolveAnime(Anime) → Anime?   (default: search + bestMatch)
        ├─ resolveVideo(Anime, int) → List<VideoSource>
        │     (default: getEpisodes → getVideoSources)
        └─ getEpisodes/getVideoSources/search (núcleo de scraping por provider)
```

- **`CatalogEpisode`** (novo, `episode.dart`): só dados de catálogo —
  `number`, `title`, `thumbnail`, `description`. Sem `url`/`source`/`owner`;
  a grade não pode vazar dados de provider (requisito da review, rejeição do
  `ProviderEpisode`).
- **`AnimeSourceAdapter`**: contrato com dois verbos **com implementação
  default** (construída sobre `search`/`getEpisodes`/`getVideoSources`), então
  cada adapter herda `resolveAnime`/`resolveVideo` de graça e sobrescreve
  apenas se a numeração/detalhe próprio exigir. `bestMatch`/`normalize`
  migraram do `AnimeScraper` para cá.
- **`AnimeRepository`**: único orquestrador. `getCatalogEpisodes` entrega a
  grade canônica; `resolveProvidersForEpisode(anime, n)` faz o fan-out
  paralelo por provider (respeitando `implemented`), usa a página persistida
  quando existe, ordena por prioridade e cacheia as resoluções
  (`AppCaches.resolutions`, TTL curto) para que re-taps no mesmo episódio
  sejam instantâneos sem re-scrape.
- **`ProviderMatchStore`**: persistência simples chave→valor
  (`provider_matches_v1`), complementar (não substituta) aos caches TTL.

## 3. Arquivos modificados

| Arquivo | O que mudou |
|---|---|
| `lib/data/models/episode.dart` | Adicionado `CatalogEpisode`; removida a classe `EpisodesResult` (fonte da contaminação da grade); `Episode` documentado como tipo interno de provider |
| `lib/core/sources/anime_source_adapter.dart` | `getEpisodes` agora retorna `ScraperResult<List<Episode>>`; adicionados `resolveAnime`/`resolveVideo` com default; `bestMatch`/`normalize` movidos do scraper |
| `lib/core/sources/anime_fire_adapter.dart` | Assinatura de `getEpisodes` alinhada ao novo contrato (retorno `List<Episode>`) |
| `lib/core/sources/goyabu_adapter.dart` | `implements`→`extends` (herda defaults); `getEpisodes` aceita URL relativa (`$_base` prefixado) — correção de robustez para URLs persistidas |
| `lib/core/sources/dooplay_adapter.dart` | `implements`→`extends`; `getEpisodes` com novo retorno |
| `lib/core/sources/animeplayer_adapter.dart` | `implements`→`extends`; `getEpisodes` com novo retorno |
| `lib/core/sources/all_anime_adapter.dart` | `implements`→`extends`; `getEpisodes` com novo retorno |
| `lib/core/scraper/anime_scraper.dart` | Reduzido a `searchAnime` apenas; removidos `getEpisodes`, `_findBySource`, `bestMatch`, `normalize`, `mergeEpisodes` (duplicados em 2 lugares) |
| `lib/core/cache/app_caches.dart` | Novos caches `catalog` (24h) e `resolutions` (30min); `clearAll()` limpa ambos |
| `lib/data/repositories/anime_repository.dart` | Reescrito: `searchAnime`, `getCatalogEpisodes`, `resolveProvidersForEpisode` (fan-out paralelo + persistência + prioridade + cache) |
| `lib/features/detail/detail_screen.dart` | Grade canônica (`List<CatalogEpisode>`); `_loadEpisodes` usa `getCatalogEpisodes`; fluxo de play via `_showEpisodeSourcePicker`→`_ProviderQualityDialog` (níveis Provider→Qualidade, provider de melhor prioridade pré-selecionado); removidos `_SourceSelector`, seletor de fonte do header e `_QualityDialog` antigo |
| `lib/features/player/player_screen.dart` | Recebe `AnimeSource provider` + `List<CatalogEpisode> episodeList`; re-resolve via `resolveProvidersForEpisode` quando necessário; `_playNextEpisode` no novo contrato |
| `test/sources_corrections_test.dart` | Teste de `mergeEpisodes` substituído por teste de `bestMatch` (`resolveAnime` escolhe o melhor candidato por título) |
| `test/ptbr_adapters_test.dart` | `getEpisodes` do Goyabu/DooPlay espera `Success<List<Episode>>` |
| `test/live_sources_probe_test.dart` | Reescrito para o contrato `resolveAnime`/`resolveVideo` |
| `test/live_focus_probe_test.dart` | Reescrito para `resolveVideo(t, n)` direto por adapter |
| `test/live_path_probe_test.dart` | Reescrito para `getCatalogEpisodes` + `resolveProvidersForEpisode` no caminho real do app |

## 4. Arquivos criados

| Arquivo | Propósito |
|---|---|
| `lib/core/storage/provider_match_store.dart` | Persistência anilistId→página do provider (D4) |
| `test/catalog_resolver_test.dart` | Contrato da nova arquitetura: grade canônica 1..N sem dados de provider + `resolveAnime`/`resolveVideo` de ponta a ponta (com `MockClient`) |
| `test/live_sources_probe_test.dart` | Probe live (fora do CI) por source × 4 animes QA |
| `test/live_focus_probe_test.dart` | Probe live (fora do CI) focada em 4 alvos por adapter |
| `test/live_path_probe_test.dart` | Probe live (fora do CI) do caminho real do app |

## 5. Arquivos removidos

| Arquivo | Motivo |
|---|---|
| `lib/core/sources/anilist_adapter.dart` | Provider AniList removido — nunca deve participar do fan-out/vídeo (metadata-only) |
| `lib/data/repositories/anime_repository_new.dart` | Caminho alternativo duplicado; ficou a implementação única no `anime_repository.dart` |
| `lib/core/sources/anime_source_adapter_factory.dart` | Código morto (nada referenciado) com mapeamento incorreto `anilist → AnimeFireAdapter` |

## 6. Mudanças arquiteturais (vs. antes)

1. **Grade independente do provider**: antes a grade de episódios era montada
   com `EpisodesResult` (url/source/owner por episódio, seletor de fonte na
   UI). Agora a grade é `CatalogEpisode` puro, e a escolha de provider acontece
   **só no momento de tocar num episódio**.
2. **Provider = resolvedor, não catálogo**: os providers não definem mais a
   lista canônica; apenas resolvem páginas e streams sob demanda.
3. **Contrato em 2 verbos com defaults**: `resolveAnime` + `resolveVideo`
   herdados por todos os adapters — o custo de adicionar um provider novo
   continua sendo implementar `search`/`getEpisodes`/`getVideoSources`.
4. **Descoberta persistida**: o custo "achar a página por provider" (search +
   Cloudflare/429) é persistido (D4), não re-pago a cada cold start.

## 7. Comportamento esperado (UX)

- Abrir anime → grade canônica (AniList `episodesV2`; fallback 1..N).
- Tocar episódio → diálogo com providers (resolvidos em paralelo, cacheado),
  melhor prioridade pré-selecionada → escolher qualidade → player.
- Episódio seguinte no player → re-resolve o próximo `n` nos mesmos termos.
- Re-tap no mesmo episódio → serve do `AppCaches.resolutions` (sem re-scrape).

## 8. Decisões de implementação

| # | Decisão | Justificativa |
|---|---|---|
| D1 | `CatalogEpisode` novo; sem `url/source/owner` | Review rejeitou `ProviderEpisode`; a grade não vaza provider |
| D2 | Reuso de `VideoSource` (qualidade/url/headers) como saída de `resolveVideo` | Evita tipo novo; nada na review pede envoltório |
| D3 | `AnimeSourceAdapter` com métodos `implements`→`extends` | Defaults só são herdados com `extends` (causa raiz dos erros `non_abstract_class_inherits_abstract_member`) |
| D4 | `resolveAnime`/`resolveVideo` com default no adapter | Adapters iguais herdam; só sobrescrevem se a numeração exigir |
| D5 | Match de provider reusa `Anime` (não cria modelo novo) | O match é só url+source; `Anime` já carrega ambos |
| D6 | `ProviderMatchStore.identity` = `anilistId ?? cleanTitle` | Id estável evita deriva de título entre providers |
| D7 | Provider de melhor prioridade pré-selecionado no diálogo | Menos cliques no TV; fallback na ordem da `SourceRegistry` |
| D8 | Remoção da factory não usada | Código morto + mapeamento `anilist→AnimeFire` incorreto pós-refactor |
| D9 | `goyabu.getEpisodes` aceita URL relativa | URLs persistidas são relativas; sem isso a re-resolução 404 |

## 9. Problemas encontrados e resolvidos

- **`non_abstract_class_inherits_abstract_member`**: adapters usavam
  `implements` e não herdavam os novos defaults → troca para `extends`.
- **URL relativa no Goyabu**: `getEpisodes(Uri.parse('/anime/x'))` produzia URI
  sem host (404) → prefixar `$_base` quando relativo.
- **`ProviderMatchStore` import**: caminho errado de `text_utils.dart`
  (`core/storage` → `../utils/`) — corrigido no analyzer.
- **`live_focus_probe_test.dart`**: `repo` e helpers órfãos após a reescrita →
  removidos (analyzer).
- **`catalog_resolver_test.dart`**: `Anime()` exige `url` e a URL do match é
  relativa — assert e instanciação corrigidos.

## 10. Pendências (fora do escopo desta fase)

- 9 avisos pré-existentes no fluxo de login AniList
  (`anilist_auth_service.dart`, `anilist_service.dart`,
  `anilist_login_dialog.dart`, scanners `background` deprecado). Não
  tocados: são de uma feature distinta (autenticação) e pré-existem a esta
  fase.
- Probes live (`test/live_*.dart`) não rodam no CI (no-op sem `LIVE=1`).
  Rodar manualmente para validar os sites reais:
  `flutter test test/live_sources_probe_test.dart --dart-define=LIVE=1 --timeout 20m`.

## 11. Débito técnico

- `resolveAnime` (default) faz **uma** busca por nome e usa `bestMatch`; se o
  provider renomeou muito a obra, pode não achar de primeira. Upgrade path já
  previsto: busca com variações + persistência em `ProviderMatchStore`.
- O fan-out por episódio dispara `N` requests (um por provider) paralelos;
  `implemented=false` exclui adapters mortos. Se o nº de providers crescer
  muito, limitar concorrência (ex.: 4 em 4).
- Grade 1..N (fallback) sem thumbnail/título quando o AniList não tem
  `episodesV2` — aceitável, é o comportamento pré-existente.

## 12. Funcionalidades impactadas

- **Tela de detalhes**: grade canônica + novo fluxo de play
  (Episódio → Provider → Qualidade). Removido o dropdown de fonte.
- **Player**: contrato novo (`AnimeSource` + `CatalogEpisode`), re-resolução
  sob demanda, próximo episódio no mesmo caminho.
- **Busca (home)**: `searchAnime` agora só existe no `AnimeScraper`; a grade
  canônica vem do `AnimeRepository` (mesmo fluxo de antes).
- **Favoritos/AniList login**: intactos (fora do escopo).

## 13. Checklist de verificação

- [x] `flutter analyze` — **sem novos problemas** (apenas 9 pré-existentes no fluxo AniList)
- [x] `flutter test` — **13 testes passando** (inclui `catalog_resolver_test.dart` novo)
- [x] Grade canônica sem `url/source/owner` de provider
- [x] `AnimeScraper` reduzido a `searchAnime`
- [x] `AniListAdapter`, `anime_repository_new.dart`, factory não usada removidos
- [x] `_SourceSelector`, `_QualityDialog`, seletor de fonte do header removidos da UI
- [x] Descoberta de provider persistida (`ProviderMatchStore`) + caches TTL complementares
- [x] Contrato `resolveAnime`/`resolveVideo` com default testado de ponta a ponta (mock)
- [ ] Validação em device (TV) com sites reais via probes live — passo manual
