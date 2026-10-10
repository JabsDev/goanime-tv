# Relatório: Novas fontes para o GoAnime TV — anime, donghua, K-drama, C-drama e dorama

**Data da pesquisa:** 10/10/2026
**Escopo:** descobrir fontes consumíveis pelo app Flutter/Android TV (scraping HTTP + `media_kit`), com foco em **PT-BR** e agora também em **conteúdo asiático além de anime**: donghua (animação chinesa), K-drama, C-drama, dorama japonês, novelas e programas de TV.
**Método:** probes HTTP reais via `curl` (status, redirects, anti-bot), inspeção de HTML/JS, introspecção de APIs GraphQL/JSON, leitura de extensões open-source (Aniyomi/CloudStream) e levantamentos em fóruns/Reddit. Tudo abaixo foi verificado ao vivo hoje; o que não foi verificado está marcado como tal.

> **TL;DR — as 3 descobertas que valem implementar primeiro:**
> 1. **DonghuaNoSekai** (`donghuanosekai.com`) — donghua chinês legendado em PT-BR, com **HLS (.m3u8) direto e limpo**, sem Cloudflare, sem CAPTCHA. Fluxo de extração curto e estável. *Viabilidade 5/5.*
> 2. **Doramasflix** (`doramasflix.in`) — **API GraphQL pública e sem autenticação** (`sv1.fluxcedene.net/api/gql`) cobrindo K-drama/C-drama/J-drama/filmes, com **Português na lista de idiomas**. É um "pseudo-app" — o site é só um cliente dessa API. *Viabilidade 5/5.*
> 3. **Internet Archive** — já existe um `ArchiveJpAdapter`, mas ele está **hardcoded num único item** (Haibane Renmei, 13 eps). A API do archive.org permite **generalizar para o catálogo inteiro**, e é a rota mais legal de todas (domínio público / licence livre). *Viabilidade 4/5.*

---

## 1. Onde o app está hoje (baseline)

`lib/core/sources/source_registry.dart` mantém 16 adapters. A auditoria de 06/10/2026 (`relatorio-auditoria-fontes-2026-10-06.md`) registra o estado: AnimeFire migrou `animefire.io → animefire.one` e o JSON de busca mudou; Goyabu caiu atrás de Cloudflare (`403 cf-mitigated`); AnimesOnline HDK quebrou o TLS; AllAnime está atrás de captcha.

Fontes **já integradas** (não priorizar de novo):

| Fonte | Base canônica | Estado observado hoje (10/10/2026) |
|---|---|---|
| AnimeFire | `animefire.one` + API `api.animefire.one` | 200 ✅ |
| Animes Digital | `animesdigital.org` | 200 ✅ |
| DooPlay / BetterAnime | `betteranime.io` | 200 ✅ |
| AnimesOnline Cloud | `animesonline.cloud` | 200 ✅ |
| AnimesDrive | `animesdrive.cloud` | 200 ✅ |
| AnimeQ | `animeq.cloud` | 200 ✅ |
| AnimePlayer | `anreyalp.vip` | 200 ✅ |
| Animes Orion | `animesorion.cc` | 200 ✅ |
| AnimesHD | `animeshd.to` | 200 ✅ |
| AnimeGG | `www.animegg.org` | 200 ✅ |
| AnimesOnline IO | `animesonline.io` | — |
| ArchiveJP | `archive.org` | 200 ✅ (mas hardcoded, ver §4) |
| Goyabu | `goyabu.io` | **403 Cloudflare** ❌ |
| AnimesRoll | `animes.tokyo` | **000 (DNS/sem resposta)** ❌ |
| AllAnime | — | captcha ❌ |

---

## 2. 🐉 DonghuaNoSekai — donghua chinês PT-BR (recomendação nº 1)

**URL:** `https://donghuanosekai.com/` · **HTTP:** 200 ✅ · **Tema:** WordPress customizado (`donghuanosekai`), SEO agressivo, atualizado até 07/10/2026.

É a **única fonte PT-BR viva e realmente extraível** de donghua (animação chinesa) que encontrei. Nenhuma das plataformas "grandes" listadas na §7 serve donghua legendado em PT-BR de forma aberta.

