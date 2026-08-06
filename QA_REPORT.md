# QA Report — GoAnime TV (v1.0.0+1000000)

> **Data:** 2026-08-05
> **Analista:** QA Tester Sênior (via opencode, inspeção de UI por subagente `vision`)
> **Nível de teste:** End-to-end manual em TV via D-pad (pesquisa → detalhe → reprodução)
> **Estratégia:** Navegação por keyevents ADB + captura de screenshots + análise visual + logcat. **Nenhum código foi alterado/criado nesta etapa.**

---

## 1. Ambiente de teste

| Item | Valor |
|---|---|
| Dispositivo 1 | Emulador Android TV **GoAnime_TV** (AVD), API 36, `sdk_google_atv64_x86_64`, 1920×1080, GPU swiftshader (software) |
| Dispositivo 2 | Fire TV Stick (AFTSS) Android 9, 1920×1080 (testes iniciais de navegação) |
| Build testado | `build/app/outputs/apk/release/app-release.apk` (ABIs: arm64-v8a / armeabi-v7a / x86_64) |
| Package | `com.example.goanime_tv` |
| Resultado geral | **APP FUNCIONA de ponta a ponta com 1 fonte ativa, mas com múltiplos bugs de dados e UX.** Crashes/ANRs: **nenhum**. |

**Fluxo E2E validado (OK):** Home carrega catálogo → Buscar → digitar consulta → resultados em grade → abrir detalhe → lista de episódios → selecionar qualidade → **player reproduz (timer avança, duração correta, controles funcionam)**.

---

## 2. Resumo executivo (bugs encontrados)

| ID | Severidade | Título |
|---|---|---|
| B1 | 🔴 Alta | Títulos de animes vêm **poluídos** com nota + faixa etária (dados do scraper) |
| B2 | 🔴 Alta | Botão **Favorito (❤) inacessível** por D-pad em TV (hero some ao scrollar) |
| B3 | 🟠 Média | **Imagens de poster quebradas** nos resultados de busca (14 de 15) |
| B4 | 🟠 Média | Detalhe vindo da **busca** sem sinopse/backdrop/gêneros (falta enriquecimento) |
| B5 | 🟠 Média | **Focus pode pousar fora do viewport** (hero/back sumidos) — navegação confusa |
| B6 | 🟡 Menor | Títulos de episódios truncados para "Epis…" (sem thumbnail nas células) |
| B7 | 🟡 Menor | Dialog "Conectar AniList": **botão "Cancelar" cortado** no rodapé |
| B8 | 🟡 Menor | Scanner QR: **preview de câmera nunca ativa** (fica em tela de instruções) |
| B9 | 🟡 Menor | Player: **overlay de erro com "spinner fantasma"** sobreposto ao texto |
| B10 | 🟢 Info | **SettingsScreen existe mas não é alcançável** (morto/órfão) |
| B11 | 🟢 Info | Apenas **AnimeFire** funciona como fonte; demais fontes "not implemented" |
| B12 | 🟢 Info | Mensagem de erro do player vaga ("Verifique o vídeo"), sem detalhe/utilidade |
| B13 | 🟢 Info | Mensagem de erro na tela inicial não é durável; focus inicial da Home sem indicador |

Referências de screenshot usadas: `.qa/screens/*.png`

---

## 3. Bugs detalhados (para a AI corrigir sem reler o projeto)

### B1 — 🔴 Títulos de animes poluídos com nota e faixa etária
- **Onde:** Dados do scraper AnimeFire.
- **Sintoma (evidência):** Ao abrir detalhe, `logcat` mostra:
  - `[Detail] initState name=Naruto: Shippuuden Movie 2 - Kizuna   7.34  A14 source=animeFire`
  - `[Detail] ... nome=Jujutsu Kaisen (TV) (Dublado)   8.39  A16`
- Na Home/busca, títulos também aparecem sujos: "Naruto 7.93 A14", "Jujutsu Kaisen (TV) (Dublado)".
- **Causa provável:** `name = el.text.trim()` puxa o texto completo do `<a>`, que inclui elementos-filhos de nota/faixa etária/label.
- **Local do código:** `lib/core/sources/anime_fire_adapter.dart:67` (`.text` do selector `.row.ml-1.mr-1 a`) e `:91` (`title = titleElem?.text.trim()` do `.card_ani .ani_name a`).
- **Correção sugerida:** extrair apenas o nó de texto do título (não o `text` agregado com filhos), ou limpar com regex os sufixos `\d+\.\d+\s*A\d+` / `(TV)` / `(Dublado)`.
- **Impacto:** títulos exibidos, histórico e matching de favoritos ficam sujos.

