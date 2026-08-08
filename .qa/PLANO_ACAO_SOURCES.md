# Plano de Ação — Correção das Sources (GoAnime TV)

**Base:** `relatorio_teste_sources.md` (06/08/2026)
**Escopo:** resolver os problemas das fontes de anime do app.
**Escopo fora:** nenhuma alteração de código nesta etapa — apenas o plano.
**Premissa-chave (adendo do usuário):** o **AniList NÃO é uma fonte de streaming**. É um provedor de *metadados* (equivalente ao IMDB): títulos, nº de episódios, títulos/thumbnails/sinopse dos episódios, nota, gêneros. Ele **não fornece vídeo** e **não deve aparecer como opção de reprodução/de origem de stream**. Logo, não deve participar da busca, do ordenamento de fallback nem da seleção de fontes de vídeo.

---

## 1. Contexto e reconciliação com o código atual

O relatório descreve comportamento de **build anterior** ao `HEAD` atual (`58b8412` "refactor: cleanup and modernization pass", 05/08/2026). Ao confrontar o relatório com o código presente, vários itens descritos **já não existem** ou foram reescritos como *stub*:

| O que o relatório diz | O que o código atual (`HEAD`) realmente tem |
|---|---|
| AnimesDigital com **erro de parse** (`<br />` esperando JSON) | `animes_digital_adapter.dart` é **stub** (`implemented=false`, só retorna `EmptyResultError`); não faz mais GET/parse. |
| SuperFlix: "FFI carrega, busca retorna vazio" | `super_flix_adapter.dart` é **stub** (`implemented=false`). `SuperFlixFFI` (`lib/core/ffi/superflix_bridge.dart`) existe mas é **código morto** (nenhuma chamada real). |
| Goyabu: API `wp-json/animeonline/search` | `goyabu_adapter.dart` atual só faz **search HTML** (`/?s=...`), sem chamada àquela API. |
| Stubs "AnimesDigital/SuperFlix/etc. falham" | Restam como stubs **intencionais**; o `AnimeScraper` já exclui estes do fan-out (filtro `implemented`). |

Conclusão: **grande parte do "stub não implementado" já foi neutralizada** (excluída do fan-out de busca). O plano a seguir foca no que **ainda é real** no código atual e no que o relato aponta como prioridade, sem recriar trabalho já feito.

**Fontes realmente ativas hoje (`implemented=true`, participam da busca paralela):**
1. `AnimeFireAdapter` — funcional (html; risco 429).
2. `GoyabuAdapter` — funcional (html + `allEpisodes` + `layersData` HLS).
3. `DooPlayAdapter` (betterAnime / animesRoll) — funcional.
4. `AnimePlayerAdapter` — funcional.
5. `AniListAdapter` — **`implemented=true` mas `search()` sempre retorna falha** → único *problema real de busca* restante, e deve ser **reclassificado como metadata-only** (remoção do fluxo de stream).

**Stubs/desativados (`implemented=false`, fora do fan-out):** AnimesDigital, SuperFlix, AllAnime (captcha), Anikyuu, AnimeIto, AnimePlay, AnimeQ.

**Sem adapter/registro:** `anitube` e `dattebayo` (enum existe, não há adapter, não aparecem no registry — resíduo).

---

## 2. Decisões estratégicas (definir ANTES de codar)

Para resolver todo problema de sources é preciso decidir — um por um — entre **implementar de verdade** ou **remover/desativar documentado**. Não há "meio-termo terço NULL": stub que falha só polui o enum/registry/fallback e os logs.

### 2.1 AniList → metadata-only (decisão já feita pelo adendo)
- NÃO é fonte de stream. Não busca stream, não vira fallback de vídeo, não aparece como "fonte" na listagem de reprodução.
- Permanece como fonte de **metadados**: enriquecimento de `Anime` (`AnimeScraper` já chama `AniListService.enrich`) e merge de títulos/thumbnails de episódios (`AniListService.getEpisodesV2`).

