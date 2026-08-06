# Análise de Causa Raiz — QA_REPORT.md (GoAnime TV)

> Documento de engenharia: o que causa cada bug reportado pelo QA, mapeado ao
> código real (arquivo:linha). Nenhum código foi alterado nesta etapa.
> Datas/valores dos `logcat`: QA_REPORT.md, 2026-08-05.

---

## Mapa rápido (bug → causa raiz)

| Bug | Causa raiz (uma linha) |
|---|---|
| B1 ⚠️ base | `el.text`/`titleElem.text` agregam texto dos filhos (nota+idade+label) p/ `Anime.name` |
| B2 | `_FavoriteButton` vive dentro do `FlexibleSpaceBar` (header colapsa ao scroll; foco não revisita) |
| B3 | `thumb` = `data-src`/`src` **relativo** e sem `Referer`; decodifica placeholder/HTML |
| B4 | «enrich» roda, mas key usa `name` sujo (B1) → lookup AniList falha → detalhe vazio |
| B5 | Header em `SliverAppBar` scroll-off + sem `ensureVisible`/`autofocus` no retorno do grid |
| B6 | `episode.title == 'Episódio N'` e `thumbnail == null`; UI duplica "EP N" + "Epis…" |
| B7 | `AlertDialog`/`Dialog` sem `SingleChildScrollView` + `Column` fixa estoura altura |
| B8 | `MobileScanner` sem fallback de erro; overlay `Mode` cobre; emulador TV sem câmera |
| B9 | `if (_isLoading)` e `if (_error != null)` são blocos irmãos em `Stack` — não exclusivos |
| B10 | `SettingsScreen` nunca é `Navigator.push` tocado (grep só declaração) |
| B11 | `SourceRegistry._adapters` registra adapters que retornam "not implemented"; só `AnimeFire` implementado |
| B12 | `_errorSub` seta string fixa "Erro de reprodução: Verifique o vídeo." (player_screen.dart:256) |
| B13 | Nem a Home nem o primeiro item têm `autofocus`; idem 'focus inicial sem anel' |

---

## B1 — 🔴 Títulos de animes poluídos com nota e faixa etária

**Onde:** `lib/core/sources/anime_fire_adapter.dart:67` e `:91`.

**O que causa:**
- Na primeira via do `search()`:
  ```dart
  final name = el.text.trim();          // :67 — <a><img><div class=…>7.34 A14</div>…</a>
  ```
  `node.text` do HTML (`package:html`) concatena o texto de **todos** os
  descendentes do `<a>`. Como o link de animefire embute badges de nota
  (`7.34`) e faixa etária (`A14`) dentro do próprio `<a>`, o `name` sai como
  `"Naruto: Shippuuden Movie 2 - Kizuna   7.34  A14"`.
- A mesma coisa na via fallback `:91`: `title = titleElem?.text.trim()` do
  `.card_ani .ani_name a`, que também arrasta `(TV)`, `(Dublado)`, nota etc.

**Por que contamina o app inteiro:** `Anime.name` é usado como chave de
**favorito** (`LocalStorage.toggleFavorite(animeKey: anime.name)`,
`detail_screen.dart:145`), de **progresso/assistido** e como **título exibido**
em `DetailScreen`, cards de busca e Home. Ou seja, B1 é a raiz de B4.

**Correção direcional (não aplicada):**
- extrair apenas o **primeiro** text node do nó de título (não o `text`
  agregado com filhos); ou
- limpar com regex antes de armazenar, centralizando num único helper
  (`TextUtils.cleanTitle` já remove sufixos no *clean* — reutilizar na *fonte*,
  antes de setar `name`, não só na chave de cache).

---

## B2 — 🔴 Botão Favorito (❤) inacessível por D-pad

**Onde:** `lib/features/detail/detail_screen.dart:346` (`_FavoriteButton`) dentro
de `_buildSliverHeader()` (`:211-373`), `Positioned` no `Stack` do
`FlexibleSpaceBar` (`:249-368`).

