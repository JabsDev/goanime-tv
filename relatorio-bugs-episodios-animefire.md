# Relatório de bugs — episódios incompletos + AnimeFire fora do ar

Data da investigação: 09/09/2026 (probes ao vivo contra o site real).
Escopo: somente diagnóstico. Nenhum código foi alterado.

---

## TL;DR

1. **AnimeFire refez o site inteiro** (HTML estático → Angular SPA + API em
   `api.animefire.io`). As 3 rotas/seletores que o app usa **morreram**:
   busca antiga retorna **404**, seletor de episódios casa **0 elementos**,
   extrator de vídeo procura endpoints que **não existem mais**.
   → AnimeFire está 100% inoperante no app, não é instabilidade temporária.
2. **Grade de episódios curta em vários animes**: o fallback
   `_episodeCountFromProviders` (`lib/data/repositories/anime_repository.dart:144`)
   retorna `data.length` (tamanho da lista do provider) em vez do **maior número
   de episódio**. Qualquer provider com lista parcial/paginada encolhe a grade.
   Com o AnimeFire morto, esse fallback passou a morder com mais frequência
   (é o 1º da ordem de tentativa).
3. **Matches obsoletos nunca são invalidados**: `ProviderMatchStore.removeMatch`
   existe mas **nunca é chamado** — URLs antigas do AnimeFire
   (`/animes/...-todos-os-episodios`, hoje 404) ficam persistidas e o app
   continua batendo em página morta sem redescobrir.
4. **Fonte secundária morta**: `animeplay.cloud` (cluster AnimesOnline)
   retorna **403** — 1 das 12 fontes do `SourceRegistry` está fora do ar.

---

## Bug 1 — AnimeFire não funciona mais (causa raiz: migração do site)

### Evidências (probes ao vivo, 09/09/2026)

| Probe | Resultado |
|---|---|
| `GET animefire.io/` | 200, ~1,4 MB (site no ar) |
| `GET animefire.io/pesquisar/naruto` (rota que o app usa) | **404** `Página não encontrada - AnimeFire` |
| `GET animefire.plus/pesquisar/naruto` | 301 → `animefire.io/...` → 404 (domínio `.plus` só redireciona) |
| `GET animefire.io/animes/pesquisar?q=naruto` (rota nova) | 200, 30 cards `<h3>` com títulos reais |
| `GET animefire.io/anime/04rj0-NUrQm` (página de anime nova) | 200, 46 `<app-episode-card>` mas **0 `<a href>` de episódio** |
| `GET api.animefire.io/animes/pesquisar?q=naruto` | 200 JSON `{data:[{id,title,...}]}` |
| `GET api.animefire.io/anime/04rj0-NUrQm` | 200 JSON `{data:{hero, seasons, episodes:[{id,number,title,...}]}}` |
| `GET api.animefire.io/episode/fNJFA2VYxBH` | 200 JSON `{data:{streams:[{url, qualities}], nextEpisode}}` |
| Tentativas `/watch/:id`, `/assistir/:id`, `/episodio/:id`, `/anime/:id/1`, `/embed/:id` (na API) | todas **404** — player é modal SPA, sem rota própria |

### O que quebrou no código (arquivo: `lib/core/sources/anime_fire_adapter.dart`)

| Método | Código atual | Situação no site novo |
|---|---|---|
| `search` (l.66) | `GET {base}/pesquisar/{slug}` + seletores `.row.ml-1.mr-1 a` / `.card_ani` | Rota **404**. Busca nova é `/animes/pesquisar?q=` (ou API). Títulos novos em `<h3>`, links `/anime/{id opaco}`, thumbs `alt="Poster"` genérico |
| `_extractEpisodeUrls` (l.224) | seletor `a.lEp.epT.divNumEp.smallbox.px-2.mx-1.text-left.d-flex` | **0 matches**: cards são `<app-episode-card>` com navegação por `click` Angular, **sem `<a href>`**. Episódios estão no JSON `ng-state` (`episodes:[{id, number,...}]`) ou na API |
| `_extractFromAnimeFire` (l.266) | regex `animefire.(plus\|io)/video/...`, `data-video-src`, `<video><source>`, iframe Blogger | Endpoint `/video/` **não existe mais**; player novo é modal que consome `GET /episode/{id}`. Streams vêm de **`akumast.net`** (ex.: `https://akumast.net/i/.../m.jpg`, 480p), não Blogger/mp4 direto |
| `_videoApiRe` (l.54) | `https://animefire.(plus\|io)/video/...` | morto |

Ou seja: **search → 404, getEpisodes → lista vazia, getVideoSources → vazio**.
Todo o caminho do AnimeFire falha em cascata; no `resolveProvidersForEpisode`
ele cai sempre em `notFound`/`matchedUnavailable`.

### Site novo — mapa para a futura correção

- Base site: `https://animefire.io` (Angular SPA, `base href="/"`, estado SSR em `<script id="ng-state">`).
- API pública (sem auth nos probes): `https://api.animefire.io`
  - `GET /animes/pesquisar?q={query}` → `{data:[{id, title, audio, poster_src,...}]}`
  - `GET /anime/{animeId}` → `{data:{hero, seasons, episodes:[{id, title, audio, season, number, still_src, synopsis}]}}`
  - `GET /episode/{episodeId}` → `{data:{streams:[{audio, url, qualities, is_offline}], nextEpisode:{id,...}}}`
