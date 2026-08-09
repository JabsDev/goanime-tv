# Plano de Ação — Correção dos bugs de episódios (ordem/quantidade e vídeo não resolvido)

**Data:** 08/08/2026
**Base:** `.qa/RELATORIO_BUG_ORDEM_EPISODIOS.md` (diagnóstico concluído; nenhum código foi alterado)
**Status do documento:** Plano apenas — **ainda não houve alteração de código**.
**Objetivo:** guiar a implementação da correção dos dois bugs, com arquivos, pontos de alteração, riscos, testes e validação (host + Fire Stick).

---

## 0. Contexto e princípios da correção

O relatório identificou **dois bugs independentes** no fluxo de episódios:

| # | Bug | Sintoma | Causa-raiz |
|---|-----|---------|------------|
| 1 | Grade com contagem errada e ordem embaralhada | “One Piece retornou 69 episódios em ordem aleatória” | `streamingEpisodes` (AniList) é parcial, decrescente e **sem número explícito**; o app numera pela **posição do array**. |
| 2 | Fonte achada, vídeo não resolve (Black Clover) | “Nenhuma fonte disponível” em quase todos os eps | Episódios BC (1–169) vivem no backend Blogger (`blogger.com/video.g?token=…`, player SPA anti-bot); o resolvedor não extrai nada de lá. |

Princípios que guiam o plano:

- **A grade nunca deve depender de um campo não-autoritativo.** Catálogo canônico = `anime.episodes` (quando conhecido) / fallback de provider. `streamingEpisodes` é só decoração (título/thumb) e deve ser casado por **número real do episódio**.
- **Bug 2 não é correção de matching** (`resolveAnime`/`bestMatch` funcionam). É defasagem de resolvedor. A solução mínima honesta agora é **não mentir na UI**; a solução completa (recuperar token Blogger) é assunto separado.
- **Nada é alterado sem teste de regressão** usando os payloads reais já salvos em `/tmp/opencode/{op,bc}_result.json`.

---

## 1. Bug 1 — Grade (contagem + ordem)

### 1.1 Diagnóstico consolidado (o que já é fato)

- `lib/core/anilist/anilist_service.dart:920-979` — `getEpisodesV2`:
  - `:921-922` exige token; deslogado → `[]` (o bug só aparece logado).
  - `:928-940` query `streamingEpisodes { title thumbnail url site }` — **sem número de episódio** no schema.
  - `:965-973` `List.generate(streaming.length, ...) number: '${i + 1}'` → numera por posição. **É a raiz do bug.**
- `lib/data/repositories/anime_repository.dart:40-54` — `getCatalogEpisodes`:
  - `:33-37` cache de 24h por identidade (`AppCaches.catalog`, `app_caches.dart:33-36`) → um grid quebrado fica “colado” por um dia.
  - `:44-53` converte para `CatalogEpisode`, **ordenando por número** (mas o número é o índice, então a “ordenação estável” preserva a ordem aleatória do backend).
  - `:56-61` fallback 1..N com `anime.episodes` (correta, hoje só roda quando a lista v2 vem vazia).
  - `:66-71` `_episodeCountFromProviders` (1..N pela fonte) só roda quando a lista continua vazia — **nunca valida que a v2 veio curta/desordenada**.
- `anime_fire_adapter.dart:196-204` → `getEpisodes` também numera por posição (`entry.key + 1`); hoje está correto por sorte (o site lista crescente). Falha por construção (ver §1.6).
- `AniListEpisode.description` guarda o `site` (anilist_service.dart:970) — cosmético; reaproveitar só se fizer sentido.

### 1.2 Objetivo de comportamento pós-fix

- Grade logado = números **reais** e crescente, total correto:
  - One Piece → `EP 1` com o título real do ep 1 em diante, ~1.172 itens (nunca 69 descendo de 130→62).
  - Black Clover → 170, títulos casados por número real.
- Tocar no card sempre resolve o episódio cujo número aparece no card (acabar com o *mismatch label × playback*).
- Progresso (AniList e local) reflete números reais.

### 1.3 Mudanças (por arquivo)

#### A. `lib/core/anilist/anilist_service.dart` — `getEpisodesV2`

1. Extrair o número real do episódio a partir do `title` (“Episode N - …”). Regex única, tolerante a variações:
   - `^\s*[Ee]p(?:isode|\.)?\s*(\d+)` — cobre `"Episode 130 - …"`, `"Ep 12 · …"`, `"Episode 5: …"`.
   - Se o título **não** casar com número, **não conter** o item (não fabricar número por posição). Itens sem número são descartados; o fallback 1..N cobre o total.
