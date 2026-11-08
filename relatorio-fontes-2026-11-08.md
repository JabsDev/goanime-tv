# Fontes PT-BR — Slime S4E23 legendado e nova fonte Dattebayo BR (08/11/2026)

## Sintoma reportado

Na 4ª temporada de *Tensei Shitara Slime Datta Ken*, episódio 23, o seletor
mostrava **só o AnimeFire** e não oferecia a escolha entre dublado e legendado.
O usuário queria legendado.

## Diagnóstico

### 1. AnimeFire (lado do site, não do app)

O manifesto **legendado** do episódio responde **404** no CDN:

```
GET /episode/VNt1hrYY199  →  streams:
  dublado   → akumast.net/i/L8Fn…/h.jpg  → 200 (HLS/DASH)
  legendado → akumast.net/i/c_bX…/h.jpg  → 404
```

O app **já fazia a coisa certa**: sonda cada manifesto, descarta o morto e
carimba `unavailableAudios`, exibindo “Legendado indisponível nesta fonte”.
Não há como “inventar” o legendado do AnimeFire — o arquivo não existe no
servidor. A solução é entregar legendado por **outra fonte**.

### 2. Por que as outras fontes sumiram — dois bugs no app

O cluster AnimesOnline (3 fontes) tinha legendado do mesmo episódio, com MP4
direto respondendo 206:

```
https://animes.click/CDN/Midia/Letra-T/Tensei-shitara-Slime-Datta-Ken-4/23.mp4
https://aniplay.online/Midias/Animes/Letra-T/Tensei-shitara-Slime-Datta-Ken-4/23.mp4
```

Mesmo assim não apareciam:

| Fonte | Bug | Efeito |
| :-- | :-- | :-- |
| `animesonline.cloud` | o tema parou de emitir `div.episode-card`; os episódios agora ficam em `#seasons .se-c ul.episodios li a` | `getEpisodes` devolvia “No episodes found” → fonte fora do seletor |
| `animesdrive.cloud`, `animeq.cloud` | player novo `animeq-player` (streams em `<video><source>` inline), sem `dooplay_player_option` | episódio achado, mas extração de vídeo falhava → `matchedUnavailable` |

## Correções

1. **`AnimesOnlineAdapter.getEpisodes`** — parser unificado do tema atual:
   `#seasons .se-c` + `.episode-card` **ou** `ul.episodios li a`, com temporada
   vinda de `.se-t`/`.numerando` (“4 - 23”). Mantém o fallback de
   `.episode-card` solto (fixtures/páginas antigas).
2. **`AnimesOnlineAdapter.resolveVideo`** — resolve ciente de temporada
   (S4E23 nunca cai em S1E23 numa página combinada).
3. **`DooPlayV2Extractor`** — além do player antigo (`dooplay_player_option`),
   lê o player inline `animeq-player`, casando cada `source` ao servidor
   (`SD`/`HD`/`FHD`) pelo índice `data-animeq-source` ↔ `data-animeq-switch`
   (iframes Blogger são ignorados). Tudo passa pelo probe 206 antes de entrar.
4. **Áudio declarado** — as fontes que separam dublado/legendado em páginas
   distintas agora carimbam `VideoSource.audio` pela URL (`…-dublado`), e o
   seletor mostra **“Animes Online · Legendado”**, **“AnimeFire · Dublado”**,
   etc. Quando há mais de um áudio na mesma fonte, o passo de áudio continua
   aparecendo normalmente.

## Nova fonte: Dattebayo BR

Origem: lista do Reddit (`r/MorpheApp`, “Ultimate List…”) → categoria de
clientes com servidores web. Para PT-BR, a referência útil são as extensões
Aniyomi/CloudStream do repositório comunitário `Kohi-den/extensions-source`
(`src/pt/`). Testei as candidatas uma a uma.

**`dattebayo-br.com`** entrou no fan-out:

- busca `GET /busca?busca=<q>&page=N` → `div.ultimosAnimesHomeItem`;
- página da série em `/animes/<slug>` (legendado) ou `/anime-dublado/<slug>`;
- episódios em `div.ultimosEpisodiosHomeItem` (href `/videos/<id>`), paginados
  em `/page/N` só quando o HTML anuncia a próxima página;
- a página do episódio traz até 3 servidores (`SD`/`HD`/`FULLHD`) com um MP4 no
  R2; o arquivo cru responde 403 e precisa da assinatura de
  `ads.animeyabu.net?url=<mp4>` (S3 presigned, ~1 h). A resolução é on-demand e
  cada URL só é oferecida depois do probe 206.

Verificado ao vivo no S4E23: 3 qualidades legendadas, tempo típico
(resolve + episodes + vídeo) ≈ 1,4 s + 1,7 s + 3,1 s neste desktop.

### Candidatas testadas e descartadas

| Fonte | Situação (08/11/2026) |
| :-- | :-- |
| Anitube (`anitube.vip`) | DNS não resolve — site fora |
| AnimesROLL (`anroll.tv` / `animes.tokyo`) | HTTP 525 (TLS quebrado na origem) |
| SmartAnimes | Cloudflare 403 em todas as rotas |
| AnimesBR (`animesbr.tv`) | domínio à venda |
| MeusAnimes (`meusanimes.net`) | domínio sequestrado (redireciona para cassino) |
| TopAnimes (`topanimes.net`) | tem S4 legendado, mas os players são hosts de terceiros (`sk-api`, `ruplay`, Rumble) — extração bem mais frágil que o Dattebayo; ficou de fora nesta rodada |
| Animes Online CC / Animes Online IO | já no projeto; players Blogger/googlevideo seguem 403 |
| AnimeGG | usado no teste de 08/10, hoje não devolveu o título |

## Verificação

- Suíte: os 21 testes de `animesonline_adapter_test.dart` + os 8 novos de
  `dattebayo_br_adapter_test.dart` passam. As falhas restantes da suíte são
  pré-existentes e ambientais (`llm_mt_test` sem binding nativo; testes do
  AnimeFire DASH dependem de rede real/mock de manifesto).
- Ao vivo (`resolveAnime` → `getEpisodes` → `resolveVideo(23)` com título do
  AniList): AnimeFire continua entregando só dublado; **animesonline.cloud,
  animesdrive.cloud, animeq.cloud e Dattebayo BR entregam legendado**, todos com
  `audio=legendado`.

## Arquivos

- `lib/core/sources/animesonline_adapter.dart`
- `lib/core/sources/dooplay_v2_extractor.dart`
- `lib/core/sources/dattebayo_br_adapter.dart` (novo)
- `lib/core/sources/source_registry.dart`
- `lib/data/models/anime.dart`, `lib/data/models/episode.dart`
- `lib/core/scraper/anime_scraper.dart`
- `lib/features/detail/detail_screen.dart`
- `test/dattebayo_br_adapter_test.dart` (novo) + fixtures
- `test/animesonline_adapter_test.dart`
