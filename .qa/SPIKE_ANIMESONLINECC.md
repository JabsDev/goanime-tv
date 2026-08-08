# Spike — AnimesOnlineCC (Fase 0 do Plano de Implementação)

**Data:** 07/08/2026
**Base:** `06_Relatorio_Comparativo_AnimeCaos.md` §2 · `02_Plano_Implementacao_Relatorio_Comparativo.md` Fase 0
**Método:** probe live do host (curl, HTTP estático, sem browser), espelhando o
padrão de `test/live_sources_probe_test.dart`. Nenhuma mudança de código.

---

## 1. Objetivo

Decidir, com evidência, se `animesonlinecc.to` é implementável com `http` +
`html` apenas ou se cai no mesmo muro Blogger/SPA dos adapters Goyabu/
DooPlay/AnimePlayer (stream entregue só via `blogger.com/video.g?token=...`).

## 2. Verificação por camada

### Busca — ✅ IMPLEMENTÁVEL
`GET https://animesonlinecc.to/search/one+piece` → **HTTP 200**.

Selector confirmado (`<article class="item se tvshows"> <div class="data"> <h3> <a>`):

```html
<article class="item se tvshows" id="post-11442">
  <div class="poster"><a href="https://animesonlinecc.to/anime/one-piece/">...<img alt="One Piece"></a></div>
  <div class="data"><h3> <a href="https://animesonlinecc.to/anime/one-piece/">One Piece</a></h3></div>
</article>
```

- `article.item.se.tvshows > div.data > h3 > a` → nome + href absoluto.
- Separador `+` validado: `?s=` (query) também funciona; o relatório falava
  `/search/<termo com +>` — o endpoint é `/search/<slug com +>`, resposta 200.
- "Naruto" retorna "Naruto Clássico Dublado" + "Naruto Shippuden" (título
  contém tag "Dublado" — `TextUtils.cleanTitle` já remove em word boundary).

### Episódios — ✅ IMPLEMENTÁVEL (temporadas no DOM, sem round-trips)
`GET /anime/one-piece/` → **HTTP 200**, 3 blocos `<div class="se-c">`/`<div class="se-a">`
(temporadas 19/20/21) **todos já no DOM** — o paradigma "saltar temporadas
retroativamente" do relatório é portável 1:1. Cada `se-a` contém `<ul class="episodios">`
com `<li><a href=".../episodio/one-piece-episodio-900/">`.

Atenção: o slug do episódio **difere** do slug do anime (`/anime/naruto/` →
`/episodio/naruto-classico-episodio-1/`). Número deve ser extraído por regex
`episodio-(\d+)` no href, não pelo slug do anime.

### Stream — ❌ MESMO MURO BLOGGER/SPA
`GET /episodio/one-piece-episodio-900/` → **HTTP 200**, mas a página contém
**apenas** um iframe:

```html
<iframe class="metaframe rptss" allow="autoplay" sandbox="allow-scripts allow-same-origin"
  src="https://www.blogger.com/video.g?token=AD6v5d..."></iframe>
```

- **Zero** `mp4`/`m3u8`/`googlevideo`/`play_url`/`VIDEO_CONFIG` no HTML.
- `GET video.g?token=...` (com Referer `animesonlinecc.to`) → 200, mas é uma
  **SPA JS** (`boq-blogger.BloggerVideoPlayerUi`): a URL do stream é montada por
  XHR com token embutido no `window.WIZ_global_data`. **Não há redirect** para
  `googlevideo.com` e **nenhuma URL estática** no corpo.
- Endpoints antigos do Blogger (`video-play.mp4?contentID=...`,
  `video.g?id=...`) → **404/400**.
- Confirmado em **2 animes** (One Piece ep 900, Naruto Clássico ep 1).

## 3. Veredito

| Camada | Resultado |
|---|---|
| Site no ar / DNS | ✅ |
| Busca (selector) | ✅ `article.item > .data > h3 > a` |
| Episódios (temporadas no DOM) | ✅ `se-c`/`se-a` + `ul.episodios` |
| Stream | ❌ **só** `blogger.com/video.g?token=...` (SPA JS anti-bot) |

Conforme a tabela de decisão da Fase 0:
> Só Blogger/JS-token (irrecuperável sem browser) → **Não implementar**.

## 4. Decisão

**Adapter AnimesOnlineCC NÃO implementado** — descartado com evidência, mesma
causa dos 3 adapters já mortos (Goyabu/DooPlay/AnimePlayer): o stream é entregue
exclusivamente via token `blogger.com/video.g` recuperável apenas por SPA JS
anti-bot, irrecuperável com `http` + `html` estáticos (a política de `resolver`
do GoAnime TV não usa browser). Busca/episódios funcionariam, mas o adapter
nunca entregaria vídeo — reavivar `implemented=true` geraria apenas mais uma
fonte "busca OK, player vazio".

Registrado também no README como fonte descartada. Fase 2 do plano = **não
executada**; as demais fases (1, 3, 4, 5, 6) seguem inalteradas.