2. Retornar `AniListEpisode(number: <número real extraído>, …)`.
3. **Manter o campo `number` como string** no modelo (`anilist_models.dart:216`), apenas passando a ser o número real.
4. **Não** numerar por `i+1` em nenhum caminho restante.

> Guia de implementação: fazer a extração como função pura (`extractEpisodeNumber(String title) → int?`), testável isoladamente e reutilizada em `AnimeFireAdapter.getEpisodes` (§1.6).

#### B. `lib/data/repositories/anime_repository.dart` — `getCatalogEpisodes`

Adicionar **validação de credibilidade** da lista v2 antes de aceitá-la:

1. Se `v2` vier **vazia** → comportamento atual (fallback `anime.episodes` → `_episodeCountFromProviders`). Mantém.
2. Se `anime.episodes != null && anime.episodes > 0`:
   - **Caso A — listas casam** (`v2.length` ≈ `anime.episodes`): montar a grade com os números reais (deduplicação por número + ordenação).
   - **Caso B — divergência grave** (ex.: `v2.length < 0.5 × anime.episodes`, ou v2 desordenada/fora do intervalo 1..N): **ignorar a lista v2 para o grid** — usar o range 1..N de `anime.episodes` e usar `v2` **apenas para decorar** título/thumb por número real quando houver casamento.
3. Independente de A/B: **ordenar por número real** e **deduplicar** (um número não pode aparecer 2×; montar mapa `número → título/thumb`, não usar a lista crua).
4. Nunca permitir que um grid v2 fora do intervalo `1..anime.episodes` substitua o total conhecido.
5. **Healing de cache:** quando a grade reconstruída divergir do cacheado (ex.: o grid quebrado de 69 itens já foi salvo em `AppCaches.catalog`), **sobrescrever** o cache com a grade correta, sem esperar o TTL de 24h. Duas formas:
   - (simples) embutir uma `catalogVersion` na chave `identity`, ou limpar `AppCaches.catalog` uma vez no startup após o deploy da correção; ou
   - (robusta) na própria `getCatalogEpisodes`, quando o grid derivado diferir do cacheado, chamar `AppCaches.catalog.set` novamente (já é feito no fluxo normal, `:73`).

> Decisão de projeto (a confirmar no refinamento): para série RELEASING (`episodes: null` — ex. One Piece), o Caso B usa o fallback provider (`_episodeCountFromProviders`) para definir o total e decorar títulos com a v2 quando casarem. Isso garante cobertura de séries longas mesmo sem `anime.episodes`.

#### C. `lib/features/detail/detail_screen.dart`

1. `:140-143` e `:726-731` — o toque já resolve pelo **número do card** (`widget.episode.number`). Após o fix do grid (número real), isso fica correto **sem mudança de código**. Apenas verificar.
2. `_reconcileWithAnilist` (`:73-109`) e `updateProgress` (anilist_service.dart:458-482):
   - Hoje operam por índice da grade; com grade correta (1..N real), o índice vira número real.
   - **Atenção legado:** grids quebrados anteriores podem ter gravado `watched`/progresso local com índices “fantasmas” (ex.: assistiu “EP 1” = ep 130 da fonte). Verificar no QA se há “pulo” de progresso após o fix; se aparecer, não corrigir o dado automaticamente — documentar e limpar localmente em teste.

### 1.4 Nova função pura — extração de número

Local sugerido: `lib/core/utils/episode_number.dart` (ou junto ao `anilist_service.dart`).

- API: `int? extractEpisodeNumber(String title)`.
- Regras: casar `Episode N` (prefixo), `EP N`, `Ep. N`, separador `-`/`:`/`·`; retornar `null` para títulos sem número ou com marcadores de extra (Movie/Special/OVA — esses não são o número da série).
- Uso nos dois lugares: `getEpisodesV2` (§1.3 A) e `AnimeFireAdapter.getEpisodes` (§1.6).

### 1.5 Progresso (amarrar com o grid real)

- `updateProgress` (`anilist_service.dart:458-482`) deve registrar o **número real** no AniList. Como o grid agora é real, basta que os callers usem o número do card. Sem mudança estrutural; só um QA de ambiguidade (§4).
- `_reconcileWithAnilist`: manter semântica (progress = nº de episódios assistidos); validar no Fire Stick após o deploy.

### 1.6 AnimeFire `getEpisodes` — numerar por URL/título (defesa)

`lib/core/sources/anime_fire_adapter.dart:196-204` numera por posição (`entry.key + 1`). Hoje funciona porque o site lista em ordem crescente. Para não herdar o bug 1 na camada de provider:

- Tentar extrair o número do href (`.../episodio-130/`) ou do título da página; caindo para `entry.key + 1` como fallback.
- **Prioridade baixa** (não bloqueia o fix do grid), mas usa a mesma função pura de §1.4; é barato.

---

## 2. Bug 2 — Black Clover (séries em Blogger): fonte achada, vídeo não

### 2.1 Fatos consolidados

- `resolveAnime`/`bestMatch` funcionam (`anime_source_adapter.dart:48-60`, `:96-153`).
- `AnimeFireAdapter._extractFromAnimeFire` (`anime_fire_adapter.dart:265-368`) não extrai nada quando o episódio é Blogger:
  - Método 0 API (`/video/…`) → ausente no BC 1–169.
  - Método 1 `[data-video-src]` → ausente.
  - Métodos 3/5 Blogger (`video.g?token=`) → `curl` do token responde com player SPA `/_/BloggerVideoPlayerUi` sem `.mp4/.m3u8` → zero de extração.
  - Ep 170 (backend novo `/video/`) → funciona.
- One Piece no mesmo probe: 1 source por ep (usa a API nova). Reproduzido no host, independente da rede do Fire Stick.

### 2.2 Objetivo com decisão de escopo

Decisão recomendada: **plano B** (honestidade da UI) como entrega mínima no mesmo sprint; **plano A** (resolução real do token Blogger) como investigação futura que **pode não ser viável**.

| Plano | Esforço | Entrega | Risco |
|---|---|---|---|
| **A — Recuperar stream real do token Blogger** | Alto (headless WebView / browser / proxy via `flutter_inappwebview` ou serviço externo) | Play real de BC 1–169 | Alto: SPA anti-bot, EULA/termos, manutenção frágil; headless em TV é pesado. |
| **B — Tratar como “indisponível” com mensagem honesta (recomendada)** | Baixo | Mensagem clara “Episódio indisponível nesta fonte” em vez de “Nenhuma fonte disponível” | Zero (melhora o comportamento atual) |

### 2.3 Ações do plano B

1. `lib/data/repositories/anime_repository.dart` — `resolveProvidersForEpisode` (`:113-177`):
   - Hoje o erro é **silencioso**: o provider casa a página, a extração devolve 0 sources, a fonte some do mapa e a UI mostra o genérico.
   - **Distinguir dois estados:**
     - **Não encontrada** (a página nem existe; `resolveAnime` retornou nulo);
     - **Casou, mas o resolvedor falhou** (página casou via `resolveAnime`, mas a extração de vídeo retornou vazio).
   - Retornar esse estado para o chamador (ex.: registrador no mapa ou um `ResolutionReport`), para a UI renderizar a mensagem certa.
2. `lib/features/detail/detail_screen.dart` — mensagens da ficha/grade:
   - Condicionar a mensagem: todas as fontes “não encontradas” → mantém o texto atual; **ao menos uma fonte casou página, mas falhou a extração** → “Episódio indisponível nesta fonte (vídeo não suportado)”.
   - Deixar explícito (como aviso) que o episódio existe, mas o vídeo não abre nesta fonte.
   - Não bloquear o fluxo de progresso (marcar assistido continua permitido; confirmar no refinamento — default: permite).
3. (Opcional, barato) — `AnimeFireAdapter._extractFromBlogger` (`anime_fire_adapter.dart:433-595`): detectar o padrão SPA (`/_/BloggerVideoPlayer` no HTML de resposta) e retornar um marcador de “blogger não suportado” em vez de zero mudo — assim o repositório classifica “casou, mas indisponível” sem depender da presença de vídeo.
4. **Não forçar agora:** sem headless/browser neste plano.

### 2.4 Opcional — fontes alternativas

- Com falha generalizada de extração, as outras fontes (goyabu/dooplay/animePlayer) já são tentadas em paralelo; se os resolvedores delas forem corrigidos (estão defasados, ver `.qa/RELATORIO_DIAGNOSTICO_PROVIDERS.md`), o app pode ganhar fonte real para essas séries. Fica fora do escopo desta correção (§7).

---

## 3. Testes / regressão

### 3.1 Payloads reais usados como fixtures

- `/tmp/opencode/op_result.json` (One Piece: **69 itens decrescentes 130→62**, `episodes: null`).
- `/tmp/opencode/bc_result.json` (Black Clover: **170 crescentes 1–170**, FINISHED com `episodes`).

Copiar para o repositório (ex.: `test/fixtures/`) **antes** de escrever os testes. Não depender de rede.

### 3.2 Testes a adicionar/ajustar