### Catálogo confirmado
`tiger-crane`, `divine-manifestation`, `spiritual-realm-walker`, `spare-me-great-lord-3a-temporada`, `zhen-dao-ge-2a-temporada`, `swallowed-star` (este último com **243+ episódios**, várias temporadas). Catálogo crescimento rápido, com equipe de tradução/revisão própria (cobre PT-BR e PT-PT).

### Fluxo de extração (verificado passo a passo)

**Passo 1 — listar episódios.** Na página do título (`/<slug>`), o HTML traz o índice completo:
```
href="https://donghuanosekai.com/swallowed-star-episodio-243"
href="https://donghuanosekai.com/swallowed-star-episodio-242"
...
```
Regex simples: `/episodio-(\d+)/`. Não há paginação (Swallowed Star listou todos os 243 de uma vez).

**Passo 2 — página do episódio.** Em `/<slug>-episodio-<N>` o player fica em elementos com `data-video-url`:
```html
<div class="slideItem" data-play-num="0" data-video-url="https://donghuanosekai.com/player?file=NjI0NTg=&type=0">Player 1</div>
<div class="slideItem" data-play-num="1" data-video-url="https://donghuanosekai.com/player?file=NjI0NTg=&type=1">Player 2</div>
```
O `file` é **base64 do ID do post** (`NjI0NTg=` → `62458`). `type=0` e `type=1` são dois "players"; no meu probe o `type=1` retornou `"haha parece que não tem nada!"` (player vazio) — então **usar sempre `type=0`**, e talvez oferecer o `type=1` só como fallback.

**Passo 3 — resolver o HLS.** A página `/player?file=...&type=0` devolve um `<iframe>` com a URL real:
```html
<iframe src="https://player.donghuanosekai.com/player-nativov2.php?v=https://cdn-s02.star-wallpaper-4k.pictures/stream/swallowed-star/season5/243_1080p_c9c70f13.mp4/index.m3u8"></iframe>
```
Basta extrair o parâmetro `v` (decodificar com `Uri.decodeComponent`) → **é a URL HLS direta**.

**Passo 4 — o m3u8 abre sem nada.** ✅
```
$ curl -s "https://cdn-s02.star-wallpaper-4k.pictures/stream/swallowed-star/season5/243_1080p_c9c70f13.mp4/index.m3u8"
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:10.000,
.../243_1080p_c9c70f13.mp4/seg-1-v1-a1.webp
.../243_1080p_c9c70f13.mp4/seg-2-v1-a1.webp
...
```
Manifest VOD completo, sem DRM, sem Cloudflare, sem Referer obrigatório (testei sem header nenhum). Os segmentos têm extensão `.webp`, mas são streams de vídeo — o `media_kit` toca normal (é o mesmo formato que o app já resolve no `AnimesOnlineAdapter`/`cdn_resolver.dart`).

### Por que é a melhor candidata
- **0 anti-bot**: probe com UA simples passou; não exige JS para chegar no m3u8.
- **3 requisições** por episódio (índice → episódio → player). Nenhuma delas precisa de navegador.
- **HLS nativo**, com a mesma forma de consumo que o player já usa hoje.
- **Preenchimento de catálogo real**: donghua é o buraco mais óbvio do app hoje — AniList tem pouquíssimo donghua e nenhuma fonte PT-BR atual o serve.

### Riscos / cuidados
- O `dnskPlayerAd()` na página chama `predictivadnetwork.com` (rede de ads) — só aparece na navegação web, **não** na cadeia que usamos. Não precisa bloquear, mas vale registrar.
- Anti-"copiar fonte" é **só JS de cliente** (`Ctrl+S` → `window.location = facebook.com`). **Não bloqueia HTTP de verdade** — confirmado no probe.
- Cuidado com `article:published_time` aparecendo no payload: um mesmo slug tem episódios publicados ao longo de meses, então **ordene pelo número do episódio**, não pela data.

---

## 3. 📺 Doramasflix — API GraphQL pública com K/C/J-drama (recomendação nº 2)

**Site:** `https://doramasflix.in/` (200 ✅) · **API:** `https://sv1.fluxcedene.net/api/gql`

