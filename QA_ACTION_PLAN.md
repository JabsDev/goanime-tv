# Plano de Ação — Correção de Bugs (GoAnime TV)

> **Fonte:** `QA_REPORT.md` (2026-08-05) + `QA_ANALYSIS.md` (análise de causa raiz, arquivo:linha).
> **Escopo desta etapa:** apenas planejamento — **nenhum código será editado/criado agora.**
> **Validado no código:** os pontos de correção abaixo foram conferidos contra o código real
> (`git` atual). Linhas citadas seguem o estado atual dos arquivos.

---

## 0. Resumo executivo

O app funciona de ponta a ponta (busca → detalhe → player), mas com **13 bugs**
de dados e UX em 3 níveis. O mais grave (B1) polui o nome do anime na origem e
cascateia para favoritos, histórico, progresso e enriquecimento (B4).

| ID | Sev. | Bug | Fase | Esforço | Arquivos principais |
|----|------|-----|------|---------|---------------------|
| B1 | 🔴 | Títulos poluídos (nota + faixa etária) | 1 | M | `anime_fire_adapter.dart`, `text_utils.dart` |
| B2 | 🔴 | Favorito inacessível por D-pad | 1 | M | `detail_screen.dart` |
| B3 | 🟠 | Posters de busca quebrados | 2 | M | `anime_fire_adapter.dart`, `cached_image.dart` |
| B4 | 🟠 | Detalhe da busca sem sinopse/gêneros | 2 | P | `search_screen.dart`, `anime_scraper.dart` |
| B5 | 🟠 | Foco pousa fora do viewport | 1 | M | `detail_screen.dart` |
| B6 | 🟡 | Título de episódio truncado "Epis…" | 3 | P | `detail_screen.dart` |
| B7 | 🟡 | Dialog AniList: "Cancelar" cortado | 3 | P | `anilist_login_dialog.dart` |
| B8 | 🟡 | Scanner QR nunca ativa preview | 3 | M | `anilist_qr_scanner_screen.dart` |
| B9 | 🟡 | Player: spinner fantasma + erro | 3 | P | `player_screen.dart` |
| B10 | 🟢 | SettingsScreen inalcançável | 3 | P | `home_screen.dart` |
| B11 | 🟢 | Fontes "not implemented" | 3 | M | `source_registry.dart`, `anime_scraper.dart` |
| B12 | 🟢 | Mensagem de erro do player vaga | 3 | P | `player_screen.dart` |
| B13 | 🟢 | Home sem focus inicial | 3 | P | `home_screen.dart`, `focusable_card.dart` |

**Ordem de execução (dependências):**
1. **Fase 1 — destrava tudo:** B1 → B2 → B5 (B4 depende de B1).
2. **Fase 2 — dados/paridade:** B4 → B3.
3. **Fase 3 — UX/limpeza:** B7, B9, B12, B6, B10, B13, B11, B8 (B8 exige hardware).

---

## 1. Fase 1 — Bugs de alta prioridade (destravam o resto)

### B1 — 🔴 Títulos de animes poluídos com nota e faixa etária

**Problema (QA §3.B1):** títulos vêm como
`"Naruto: Shippuuden Movie 2 - Kizuna   7.34  A14"` e
`"Jujutsu Kaisen (TV) (Dublado)   8.39  A16"`. Contaminam exibição, chave de
favoritos (`LocalStorage.isFavorite/toggleFavorite` em `detail_screen.dart:36,145`),
progresso e o lookup de enriquecimento (B4).

**Causa raiz (QA_ANALYSIS B1):**
- `anime_fire_adapter.dart:67` — `final name = el.text.trim();` concatena o texto de
  **todos** os descendentes do `<a>` (badges de nota/idade inclusos).
- `anime_fire_adapter.dart:91` — `final title = titleElem?.text.trim();` no fallback
  `.card_ani .ani_name a`, arrasta `(TV)`, `(Dublado)`, nota.
