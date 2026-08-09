# Plano de Ação Melhorado — Ordem/quantidade de episódios + vídeo não resolvido

**Data:** 08/08/2026
**Base:** `.qa/RELATORIO_BUG_ORDEM_EPISODIOS.md` (diagnóstico) e `.qa/PLANO_ACAO_BUG_ORDEM_EPISODIOS.md` (plano original — este documento corrige as falhas dele).
**Status:** Plano apenas — **nenhum código foi alterado ou criado nesta etapa**.
**Objetivo:** criticar o plano original (Seção 0), apontar erros de lógica e promessas irreais, e apresentar um plano executável corrigido para os dois bugs.

---

## 0. Crítica ao plano original

### 0.1 Erros de lógica / bugs reais

**P1. O "Caso A" do plano original ancora a grade no TAMANHO de `v2` (`v2.length ≈ anime.episodes`) — isso viola o próprio princípio anunciado no §0 do plano ("a grade nunca deve depender de um campo não-autoritativo").**
- Se `v2` tiver 170 itens com números reais 40–209 (mesmo tamanho de `anime.episodes=170`), o Caso A aceitaria a grade e o usuário veria uma grade iniciando no episódio 40.
- Um `streamingEpisodes` parcial, mas com comprimento igual ao total, passa na heurística e gera grade errada.
- **Correção:** a grade é **sempre** a lista contígua `1..N`, onde `N` vem de fonte canônica (AniList `episodes` ou fallback provider). `v2` **apenas decora** títulos/thumbnails por número real. Remove-se a heurística `0.5×` inteira.

**P2. A meta "EP 1 com o título real do EP 1 em diante" (plano §1.2 e repro §7) é inatingível com a fonte atual.**
- O payload real de One Piece (`streamingEpisodes`) cobre somente os episódios **62–130**. Não existem títulos para EP 1–61 nem 131–1172.
- O plano original promete algo que os dados não entregam → critério de aceitação inválido.
- **Correção:** meta realista = **contagem e ordem corretas** (nunca 69 descendentes), com títulos exibidos **somente** na faixa coberta por `v2`. Aceitar explicitamente que EP 1 de One Piece ficará sem título.

**P3. O cache do grid ignora o estado de login.**
- `AppCaches.catalog` é chaveado por `identity` (anilistId ou título limpo). `getEpisodesV2` retorna `[]` deslogado e dados ricos logado — **a mesma chave de cache pode servir uma grade deslogada para um usuário logado (e vice-versa) por até 24h**.
- **Correção:** chave do cache passa a incluir um flag de sessão (`logado ? 'v2' : 'v1'`) + bump de versão do algoritmo, invalidando grids antigos da mesma execução.

**P4. `resolveProvidersForEpisode` remove o match persistido sempre que a extração volta vazia (`anime_repository.dart:146-154`).**
- No caso Blogger (Black Clover), a página **existe e o match está correto** — o resolvedor é que não extrai. Remover o match força um re-search por toque (custo de busca + throttle de 250ms + mais risco de 429 no AnimeFire).
- **Correção:** quando a página casou mas a extração falhou (`matchedUnavailable`), o match persistido é **mantido**. `removeMatch` só é chamado quando a página realmente não existe/não foi achada.

**P5. O plano original trata "0 sources" como um único estado, mas existem duas causas distintas.**
- (a) o episódio **não existe** na fonte; (b) o episódio **existe mas o resolvedor não consegue o vídeo** (Blogger/SPA anti-bot). O plano propôs distinguir "página existe" de "página não existe", mas o motivo (b) exige um marcador explícito do resolvedor, não heurística de vazio.
- **Correção:** classificação tripla por provider: `ok` / `matchedUnavailable` / `notFound`, alimentada por um marcador de Blogger no `AnimeFireAdapter`.

**P6. `extractEpisodeNumber` do plano original usa regex restrita (`^\s*[Ee]p(?:isode|\.)?\s*(\d+)`).**
- Não cobre títulos em pt-BR ("Black Clover – **Episódio 1** – Asta e Yuno") nem número no meio do texto; e o número do AnimeFire vem da **URL** (`/animes/black-clover/1`), não do título.
- **Correção:** duas funções puras: `episodeNumberFromTitle` (tolera `Ep`, `Ep.`, `Episode`, `Episódio`, acentos) e `episodeNumberFromUrl` (último segmento numérico).