### 2.2 Implementar vs remover (gate de decisão, por fonte)
| Fonte | Proposta (lazy) | Justificativa |
|---|---|---|
| **AnimesDigital** | **Remover** (ou, em 2ª opção, implementar se valer a pena o esforço) | Site com endpoint/redirect instável; antiga implementação era "JSON→HTML" inconsistente (`index/`). PT-BR, porém **nenhum dos 4 testes de busca achou resultado**. |
| **SuperFlix** | **Remover** do portfólio (marcar `implemented=false` definitiva + remover fluxos) | EN + anti-bot Cloudflare Turnstile; FFI Go fora do repo; exige WebView. Custo alto, retorno incerto. Deletar código morto `SuperFlixFFI`. |
| **AllAnime** | **Desativado documentado** (mantém `implemented=false`) | captcha externo, fora do alcance do app. Sem ação além de tentar. |
| **Anikyuu / AnimePlayer / AnimeQ / AnimeIto** | **Remover** do enum+registry (ou manter apenas como stub documentado) | 4 clones idênticos, sem busca, sem vídeo, com **connection leak**; baixíssimo valor. Remover elimina o leak de uma vez. |
| **Anitube / Dattebayo** | **Remover** do enum | Nunca teve adapter; sem persistência. |
| **animesRoll** | Decidir base URL correta (`anroll.plus` vs `anroll.tv`) ou remover | mesmo adapter DooPlay; `dooplay_adapter.dart:41` usa `anroll.tv`, mas `AppConstants.animesRollBase` = `anroll.plus`. Inconsistente. |

> Obs.: se a decisão for **manter** um stub desativado, deixe `implemented=false` e **documente** em `README.md` (seção "Fontes"). Isso encerra o problema "stub chamado sem propósito" quando nada garante o servidor.

### 2.3 Resumo do alvo funcional desejado
- **Fontes de vídeo funcional (manter/estabilizar):** `AnimeFire`, `Goyabu`, `DooPlay`/`BetterAnime`, `AnimePlayer`.
- **Metadados:** `AniList` (fora do circuito de vídeo).
- **Descartados/desativados:** todos os demais, de forma limpa (sem enum morto, sem fallback, sem logs de erro diários).

---

## 3. Plano de tarefas por prioridade

### FASE A — AniList como metadata-only (prioridade ALTA, pré-requisito p/ tudo)

**Objetivo:** AniList deixa de ser tratado como fonte de stream.

1. **`lib/core/scraper/anime_scraper.dart`** — faixas:
   - `searchAnime()` (linha ~28): o fan-out `SourceRegistry.adapters.where((a) => a.implemented)` hoje inclui `AniListAdapter` (`implemented=true`) e ele dispara `search` que sempre falha + rede desnecessária. **Remover** AniList do fan-out (`anime_scraper.dart:28-42`). AniList entra como dado apenas via `AniListService.enrich` (linha 78), que já roda por título.
   - `getEpisodes()` (linha ~142-146): hoje registra `'AniList'` como bloco de episódios (linha 144-145) e depois funde com AnimeFire (função `mergeEpisodes`, 201-268, linhas 251-268). **Novo fluxo:** ao invés de listar `AniList` como `sourceOption`/fonte selecionável, quando houver `anime.anilistId != null` buscar `AniListService.getEpisodesV2` e **mergear sempre** as EP ids/títulos/thumbnails de AniList **sobre os episódios da fonte de vídeo principal (AnimeFire/Goyamu/BetterAnime/etc.)**, mantendo como `owner.source` a fonte de vídeo. Não deixar episódio com `source=AniList`.
2. **`lib/core/sources/anilist_adapter.dart`**:
   - Tirar de `SourceRegistry.adapters` (ou, se manter o adapter, `implemented => false`) para não participar da busca/fallback de vídeo. Carregar em `SourceRegistry` (lista + `forSource` + `fallbackOrder` + `getPriority`).
3. **UI — `lib/features/detail/detail_screen.dart`**:
   - Remover os ramos de erro/descrição específicos "AniList não fornece stream" (linhas ~780-792, 793-807, 819-827, e a branch `_effectiveSourceName` p/ `anilist` em 837-838) — com a mudança (Fase A.1) **nenhum episódio terá `source=AniList`**, então o caso não ocorre.
   - Atualizar a mensagem do estado vazio (linha ~499) — retirar "AniList" da lista de fontes de stream.
4. **`lib/data/models/anime.dart`**:
   - Reclassificar `AnimeSource.anilist`: não é `isPtBr`? (é metadado). Ajustar se `priority`/`isPtBr` forem usados para ranquear fontes de vídeo (linhas 100-154). AniList não deve entrar na ordenação de fontes de reprodução.
5. (Opcional/limpeza) **`lib/core/ffi/superflix_bridge.dart`** — só se SuperFlix for removido (Fase C); remove código morto.

### FASE B — Remoção/limpeza dos stubs e enums órfãos (prioridade ALTA)

