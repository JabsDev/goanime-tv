# Relatório Comparativo — GoAnime TV × AnimeCaos

> **Objetivo:** explorar o app desktop **AnimeCaos** (https://github.com/henriqqw/AnimeCaos)
> e levantar diferenças, boas ideias e fontes de anime que valham a pena
> trazer para o **GoAnime TV** (Android TV / Flutter). Nenhuma mudança de
> código foi feita nesta etapa; apenas análise exploratória.

---

## 1. Visão geral dos dois apps

|                        | **AnimeCaos**                     | **GoAnime TV**                        |
|------------------------|-----------------------------------|---------------------------------------|
| Plataforma             | Desktop (Windows/Linux/Flatpak)   | Android TV                            |
| Stack                  | Python + PySide6 (Qt)             | Flutter + Dart                        |
| Player                 | mpv externo (processo separado)   | media_kit (mpv embarcado)             |
| Resolução de streams   | delega para yt-dlp / mpv          | resolve mp4/m3u8 no próprio adapter   |
| Catálogo               | AniList (trending/temporada)      | AniList + fallback de scrapers        |
| Fontes PT-BR ativas    | AnimeFire, AnimesOnlineCC         | AnimeFire, Goyabu, DooPlay/BetterAnime/AnimesROLL, AnimePlayer |
| Extras                 | downloads, manga, Discord RPC, auto-update | favoritos, perfis, AniList (QR + web) |

**Convergência arquitetural importante:** os dois apps tomaram a **mesma**
decisão de não ter backend próprio e usar o **AniList como catálogo central**
(trending + temporada + watchlist / continue assistindo), deixando os
scrapers apenas para resolver o player sob demanda. Isso valida a nossa
direção de projeto.

O AnimeCaos tem features de UX desktop mais amadurecidas e uma fonte
exclusiva (**AnimesOnlineCC**) que ainda não temos. Abaixo, o que vale a pena.

---

## 2. Fontes de animes usadas pelo AnimeCaos

### AnimeFire (`plugins/animefire.py`) — já usamos
A mesma fonte que já temos. Reusam o **fast path via API JSON**
(`https://animefire.io/video/{slug}`) com **fallback Selenium** apenas se o
API falhar. Ponto que nos interessa: eles **escolhem a melhor qualidade
(1080p > 720p > 360p)** em vez de pegar a primeira da lista
(`_pick_best_source`), e o `_quality_rank` dá prioridade a um entry sem label
como última alternativa (nunca retorna vazio se existir qualquer origem).

### Fonte exclusiva: **AnimesOnlineCC** (`plugins/animesonlinecc.py`)
Fonte nova para nós — base `https://animesonlinecc.to`:
- **Busca:** `GET /search/<termo com +>`, parseia `div.data > h3 > a`.
- **Episódios:** a página tem `<ul.episodios>` **por temporada**. Eles
  registram as temporadas T2/T3 de forma **retroativa** depois de carregada a
  página, justamente para não disparar requisições extras durante a busca.
- **Stream:** pega o `iframe[src]` e **rejeita iframe `blogger.com/video`**
  (hospedagem indisponível). O `is_episode_playable` é um **cheque HTTP
  barato**: abre a página do episódio e devolve `False` se o HTML contém
  `blogger.com/video` — ótima heurística de pré-filtro sem abrir browser.

> **Ação recomendada:** o AnimesOnlineCC é candidato direto a um
> `AnimeSourceAdapter` novo no GoAnime TV. Scraping só com `http` + `html`
> (não precisa de browser), fonte legítima PT-BR. A lógica de temporadas e o
> `is_episode_playable` via `"blogger.com/video"` são portáveis 1:1.

### BetterAnime (`plugins/betteranime.py`) — desativado no AnimeCaos
O `load()` retorna cedo com comentário `betteranime.net DNS error` (fora do
ar). Nós também já temos BetterAnime (alias do DooPlay) no registry. A fonte
caiu nos **dois** lados — coerência entre os projetos.

### Scrapers removidos pelo AnimeCaos (CHANGELOG v2.0.0)
`animeplayer`, `hinatasoul`, `animesvision` — removidos por instabilidade/fora
do ar. **Nota útil:** nós temos `AnimePlayer` vivo
(`animeplayer_adapter.dart`). Fonte que o AnimeCaos descartou nós mantemos com
sucesso — isso valida a robustez do nosso modelo de múltiplas fontes + tolerância
a fonte morta no player, vs. o modelo deles (um único URL por episódio, sem
fallback entre fontes).

### yt-dlp/instalador — flag de alerta (não portável)
O AnimeCaos **prefere player externo + yt-dlp** (`mpv --hls-bitrate=max`,
`--ytdl-format=bestvideo[height>=1080]...`) e passa a URL do player direto
para o yt-dlp resolver m3u8/assinaturas externamente. Isso é bom no desktop
mas **não dá para usar no Android com media_kit**: yt-dlp é um binário externo
que não empacota bem e nós já resolvemos o mp4/m3u8 dentro do adapter e
repassamos os headers (Referer/UA) para o media_kit. Ideia aproveitável: a
flag **`--hls-bitrate=max`** — quando a URL for `.m3u8`, repassar essa opção
ao media_kit para priorizar 1080p sobre 720p em HLS variante.

---

## 3. Funcionalidades boas ideias para o GoAnime TV

Ordenadas por **impacto × esforço** no contexto de UI para TV (remoto/D-pad).
Fonte original entre parênteses.

### 3.1 Search inteligente com fallback progressivo + fuzzy — ⭐⭐⭐ alto
`main_window._search_with_translation` faz fallback em camadas:
1. query original (nós já fazemos igual).
2. **Expansão de palavras agregadas:** `"rezero" → tenta "re zero",
   "rez ero", "reze ro"` — resolve animes cujo slug está separado no site.
3. **Variantes de título via AniList** (`get_title_variants`: romaji/english)
   e o **primeiro token** (`"Re:Zero kara..." → "Re:"`).
4. **Fuzzy match** (`fuzzywuzzy.partial_ratio`) para escolher melhor
   resultado / casar discovery→scraper.

**No GoAnime:** já temos `AnimeScraper.bestMatch` + normalize e enriquecimento
AniList, mas **não tentamos variações de query**. Adicionar os passos 2 e 3
ao `searchAnime` daria um salto de qualidade para milhares de títulos cujo
site indexa por outro nome — sem servidor, reusando a busca existente depois
que o AniList resolve a variante.

### 3.2 Prefetch do próximo episódio em background ⭐⭐ `main_window._play_episode`
Enquanto o episódio atual abre, uma **thread de daemon resolve o próximo**
episódio (`resolve_player_url(ep+1)`). Quando o usuário termina, o autoplay é
**instantâneo** (URL já em cache).

Nosso PlayerScreen já tem autoplay + countdown. Falta o **prefetch dos
providers do ep. seguinte em background** antes do fim do atual — natural de
somar em `_playNextEpisode`/`_advanceSource`. Ganho real de UX na TV.

### 3.3 Escolher a melhor qualidade automaticamente (sem seleção manual) ⭐⭐
- `_pick_best_source` (AnimeFire) e `--hls-bitrate=max` (mpv).
- **Oportunidade:** no fluxo automático (autoplay/auto-next), tocar direto a
  melhor qualidade por padrão e só mostrar o seletor quando pedido, em vez de
  obrigar um clique a mais no controle remoto. Manter a lista para quando o
  usuário quiser trocar.

### 3.4 Estado/erro AniList categorizado no UI ⭐⭐ `anilist_service.py`
O `AniListStatus` (`ok/offline/ip_blocked/rate_limited/auth_error/server_error`)
gera um **banner por tipo** com mensagem context-aware ("Pesquisa, episódios e
player funcionam **normalmente**.") e usa **cache em disco de 4h** para
trending/temporada, garantindo discover funciona **offline**.

**No nosso:** já temos `TtlCache` e fallback para scrapers quando o AniList
falha, mas **não tipamos o status do AniList no UI**. Dar feedback categorizado
no home (banner com mensagem por tipo de erro) melhora a robustez percebida.
Persistir o trending em disco (por perfil) é extensão natural.

### 3.5 Rate limiter AniList central compartilhado ⭐⭐ `anilist_rate_limiter.py`
Liberação global única esperando `0.8s` entre chamadas a `graphql.anilist.co`
em todos os call sites, para nenhuma tela estourar o limite de ~90/min por
IP e derrubar outra chamada não relacionada (ex.: a busca de sinopses de
~50 cards de uma vez derrubava o login).
No GoAnime já temos limitação para o AnimeFire (250ms) e downscaling; mas a
ideia de uma **única fonte da verdade de pacing para o AniList** (evitando
que um `enrich` em lote derrube o `updateProgress`) é diretamente aplicável.

### 3.6 Preview na capa (Crunchyroll-style) ⭐ média `anime_card.py`
No AnimeCaos, passar o mouse expande o card com **nota, nº de episódios e
sinopse reais da AniList** (+ botão Assistir). Tudo **sob demanda só no hover**,
explicitamente para não estourar rate limit (não pré-buscam ~50 cards).

**No nosso:** TV/remoto não tem mouse. Equivalente natural: ao **focar** um
card (foco visual/d-pad), mostrar nota + sinopse num painel lateral. Baixa
prioridade pelo foco TV, mas a lição de **carregar metadados só sob demanda**
(uma busca ao focar, não N no início) é importante — já fazemos `enrich` sob
demanda; manter.

### 3.7 Downloads + biblioteca local de episódios ⭐⭐⭐ (features novas no GoAnime)
`downloads_service.py` (yt-dlp) + `download_worker.py` (cancelamento) +
biblioteca que escaneia a pasta por `"Anime - EPxx"` e re-lê um sidecar
`{título}.meta.json`. Mostra total de tamanho, agrupa por anime, permite
deletar.

No Android TV é um caso de uso real (streaming pode falhar em conexão
fraca). Exigiria outra biblioteca/bundle no lugar do yt-dlp. É uma feature
de produto que não temos e que agrega valor claro de "assistir offline".

### 3.8 Manga (LEITURA DE MANGÁ) ⭐ (surpresa) `manga_service.py`
O AnimeCaos inclui um **reader de mangá** via API pública do MangaDex
(capítulos PT-BR), com download CBZ para leitura offline.
> Fora do escopo do GoAnime TV (app de anime puro). Opcional para o futuro.

---

## 4. Detalhes técnicos aproveitáveis (sem feature nova)

- **Saltar temporadas retroativamente** no scraping (AnimesOnlineCC): reduz
  round-trips na busca; paradigma bom para nosso `getEpisodes` quando a fonte
  tem várias temporadas.
- **`is_episode_playable` barato** (checa o HTML por `blogger.com/video`):
  custa quase nada e evita listar episódio morto.
- **Pool de drivers/browser e page_load_timeout** com `driver_session`
  (context manager) — desnecessário no GoAnime (não usamos Selenium).
- **Estrutura de plugins + `PluginInterface` + logs** — arquitetura de
  fontes similar à nossa `AnimeSourceAdapter`; o padrão de plugins com
  `languages`/`name` espelha o nosso enum `AnimeSource`.
- mpv flags úteis via media_kit: `--hls-bitrate=max` e
  `--ytdl-format=bestvideo[height>=1080]...`.
- Cobertura de teste **forte** (36 arquivos, 168 testes) em behaviors UI que
  nós tratamos como hacks (`test_spotlight_title_wrap`, `test_search_view...`).

---

## 5. Resumo das recomendações (prioridade)

1. **Adicionar AnimesOnlineCC como fonte** (nova fonte PT-BR, scraping leve,
   portável 1:1) — ⭐ alto.
2. **Search com variantes + fuzzy** em `AnimeScraper.searchAnime` (reduzir
   "não achei" para animes com título divergente) — ⭐ alto.
3. **Prefetch do próximo episódio** em background no player — ⭐ médio.
4. **`--hls-bitrate=max` / escolher melhor qualidade automaticamente** no
   autoplay — ⭐ médio.
5. **Status/erro AniList categorizado + cache em disco** de trending — ⭐ médio.
6. **Rate limiter único do AniList** — ⭐ médio.
7. **Preview no foco TV (equivale ao hover)** — depois, se couber no fluxo de D-pad.
8. **Downloads offline** — feature maior de produto, avaliar roadmap.

---

## 6. Notas de execução (não testei o app)

Conforme pedido, **não rodei o app no emulador**: o AnimeCaos exige desktop
(PySide6 + Firefox/Selenium + mpv) e não é executável no `avdmanager` do
GoAnime TV. A análise foi 100% baseada em leitura de código fonte (clone em
`/tmp/opencode/animecaos`), arquivos de deploy, CHANGELOG e testes.