**O que causa:**
- O botão é filho do `flexibleSpace`, que é o **expanded area** do
  `SliverAppBar`. Quando o usuário scrolla p/ baixo (para ver a grade de
  episódios), o `FlexibleSpaceBar` colapsa e o trecho onde o coração vive
  **sai do viewport** e é desmontado do layout.
- `_FavoriteButton`, `_BackButton`, `_EpisodeCard` usam `Focus` +
  `FocusKeyHandler` (`detail_screen.dart:585-590`, `:1280-1282`), mas o header
  está dentro de um **scrollable** e não há `Scrollable.ensureVisible`/`ShowOnFocus`
  nem `nextFocus` explícito do grid → o `ArrowUp` "pula" o hero e pousa no back.
- O `leading` (`_BackButton`) é fixado no `pinned` `SliverAppBar`; o favorito,
  não. Via `ArrowUp` do card → focus vai para o `leading` (único foco
  persistente do header) e nunca chega ao coração que está "dentro" do area
  colapsada.
- Toque por coordenadas também não dispara: o `CustomScrollView` consome o
  gesto como drag (`e28/e29`).

**Correção direcional:** mover o coração para superfície **persistente**
(actions da `SliverAppBar` `pinned`, que colapsa mas fica visível) + ligar
`FocusNode` com prev/next para o `_BackButton`; e/ou `ensureVisible` no focus
de retorno.

---

## B3 — 🟠 Imagens de poster quebradas em busca

**Onde:** `anime_fire_adapter.dart:71-72,94-95`.

**O que causa:**
```dart
thumb = img.attributes['data-src'] ?? img.attributes['src'];   // :72
```
- AnimeFire usa lazy-load (`data-src`) com `src` placeholder. O valor puxado
  pode ser um **caminho relativo** (`/uploads/...jpg`) — **não passa por
  `_resolveUrl`** (diferente do `href`, que é resolvido em `:77`). URL relativa
  → request inválido → placeholder.
- `CachedNetworkImage` (`cached_image.dart:33`) dispara **sem header
  `Referer`** (`AppConstants.baseSiteUrl`). AnimeFire/IPB protege imagem por
  hotlink; a resposta às vezes é **HTML/erro** em vez da imagem →
  `FlutterImageDecoderImplDefault: Failed to decode ... Input contained an
  error`.
- O placeholder `src` (gif/data-URI branco) decodifica "ok" mas mostra cinza;
  em acessos seguintes o cache/redownload retorna o CDN real → de 14/15 falha
  alguma (evidência `e04` vs reteste).
- No segundo acesso carregou porque o cache em disco (mem/disk) reutilizou a
  imagem já baixada via fallback/CDN certo.

**Correção direta:** normalizar o `thumb` com `_resolveUrl` (montar esquema/
host), e adicionar `Referer`/`User-Agent` à request de imagem — seja via
`httpHeaders` do `CachedNetworkImage`, seja garantindo que o `data-src` seja a
URL completa. `AppConstants.userAgent` + `Referer` já existem para stream;
reusar.

---

## B4 — 🟠 Detalhe vindo da busca sem sinopse/backdrop/gêneros

**Onde:** `search_screen.dart:169-176` (push de `DetailScreen`).

**Ponto de atenção sobre a "causa provável" do QA** — o relatório diz que a
busca não enriquece. No código real, `_repo.searchAnime(q)` →
`AnimeScraper.searchAnime` **faz** `AniListService.enrich(a)` em cada resultado
(`anime_scraper.dart:74`). Então a rota de enriquecimento existe. A causa real
é uma combinação mais sutil:

1. `enrich()` (`anilist_service.dart:490-508`) faz lookup por
   `TextUtils.cleanTitle(anime.name)` → AniList `Media(search: …)`. O key usa o
   **`name` sujo produzido no B1**. Quando a limpeza do título poluído não
   resolve num match AniList estável (filme/spin-off/duplicado), `_fetchDetail`
   retorna `null` e `_applyDetail` é pulado → `description`/`banner`
   `/genres`/`episodes` permanecem `null`/`[]`.