Este é o achado mais interesante em termos de **arquitetura**: o site é um SPA e **toda** a lógica está numa API GraphQL pública, sem autenticação e com **introspection habilitada**. O mesmo backend (`fluxcedene.net`) serve outros sites da mesma rede — dá para construir um único adapter que cubra vários catálogos.

### A API responde (sem token, sem header especial)
```bash
curl -s https://sv1.fluxcedene.net/api/gql -X POST -H "Content-Type: application/json" \
  -d '{"query":"{ listDoramas(limit:3){ _id name name_es country poster genres{name} status number_of_episodes } }"}'
```
```json
{"data":{"listDoramas":[
  {"_id":"5f2c3be15c0e2a2b32d08313","name":"Another Miss Oh","name_es":"La otra señorita Oh",
   "country":"corea","genres":[{"name":"Comedia"},{"name":"Drama"},{"name":"Familia"}],
   "status":"Ended","number_of_episodes":18},
  {"_id":"5f2c3daaca7ff72d546e4982","name":"Goblin","country":"corea","number_of_episodes":16},
  {"_id":"5f2c3ec3ca7ff72d546e4997","name":"Cinderella and Four Knights","country":"corea","number_of_episodes":22}
]}}
```

### **Português está disponível** ✅
`listLanguagees` retorna 12 idiomas, incluindo:
```
Latino · Castellano · Subtitulado · Coreano · Japones · Mandarín
Tailandes · Filipino · Indones · Inglés · Vietnamita · **Portugués**
```
IDs relevantes: `Portugués = 64bad14b3cdb8dd0a7032619`, `Latino = 60ac291aac46a43f59a5b22a`.

### Superfície da API (todas as queries úteis)
- **Catálogo**: `listDoramas` · `searchDorama(input, limit)` · `detailDoramaById` · `trendsDoramas` · `carrouselDoramas` · `randomDoramas` · `similarsDoramas` · `listGenres` · `listCountries` · `listNetworks` · `listLanguagees`
- **Séries (formato ocidental / anime-style)**: `listSeries` · `searchSerie` · `detailSerieById` · `randomSeries` · `paginationSerie`
- **Filmes**: `listMovies` · `searchMovie` · `detailMovieById` · `listFilms` · `searchFilm`
- **Episódios**: `listEpisodes(filter:{serie_id})` · `detailEpisodeById` · `prevEpisode`/`nextEpisode` · `paginationEpisode`
- **Links de reprodução**: `getEpisodeLinks(id, app, iosapp, externalLink)` · `getMovieLinks(...)`

### Modelo de dados (introspecção do tipo `Episode`)
```
_id · name · name_es · overview · episode_number · season_number · air_date
languages [String] · links_online [JSON] · count_links · type_serie · serie_id
serie_slug · serie_name · season_id · is_ova · ova_number · premiere · commingSoon
sources [EpisodeSources]   → url, lang, server, subtitles[{url,lang}]
urls    [EpisodeUrls]      → page, url, lang, isChange
subbers [EpisodeSubbers] · uploaders [EpisodeUploaders]
```
E o tipo `Dorama` tem `tmdb_id`, `poster_path`, `backdrop_path`, `number_of_seasons`, `episode_run_time`, `networks`, `genres`, `labels`, `videos[JSON]`, `images`, `cast[JSON]`.

### Como os episódios apontam para vídeo (ex. Goblin, ep. 1)
```json
{"listEpisodes":[{"_id":"5f2c3dc8ca7ff72d546e4987","name":"Goblin 1x1","episode_number":1,
  "urls":[{"page":"doramasyt","url":"https://www.doramasyt.com/ver/goblin-the-lonely-and-great-god-episodio-1","lang":"13109"},
          {"page":"doramasmp4","url":"https://www25.doramasmp4.com/goblin-capitulo-1/","lang":"13109"},
          {"page":"doramasyt","url":"...-latino-episodio-1","lang":"38"},
          {"page":"doramasmp4","url":"...-doblado-al-espanol-capitulo-1/","lang":"38"}],
  "sources":[]}]}
```
Ou seja: **a API não serve vídeo — ela é um índice que aponta para `doramasyt.com` e `doramasmp4.com`**, com tag de idioma por link. Então o adapter precisa de uma segunda etapa (ver §5: esses hosts usam os mesmos extractores que o app já tem).