**P7. O plano original deixava a decisão do RELEASING ("episodes: null" — exatamente o caso One Piece) "a confirmar no refinamento".**
- O bug principal do relatório fica sem decisão no documento que deveria executá-lo.
- **Correção:** decisão tomada neste plano (Seção 2.2): RELEASING usa a cadeia `anime.episodes → _episodeCountFromProviders → max(v2) → 0`.

**P8. Testes do original dependiam de rede/token implícitos.**
- Testar grade `1..1172` para One Piece exigiria token mockado e um `_episodeCountFromProviders` sem mock → testes flaky/network-dependentes.
- **Correção:** testes com token via `httpOverride`, `AnimeRepository(adapters: [fakeAdapter])` para prover contagem, e fixtures no repo.

### 0.2 Promessas/coisas que estavam certas e foram mantidas
- Causa-raiz correta do Bug 1 (`getEpisodesV2` numera por posição).
- Escopo do Bug 2: Plano B (honestidade da UI) como entrega mínima; Plano A (headless) fora do escopo.
- Uso dos payloads reais como fixtures.
- Não bloquear fluxo de progresso quando a fonte está indisponível.

---

## 1. Princípio único (o coração deste plano)

> **A grade de episódios é sempre uma lista contígua `1..N`, onde `N` vem de fonte canônica de contagem (AniList `episodes` ou fallback provider). `streamingEpisodes` (v2) nunca define a grade — apenas decora títulos/thumbnails por número real.**

Isso elimina o Caso A/Caso B do plano original (e a heurística arbitrária `0.5×`), elimina o P1/P2/P9, e segue — agora por inteiro — o princípio que o próprio plano original anunciava no §0, mas que o Caso A violava.

---

## 2. Bug 1 — Grade (contagem + ordem)

### 2.1 Arquivos afetados

| Arquivo | Função | Mudança |
|---|---|---|
| `lib/core/utils/episode_number.dart` | **novo** | `episodeNumberFromTitle(String) → int?` e `episodeNumberFromUrl(String) → int?` |
| `lib/core/anilist/anilist_service.dart` | `getEpisodesV2` (`:920-979`) | número real do título; descarta itens sem número |
| `lib/data/repositories/anime_repository.dart` | `getCatalogEpisodes` (`:34-75`) e `_episodeCountFromProviders` (`:81-105`) | grade `1..N` canônica + decoração por número; cadeia de contagem |
| `lib/data/repositories/anime_repository.dart` | chave do cache | incluir flag de login + versão do algoritmo |
| `lib/core/sources/anime_fire_adapter.dart` | `getEpisodes` (`:196-204`) | `episodeNumberFromUrl` no href (prioridade baixa) |
| `lib/features/detail/detail_screen.dart` | `_reconcileWithAnilist` / `updateProgress` | QA de progresso legacy (não reescrever dados ativos) |

### 2.2 `getEpisodesV2` (anilist_service.dart:920-979)

1. Para cada item de `streamingEpisodes`:
   - `int? n = episodeNumberFromTitle(title)`;
   - `n == null` → **não incluir** o item (não fabricar número por posição).
2. Montar `AniListEpisode(number: '$n', title: ..., thumbnail: ...)` — `number` continua String, mas agora com o número real.
3. Remover o `List.generate(streaming.length, i => i + 1)`.
4. Manter o retorno `[]` quando deslogado (sem token → sem títulos; comportamento atual preservado).

> `episodeNumberFromTitle` deve cobrir `Episode 130 - …`, `EP 1 · …`, `Ep. 12: …`, `Episódio 5 - …` (acento) e retornar `null` para `Special`/`OVA`/`Movie`/título sem número.

### 2.3 `getCatalogEpisodes` — reescrita mínima do fluxo

```
N = anime.episodes (se != null && > 0)
    senão: N = await _episodeCountFromProviders(anime)      // provider (ex.: 1172 p/ OP)
    senão: N = max de número real presente em v2 (se houver) // último recurso p/ não zerar
    senão: N = 0 (grade vazia)

grade = [CatalogEpisode(number: i) for i in 1..N]            // sempre contígua

decoração = mapa { número_real -> {title, thumbnail} }       // de v2
            ignorando itens fora de [1..N] e duplicatas por número
grade[i].title/thumbnail = decoração[i+1] quando existir
```