### B2 — 🔴 Botão Favorito (❤) inacessível em TV via D-pad
- **Onde:** `DetailScreen` — header (`SliverAppBar` com `FlexibleSpaceBar`).
- **Sintoma:** O coração fica no canto superior-direito dentro do hero (backdrop). Quando a página scrolla, o hero (e o coração) saem do viewport. A navegação por D-pad **não** alcança o coração:
  - UP vindo da grade de episódios pula o hero e pousa direto no **botão voltar** (evidência `e33_hero_visible.png`).
  - RIGHT a partir do voltar não vai ao coração (`e34_from_back.png`).
  - Tap por coordenadas não funciona (interpretado como arrasto no `CustomScrollView`) — `e28/e29` coração continua outline.
- **Local do código:** `lib/features/detail/detail_screen.dart` — `_FavoriteButton` (widget `_FavoriteButton`, `:1204`) é `Positioned` dentro do `Stack` do `FlexibleSpaceBar` (`:249-368`), que colapsa ao scrollar.
- **Correção sugerida:** (a) manter o coração em área persistente (ex.: na `SliverAppBar` `pinned` acima do collapse, ou em ação da barra superior), e/ou (b) garantir foco reverso do grid para o header com `nextFocusUp`, e (c) tornar o alvo de toque maior/estável.

### B3 — 🟠 Imagens de poster quebradas em resultados de busca
- **Sintoma:** Pesquisa "naruto" → 15 resultados, mas **14/15** mostram placeholder cinza (ícone de filme). `logcat`: `FlutterImageDecoderImplDefault: Failed to decode image ... Input contained an error.`
- **Nota:** Num segundo acesso os mesmos itens carregaram (cache/redownload OK). Indica URLs de imagem instáveis/conteúdo inválido às vezes.
- **Evidência:** `e04_search_result.png` (14/15 quebradas); `e13_jujutsu.png` (todas OK).
- **Local/causa provável:** construção de `thumb`/`fallbackImageUrl` em `anime_fire_adapter.dart:68-79,94-95` (`data-src`/`src`). Imagem pode exigir `Referer` ou ser protegida por hotlink.
- **Correção sugerida:** validar/redirect das URLs; testar com header `Referer: https://animefire.io/` e fallback por outro CDN.

### B4 — 🟠 Detalhe vindo da busca sem sinopse/backdrop/gêneros
- **Sintoma:** Abrir resultado da **busca** → detalhe só com título, nota, pill de fonte e episódios; **sem sinopse, sem backdrop (área vazia no topo), sem gêneros** (`e08_detail.png`). Já abrir da **Home** ("Em Alta" / AniList) → detalhe rico com sinopse, gêneros, backdrop (`e27_onepiece_detail.png`).
- **Causa provável:** `SearchScreen` empurra `DetailScreen` **sem** passar por `AniListService.enrich()`. Diferente de `openFromMap`/`openAnilistDetail` em `lib/features/home/home_navigation.dart` que fazem enrich.
- **Local do código:** `lib/features/search/search_screen.dart:169-176` (`Navigator.push(... DetailScreen(anime: _results[i]))`).
- **Correção sugerida:** aplicar `AniListService.enrich(anime)` antes de abrir o detalhe na busca (padrão já usado em `home_navigation.dart`), ou buscar metadados no próprio `DetailScreen` quando vazios.

### B5 — 🟠 Foco pode pousar fora do viewport / navegação salta hero
- **Sintoma:** No detalhe, UP a partir da grade joga o foco para o voltar sem revelar o hero (coração/metadados) — vide B2 (`e33_hero_visible.png`, `e34_from_back.png`). Em alguns passos o foco vai parar em elemento **fora da tela**, e a captura não mostra nenhum anel de foco.
- **Local envolvido:** `_EpisodeCard` / `_BackButton` usa `FocusKeyHandler` com `onKeyEvent` interceptando direção; foco com seta no `CustomScrollView` nem sempre scrolla o alvo para a vista.
- **Correção sugerida:** usar `Focus` com `Scrollable.ensureVisible` / `ShowOnFocus`, e `descendantsAreFocusable`/`FocusTraversalPolicy` adequado para o header; ou `autofocus` no primeiro card ao abrir.