2) Os paths catálogo da Home usam `getTrending`/`getPopularThisSeason` que
   **já trazem descrição/backdrop/nota/gêneros direto do query AniList**
   (`anilist_service.dart:374-481`, `_catalogQuery` pede `description`,
   `bannerImage`, `genres`, `averageScore`). A busca não tem esse caminho rico:
   depende só do `enrich` (lookup secundário). Se o lookup falha → tela pobre.
3) `AnimeFireAdapter` retorna `Anime` sem metadados (nome/url/imagem); o único
   enriquecimento vem do `enrich`.

**Conclusão:** B4 é **efeito de B1** (key de annotation contaminada) + uso de
`enrich` como única fonte de metadata na busca (vs catálogo rico). Corrigir a
limpeza do título no parser (B1) destrava o `enrich` e preenche
synopsis/backdrop/gêneros nos resultados de busca.

**Correção direta:** limpar `name` na origem (B1); e/ou no `DetailScreen`,
quando `description`/`genres` vazios, chamar `enrich`/catálogo como fallback
(paridade com a Home).

---

## B5 — 🟠 Foco fora do viewport / navegação "pula" hero

**Onde:** `detail_screen.dart` (`_buildSliverHeader`, `_EpisodeCard`; o
`CustomScrollView` `:198-208`).

**O que causa:**
- Toda a tela é um `CustomScrollView`; header e grid são slivers irmãos
  (`:200`,`:205`). O foco do grid (`_EpisodeCard`, `FocusKeyHandler` intercepta
  direções) não dispara `ensureVisible` para o header quando `ArrowUp`
  retorna a ele.
- O único foco sempre visível do header é o `_BackButton` (`pinned`). O
  `Scrollable` + `focusTraversal` colocam o alvo fora da vista sem rolar → em
  uma captura não há nenhum anel de foco.
- Como todos os elementos usam `onKeyEvent` (fire-and-forget directional),
  o foco "viaja" para nós não-renderizados/fora do viewport.

**Correção direta:** `Focus(… )` com `Scrollable.ensureVisible` ao retomar o
header; `FocusScope` com `autofocus` no primeiro `_EpisodeCard` ao abrir
(garantindo que o foco inicial é um item do grid dentro da vista); garantir
nexo de navegação do `_BackButton` p/ a grade para fechar o ciclo.

---

## B6 — 🟡 Episódios sem thumbnail e título truncado

**Onde:** `anime_fire_adapter.dart:171-179` (gera os episodes) e
`_EpisodeCard` `detail_screen.dart:621-665` (`:631`, `:656`).

**O que causa:**
```dart
return Episode(number, …, title: 'Episódio $num', …);   // :176 — sempre
```
- `AnimeFire` não fornece título/thumbnail por episódio; o adapter fabrica
  `title = "Episódio N"` e deixa `thumbnail = null`. A **fusão de metadata**
  só ocorre quando `anilistId != null` (via `episodesV2`) — busca/usuário
  deslogado não têm isso.
- Como `thumbnail` é `null`, `:638` deixa a célula sem `DecorationImage` →
  fundo escuro com "EP N". O `Text` `:655-664` recebe `title == "Episódio N"`
  e exibe "Epis…" (truncado pelo `maxLines:1`/ellipsis), repetindo o que
  o badge "EP N" já mostra.

**Correção direta:** quando `title == null`/vazio/`"Episódio N"`, omitir a
linha de texto (deixar só o badge "EP N"); exibir ícone de `play` como
placeholder quando `thumbnail` vazio (paridade com o placeholder de poster).

---

## B7 — 🟡 Dialog "Conectar AniList": botão "Cancelar" cortado

**Onde:** `anilist_login_dialog.dart:108-271`.

**O que causa:**
- `Dialog > Padding > Column(mainAxisSize.min)` sem `SingleChildScrollView`.
  O conteúdo: QR 250px + textos + linha "Usar Câmera / Inserir token" + botão
  "Cancelar" excede a altura disponível em TV (Dialog). Com `mainAxisSize.min`
  o conteúdo flui para fora; o "Cancelar" (`:241-260`, no fim da coluna) fica
  fora da área de recepção → aparece parcialmente/cortado no rodapé.