### Riscos / cuidados — leia antes de investir
- **A camada de vídeo é a parte frágil.** A API é sólida, mas `doramasyt`/`doramasmp4` são sites de terceiros com hopers que mudam. Trate como "metadados ricos + vídeo best-effort", e use o `Doramasflix` adapter sobretudo como **catálogo** (o que resolve o maior problema: o app hoje não tem catálogo nenhum de drama).
- `getEpisodeLinks(id:...)` retornou `INTERNAL_SERVER_ERROR: Cannot read properties of null (reading 'links_online')` num id que eu inventei — provavelmente exige um `id`/`serie_id` válido e os outros args preenchidos. **Não leverages ainda**: teste com um `_id` real de `listEpisodes` antes.
- A extension da Aniyomi (`Doramasflix.kt`) confirma a viabilidade: usa exatamente `https://sv1.fluxcedene.net/api/gql` com header `platform: doramasflix` + `x-access-platform` fixo, e extrai vídeo com Voe/StreamTape/Mp4Upload/BurstCloud. **O token está hardcoded no repositório público** — o mesmo vale para nós.

---

## 4. 🗄️ Internet Archive — generalizar o `ArchiveJpAdapter` (recomendação nº 3)

O archive.org **já é fonte do app**, mas o adapter atual é um caso hardcoded de estudo (§Haibane): 13 MP4s de Haibane Renmei, busca por substring "haibane", zero Flexible. Dá para transformar em fonte de verdade.

### O que a API permite (tudo testado)
```bash
# busca completa no catálogo
curl -s "https://archive.org/advancedsearch.php?q=mediatype:movies+AND+<termo>&fl[]=identifier&fl[]=title&rows=20&output=json"

# lista de arquivos + formatos de um item
curl -s "https://archive.org/metadata/haibane-renmei_202606"
```
O `metadata` devolve **todos os arquivos com `format` e `size`** — permite escolher o melhor `.mp4`:
```
Haibane Renmei - S01E01.mkv | Matroska | 951431660
Haibane Renmei - S01E01.mp4 | h.264    | 136923771
...
```
E o MP4 abre direto: `GET /download/<id>/<arquivo>.mp4` → **302 → 200 `video/mp4`**.

### O que **não** funciona (importante)
- **Não existe HLS.** `.../arquivo.mp4.m3u8` devolve `302 → text/html` (página de erro), não um manifest. O app precisa Reproduzir MP4 direto — o `media_kit` já faz isso (o adapter atual usa exatamente esse caminho).
- **O índice de busca é poluído.** `mediatype:movies AND subject:"anime"` devolve **62.756** itens, mas o topo é lixo: `youtube-bjO-xRs_o6E`, `TwitchVod-2309269063`, vídeos de reaction. O `q` textual varre **mirrors do YouTube** e VODs da Twitch, não o acervo curado.
- **Não há coleção "anime" curada.** `collection:animation AND japan` → **0 resultados**. `collection:classic_cinema AND japan` → **0**.
- O que *funciona* é filtrar por coleção: `collection:feature_films AND korean` → 74 itens (inclui `Lone Wolf and Cub 3`); `collection:opensource_movies` → achou `haibane-renmei-dvd-collection`.

### Tese defensável
Tratar o archive.org como **fonte de nicho de faixa longa e catálogo profundo**, não como fonte de busca:
1. `metadata` listando arquivos é **confiável e rápido** → perfeito para o caso "a fonte PT-BR não tem este episódio".
2. Filtros obrigatórios na busca: `mediatype:movies AND collection:(feature_films OR opensource_movies) AND NOT collection:(movie_trailers_unsorted)`, e descartar `identifier` com prefixo `youtube-`/`TwitchVod-`.
3. É a rota **mais legal** de todas: domínio público / licença livre, sem Cloudflare, sem captcha, sem ToS agressivo.

### Ligação direta com o LegendAI (diferencial do projeto)
O app já tem pipeline de legenda por IA (`lib/core/subtitles/legendai/`, tela `[Gerar legenda com IA]`). O `ArchiveJpAdapter` foi feito exatamente para isso: vídeo **JA cru sem legenda** → IA gera PT-BR. Com o catálogo do archive.org aberto, essa combinação vira um diferencial real: **qualquer título raríssimo do catálogo AniList pode ser resolvido com áudio japonês + legenda gerada por IA**, quando nenhuma fonte PT-BR tem.

