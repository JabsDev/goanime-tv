# Plano de Implementação — Fontes Novas via CDN Direta (mangas.cloud / animeflix.blog)

**Data:** 10/08/2026
**Escopo desta etapa:** NENHUMA alteração de código — apenas teste das fontes e plano de implementação.
**Método de teste:** probe HTTP estático (curl + parse de HTML/JSON), sem browser, espelhando o padrão do app (`http` + `html`). Sondei as 16 fontes do relatório do usuário + os CDNs revelados.

---

## 1. Descoberta central (o "ouro")

Vários sites agregadores brasileiros **não servem o vídeo deles** — apenas **espelham** arquivos `.mp4` de uma **CDN própria**, num padrão de caminho previsível:

```
https://<cdn>/Animes/Letra-<1ª letra do título>/<Título>/<nº-do-episódio>.mp4
```

Exemplos verificados ao vivo (HTTP 206 = range/seek OK, mp4 direto, sem anúncio, playável pelo media_kit):

| CDN | Dono | Exemplo confirmado |
|---|---|---|
| `https://mangas.cloud` | animesonline.cloud | `/Animes/Letra-B/Black Clover/27.mp4` OK · `/Animes/Letra-B/Black-Clover-Dublado/01.mp4` OK |
| `https://animeflix.blog` | animeflix | `/Animes/Letra-O/One Piece Fan Letter/01.mp4` OK |

- `mangas.cloud/` raiz só abrevia um redirect brandado ("...assiste em animesonline.cloud/"); diretórios sobem **403** → não dá para enumerar o catálogo, a URL precisa vir do agregador ou ser construída a partir do título.
- Arquivos respondem **206 (range)** → seek normal no player.

### Como o agregador expõe a URL direta (o achado-chave)

Na família "AnimesOnline-clone" (animesonline.cloud / animesdrive.online / animeq.blog / animeplay.cloud), o episódio é um post WordPress com `data-post / data-nume / data-type`. O endpoint de player do tema DooPlay devolve o mp4 **direto da CDN** no parâmetro `source`:

```
GET https://animesonline.cloud/episodio/one-piece-fan-letter
  → data-post='26479' data-nume='1' data-type='tv'

GET https://animesonline.cloud/wp-json/dooplayer/v2/26479/tv/1
  → {"embed_url":"https://animesonline.cloud/jwplayer?source=https%3A%2F%2Fanimeflix.blog%2FAnimes%2FLetra-O%2FOne+Piece+Fan+Letter%2F01.mp4&id=26479&type=mp4","type":"mp4"}
```

`source=` = URL do mp4 na CDN. Não precisa resolver o jwplayer: basta fazer `decodeUrlComponent(query['source'])`.

Para Black Clover (dublado) no mesmo host:

```
GET .../episodio/black-clover-dublado-episodio-01  → post 76983 nume 1
GET .../wp-json/dooplayer/v2/76983/tv/1
  → source=https://mangas.cloud/Animes/Letra-B/Black-Clover-Dublado/01.mp4
```

Nota: o título no caminho da CDN **não é o slug** nem o nome AniList — é o nome de exibição do site (com hífens/acentos como em "Black-Clover-Dublado"). **Sempre que possível, usar o `source=` vindo do agregador** em vez de reconstruir o caminho.

### Clones compartilham o mesmo banco

`animesonline.cloud`, `animesdrive.online` e `animeq.blog` devolveram o **mesmo post id (26479)** e a **mesma URL CDN** para o mesmo episódio. São o mesmo site em domínios diferentes → **um adapter parametrizável por baseUrl cobre os três**. `animeplay.cloud` tem a mesma marcação `data-post` mas o endpoint `dooplayer/v2` devolve **corpo vazio (HTTP 200 sem JSON)** — precisa de diagnóstico específico ou do fallback por probe de CDN (seção 3).

---

## 2. Matriz de fontes testadas

Legenda: ✅ ok sem browser · ⚠️ parcial/laborioso · ❌ bloqueado para `http`+`html`.