1. **`extractEpisodeNumber` — unit (nova):**
`"Episode 130 - …" → 130`, `"EP 1 · …" → 1`, `"Ep. 12: …" → 12`, `"Episode 5" → 5`; título sem número → `null`; título com `Special`/`OVA`/`Movie` → `null` (comportamento documentado).
2. **`getEpisodesV2` com payload de One Piece** (`catalog_resolver_test.dart` ou arquivo novo): a grade **não** vira os 69 itens descendentes; sai ordenada 1..N com título real por número; com `episodes:null` (RELEASING) → usa decorar a grade do fallback.
3. **`getCatalogEpisodes` com casos-limite:** lista parcial (69/1172), decrescente, números não sequenciais, série sem `anime.episodes` → sempre um grid ordenado 1..N, sem duplicatas, dentro do total conhecido.
4. **Garantir o contrato canonical** (já cobre `catalog_resolver_test.dart`): o grid v2 com números reais continua puro (sem url/provider).
5. **Plano B (Bug 2):** unit de `resolveProvidersForEpisode` com `MockClient` que devolve HTML de Blogger SPA para uma fonte e HTML normal para outra → o resultado distingue “indisponível” de “não encontrada”.
6. **Live probe** (`test/live_sources_probe_test.dart`): já cobre One Piece/Black Clover; ao executar com `LIVE=1`, BC EP1 continua zerando sources hoje, e o plano B exige que a classificação seja coerente (mensagem, não exceção).

### 3.3 Verificação geral

- `flutter analyze`.
- `flutter test` (CI).
- `flutter test test/live_sources_probe_test.dart --dart-define=LIVE=1` (quando houver rede).
- Repro passo a passo do relatório (§7).

---

## 4. Validação no Fire Stick

- Usar o `deploy_firestick.sh` (`.qa/`) para a nova build.
- Fire Stick (`100.66.110.37:5555`), e o teste com usuário logado.
1. One Piece (lista “Continue assistindo”): grade → EP 1 com título real, contagem ~1.172 crescente, sem duplicatas.
2. Tocar EP 1 → abrir ep 1; EP 62 → abrir 62 (local igual ao título do card).
3. Black Clover: ep 170 abre; ep 1 exibe a mensagem de indisponibilidade tratada (nunca “Nenhuma fonte”).
4. Progresso: assistir 2 vols → o AniList (perfil) reflete o número real; reabrir a série → “Continue assistindo” correto.

---

## 5. Ordem de execução (sequencial)

| Passo | Tarefa | Artefato |
|---|---|---|
| 1 | Copiar payloads para fixtures (`test/fixtures/`) | `op_result.json`, `bc_result.json` |
| 2 | `extractEpisodeNumber` + unit test (§1.4, §3.2.1) | `lib/core/utils/episode_number.dart` ou `anilist_service.dart` |
| 3 | `getEpisodesV2` com número real + testes | `lib/core/anilist/anilist_service.dart` |
| 4 | `getCatalogEpisodes` — validação de total + deduplicação + healing de cache | `lib/data/repositories/anime_repository.dart` |
| 5 | Verificar toque → resolução (sem mudança; validar) | `lib/features/detail/detail_screen.dart` |
| 6 | Plano B — classificação “casou, mas indisponível” + UI | `anime_repository.dart`, `anime_fire_adapter.dart`, `detail_screen.dart` |
| 7 | AnimeFire `getEpisodes` por número (título/URL) — baixa prioridade | `lib/core/sources/anime_fire_adapter.dart` |
| 8 | `flutter analyze` + `flutter test` completo + live probe | — |
| 9 | Deploy Fire Stick + validação manual (§4) | — |

---

## 6. Riscos e decisões abertas

- **Grid “colado” por TTL 24h** em instalações com o grid quebrado cacado — mitigado pelo healing (§1.3.B.5).
- **Bug 2: plano B não resolve o vídeo** — apenas deixa a UI honesta. A decisão de fazer o plano A (headless) é arquitetural e fica fora do escopo salvo nova autorização.
- **Progresso legado** gravado sob grade quebrada pode vir com índices errados (§1.5) — validar no QA; limite só se realmente quebrar.
- **Filmes/OVAs em `streamingEpisodes`** podem casar número errado se a heurística não filtrar — a extração deve retornar `null` para títulos com Special/OVA/Movie (ver §1.4).

---

## 7. Não-objetivos (fora do escopo, documentado para depois)

- Recuperação do token Blogger via headless/browser (plano A — só se autorizado).
- Correção dos resolvedores goyabu/dooplay/animePlayer (defasagem de markup em `.qa/RELATORIO_DIAGNOSTICO_PROVIDERS.md`).
- Mudança de arquitetura do `AnimeRepository`/orquestração além do necessário para esses dois bugs.

*Fim do plano.*