- `TextUtils.cleanTitle` (`text_utils.dart:82-109`) **já** remove `\d+.\d+ A\d+`,
  `(Dublado)`, `Dublado`, `todos os episodios`… — mas só é aplicado **na chave de cache
  do enrich** (`anilist_service.dart:491`), nunca **na origem** do `name`.
  `(TV)` ainda não é removido por `cleanTitle`.

**Ação:**
1. Criar um helper central em `text_utils.dart` (ex.: `static String cleanTitle(String title)`
   — **estender o existente**), adicionando também:
   - `\s*\(TV\)\s*` no fim (case-insensitive);
   - `\s*\(\d+\)` se aparecer como sufixo de faixa;
   - normalizar múltiplos espaços (já existe em `:107`).
2. **Aplicar `TextUtils.cleanTitle(...)` na origem**, em `anime_fire_adapter.dart:67`
   (`final name = TextUtils.cleanTitle(el.text.trim());`) e em `:91`
   (`final title = TextUtils.cleanTitle(titleElem?.text.trim() ?? '');`).
   *Nota:* `cleanTitle` não pode esvaziar nomes legítimos — manter fallback para
   resultado vazio.
3. Confirmar que `AnimeFireAdapter` usa o nome limpo para `url`/`fallbackImageUrl`
   (não mudar href; só o texto exibido/armazenado).
4. **Regressão crítica:** favoritos/histórico já salvos com nome sujo não "casam"
   com o nome limpo. Decisão:
   - Migração: normalizar a chave ao ler/escrever (`LocalStorage`) aplicando o mesmo
     `cleanTitle` na leitura, OU
   - aceitar que favoritos antigos "sumam" (recomendado para v1: normalizar na leitura
     é barato — um único helper no `LocalStorage`).

**Arquivos afetados:** `lib/core/utils/text_utils.dart`,
`lib/core/sources/anime_fire_adapter.dart`, `lib/core/storage/local_storage.dart` (leitura).

**Critério de aceite:** `logcat` de `[Detail] initState name=...` mostra nome limpo
("Naruto: Shippuuden Movie 2 - Kizuna"); título de favoritos/histórico consistente.

---

### B2 — 🔴 Botão Favorito (❤) inacessível por D-pad

**Problema (QA §3.B2):** o coração fica dentro do `FlexibleSpaceBar` (hero) e some ao
scrollar; D-pad (UP vindo da grade) pula o hero e cai no **voltar**; RIGHT do voltar
não alcança o coração; tap é consumido como drag do `CustomScrollView`.

**Causa raiz (QA_ANALYSIS B2):**
- `_FavoriteButton` (`detail_screen.dart:1204`) é renderizado em
  `_buildSliverHeader()` dentro do `Positioned` do `Stack` do `FlexibleSpaceBar`
  (`detail_screen.dart:249-368`). O `flexibleSpace` **colapsa** ao scrollar → o nó
  focável sai do layout/viewport.
- `leading: _BackButton` é `pinned` (sempre visível), mas o coração não → a única
  âncora de foco persistente do header é o voltar; `ArrowUp` do grid pousa nele.

**Ação (recomendada):**
1. **Mover o `_FavoriteButton` para `actions` da `SliverAppBar`** (`detail_screen.dart:216-372`),
   que é `pinned` e **permanece visível no colapso**. Remover a instância dentro do
   `FlexibleSpaceBar` (evitar duplicação de foco/toque).
2. Manter o widget `_FavoriteButton` (`:1204-1264`) como está (já é focável via
   `Focus` + `FocusKeyHandler`); basta realocá-lo.
3. **Ciclo de foco:** o layout `leading (voltar) ↔ actions (coração) ↔ grade` passa a
   ser alcançável pelo traversal padrão horizontal; testar se `_BackButton`
   (`:1266-1323`) precisa de `focusNode.nextFocus` explícito para o coração
   (se o traversal automático não fechar o ciclo, ligar prev/next manualmente).