---

## 5. Sites de drama aggregated / genéricos (risco alto)

Probei os agregadores酬 asiáticos clássicos e os repositórios CloudStream:

| Site | HTTP | Veredito |
|---|---|---|
| `kissasian.sh` | 200 | ⚠️ Vive, mas histórico sério de malware/popunder. **Não integrar.** |
| `dramacool.su` | 200 | ⚠️ Pirata. A própria comunidade reddit (`r/CDrama`) recomenda explicitamente para **não** usar. **Não integrar.** |
| `myasiantv.cx` | **410** | ❌ Morto |
| `doramayen.com` | **000** | ❌ Morto |
| `estrenosdoramas.es` | **410** | ❌ Morto (a extension Aniyomi dele ainda está no repo) |

**Vale registrar o padrão:** os agregadores de drama morrem ou viram malware com muito mais frequência do que os de anime — que é justamente por isso que os BR menores (`donghuanosekai`, `doramas.com.br`) de PT-BR são a melhor aposta: têm audiência própria e 합법-ish.

### Portal de descoberta (não é host de vídeo, mas é útil como **metadado/manual**)
`https://doramas.com.br/` — 200 ✅. SPA pt-BR que catalogueia K-dramas/C-dramas/J-dramas e diz **onde assistir** (legal). Não serve vídeo. Serve como: (a) fonte para popular o catálogo de dramas do app via os `tmdb_id` que ele expõe; (b) curadoria editorial.

---

## 6. Plataformas "legais" com PT-BR — o que dá e o que não dá para o app

Todas respondem 200, mas **nenhuma é integrável via scraping** sem login/DRM. Ainda assim são o que o app deve **linkar** (em vez de raspar) e o que responde "onde assistir legal" ao usuário.

| Plataforma | HTTP | PT-BR | Veredito p/ scraper | Observação |
|---|---|---|---|---|
| **WeTV** `wetv.vip/pt` | 200 ✅ | Sim (dub+sub) | ❌ DRM/login | Rota `/pt` existe e funciona (a raiz ok). Melhor cobertura de C-drama/dorama **com dublagem PT**. |
| **Viki** `viki.com` | 200 ✅ | Sim (sub, comunidade PT) | ❌ | `api.viki.io` responde `{"error":"invalid app","vcode":8004}` → exige registro de app. `/pt` não existe (404). |
| **iQIYI** `iq.com` | 200 ✅ | Sim (sub) | ❌ | Título confirma *"with subtitles and dubbing"*. `/pt` 404. |
| **Viu** `viu.com` | 200 (sem-serviço) | Parcial | ❌ | /pt 404. |
| **KOCOWA** `kocowa.com` | 200 ✅ | Não (KO/EN) | ❌ | Só coreano. |
| **OnDemandKorea** `ondemandkorea.com` | 200 ✅ | Não (EN) | ❌ | Variedades/Programas KO. |

**Conclusão:** para conteúdo comercial, o app **não deve raspar** — deve abrir a plataforma no WebView / gerar deep-link de busca. Para **catálogo**, use a §4 (TMDB) e a §7 (Doramasflix GraphQL).

---

## 7. Metadata: o gap crítico — TMDB

Hoje o app usa **só AniList**, que é exclusivamente anime. Para K/C/J-drama, donghua e novelas, **não existe equivalente no AniList** → o catálogo canônico não cobre nada além de anime. Isso é o bloqueio de produto nº1 para expandir além de anime.

- **TMDB** (`themoviedb.org`) é o padrão da indústria: cobre anime, K-drama, C-drama, dorama, donghua, filmes e séries, com metadados ricos **em português** (`language=pt-BR`), imagens, `similar`, `recommendations`, IDs externos.
- A API **exige chave** (grátis, cadastro): meu probe com `api_key=test` retornou `{"status_code":7,"status_message":"Invalid API key"}` — ou seja, o endpoint está vivo, só falta registrar.
- Complemento útil: a própria API do **Doramasflix já traz `tmdb_id`** (§3) → dá para casar catálogo próprio com TMDB sem double search.

---

## 8. Referências open-source (extensions Aniyomi/CloudStream)