### B6 — 🟡 Títulos de episódio truncados e sem thumbnail
- **Sintoma:** todas as células de episódio mostram `EP <n>` + título cortado em "Epis…" e **nenhuma thumbnail** (apenas fundo escuro). `e14_jjk_detail.png`, `e27_onepiece_detail.png`.
- **Causa:** `episode.title` costuma vir como "Episódio N" (`anime_fire_adapter.dart:176`) e `episode.thumbnail` vem vazio — então o card mostra "EP N" e repete "Epis…" no texto, truncado.
- **Local:** `_EpisodeCard` em `lib/features/detail/detail_screen.dart:581-683` (coluna de texto com `maxLines:1`/ellipsis); thumbnail condicionada a `episode.thumbnail` não-vazio.
- **Correção sugerida:** quando `title == 'Episódio N'` ou vazio, omitir a linha de texto (deixar só "EP N"); exibir placeholder com ícone de play quando não houver thumbnail.

### B7 — 🟡 Dialog "Conectar AniList": botão "Cancelar" cortado
- **Sintoma:** no rodapé do dialog o botão "Cancelar" aparece parcialmente fora da área visível (cortado no canto inferior). `e21_login.png`, `e22_login_focus.png`.
- **Local:** `lib/features/home/anilist_login_dialog.dart` (conteúdo do `Dialog`/`AlertDialog` excede a altura com QR + 3 botões).
- **Correção sugerida:** garantir `SingleChildScrollView` no conteúdo, `mainAxisSize.min`, ou reduzir altura/empacotamento.

### B8 — 🟡 Scanner QR: preview de câmera não ativa
- **Sintoma:** ao conceder permissão de câmera e entrar em "Escanear QR Code", a tela fica na **instrução estática** ("Escaneie o QR Code na TV", "Como escanear: 1. Abra a câmera do celular") com área de scan escura — **nunca ativa o preview/finder**. `e24_qr_scanner.png`.
- **Nota:** pode ser limitação do emulador (câmera virtual Android TV). Verificar em hardware real. Também o conteúdo de instruções é cortado na parte de baixo.
- **Local:** `lib/features/home/anilist_qr_scanner_screen.dart` (usa `mobile_scanner`).
- **Correção sugerida:** validar inicialização do scanner e dar fallback legível (mensagem de erro se câmera indisponível); revisar corte do texto de instruções.

### B9 — 🟡 Player: overlay de erro com "spinner fantasma"
- **Sintoma:** na tela de erro do player, aparece um **anel de spinner branco parcial sobreposto ao texto** ("...reprodução: ‖ Verifique...") — estados de loading+erro renderizados juntos. `e12_player.png`.
- **Local:** `lib/features/player/player_screen.dart` (transição entre spinner de carregamento e overlay de erro sem ocultar o primeiro).
- **Correção sugerida:** ocultar o spinner quando marcar o estado de erro (`_error != null` → remover widget do spinner).

### B10 — 🟢 SettingsScreen órfã / inalcançável
- **Fato:** existe `lib/features/settings/settings_screen.dart`, mas **nenhum fluxo navega para ela** (grep de `SettingsScreen(` só a declaração; Home só tem "Buscar" e "Perfil" no topo). O usuário nunca chega às configurações.
- **Correção sugerida:** adicionar entrada de Configurações (ex.: no menu Perfil) e/ou remover o arquivo se não for entregar.

### B11 — 🟢 Somente AnimeFire ativo (resto não implementado)
- **Fato (logcat):** busca tenta todas as fontes; só AnimeFire retorna resultados:
  - Goyabu/SuperFlix/AnimesDigital/DooPlay/Anikyuu/AnimeIto/AnimePlay/AnimePlayer/AnimeQ → *"search not implemented"*; AllAnime → *"requires captcha"*; AniList → *"not authenticated"*.
- Consistente com `README.md` (status das fontes).
- **Sugestão:** deixar claro na UI quais fontes estão ativas, e esconder/habilitar as ainda não implementadas.

### B12 — 🟢 Mensagem de erro do player vaga
- **Sintoma:** falha de stream mostra apenas "**Erro de reprodução: Verifique o vídeo.**" com "Tentar novamente". Sem contexto (URL/host/erro TCP). `e12_player.png`.
- **Local:** `lib/features/player/player_screen.dart` (estado de erro `_error`).
- **Correção sugerida:** incluir causa amigável (ex.: "Não foi possível conectar à fonte 360p. Fonte pode estar fora do ar.") e re-tentar em outra qualidade automaticamente.