4. Remover/ajustar o `Positioned` da `Column` em `:343-364` (a coluna que continha
   coração + status) para não deixar área morta focável.

**Arquivos afetados:** `lib/features/detail/detail_screen.dart`.

**Critério de aceite:** com a tela scrollada até a grade, `ArrowUp` → `ArrowRight`
foca o coração; `Select` alterna favorito; o coração é **visível** na barra pinada.

---

### B5 — 🟠 Foco pode pousar fora do viewport / navegação "salta" o hero

**Problema (QA §3.B5):** UP a partir da grade joga foco para fora da vista; capturas
sem anel de foco em alguns passos. Causa raiz compartilhada com B2.

**Causa raiz (QA_ANALYSIS B5):**
- Header e grade são **slivers irmãos** (`detail_screen.dart:198-208`). `_EpisodeCard`
  intercepta direções via `onKeyEvent` (`:585-590`); o retorno ao header não dispara
  `Scrollable.ensureVisible`.
- `CustomScrollView` + `focusTraversal` colocam o alvo fora da vista sem rolar.

**Ação:**
1. Envolver o header (`_buildSliverHeader`) num `Focus` com **`autofocus` no primeiro
   `_EpisodeCard`** ao abrir a tela (foco inicial sempre num item visível do grid).
2. Ao **retomar o foco para o header** (ArrowUp), chamar `Scrollable.ensureVisible`
   no nó do header/`actions` (helper: usar `FocusNode` + `Scrollable.ensureVisible(context)`).
3. Fechar o ciclo de navegação: `_BackButton` ↔ `_FavoriteButton` (B2) ↔ grid, com
   `nextFocus` explícito se necessário.
4. Considerar `ShowOnFocus` (widget do Flutter) para o botão de favorito/voltar
   (garante scroll até o item focado).

**Arquivos afetados:** `lib/features/detail/detail_screen.dart`.

**Critério de aceite:** sequência UP/DOWN/LEFT/RIGHT a partir da grade nunca deixa
o anel de foco fora da área visível; UP do grid revela o hero com foco visível.

---

## 2. Fase 2 — Dados / paridade (depende de B1)

### B4 — 🟠 Detalhe vindo da busca sem sinopse/backdrop/gêneros

**Problema (QA §3.B4):** abrir resultado da busca → detalhe só com título, nota, fonte
e episódios; sem sinopse, sem backdrop, sem gêneros. Da Home, detalhe rico.

**Causa raiz (QA_ANALYSIS B4 — mais sutil que o QA):**
- A rota de enrich **existe**: `AnimeScraper.searchAnime` chama
  `AniListService.enrich(a)` em cada resultado (`anime_scraper.dart:74`).
- Porém o lookup usa `TextUtils.cleanTitle(anime.name)` (`anilist_service.dart:491`).
  Com o **nome sujo do B1**, o match AniList falha → `_fetchDetail` retorna `null`
  (`anilist_service.dart:524-565`) → `_applyDetail` é pulado
  (`anilist_service.dart:503-504`) → `description`/`bannerImage`/`genres` ficam vazios.
- A Home usa queries AniList que **já trazem** metadata rico (`_catalogQuery` pede
  `description`, `bannerImage`, `genres`, `averageScore`); a busca depende só do
  enrich secundário.

**Ação:**
1. **Corrigir B1** (precondição): com o nome limpo, `cleanTitle` resolve e o enrich
   passa a preencher a busca.
2. **Fallback de paridade:** em `search_screen.dart:169-176` (push do `DetailScreen`),
   antes de abrir, garantir `await AniListService.enrich(anime)` — ou, mais robusto,
   fazer o enrich dentro do `DetailScreen.initState` quando `description`/`genres`
   vazios **e** `anilistId == null` (paridade com `home_navigation.dart`, que já
   enriquece em `openDetail`/`openAnilistDetail`).
3. Garantir que, ao fallhar o enrich, a UI não mostre área vazia feia no topo
   (`detail_screen.dart:225-231` já tem fallback de cor sólida — ok).