**Objetivo:** encerrar "7 sources com stubs" com decisão única por fonte (seção 2.2), reduzindo superfície e eliminando connection leaks.

1. **`lib/data/models/anime.dart` (enum `AnimeSource`)**: remover do enum (e da ordenação `isPtBr`/`sourceName`/`priority`) as fontes decididas como removidas: `anikyuu`, `anitube`, `dattebayo`, `animeIto`, `animePlay`, `animeQ`, `superFlix`, `animesDigital` e (se fora) `animesRoll`/`allAnime`. Rodocar a enum mínimo: `animeFire, goyabu, dooPlay, betterAnime, animesRoll, animePlayer, anilist` (+ conforme decisão).
2. **`lib/core/sources/source_registry.dart`**: remover os adapters correspondentes da lista `_adapters`, do `forSource`, do `fallbackOrder` e do `getPriority`. Recriar solo com os ativos.
3. **Remover arquivos de adapter stubs** (ou manter zerados *somente* se houver decisão de manter desativado + documentar): `animes_digital_adapter.dart`, `super_flix_adapter.dart`, `all_anime_adapter.dart`, `anikyuu_adapter.dart`, `animeito_adapter.dart`, `animeplay_adapter.dart`, `animeq_adapter.dart`.
4. **`lib/core/sources/anime_source_adapter_factory.dart`**: alinhar ao novo registry (remover casos de fontes removidas).
5. **Código e telas SuperFlix** (se remover SuperFlix): `lib/features/superflix/superflix_web_screen.dart` e a chamada em `detail_screen.dart:773` (`SuperFlixWebScreen.resolve`) + `lib/core/ffi/superflix_bridge.dart` e a pack, descontinuando `AnimeSource.superFlix`. (Deixar WebView de outras telas — como o login AniList — intocados.)
6. **`AppConstants`** (`lib/core/constants/app_constants.dart`): remover constantes de fontes removidas (`allAnime*`, `superFlix*`, `animesRollBase`, `anikyuuBase`, `anitubeBase`, `dattebayoBase`, `animesDigitalBase`, `animesDigitalReferer`).

> **Observação:** remover itens do enum requer `switch` exaustivos (`sourceName`, `sourcesPriority`) e os `switch`/case de `_effectiveSourceName` na `detail_screen`. Rodar `flutter analyze` ao final para cobrir a compilação.

### FASE C — Estabilizar fontes funcionais (prioridade MÉDIA)

1. **Rate limiting no AnimeFire (HTTP 429)** — `relatorio`, seção 2.
   - O `ApiClient._retryWithBackoff` (`api_client.dart:15-59`) só retenta em **exceção/timeout**, não em `429` (que retorna como resposta). Adicionar **retry com backoff específico em `429`** no `ApiClient.get` (loop no `statusCode`), com `wait` curto crescente (ex.: 800ms→1600→3200, máx. 3 tentativas) e jitter.
   - **Serializar (throttle) as chamadas ao AnimeFire:** o fan-out/volume de requests simultâneos (busca + `_findBySource` + resolver vídeo de múltiplos eps) é a causa. Adicionar **fila/concurrency** (gating simples, ex.: `AsyncMutex` ou `concurrency=1`) entre os `_httpGet` do `AnimeFireAdapter`, ou um `Delayer` mínimo (100–250ms) entre requests a `animefire.io`. `ponytail: package: async` não é citado; se não houver dep, implementar uma `Queue`/semáforo de micro-linhas (`lib/core/network/`).
   - Aproveitar o **cache** já existente (`ApiClient` cacheia por URL+headers) — os 6 erros do teste vieram ± da sobrecarga; a cache resolve repetir requests, não a 1ª rajada.
2. **Goyabu — busca suja / parsing** (`relatorio/seç. Goyabu`):
   - Caso termo de busca incluir avaliação/fix (ex.: "Naruto 7.93 A14") → o query `/?s=...` retorna 0. **Limpar o termo uma única vez antes do fan-out** em `AnimeScraper.searchAnime` e `_findBySource` via `TextUtils.cleanTitle` (e/ou `normalize`), de modo a não enviar nota/badge em query. Criar um helper central `cleanSearchQuery` e aplicar em todos os `search`.
   - **"No episodes parsed" para alguns animes:** o `gotEpisodes` do `GoyabuAdapter` espera literal `allEpisodes = [...]` (regex em `goyabu_adapter.dart:122`). Para páginas com marcação diferente retorna vazio. Adicionar **fallback de parser** (procurar links `a`/`.episodios` por seletores) + manter só success quando realmente houver lista; e um teste mocked com HTML de página real.