Decisões tomadas (não "a confirmar"):
- **RELEASING (`episodes == null`)** usa a cadeia acima. `_episodeCountFromProviders` já existe e retorna o `data.length` do primeiro provider que responde (AnimeFire → 1172 para One Piece hoje). Se o provider falhar (offline/429), usa `max(v2)` como último recurso para não zerar a grade.
- **Cache:** chave `'${identity}|${logado ? 'v2' : 'v1'}|gridV2'`. O bump `gridV2` invalida grids cacheados em execução antiga.
- **Dedup** apenas no mapa de decoração; a grade base é `1..N` e não pode ter duplicatas por construção.

### 2.4 Progresso (amarrar com números reais)

- `_reconcileWithAnilist` (detail_screen:73-109) e `updateProgress` (anilist_service:458-482) marcam por `episodeIndex + 1`. Com grade contígua `1..N`, `index + 1 == número real` — **nenhuma reescrita estrutural é necessária**; só QA.
- **Dado legacy:** progresso local "fantasma" gravado sob a grade quebrada (ex.: achou "EP 1" que era EP 130) permanece em `watched`. Mantém-se a regra do plano original: **não reescrever dados ativos automaticamente**; validar explicitamente no Fire Stick (§8) e documentar, sem limpeza automática por boot.

### 2.5 O que foi removido do plano original
- A heurística `v2.length < 0.5 × anime.episodes`.
- A construção de grade "números reais" no Caso A — tudo unificado em `1..N`.
- A decisão adiada do RELEASING.

---

## 3. Bug 2 — Black Clover / séries em Blogger

### 3.1 Objetivo de escopo (mantém a decisão do plano original: **Plano B**)
- Entrega mínima: **UI honesta**, sem headless no mesmo sprint.
- Plano A (recuperar o token Blogger) fora do escopo, salvo nova autorização.

### 3.2 Marcar o Blogger de forma explícita (não heurística)
- Em `anime_fire_adapter.dart` (`_extractFromAnimeFire` :265-368 / `_extractFromBlogger` :433-595): quando a extração devolver vazio e a página de episódio referenciar o player SPA (`/_/BloggerVideoPlayer` / `BloggerVideoPlayerUi`), retornar falha tipada `BloggerUnsupportedError` (estende `EmptyResultError`).
- Quando **não** houver marcador e não houver fontes → vazio comum = episódio não existe na fonte.

### 3.3 Tri-state no repositório + UI

`resolveProvidersForEpisode` hoje devolve `Map<AnimeSource, List<VideoSource>>` (só fontes ok). Superfície mínima nova:
- `providers` — mapa de fontes com vídeos (como hoje);
- `matchedUnavailable: Set<AnimeSource>` — página casou, mas a extração falhou (Blogger ou falha);
- `notFound: Set<AnimeSource>` — página não achada (`resolveAnime` nulo).

Regras de persistência:
- Página **não achada** → nada a persistir.
- Página **achada + sources vazio** → **manter** o match persistido (NÃO chamar `removeMatch`). A página é válida; o vídeo é que não resolve. Remove o `removeMatch` da branch de vazio (P4).
- Página achada + Blogger → idem, classificado `matchedUnavailable`.

Cache:
- `AppCaches.resolutions` continua cacheando o mapa com fontes (`providers`).
- **Os estados `matchedUnavailable`/`notFound` não são cacheados** (evita 30min de erro preso; re-classificar é barato porque o match já está persistido).

UI (`_ProviderQualityDialog.build`, detail_screen:897-908):
- `providers.isEmpty && notFound` → texto atual "Nenhuma fonte disponível".
- `providers.isEmpty && matchedUnavailable` → **"Episódio indisponível nesta fonte (vídeo não suportado)"** — informa que o episódio existe mas a fonte não entrega vídeo.
- Algum provider com fontes → comportamento atual.
- Não bloquear fluxo de progresso (marcar EP como assistido permanece permitido).

---

## 4. AnimeFire `getEpisodes` — defesa (prioridade baixa)

- `anime_fire_adapter.dart:196-204` numera por posição (`entry.key + 1`). Com página ordenada (estado atual) funciona, mas é frágil por construção.
- Mudança barata: `episodeNumberFromUrl(episode.url)` (último segmento numérico, ex.: `/animes/black-clover/1`); fallback `entry.key + 1`.
- Nota: `_episodeCountFromProviders` usa `data.length` para a contagem — continua válido, pois a grade passa a ser `1..N` independentemente da numeração do provider.

---

## 5. Testes / regressão (offline, sem rede)