**Arquivos afetados:** `lib/features/search/search_screen.dart`,
`lib/features/detail/detail_screen.dart`, `lib/features/home/home_navigation.dart` (referência).

**Critério de aceite:** abrir busca → detalhe mostra sinopse, gêneros e backdrop
(paridade com Home).

---

### B3 — 🟠 Imagens de poster quebradas nos resultados de busca

**Problema (QA §3.B3):** 14/15 posters de busca como placeholder cinza;
`FlutterImageDecoderImplDefault: Failed to decode ... Input contained an error`.
No 2º acesso carrega (cache/CDN).

**Causa raiz (QA_ANALYSIS B3):**
- `anime_fire_adapter.dart:72` — `thumb = img.attributes['data-src'] ?? img.attributes['src'];`
  puxa **URL relativa** (`/uploads/...jpg`) que **não passa por `_resolveUrl`** (diferente
  do `href`, resolvido em `:77`). Relativa → request inválido → placeholder.
- `fallbackImageUrl` é usado como `imageUrl` (`anime.dart:39` → `cached_image.dart:33`).
  `CachedNetworkImage` dispara **sem `Referer`** → hotlink-block da AnimeFire/IPB
  devolve **HTML/erro** em vez da imagem → falha de decode.
- O `src` placeholder (gif/data-URI) decodifica "ok" mas mostra cinza.

**Ação:**
1. **Normalizar `thumb` na origem:** em `anime_fire_adapter.dart:72` e `:95`, aplicar o
   mesmo `_resolveUrl` (já existente em `:612-616`) ao `thumb` antes de setar
   `fallbackImageUrl`. Montar esquema/host quando for relativo.
2. **Adicionar headers à request de imagem:** em `cached_image.dart:33-50`,
   passar `httpHeaders: { 'Referer': AppConstants.baseSiteUrl, 'User-Agent': AppConstants.userAgent }`
   ao `CachedNetworkImage` (constantes já existem em `app_constants.dart`; reutilizar).
3. **Ignorar placeholder:** se `src`/`data-src` for data-URI/gif de placeholder e não
   houver `data-src`, **não** setar `fallbackImageUrl` (deixar null → o enrich de B1/B4
   vai preencher com a capa do AniList via `anilist_service.dart:519-521`).
4. **Validação:** evitar requests desnecessários — `CachedImage` já faz
   `memCacheWidth`; manter.

**Arquivos afetados:** `lib/core/sources/anime_fire_adapter.dart`,
`lib/shared/widgets/cached_image.dart`.

**Critério de aceite:** busca "naruto" mostra 15/15 posters reais (ou fallback de capa
AniList); `logcat` sem `Failed to decode` para posters.

---

## 3. Fase 3 — UX, dialogs, player e limpeza

### B6 — 🟡 Episódios sem thumbnail e título repetido/truncado

**Problema (QA §3.B6):** células mostram "EP N" + texto "Epis…" (redundante) e fundo
escuro sem thumbnail.

**Causa raiz (QA_ANALYSIS B6):**
- `anime_fire_adapter.dart:171-179` fabrica `title: 'Episódio $num'` e `thumbnail: null`
  (AnimeFire não fornece esses dados; a fusão com `episodesV2` só ocorre logado/`anilistId`).
- `detail_screen.dart:631,638` condiciona thumbnail a não-vazio; `:655-664` exibe o
  `title` genérico truncado.

**Ação:**
1. Em `_EpisodeCard` (`detail_screen.dart:621-665`): se `title` for nulo/vazio ou
   igual a `'Episódio ${number}'` (ou casar `^Episódio \d+$`), **omitir a linha de texto**
   (manter só o badge "EP N").
2. Quando `thumbnail` vazio, exibir **ícone de play** como placeholder visual
   (paridade com placeholder de poster em `:264-271`), mantendo o badge "EP N".