3. **Começo conservador já existente é suficiente** — não re-implementar busca lançando tanque para mil coisas.

### FASE D — Higiene de rede (prioridade MÉDIA)

1. **Connection leaks** — `anikyuu/animeito/animeplay/animeq` criam `http.Client()` por chamada sem `.close()` (relatório seç.3/código). Como a Fase B **remove** esses 4 adapters, o leak é eliminado na origem. Se por acaso mantivermos algum, reescrever para usar o `apiClient` singleton (reuso da infra já existente).
2. **`AnimeFire._extractFromBlogger`** (`anime_fire_adapter.dart:426,443,467`): usa `HttpClient()` próprio; garanta `.close()` em `finally` (hoje fecha nas ramas de sucesso mas não em erro/timeout). Pequeno diff: `try/{...}/finally{ client.close(force:true) }`.

### FASE D — Malha de fallback / prioridades — ajuste fino

1. **`source_registry.dart` `fallbackOrder`/`getPriority` e `AnimeSourcePriority.priority`** (`anime.dart:98-154`): depois da remoção (Fase B), garantir que a ordem de fallback reflita só fontes ativas e com fonte=correta (ex.: AnimeFire → Goyabu → DooPlay/BetterAnime → AnimePlayer). nA AniList não pode estar nessa ordem.
2. **`aluno_repository.dart` (`lib/data/repositories/anime_repository.dart`)**: a seção `getVideoSources` tresta como `fallback` só exploraticamente `superFlix`/`allAnime`/`animeFire` (linhas 62-68). Após remover SuperFlix/AllAnime, limpar esses ponteiros e centralizar/usar `SourceRegistry.adapters` (só os ativos). `_superFlixContext`/`_contextForSource` para `allAnime` podem ser removidos.

### F DE UI / textos (prioridade BAIXA)

1. `detail_screen.dart:499` — mensagem de episódios vazios mencionam "AniList… SuperFlix, AllAnime". Atualizar para a lista real de fontes ativas (decisão Fase 2).
2. `detail_screen.dart:994` — mensagem de "nenhuma resolução" mencionar "AnimeFire, Goyabu, SuperFlix e AllAnime". Trocar p/ "AnimeFire, Goyabu, BetterAnime e AnimePlayer".
3. `README.md` seção "Fontes" — refletir o estado pós-trabalho (remover "pendente" de GoyServer/superFlix etc.).

### FASE TESTS / verificação

1. Revisar/extender **`test/ptbr_adapters_test.dart`** (mocked) para:
   - Goyabu fallback de episódios divergente.
   - Garantir que **nenhum episódio gerado tem `source=AniList`** quando a Fase A estiver implementada.
   - `cleanSearchQuery` não deixar avaliação no termo (regressão do caso "Naruto 7.93 A14").
2. Adicionar (gate/flake pronto) um **retry-429** mockado: simular 2 respostas 429→200 no `ApiClient`.
3. Rodar o harness **`test/live_sources_probe_test.dart`** (requer `--dart-define=LIVE=1`, rede) para as 4 fontes ativas × 4 animes, após as mudanças.
4. Rodar `flutter analyze` e `flutter test` para cobrir refactors (enum, registry, UI).
5. **Regarar** `relatorio_teste_sources.md`/QA run para validar que na busca/`getEpisodes`/`getVideoSources`:
   - As fontes voltadas retornam OK,
   - O AniList não aparece como fonte/reprodução,
   - Não há mais erros de "stub" nem 429 contínuos (retry resolve).

---

## 4. Sequência recomendada (ordem de execução / dependências)

1. **Fase A** (AniList → metadata) — desbloque cheiro do problema conceptual; o restante só faz sentido com esta definição.
2. **Fase B** (remover stubs/órfãos) — destrava a limpeza do registry/enum e elimina os `http.Client()` leaks de uma vez.
3. **Fase C** (429 + query limpa + Goyabu) — estabiliza as fontes que ficam.
4. **Fase D** (rede real e fallback) e **Fase E** (UI/textos) — paralelizáveis pós- B/C.
5. **Fase Verificação** — re-análise, testes e novo relatório.

> As Fases B–D trabalham na lista de fontes "final". Faça a **Fase A** e a **decisão da seção 2.2** (implementar vs remover) o quanto antes, pois determinam o escopo de tudo.