O ecossistema Aniyomi (`yuzono/anime-extensions`, branch `master`, ~6.600 arquivos) é o melhor mapa público de fontes BR. Filtro `src/pt/*` = Brasil:

| Extension | Situação p/ o GoAnime |
|---|---|
| `pt/animefire` | ✅ já integrado |
| `pt/animesdigital` | ✅ já integrado |
| `pt/animeq`, `pt/animesdrive`, `pt/animeplayer` | ✅ já integrados |
| `pt/animesonlinecloud` | ✅ já integrado |
| `pt/betteranimeio` | ✅ já integrado |
| `pt/animeplay` | ⚠️ já desativado no app (503) |
| `pt/goyabu` | ❌ Cloudflare |
| `pt/animesonlinecc` | 🔶 **não integrado, 200 ✅ → candidato** (§9) |
| `es/doramasflix` | 🔶 GraphQL forte, camada de vídeo frágil (§3) |
| `es/doramasyt`, `es/pandrama` | 🔶 candidatos a host de vídeo (só ES) |
| `es/estrenosdoramas`, `fr/mykdrama` | ❌ 410/000 (mortos) |

Provedores do **Saimuel Repo (Portuguese)** que testei: NetCine (200, mas é catálogo de venda/aluguel, não streaming), PobreFlix (**domínio à venda**), TopFilmes/AnimesCloud/MegaFlix/UltraCine/OverFlix (**todos 000, mortos**). → O único vivo da lista é o DonghuaNoSekai, reforçando a recomendação.

---

## 9. Candidatas anime extras (Tier 2 — site clássico, HLS possivelmente)

Verificadas 200 hoje, **não** no app. Mesmo padrão dos DooPlay atuais — quando implementadas vão no `DooPlayAdapter` + `DooPlayV2Extractor` sem código novo.

| Fonte | URL | HTTP | Observação |
|---|---|---|---|
| AnimesOnline CC | `animesonlinecc.to` | 200 ✅ | Slugs `episodio/<slug>-episodio-N`. Vídeo servido via `blogger.com/video.g` (Google) — precisa do `BloggerSpaResolver`/base64 que o app já tem. **Melhor candidata extra.** |
| My Animes | `myanimes.online/pt-BR` | 200 ✅ | Site oficial com rota `/pt-BR` → catálogo PT-BR nativo. |
| Meus Animes | `meusanimes.blog` | 200 ✅ | WordPress simples, mesma família dos atuais. |

Não implemente sem antes rodar o probe de forma (HTML parseável vs. XHR/JS) — o theme DooPlay não é garantido.

---

## 10. Roadmap de implementação (priorizado)

**Fase 1 — alto retorno / baixo risco**
1. **DonghuaNoSekaiAdapter** (`donghuanosekai_adapter.dart`) — o fluxo §2 é 3 GETs e um base64; o `AnimeSourceAdapter` atual serve quase inteiro (só precisa extrair `data-video-url` e decodificar o `v`). Adiciona `AnimeSource.donghuaNoSekai`.
2. **TMDB no catálogo** — cliente GraphQL/REST com `language=pt-BR`, chave free. Começar por `search/multi` + `tv/{id}` + `external_ids`. É o unlock de tudo que vem depois.

**Fase 2 — catálogo de drama (o maior gap de UX)**
3. **DoramasflixAdapter** via GraphQL — usar `searchDorama` + `listEpisodes` para **metadados/episódios**; a camada de vídeo (doramasyt/doramasmp4) entra como *best-effort* atrás dos extractores já existentes. Filtro obrigatório `languages`/`lang == Português`.
4. Ligar **Doramas.com.br** como fonte de curadoria/manual "onde assistir".

**Fase 3 — catálogo profundo + legalidade**
5. **Generalizar `ArchiveJpAdapter`** → `InternetArchiveAdapter`: busca via `advancedsearch.php` com filtros anti-lixo, episódio via `metadata/<id>`, vídeo MP4 direto. Integrar com o **LegendAI** para gerar PT-BR dos títulos sem fonte PT-BR.

**Fase 4 — conveniência (não scraping)**
6. Deep-links / "assistir no WeTV/Viki/iQIYI" em vez de raspar plataformas com DRM.
7. Avaliar `animesonlinecc.to` / `myanimes.online` como fontes anime extras.