**Arquivos afetados:** `lib/features/detail/detail_screen.dart` (e, se quiser limpar o
título fabricado, `lib/core/sources/anime_fire_adapter.dart:176` → manter `title: null`
ou `'Episódio N'`; a UI trata).

**Critério de aceite:** célula com fundo escuro + ícone de play + badge "EP N",
sem texto truncado redundante.

---

### B7 — 🟡 Dialog "Conectar AniList": botão "Cancelar" cortado

**Problema (QA §3.B7):** "Cancelar" aparece cortado no rodapé do dialog
(`e21/e22_login*.png`).

**Causa raiz (QA_ANALYSIS B7):** `anilist_login_dialog.dart:108-271` —
`Dialog > Padding > Column(mainAxisSize.min)` **sem `SingleChildScrollView`**; o conteúdo
(QR 250px + textos + botões) excede a altura disponível; o "Cancelar" (`:241-260`)
vaza da área de recepção.

**Ação:**
1. Envolver a `Column` (filha do `Padding` em `:113`) num `SingleChildScrollView`
   (manter `mainAxisSize.min` no interior; o scroll aparece quando o conteúdo é alto).
2. Garantir que o "Cancelar" fique após o scroll (o usuário consegue rolar até ele).
3. Testar foco do botão dentro do scroll (scroll deve revelar o botão ao focar —
   checar necessidade de `ensureVisible`/`ShowOnFocus`).

**Arquivos afetados:** `lib/features/home/anilist_login_dialog.dart`.

**Critério de aceite:** no emulador TV, dialog aberto mostra "Cancelar" inteiro
(ou rolável até ele) sem cortes.

---

### B8 — 🟡 Scanner QR: preview de câmera nunca ativa

**Problema (QA §3.B8):** após permissão, tela fica na instrução estática com área de
scan escura; preview nunca ativa. Texto de instruções cortado no rodapé.

**Causa raiz (QA_ANALYSIS B8):**
- `anilist_qr_scanner_screen.dart` usa `MobileScanner` sem `controller` explícito;
  sem câmera (emulador TV / swiftshader) o preview fica preto.
- `if (_isScanning)` pinta **overlay `Center` de instruções por cima da área de scan**
  (`:85-150`) → a UX parece "tela morta"; não há estado de erro.
- `Token capturado em: ${DateTime.now()}` (`:139`) roda sempre, reforçando o
  comportamento estático.

**Ação:**
1. Criar `MobileScannerController` explícito com **callback de erro** (`onDetect` +
  estado `isRunning`), ou usar o `controller.error`/`isRunning` para detectar falha.
2. Se falhar em inicializar (erro de câmera), **mostrar fallback legível**
  ("Câmera indisponível neste dispositivo") em vez do preview escuro.
3. **Revisar o overlay de instruções:** não sobrepor 100% a área de scan (deixar a
  câmera visível ao redor) e envolver o conteúdo em scroll/compactação para não cortar
  o texto no rodapé (`:117-147`).
4. Remover a redundância do `reassemble` (`:23-30` — ambos os branches chamam `pause()`).
5. **Limitação:** preview só pode ser validado em **hardware real (Fire TV)**; o emulador
  Android TV não tem câmera virtual. Registrar resultado no QA.

**Arquivos afetados:** `lib/features/home/anilist_qr_scanner_screen.dart`.

**Critério de aceite:** sem câmera → mensagem de erro amigável (sem tela "preta");
com câmera → preview ativo e scan detecta; instruções não cortadas.

---

### B9 — 🟡 Player: overlay de erro com "spinner fantasma"

**Problema (QA §3.B9):** anel de spinner branco sobreposto ao texto de erro.

**Causa raiz (QA_ANALYSIS B9):** `player_screen.dart:503-520` — `if (_isLoading)` e
`if (_error != null)` são **blocos irmãos independentes** no `Stack`. Quando coexistem
(ex.: timeout de load `:159-171` + `_errorSub` `:244-264` em janela transitória),
spinner e erro são pintados juntos.