- Cards de anime navegam para `["/anime", card.id]`; episódio abre modal via `watch.open(episodeId)` (sem URL roteável — o app **precisa** usar a API, scraping de HTML não alcança o vídeo).
- IDs são opacos (`04rj0-NUrQm`, `fNJFA2VYxBH`) — o `bestMatch` atual, que dá
  +15 para URL contendo `todos-os-episodios`, perde o sentido e deve ser revisto.
- `AppConstants.baseSiteUrl = 'https://animefire.io'` continua válido como origem.

---

## Bug 2 — vários animes sem listar todos os episódios

A grade da tela de detalhe é canônica AniList (`getCatalogEpisodes`), então a
grade só encolhe quando `anime.episodes` é nulo/0 (em lançamento, falha de
enriquecimento) e o total vem do fallback de providers. Três defeitos
combinados explicam os relatos:

### 2a. `data.length` em vez do maior número (defeito real, alta confiança)

`lib/data/repositories/anime_repository.dart:130-154`:

```dart
case Success(data: final data):
  if (data.isNotEmpty) return data.length;   // <-- BUG
```

Se o provider que responder primeiro tiver lista parcial (paginação, filtro
dublado/legendado, parse incompleto), a grade nasce curta. O correto é o
**máximo `int.tryParse(e.number)`** da lista. Como o AnimeFire (1º da ordem)
morreu, o primeiro sucesso agora vem de providers menos testados — o fallback
passou a ser exercido muito mais, e o `length` passou a morder.

### 2b. `bestMatch` pode fixar página errada (filme/OVA em vez da série)

`lib/core/sources/anime_source_adapter.dart:98-153`. As penalidades de
spin-off existem, mas é heurística por string: mapeou para a página do filme
(1 ep) em vez da série (ex.: 220 eps), o `resolveVideo` de N>1 retorna `[]`
para aquele provider — episódio "existe na grade, mas sem fonte". O bônus
`todos-os-episodios` (+15) morreu junto com o site antigo (ver Bug 1).

### 2c. Matches errados/mortos são persistidos para sempre

`resolveProvidersForEpisode` (`anime_repository.dart:259-304`) salva o match
no `ProviderMatchStore` e nunca o remove: `removeMatch` existe
(`provider_match_store.dart:74`) mas **não tem nenhuma chamada** no código.
Consequências:

- URLs antigas do AnimeFire (`...-todos-os-episodios`, hoje 404) continuam
  sendo usadas sem redescoberta;
- um match errado (filme em vez de série, bug 2b) gruda no aparelho até
  limpar dados do app.

### Fatores agravantes (não são causa raiz, mas reduzem cobertura)

- `animeplay.cloud` → **403** (morta; demais do cluster OK: `goyabu.io` 200,
  `betteranime.io` 200, `animesonline.cloud` 200).
- `resolveVideo` casa episódio por `int.tryParse(e.number) == episodeNumber`
  (`anime_source_adapter.dart:71`); providers que numeram por temporada
  (`SxE`) ou com sufixos não casam e viram `matchedUnavailable` silencioso.
- DooPlay/AnimesOnline coletam episódios varrendo `<a>` da página de detalhe;
  se o tema paginar a lista ("carregar mais"), o parse captura só a 1ª página.

---

## Plano de correção sugerido (não executado)

1. **Reescrever `AnimeFireAdapter` sobre a API** (prioridade máxima):
   `search` → `GET api.animefire.io/animes/pesquisar?q=`; `getEpisodes` →
   `GET /anime/{id}` (campo `episodes[].number`); `getVideoSources` →
   `GET /episode/{id}` (`streams[].url`, com `qualities`). Investigar o
   formato real do stream `akumast.net` (redirect? token? m3u8?) antes de
   plugar no player.
2. **Fallback conta o máximo, não o tamanho**: trocar `return data.length`
   por max de `episodeNumberFromUrl`/`int.tryParse(e.number)`.
3. **Invalidar match morto**: no `resolve()`, quando `getEpisodes` der 404/
   lista vazia em URL persistida, chamar `removeMatch` e tentar redescobrir
   via `resolveAnime` uma vez.
4. **Remover/condicionar `animeplay.cloud`** do `SourceRegistry` (ou marcar
   `implemented=false`) enquanto devolve 403.
5. **Revisar `bestMatch`**: remover bônus `todos-os-episodios`; com IDs
   opacos, ponderar `audio` (dublado vs legendado duplicado) e temporada.
6. **Testes**: estender `ptbr_adapters_test.dart`/`resolve_anime_regression_test.dart`
   com fixtures da **nova** API (exemplos reais capturados em `/tmp/af_*.html`
   durante esta investigação — serão apagados com reboot; recapturar se preciso).

---

## Anexos — arquivos/pontos citados

- `lib/core/sources/anime_fire_adapter.dart` — l.66 (`search`), l.157
  (`getEpisodes`), l.224 (`_extractEpisodeUrls`), l.266
  (`_extractFromAnimeFire`), l.54 (`_videoApiRe`)
- `lib/data/repositories/anime_repository.dart` — l.76 (`getCatalogEpisodes`),
  l.130 (`_episodeCountFromProviders`), l.259 (`resolve`)
- `lib/core/sources/anime_source_adapter.dart` — l.65 (`resolveVideo`), l.98
  (`bestMatch`)
- `lib/core/storage/provider_match_store.dart` — l.74 (`removeMatch`, sem chamadas)
- `lib/core/sources/source_registry.dart` — l.20 (ordem das 12 fontes)
- `lib/core/constants/app_constants.dart` — l.3 (`baseSiteUrl`)