| Site | Busca | Episódios | Vídeo (via http) | Veredito |
|---|---|---|---|---|
| animesonline.cloud | ✅ `/?s=` server-rendered → `/anime/<slug>` | ✅ `.episode-card` no DOM do anime page | ✅ **mp4 direto da CDN** via `dooplayer/v2` (animeflix.blog / mangas.cloud) | **IMPLEMENTAR** |
| animesdrive.online | ✅ idem | ✅ idem | ✅ idem (mesmo post id) | **IMPLEMENTAR** (clone) |
| animeq.blog | ✅ idem | ✅ idem | ✅ idem (mesmo post id) | **IMPLEMENTAR** (clone) |
| animeplay.cloud | ✅ `/?s=` | ✅ `.episode-card` | ⚠️ `dooplayer/v2` vazio → tentar probe CDN | **IMPLEMENTAR** com fallback |
| betteranime.io | ✅ (adapter DooPlay existente) | ✅ `/episodios/` | ⚠️ hoje o resolver jwplayer quebra (relatório 0 providers); avaliar extração `source=` via `dooplayer/v2` | **REFATORAR resolver** |
| animesonline.io | ✅ `/?s=` (server-rendered) | ⚠️ anime page **sem** episódios no DOM (AJAX) | não confirmado | **SPIKE** (achar endpoint AJAX) |
| animesonline.blue | ✅ homepage | ⚠️ `wp-json` público exige login (`rest_not_logged_in`) | não confirmado | **SPIKE** |
| sushianimes.com.br | ✅ `/?s=` (retorna lista, parece não filtrar por query) | ⚠️ sem episódios no DOM | não confirmado | **SPIKE** (live-search AJAX) |
| animes.tokyo | ⚠️ SPA (busca não vem no HTML) | n/d | n/d | **SPIKE** (API interna) |
| animesonlinecc.to | ✅ `/?s=` | ✅ (spike anterior: temporadas no DOM) | ❌ player = só `blogger.com/video.g?token=` (SPA JS) | **DESCARTAR** (já documentado) |
| smartanimes.net | ❌ Cloudflare **403** | ❌ | ❌ | **DESCARTAR** (CF) |
| donghuanosekai.com | ✅ (devolve até páginas de episódio) | ⚠️ player `/player?file=<b64>` JS | ⚠️ `blob:` (usuário) / mp4 só em promo | **SPIKE / baixa prioridade** |
| animesdigital.org | ✅ `/?s=` | ✅ links | ⚠️ `blob:` (usuário) | **BAIXA** |
| dattebayo-br.com | ✅ catálogo `/animes/letra/` | não confirmado | não confirmado | **SPIKE** |
| goyabu.io | ✅ (adapter existente) | ✅ `allEpisodes` | ✅ `layersData` HLS (adapter existente) | manutenção pontual |
| animeplayer.com.br | ✅ (adapter existente) | ✅ | ⚠️ resolvedor defasado (token thatwebsite) | refatoração pontual |

Conclusão: **a família dooplay-clone é o maior ganho com menor esforço** — busca e episódios em HTML puro + vídeo mp4 direto da CDN. As demais exigem spike para achar endpoint AJAX ou caem em paredes (Cloudflare/blob/blogger).

---

## 3. Estratégia em 3 camadas

1. **Camada A — extrair o mp4 direto do agregador (primário).**
   Fluxo por episódio: anime page `.episode-card` → página do episódio (`data-post/nume/type`) → `wp-json/dooplayer/v2/<post>/<type>/<nume>` → `source=` (mp4 CDN). Zero anúncio, zero JS.
2. **Camada B — resolver direto na CDN (fallback).**
   Catálogo de CDNs conhecidas (`mangas.cloud`, `animeflix.blog`, configurável). Dado `título + nº`, constrói `Animes/Letra-<X>/<título>/<n>.mp4` e faz **probe barato de 1 byte (range 0-0)**: primeira CDN que responder **206** ganha. Cobrir os casos em que a API do agregador morre (animeplay.cloud) ou o player é blob/blogger.
3. **Camada C — variantes de título.**
   Quando a Camada B falha por divergência de título (acento, hífen, "Dublado/Dublado-Todos-Os-Episódios"), tentar variantes: título display do agregador (casa com a CDN), nome romaji/english do AniList, com/sem acento, com/sem sufixo Dublado.

Regra:"sempre o `source=` do agregador; probe de CDN é fallback". O título CDN é o do site — reconstruí-lo sozinho é frágil.

---

## 4. Integração no app (arquitetura atual)

Pontos de contato (arquivos existentes):

| Arquivo | Mudança pretendida |
|---|---|
| `lib/data/models/anime.dart` | novos `AnimeSource` (`animesOnlineCloud`, ...), `sourceName`, `isPtBr` e `priority` |
| `lib/core/sources/source_registry.dart` | registrar adapters novos em `_adapters`, `fallbackOrder`, `getPriority`, `forSource` |
| `lib/core/sources/anime_source_adapter.dart` | sem mudança de contrato (novos adapters implementam a interface) |
| `lib/core/sources/dooplay_adapter.dart` | **reusar o mesmo tema**: extrair `source=` de `embed_url` em vez de resolver jwplayer (beneficia betterAnime/animesRoll) |
| `lib/data/models/episode.dart` | `VideoSource(headers)` já suporta Referer/UA p/ a CDN |

Desenho novo (mínimo):

- **`lib/core/sources/dooplay_v2_extractor.dart`** (helper compartilhado): dado episódio page → `data-post/nume/type` → GET dooplayer → `source=` → `VideoSource(url: mp4, headers: {Referer: baseUrl, UA})`. Falha tipada quando o JSON vier vazio.
- **`lib/core/sources/cdn_resolver.dart`** (fallback): lista de CDNs + probe range + cache por (título, ep). Usado pela Camada B.
- **`lib/core/sources/animesonline_adapter.dart`**: classe parametrizada por `baseUrl` cobrindo o cluster (animesonline.cloud, animesdrive.online, animeq.blog, animeplay.cloud) — mesmo padrão do `DooPlayAdapter` que já cobre 3 sources com um `Map<AnimeSource, String> baseUrls`.
  - `search`: `GET /?s=<query>` → cards de resultado → `Anime(name, url=/anime/<slug>, fallbackImageUrl)`.
  - `getEpisodes`: anime page → `.episode-card` (data-episode-number + href `/episodio/<slug>`).
  - `getVideoSources`: episódio page → Camada A; se vazio → Camada B/C.