**Correção direta:** envolver o `Column` num `SingleChildScrollView`
(`mainAxisSize.min` + scroll em conteúdo alto).

---

## B8 — 🟡 Scanner QR: preview de câmera nunca ativa

**Onde:** `anilist_qr_scanner_screen.dart`.

**O que causa:**
- `MobileScanner` (sem `controller` explícito) depende de câmera do device. Em
  **Android TV emulador (API 36, swiftshader)** não há câmera virtual física →
  o preview fica preto. O `if (_isScanning)` renderiza um **overlay `Center`
  de instruções por cima da área de scan** (`:85-150`), então a UX mostra a
  tela de instruções "estática" e a câmera por trás não se vê — parece morta.
- Não há estado de erro ao a `MobileScanner` não disparar (`onDetect` nunca
  chamado), e não há mensagem tipo "câmera indisponível". O campo
  `Token capturado em: ${DateTime.now()}` (`:139`) roda sempre, reforçando o
  comportamento de "instruções estática".
- Nota de QA: o texto de instrução também cortado na parte inferior.

**Correção direta:** capturar o estado do scanner (`MobileScannerController`
com callback de erro) e, ao falhar em inicializar/detectar, mostrar fallback
com mensagem em vez do preview escuro; revisar o overlay de instruções para não
sobrepor a área de scan nem cortar o texto. Validar em hardware real (Fire TV)
— o emulador Android TV não tem câmera virtual. Nota: `reassemble` duplica
`pause()` para iOS/Android (pequena redundância, não gera bug).

---

## B9 — 🟡 Player: overlay de erro com "spinner fantasma"

**Onde:** `build()` `player_screen.dart:503-520`.

**O que causa:**
```dart
if (_isLoading)        Child(spinner … )                     // :503
if (_error != null)    _buildErrorState()                   // :519
```
- São dois `if`s **independentes** no mesmo `Stack`. Sempre que `_isLoading`
  e `_error != null` coexistem, o spinner (`Center`) e o overlay de erro
  (`Center`) são pintados juntos — o anel do spinner fica por trás/depois do
  texto de erro.
- Como os dois estados são setados por *callbacks assíncronos*
  (`_playSource`, `_errorSub`, timeout), há janelas em que
  `_isLoading` continua `true` enquanto `_error` é atribuído (ex.: o
  `loadTimeout`/auto-advance dispara e `setState` transitório mantém ambos).
- A QA observou o efeito final de "spinner + '…: Verifique…'".

**Correção direta:** tornar os estados **mutualmente exclusivos** no builder:
`if (_isLoading && _error == null)` e/ou forçar `_isLoading = false` em todo
set de `_error` (todos os pontos já fazem, mas o `check` + `_errorSub`
concorrente quebra); simplificar para um single estado (`enum PlayerState`) ou
um top-level "error != null => não mostra spinner".

---

## B10 — 🟢 SettingsScreen órfã / inalcançável

**Onde:** `settings_screen.dart` + `home_screen.dart`.

**O que causa:** grep de `SettingsScreen(` só encontra a própria declaração
(`settings_screen.dart:9`). Nenhuma rota usa `Navigator.push(... SettingsScreen())`.
A Home (`_buildTopBar`) expõe apenas "Buscar" e "Perfil"
(`home_screen.dart:202-217`); o menu de Perfil (`_showProfileMenu`, `:227-305`)
tem Logar/Atualizar/Favoritos/Deslogar — **sem Configurações**. O usuário não
tem como chegar às configurações de desempenho (Modo lite/completo) que a tela
implementa.

**Correção direta:** adicionar entrada "Configurações" no menu de Perfil
(ou no topo), ou remover o arquivo se não for entregar.

---

## B11 — 🟢 Somente AnimeFire ativo (resto não implementado)

**Onde:** `lib/core/sources/*_adapter.dart` + `source_registry.dart:23-36`.