### B13 — 🟢 Focus inicial da Home / indicador
- Ao abrir o app a captura inicial às vezes não mostra **nenhum** elemento com anel de foco (`e01_home.png`) — provável ausência de autofocus no lançamento. O anel cyan aparece assim que se navega. 
- **Correção sugerida:** definir `autofocus` num item inicial da Home para que o usuário veja o estado focado desde o início.

---

## 4. Reprodução de um stream (resultado misto)

Testado para avaliar reprodução de vídeo:

| Título | Qualidade(s) | Resultado | Evidência/log |
|---|---|---|---|
| Naruto: Shippuuden Movie 2 (filme) | 360p (única) | ❌ **Falhou: connection refused** a `zzz.athena.feralhosting.com:8181` | `e10/e12`, log `[Player] Error event: tcp: ... Connection refused` |
| Jujutsu Kaisen (TV) EP 6 | 720p (2 fontes) | ✅ **Player abriu, durou 1433s, timer avançou (0:55/23:53), 720p OK** | `e16/e17`, log `Source 1 opened successfully`, `Video is ready` |

- **Conclusão:** o player de fato reproduz (decodifica, avança timer, mostra controles, badge de qualidade, skip ±10s, CC). A falha do Naruto foi uma **fonte específica indisponível** (feralhosting), não um bug geral do player.
- **⚠️ Limitação do ambiente (confirmada por reteste):** o **frame de vídeo aparece preto** na captura mesmo com **GPU host (NVIDIA RTX) + janela visível** — testado com `-gpu swiftshader_indirect` e `-gpu host`, em ambos o timer de reprodução avança (1:01/23:53) mas o vídeo não é composto/capturado. Conclusão: é limitação do pipeline de vídeo do emulador/media_kit (não fornece a tela para o app nesta VM), **não** um bit do app nem do modo de GPU/janela. **Avaliar imagem real em device real (Fire TV, decoder HW + tela física).** A tela de erro (B9/B12) sim é bug visível e independe disso.

---

## 5. Problemas de dados (qualidade)

1. **Títulos sujos** (B1) — nota + faixa etária + "(TV)/(Dublado)" anexados ao nome.
2. **Imagens de poster instáveis** (B3) — decodificação falha intermitente.
3. **Episódios sem descrição/thumbnail** na fonte AnimeFire (B6) — a UI fica pobre por ausência de dado.

---

## 6. Observações de UX (visão geral, dos testes visuais)

- Foco usa borda cyan + glow + (cards) escala + glow; aparece corretamente quando um item está focado. OK.
- Cards de catálogo com títulos longos encostam na borda do card (visão `01_home.png`, `02`): considerar `maxLines`+ellipsis consistente.
- Na Home, apenas 1 linha de catálogo visível por vez; resto exige scroll vertical — sem indicador de scroll. Comum em TV, ok.
- Borda direita dos cards cortada na borda da tela é comportamento esperado de rail horizontal.

---

## 7. Limitações do teste (para não confundir bugs da AI)

- **Vídeo preto no screenshot** = limitação do emulador (GPU software/midia), não confirmado como bug do app — testar no Fire TV.
- **Câmera do scanner QR** (B8) abriu a permissão, mas sem preview no emulador — confirmar em hardware.
- Login AniList completo (fluxo QR de 2 dispositivos) **não concluído** no emulador (sem 2º dispositivo); validado apenas a abertura do dialog, QR e scanner.
- Digitar texto usa o teclado LatinTV do sistema; em Fire TV o teclado tem painel QR "digite pelo telefone" (recurso do sistema, não do app).

---

## 8. Prioridade de correção recomendada

1. **B1** títulos limpos (corrompe quase toda a UI de dados).
2. **B2/B5** acesso ao Favorito e foco-fora-de-tela (rota de navegação em TV).
3. **B4** enriquecer detalhe vindo da busca (paridade com Home).
4. **B3** posters de busca.
5. **B7/B9/B12** correções visuais/mensagens de dialog e player.
6. **B6, B8, B10, B11, B13** melhorias e limpezas.

Screenshots de evidência em `.qa/screens/` (listados nas seções acima).