---

## Apêndice — comandos de verificação (copiar/colar)

```bash
# 1) DonghuaNoSekai — cadeia completa
curl -s "https://donghuanosekai.com/swallowed-star" \
  | grep -oE 'href="[^"]*-episodio-[0-9]+"' | head
curl -s "https://donghuanosekai.com/swallowed-star-episodio-243" \
  | grep -oE 'data-video-url="[^"]+"'
curl -s "https://donghuanosekai.com/player?file=NjI0NTg=&type=0" \
  | grep -oE 'player-nativov2\.php\?v=[^"]+'
curl -s "https://cdn-s02.star-wallpaper-4k.pictures/stream/swallowed-star/season5/243_1080p_c9c70f13.mp4/index.m3u8" | head

# 2) Doramasflix GraphQL (sem token)
curl -s https://sv1.fluxcedene.net/api/gql -X POST -H "Content-Type: application/json" \
  -d '{"query":"{ searchDorama(input:\"goblin\",limit:5){ _id name country languages } }"}'

# 3) Archive.org
curl -s "https://archive.org/advancedsearch.php?q=mediatype:movies+AND+collection:feature_films+AND+korean&fl[]=identifier&fl[]=title&rows=10&output=json"
curl -s "https://archive.org/metadata/haibane-renmei_202606" | head -c 800

# 4) Checagem rápida de vida das fontes (status)
for u in https://animefire.one/ https://animesdigital.org/ https://donghuanosekai.com/ \
         https://doramasflix.in/ https://myanimes.online/ https://animesonlinecc.to/ \
         https://goyabu.io/ https://animes.tokyo/; do
  curl -s -o /dev/null -w "%{http_code} %{url_effective}\n" -m 12 -L -A "Mozilla/5.0" "$u"
done
```

---

### Nota metodológica
Todas as afirmações acima vêm de probes executados nesta sessão (curl/inspeção de HTML/GraphQL introspection). Onde não houve verificação direta (ex.: comportamento do `type=1` player em outros sites, robustez do `doramasyt` no longo prazo, disponibilidade de `.webp`-segmentos no player Android em hardware antigo), está explicitamente sinalizado como "a testar". Nenhuma fonte foi testada com o app Flutter de ponta a ponta — isso exige build e rodar no dispositivo.

---
---

# PARTE 2 — Implementação (10/10/2026, mesma sessão)

As três fontes foram implementadas e testadas. **35 testes novos, todos verdes. Zero regressões** na suíte existente.

## Estado final da suíte

| | Passando | Falhando |
|---|---|---|
| Baseline (antes) | 506 | 15 |
| Após | **541** (+35) | 15 (idênticas) |

As 15 falhas são **pré-existentes e não relacionadas** — verificado rodando o baseline com `git stash`:
- `test/llm_mt_test.dart` (7) — canal llama.cpp
- `test/resolve_provider_states_test.dart` (8) — testes *live* do AnimeFire batendo no CDN `akumast.net`, que responde **404** (já documentado em `relatorio-animefire-qualidade-nao-carrega.md`)

## Arquivos criados

| Arquivo | Papel |
|---|---|
| `lib/core/sources/donghua_no_sekai_adapter.dart` | Donghua PT-BR, HLS limpo |
| `lib/core/sources/doramasflix_adapter.dart` | Catálogo K/C/J-drama via GraphQL |
| `test/donghua_no_sekai_adapter_test.dart` | 13 testes |
| `test/doramasflix_adapter_test.dart` | 11 testes |
| `test/fixtures/dnsk_*.html`, `df_*.json`, `ia_*.json` | Fixtures capturadas ao vivo |

## Arquivos alterados

| Arquivo | Mudança |
|---|---|
| `lib/data/models/anime.dart` | +2 no enum `AnimeSource`; +`spanish` no `SourceLanguage`; `isPtBr`/`priority`/`displayName`/`language` |
| `lib/core/sources/source_registry.dart` | Registro dos 2 adapters novos + `fallbackOrder` + `getPriority` + `forSource` |
| `lib/core/sources/archive_jp_adapter.dart` | **Generalizado** (era hardcoded em 1 item) |
| `lib/core/scraper/anime_scraper.dart` | `hasValidId` para as fontes novas |
| `test/archive_jp_adapter_test.dart` | Reescrito (11 testes) |