**O que causa:**
- `SourceRegistry._adapters` (`:23-36`) registra Todos os adapters, mas a
  busca `AnimeScraper.searchAnime` (`anime_scraper.dart:26-52`) faz
  `Future.wait` sobre **todos**; cada adapter produz:
  - "not implemented"/vazio: `Goyabu`, `SuperFlix`, `AnimesDigital`, `DooPlay`,
    `Anikyuu`, `Animeito`, `AnimePlay`, `AnimePlayer`, `AnimeQ`
    (integrações em fases iniciais → a própria `search` nem resolve / fica vazio);
  - `AllAnime` → Cloudflare/Turnstile (externo, não resolvível no app);
  - `AniList` → precisa token p/ autenticado; sem login retorna "not
    authenticated".
  Só `AnimeFireAdapter.search` resolve. Conclusão mantém `README.md`.
- **Consequência UX de B11:** `AnimeScraper.searchAnime` ainda dispara ~12
  chamadas de rede a cada busca (tempo/bolo); resultados ruins de outras fontes
  descartados por `hasValidId` (`anime_scraper.dart:56-70`).

**Correção direta (UX):** na UI, sinalizar/esconder as fontes "não
implementadas" (ex.: ícone/status) e/ou filtrar `SourceRegistry.adapters`
durante iteração a máscara `implemented` (flag por adapter), para não pedir
trabalho morto/demorada.

---

## B12 — 🟢 Mensagem de erro do player vaga

**Onde:** `player_screen.dart:256-259`.

**O que causa:**
```dart
String errorMessage = 'Erro de reprodução: Verifique o vídeo.';
```
- O `_errorSub` (`:244-264`) só tem uma string padrão genérica; a exceção
  (`e` do media_kit) é logada mas não exposta ao overlay. `"Verifique o vídeo"`
  não informa URL, host ou se é rede/codec — e não oferece retry em qualidade
  alternativa automaticamente (a auto-avanço existe só no *timeout* de load
  `:159-171` e no erro `completed` `:234`, não num decode/network error).

**Correção direta:** compor mensagem amigável com o contexto já disponível
(ex.: `_sources[_selectedQualityIndex].quality` e host de `src.url`); e, ao
erro de fonte, tentar `_playSource(index+1)` (última qualidade) antes de fechar
no verniz error.

---

## B13 — 🟢 Focus inicial da Home sem indicador

**Onde:** `home_screen.dart` (`_buildTopBar`, `_buildContent`, cards).

**O que causa:** a Home monta `ListView` de seções com `FocusableCard`/
`FocusableBannerCard`/`_ProfileButton`/`_FocusableNavItem`, nenhum com
`autofocus: true`. Ao abrir, o foco primário fica no boot do Flutter (sem nenhum
item focado) e a primeira tecla direcional do remote "acorda" o traversal →
anel só aparece depois de navegar (evidência `e01_home.png`).

**Correção direta:** definir `autofocus: true` no primeiro `FocusableCard` /
primeiro item da Home (ou no primeiro eixo do `ListView`), garantindo que o
usuário veja o estado focado desde o boot (`sem foco` visual inicial).

---

## Correlações / dependências entre bugs

- **B4 ← B1:** título sujo destrava o `enrich` da busca → detalhe pobre.
- **B1 → (favoritos/progresso):** `anime.name` sujo também vira a chave de
  favorito/histórico/progresso → matching de favoritos fica sujo.
- **B2 ↔ B5:** raiz comum (botão no `FlexibleSpaceBar` + falta
  `ensureVisible`/retorno de foco) — corrige os dois juntos (`_buildSliverHeader`
  > ação persistente da `SliverAppBar`).
- **B1 → B3 (qualidade de imagem):** mesmo caminho de scraping responsável por
  nome e poster; corrigir a extração na origem.

---

## Prioridade (alinhada ao recom do QA, §8)

1. B1 (limpa título — destrava B4 e chaves).
2. B2/B5 (acesso ao favorito + foco fora de tela).
3. B4 (enriquecer busca — paridade com Home).
4. B3 (posters).
5. B7/B9/B12 (visual/ux dialogs+player).
6. B6/B8/B10/B11/B13 (melhorias e força).