### Fixtures
- Copiar `/tmp/opencode/op_result.json` e `/tmp/opencode/bc_result.json` para `test/fixtures/`.
- Novo fixture pequeno "parcial_com_gaps" (v2 com faixa que não começa em 1, ex.: 62..130, com duplicatas) para cobrir o Caso de decoração.

### Testes novos/ajustados
| Teste | Detalhe |
|---|---|
| `episode_number_test.dart` | title: `Episode 130`, `EP 1`, `Ep. 12:`, `Episódio 3` (pt), `null` para `Special`/`OVA`/`Movie`/sem número; url: `/animes/x/1` → 1, `/1/` → 1, sem número → null. |
| `anilist_episodes_test.dart` | `getEpisodesV2` com token mockado + `httpOverride` servindo payload de OP → números reais (não 1..69). |
| `catalog_resolver_test.dart` (ampliar) | Com `AnimeRepository(adapters: [fakeAdapter])`: OP → grade `1..1172` com títulos só na faixa 62..130; BC → grade `1..170`; `episodes:null` + provider falha → grade `1..130` (max v2); v2 com gaps → grade contígua `1..N`; cache com/sem token → entradas distintas. |
| `resolve_provider_states_test.dart` (novo) | `MockClient` p/ AnimeFire: página achada + extração vazia → `matchedUnavailable`; página não achada → `notFound`; **match persistido NÃO é removido** no caso `matchedUnavailable`. |
| `live_sources_probe_test.dart` | com `LIVE=1`: BC EP1 → classificado `matchedUnavailable` (mensagem), OP EP1 → ≥1 source. |

### Verificação geral
- `flutter analyze`
- `flutter test` (offline, com fixtures + mocks)
- `flutter test test/live_sources_probe_test.dart --dart-define=LIVE=1` (com rede, QA opcional)

---

## 6. Validação no Fire Stick

1. **One Piece logado** (lista "Continue assistindo"): grade abre `EP 1..` em ordem crescente com contagem ~1172 (nunca 69 descendentes). Título existe apenas na faixa 62–130 (realidade do payload; EP 1 sem título é aceitável e deve ser tratado como não-requisito).
2. Tocar EP 62 → abre EP 62; tocar EP 130 → abre EP 130. Sem mismatch label × playback.
3. **Black Clover**: EP 170 abre (API nova); EP 1 mostra "Episódio indisponível nesta fonte (vídeo não suportado)" — nunca "Nenhuma fonte".
4. **Progresso**: após assistir, o progresso local/AniList continua subindo corretamente (`index+1 == número`).

---

## 7. Ordem de execução (sequencial)

| # | Tarefa | Arquivo(s) |
|---|--------|------------|
| 1 | Copiar fixtures para `test/fixtures/` | — |
| 2 | `episode_number.dart` + unit test | `lib/core/utils/episode_number.dart` |
| 3 | `getEpisodesV2` com número real | `lib/core/anilist/anilist_service.dart` |
| 4 | `getCatalogEpisodes` grade `1..N` + cadeia de fallback + cache com flag de login/versão | `lib/data/repositories/anime_repository.dart` |
| 5 | Testes `anilist_episodes_test` + `catalog_resolver_test` | test/ |
| 6 | Bug 2: marcador Blogger, tri-state, remoção do `removeMatch` indevido, UI do dialog | `anime_fire_adapter.dart`, `anime_repository.dart`, `detail_screen.dart` |
| 7 | Teste `resolve_provider_states_test` | test/ |
| 8 | `flutter analyze` + `flutter test` | — |
| 9 | `AnimeFire getEpisodes` por URL (prioridade baixa) | `anime_fire_adapter.dart` |
| 10 | Deploy Fire Stick + validação §6 | — |

---

## 8. Riscos abertos (honestos, não decididos de propósito)

- **EP 1–61 do One Piece sem título**: a fonte `streamingEpisodes` não tem esse dado. Requer decoração extra futura (ex.: scrape de títulos por episódio) — fora do escopo.
- **`_episodeCountFromProviders` depende de rede do momento**: se o primeiro provider falhar, cai para o próximo ou para `max(v2)`; a contagem pode variar entre execuções. Aceito como fallback; não é a grade primária.
- **Plano B não faz o vídeo tocar**: Black Clover 1–169 continua sem play; o plano apenas torna a UI honesta. Plano A (headless) é decisão arquitetural e precisa de novo comando.
- **Teste de "manter match persistido"** exige estado de match no teste; se o teste falhar, é mock inadequado, não mudança de acabamento.

---

*Fim do plano melhorado.*