**Ação:**
1. Tornar os estados **mutuamente exclusivos** no builder:
   `if (_isLoading && _error == null) spinner` (ou `final showError = _error != null`
   e `if (_isLoading && !showError)`).
2. **Reforço estrutural (opcional, barato):** substituir os dois booleans por um
   único `enum _PlayerState { loading, ready, error }` — menor risco de estados
   inválidos; ou apenas garantir que **todo** set de `_error` zere `_isLoading`
   (já acontece em `:168,:196,:262` — o problema é o `check` concorrente).

**Arquivos afetados:** `lib/features/player/player_screen.dart`.

**Critério de aceite:** tela de erro mostra **apenas** o texto/retry, sem anel.

---

### B10 — 🟢 SettingsScreen órfã / inalcançável

**Problema (QA §3.B10):** `settings_screen.dart:8` não é navegado por nenhum fluxo;
grep de `SettingsScreen(` só acha a declaração. Home expõe só "Buscar" e "Perfil".

**Causa raiz (QA_ANALYSIS B10):** `_showProfileMenu` (`home_screen.dart:227-305`) tem
Logar/Atualizar/Favoritos/Deslogar, **sem Configurações**.

**Ação (escolha do produto):**
- **Recomendado:** adicionar entrada "Configurações" (`Icons.settings`) no menu de Perfil
  (`home_screen.dart:252-300`, no bloco `_menuEntry`), com
  `Navigator.push(... SettingsScreen())`. Exibir sempre (logado ou não).
- Alternativa: remover o arquivo se a tela não for entregar.

**Arquivos afetados:** `lib/features/home/home_screen.dart`.

**Critério de aceite:** Perfil → "Configurações" abre a tela (modo lite/completo funciona).

---

### B11 — 🟢 Somente AnimeFire ativo; demais fontes "not implemented"

**Problema (QA §3.B11):** a busca dispara ~12 requests; só AnimeFire retorna resultados
(Goyabu/SuperFlix/etc. → "not implemented"; AllAnime → CAPTCHA; AniList → sem token).

**Causa raiz (QA_ANALYSIS B11):** `source_registry.dart:23-36` registra todos os
adapters; `anime_scraper.dart:26-38` faz `Future.wait` sobre **todos**.

**Ação (UX):**
1. Adicionar flag `bool get implemented` (ou `isImplemented`) em
   `AnimeSourceAdapter` e setá-la como `false` nos adapters sem `search` real
   (goyabu, superflix, animesdigital, dooplay, allanime, anikyuu, animeito,
   animeplay, animeplayer, animeq). `AnimeFireAdapter` e `AniListAdapter` → `true`.
2. Em `AnimeScraper.searchAnime` (`anime_scraper.dart:26`), filtrar
   `SourceRegistry.adapters.where((a) => a.implemented)` antes do `Future.wait`
   (ou rodar em paralelo apenas as implementadas) → corta o "bolo" de rede.
3. Opcional: na UI, exibir indicador de fontes ativas (rodapé da busca, ex.:
   "Fonte ativa: AnimeFire") para o usuário saber o que está disponível.

**Arquivos afetados:** `lib/core/sources/anime_source_adapter.dart`,
`lib/core/sources/source_registry.dart`, `lib/core/scraper/anime_scraper.dart`,
adapters individuais.

**Critério de aceite:** busca dispara ~1-2 requests (não 12) e retorna os mesmos
resultados; log sem avalanche de "not implemented".

---

### B12 — 🟢 Mensagem de erro do player vaga

**Problema (QA §3.B12):** "Erro de reprodução: Verifique o vídeo." sem contexto
e sem retry automático em outra qualidade.

**Causa raiz (QA_ANALYSIS B12):** `player_screen.dart:256` — string fixa no
`_errorSub`; a exceção `e` é logada mas não exposta. Auto-avanço existe só no
timeout (`:159-171`) e no `completed` não-ready (`:229-243`), não em decode/network error.