Sem mudança no fluxo `AnimeRepository.resolveProvidersForEpisode` / `AnimeScraper` — os adapters novos entram como "implemented" e participam do fan-out normalmente.

---

## 5. Fases de implementação

### Fase 0 — Spikes pendentes (fechar antes de codar a Camada A para esses)
- animesonline.io: descobrir o endpoint AJAX que carrega os episódios do anime page.
- sushianimes.com.br: descobrir o live-search AJAX real (o `?s=` não filtra).
- animeplay.cloud: reproduzir o `dooplayer/v2` vazio (falta header/nonce? rota com slug-ação?); validar se a Camada B cobre.
- animesonline.blue / animes.tokyo / dattebayo-br.com / donghuanosekai.com / animesdigital.org: decidir entre implementar (Custo B) ou documentar como descartadas.

### Fase 1 — Helpers compartilhados
1. `dooplay_v2_extractor.dart`: parser `data-post/nume/type` + decode de `embed_url?source=`. Testes com `MockClient` (HTML/JSON fixos).
2. `cdn_resolver.dart`: `buildCdnUrl(cdn, title, ep)` (letra), `probe(url)` (range `0-0`, 206 = ok), cache TTL por anime. Testes com `MockClient`.

### Fase 2 — Adapter do cluster (maior ROI)
3. `animesonline_adapter.dart` com `baseUrls` para os 4 clones (+ melhorar `DooPlayAdapter` com o mesmo extractor).
4. Wire-up em `anime.dart`, `source_registry.dart`, `anime_repository.dart` (nada exigido no repo, só registry/priority).
5. Verificação: `flutter analyze` + testes de regressão existentes (`test/ptbr_adapters_test.dart`, `sources_corrections_test.dart`).

### Fase 3 — Fallback CDN
6. Ligar Camada B no `getVideoSources` do adapter do cluster (e, futuramente, num resolver genérico por título AniList).
7. Rate-limit amigável: probe serializado (reuso do padrão de throttle do AnimeFireAdapter) e cache dos "CDN por título".

### Fase 4 — Testes
8. Fixtures: HTML de busca/anime page/episódio + JSON do dooplayer (clone dos cortes ao vivo desta spike) em `test/fixtures/`.
9. `ptbr_adapters_test.dart` estendido para o novo adapter (MockClient).
10. `live_sources_probe_test.dart` ganha os novos sources na lista `_animes`.

### Fase 5 — QA (Fire Stick)
11. Buscar "One Piece" e "Black Clover" → reproduzir episódio 1 direto via CDN; checar seek/qualidade/log sem erro.
12. Conferir que `animesonline.cloud` (fonte com anúncio) nunca é chamada para vídeo além do mínimo de cupom (a CDN não tem anúncio).

---

## 6. Riscos e decisões abertas

| Risco/Decisão | Impacto | Ação |
|---|---|---|
| CDN muda de domínio/padrão | fonte inteira morre | manter lista de CDNs em config; probe 206 antes de oferecer |
| Título CDN ≠ título AniList (acento/hífen/"Dublado") | Camada B erra | sempre Camada A primeiro; Camada C com variantes |
| `dooplayer/v2` vazio em animeplay.cloud | 1 fonte do cluster falha | diagnóstico Fase 0 ou deixar fora do cluster inicial |
| Cloudflare (smartanimes) | sem scraping | descartar documentado |
| SPA sem API exposta (animesonline.io, animes.tokyo) | busca em HTML impossível | spike; se não achar, descartar |
| 429 em sushianimes | trava | UA real + retry (padrão já existente) |
| Quantas qualidades a CDN serve | UI de qualidade | investigar serviço (o `type=mp4` sugere 1 qualidade; se desejar multi, ver subpastas) |
| Prioridade vs fontes atuais | ordenação do seletor | definir na Fase 2: cluster acima de AnimeFire? (CDN = direto sem anúncio → provavelmente sim) |

---

## 7. Critérios de aceite

1. Cluster animesonline.cloud/drive/q.blog resolve episódios de One Piece e Black Clover via mp4 direto da CDN (206, reproduz no media_kit) no host e no Fire Stick.
2. Nenhuma chamada a player com anúncio; vídeo vem sempre do `source=` ou do probe de CDN.
3. Fontes descartadas (smartanimes, animesonlinecc) permanecem fora do fan-out (`implemented=false`) com entrada no README.
4. `flutter analyze` limpo e testes de regressão verde; novos fixtures+casos de teste para o adapter.
5. Seletor de qualidade/headless de vídeo intactos (nenhuma mudança na UI).