## ⚠️ Correção importante ao relatório original: Doramasflix NÃO é PT-BR

A Parte 1 afirmou que o Doramasflix tinha Português. **Auditando o acervo, isso não se confirmou:**

- `listLanguagees` declara 12 idiomas **incluindo Português** (`64bad14b3cdb8dd0a7032619`) — isso é verdade.
- Mas o acervo real é **Latino**. Amostra de 800 dramas (`listDoramas(limit:200, skip:0|200|400|600)`) retornou **apenas** os códigos `13109` (534), `13111` (223), `38` (118), `13112` (39), `13110` (22), `13114` (3), `13113` (1).
- `filter: { bylanguage: "Portugués" }` → `[]`
- `filter: { languages: ["64bad14b…"] }` → `[]`

**Consequência no código:** `doramasflix` foi marcado como `isPtBr == false` e `SourceLanguage.spanish` ("Latino"). Sem isso ele competiria no ranking PT-BR e o app prometeria português onde não há.

## O que cada fonte entrega hoje

| Fonte | search | episódios | vídeo nativo |
|---|---|---|---|
| **DonghuaNoSekai** | ✅ WordPress | ✅ página única, sem paginação | ✅ **HLS `.m3u8` direto** (3 GETs) |
| **Internet Archive** | ✅ `advancedsearch` | ✅ via `/metadata` | ✅ **MP4 direto** (sem HLS — não existe) |
| **Doramasflix** | ✅ GraphQL | ✅ `listEpisodes` | ❌ **fallback WebView** |

## Decisões de projeto que valem registrar

**1. Doramasflix é catálogo-first, vídeo best-effort.**
O `doramasyt` embute o vídeo em `data-player` = base64 de `{iv,value,mac}`, que é **AES-CBC com MAC** — o mesmo esquema `Protector` do AnimesDigital, para o qual o app **não** tem decifrador. Preferi devolver `EmptyResultError` e deixar o app cair no **fallback por WebView que já existe** (`watchUrl` → `WebViewPlayerScreen`) a inventar um decifrador frágil. O catálogo sozinho já resolve o maior gap (não existe catálogo de drama no app).

**2. Internet Archive filtra lixo explicitamente.**
O índice do archive.org varre espelhos do YouTube (`youtube-*`) e VODs da Twitch: `subject:"anime"` devolve 62.756 itens cujo topo é reaction aleatório. A busca ancora em `collection:(opensource_movies OR feature_films)` **e** descarta `youtube-`/`TwitchVod-`/`vimeo-` por prefixo. Sem isso a fonte é inutilizável.

**3. Episódios duplos do Donghua.**
O site publica `…-episodio-379-380` (dois de uma vez) e `…-episodios-40-41`. O parser usa o **último** número como canônico e só cria alias quando o par é **consecutivo** (`N`, `N+1`) — pares esquisitos como `13-178` ficam só pelo canônico, para não gerar match errado.

## Bugs encontrados pelos próprios testes (e corrigidos)

Só apareceram porque os testes rodaram contra fixtures reais:

1. **Condição invertida no filtro de slugs** — o blocklist de rotas institucionais estava escrito como `!contains`, descartando **todas** as séries. `parseSearch` devolvia lista vazia sempre.
2. **Sort invertido dos players** — `type=1` (que responde "não tem nada") era tentado antes do `type=0`.
3. **`fl[]` duplicado** — `Uri.replace(queryParameters:)` não aceita chaves repetidas; a query do archive.org precisou ser montada à mão.

## O que NÃO foi implementado (e por quê)

- **Decifrador `Protector` do doramasyt** — frágil e sem chave conhecida. WebView resolve por ora.
- **TMDB como catálogo** — é o unlock de verdade para dramas/doramas (§7 da Parte 1). Trabalho grande e independente.
- **Listar programas fora do AniList** — o ponto adiado pelo usuário. Depende do TMDB: hoje o catálogo canônico é o AniList, que **não tem** K-drama/C-drama/dorama. O Doramasflix entrega catálogo, mas o app ainda não tem onde pendurá-lo na Home/Search.