**Ação:**
1. Compor mensagem amigável com contexto disponível:
   `_sources[_selectedQualityIndex].quality` + host de `src.url`
   (ex.: "Não foi possível conectar à fonte 360p de animefire.io. A fonte pode
   estar fora do ar.").
2. No `_errorSub` (`:244-264`), quando `_videoReady == false` (erro fatal real),
   tentar **auto-avanço** `_playSource(_selectedQualityIndex + 1)` antes de mostrar o
   erro (paridade com o timeout). Só mostrar erro quando não houver mais fontes.
3. Preservar o guard de não-fatalidade (`:252-255` — vídeo tocando = ignorar).

**Arquivos afetados:** `lib/features/player/player_screen.dart`.

**Critério de aceite:** erro mostra qualidade/host e tenta próxima fonte
automaticamente quando existir.

---

### B13 — 🟢 Focus inicial da Home sem indicador

**Problema (QA §3.B13):** ao abrir, nenhum item tem anel de foco (`e01_home.png`);
o anel só aparece após navegar.

**Causa raiz (QA_ANALYSIS B13):** nenhum `FocusableCard`/`FocusableBannerCard`/
`_ProfileButton`/`_FocusableNavItem` tem `autofocus: true`
(único autofocus do app está no player: `player_screen.dart:498,592,1025`).

**Ação:**
1. Adicionar parâmetro `autofocus` a `FocusableCard`/`FocusableBannerCard`
   (`focusable_card.dart:7-60`) e repassar ao `Focus`.
2. Marcar `autofocus: true` no **primeiro card da primeira seção da Home**
   (`home_screen.dart:454-472` — seção "Em Alta") — só o primeiro da lista, para não
   focar item off-screen.
3. Alternativa mais barata: `autofocus: true` no primeiro `_FocusableNavItem`
   ("Buscar") da `_buildTopBar` (`home_screen.dart:202-209`), garantindo anel visível
   no boot. Escolher conforme UX desejada (card de conteúdo é mais útil).

**Arquivos afetados:** `lib/shared/widgets/focusable_card.dart`,
`lib/features/home/home_screen.dart`.

**Critério de aceite:** screenshot do boot mostra um item focado (anel cyan).

---

## 4. Ordem de execução recomendada (com dependências)

1. **B1** (limpeza de título) — *precondição de B4, favoritos, histórico.*
2. **B2 + B5 juntos** — mesma região (`_buildSliverHeader`/`_EpisodeCard`); evita
   re-trabalho de foco.
3. **B4** (enrich da busca) — destrava com B1.
4. **B3** (posters) — independe; pode andar em paralelo com B4.
5. **B7, B9, B12** — fixes visuais/mensagens (rápidos, alto valor percebido).
6. **B6, B10, B13, B11** — melhorias e limpeza.
7. **B8** — requer **hardware real** para validar preview; deixar por último e
   registrar resultado.

---

## 5. Validação / testes

### Automatizado
- `flutter analyze` — zero novos warnings/errors (gate de cada PR).
- `flutter test` — rodar suíte existente (se houver) após cada mudança.

### Manual (TV via ADB keyevents, como o QA)
- Fluxo E2E: Home → Buscar "naruto" → detalhe → episódio → player (timer avança).
- Navegação D-pad no detalhe: grade ↔ voltar ↔ favorito (B2/B5).
- Verificar nomes limpos em: card de busca, detalhe, favoritos, histórico (B1).
- Busca com posters reais ou fallback AniList (B3); detalhe da busca rico (B4).
- Dialog AniList sem cortes (B7); player sem spinner fantasma (B9); erro com
  contexto e auto-retry (B12); Home com foco inicial (B13); Perfil → Configurações (B10).
- Verificar que buscas não disparam 12 requests (B11) — via logcat.

### Limitações conhecidas (não confundir com bugs)
- **Vídeo preto no screenshot** = limitação do emulador (pipeline media_kit), não bug.
- **Câmera do QR (B8)** = validar em Fire TV físico.
- **Login AniList completo (2 dispositivos)** = não validável no emulador.

---

## 6. Decisões pendentes (precisam do dono do produto)

1. **B1/migração de chaves:** normalizar favoritos/histórico antigos na leitura, ou
   aceitar "perda" dos antigos? *(recomendado: normalizar na leitura)*
2. **B2/UX:** mover o coração para a `SliverAppBar` `actions` (persistente) —
   confirmar que não se perde a estética do hero.
3. **B10:** entregar `SettingsScreen` (entrada no menu Perfil) ou **remover** o arquivo?
4. **B11:** esconder fontes não implementadas (UX) vs. investir em implementá-las
   (fora de escopo desta correção).
5. **B13:** foco inicial no primeiro card de conteúdo vs. no item "Buscar" da topbar.

---

## 7. Status de verificação (2026-08-05)

Fix implementado, `flutter analyze` limpo (0 errors) e `flutter build apk --release` OK
para **todos os 13 bugs**. Status de confirmação no emulador (`emulator-5554`,
1920x1080 @ density 320 = **960x540dp landscape**):

| ID | Fix | Verificação em device |
|----|-----|------------------------|
| B1 | limpeza de título na origem + migração de chave | ✅ parcial — busca retorna títulos reais e limpos (sem `7.93`/`A14`/`(TV)`) |
| B2 | favorito movido para `SliverAppBar.actions` | ◐ código (tela de detalhe aberta no emulador; confirmação visual de foco limitada pela ferramenta) |
| B3 | `thumb` normalizado + headers `Referer`/`User-Agent` | ✅ parcial — posters reais renderizam na grade de busca |
| B4 | enrich fallback no `DetailScreen.initState` | ◐ código |
| B5 | `autofocus` no `_EpisodeCard` índice 0 | ◐ código |
| B6 | `_EpisodeCard` omite título genérico + ícone de play | ◐ código |
| B7 | `SingleChildScrollView` + **QR encolhe em tela baixa** | ✅ **corrigido + confirmado** — root cause era overflow em landscape 540dp tall; "Cancelar" agora visível |
| B8 | scanner com controller + fallback de erro | NOTA: câmera só validável em Fire TV físico |
| B9 | estados loading/erro mutuamente exclusivos | ◐ código |
| B10 | entrada "Configurações" no menu Perfil | ✅ confirmado — item visível no menu |
| B11 | filtro `a.implemented` no scraper | ◐ código |
| B12 | `_friendlyError` com qualidade/host + auto-avanço | ◐ código |
| B13 | `autofocus` no "Buscar" | ✅ **confirmado** — anel de foco cyan presente no boot |

**Contexto B7:** o fix original do plano (só `SingleChildScrollView`) **não** resolveu:
no emulador a tela é 960×540dp (landscape), o conteúdo (QR 250dp + textos + botões)
estoura a altura máxima do dialog (~492dp) e corta o "Cancelar" sem scroll descobrível.
Fix adicional aplicado em `anilist_login_dialog.dart`: o QR agora usa
`size: MediaQuery.of(context).size.height < 700 ? 170 : 250` → o conteúdo cabe inteiro.

**Limitações da ferramenta de verificação:** o tool de visão (`vision`) **alucinou**
um dialog quando direcionado demais e confundiu a tela de detalhe com a home; as
confirmações acima marcam `◐ código` quando dependem de ler texto/ícones pequenos, pois
o mesmo foi validado por inspeção de código + `flutter analyze` + build release, e o
fluxo E2E (busca → detalhe → player) abre sem crash.

---

## 8. Fora de escopo desta rodada

- Implementação de fontes novas (Goyabu/SuperFlix/etc.) — só filtragem/UX (B11).
- Captura de vídeo no emulador — depende de hardware (documentado no QA §7).
- Refatorações não ligadas a bug (ex.: consolidar `_controlNodes`, limpar
  `reassemble` do scanner já coberto em B8).
