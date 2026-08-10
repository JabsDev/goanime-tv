# Relatório v2 — Crítica ao `RELATORIO_ANILIST_0_ANIMES.md` e plano de implementação revisado

**Data:** 2026-08-08
**Base:** `.qa/RELATORIO_ANILIST_0_ANIMES.md` (v1)
**Escopo:** Crítica ao diagnóstico/plano anterior + novo plano de implementação. **Sem alteração de código nesta etapa.**

---

## 1. Veredito sobre o relatório v1

O diagnóstico central do v1 está **correto e foi re-confirmado por mim contra a API real**:

- A query atual do app devolve **HTTP 400** `Cannot query field "nextAiringEpisode" on type "MediaList".` (reproduzida nesta revisão).
- A query com `nextAiringEpisode` movido para dentro de `media { … }` devolve **HTTP 200** com os 6 grupos (`Planning`, `Watching`, `Completed`, …) — `nextAiringEpisode` presente em `media` (verificado).
- A regressão veio do commit `b81de7e` (antes a query era válida, sem o campo errado).
- O efeito colateral de `logout()` em `400` em `_graphQL` é real e agrava o sintoma.

O que o v1 **acerta** — causa raiz, prova, commit culpado e o efeito colateral de logout — está confirmado. O que o v1 **erra ou deixa de fora** está listado abaixo (seção 2) e vira o foco do plano v2 (seção 4).

---

## 2. Erros e falhas do relatório v1

### E1 — Erro de taxonomia do schema (§4 do v1)

O v1 afirma:

> `MediaListCollection.lists` → `MediaList` / `MediaList.entries` → `MediaList (a entrada da lista)`

Via introspection na API real, a taxonomia é:

| Caminho | Tipo real |
|---|---|
| `MediaListCollection.lists` | `MediaListGroup` |
| `MediaListGroup.entries` | `MediaList` |
| `MediaList.media` | `Media` |
| `Media.nextAiringEpisode` | `AiringEpisode` |

O v1 rotula o `MediaListGroup` como `MediaList`, o que induz ao erro inverso (procurar `nextAiringEpisode` em `MediaList`, o tipo da **entrada**). A conclusão final (`nextAiringEpisode` deve ficar em `media`) continua certa — mas a nomenclatura que sustenta o raciocínio é errada e **não a nos transmitir correção futura** (qualquer query nova sobre listas vai erary a partir da taxonomia do relatório).

### E2 — Falha de plano: refresh que falha "apaga" o cache bom → outro caminho para o sintoma "0 animes"

Em `lib/features/home/home_screen.dart:92-100`, a Home pinta o cache e **depois sobrescreve com o resultado da rede, mesmo que vazio**:

```dart
final cached = await AniListService.getCachedAnimeLists();
setState(() {
  _anilistLists = cached;            // pinta o bom
});
final lists = await AniListService.getUserAnimeList();  // pode vir [] (erro/offline)
setState(() => _anilistLists = lists);                   // SOBRESCREVE com vazio
```

O v1 não trata esse caminho: com a query **já corrigida**, basta uma falha de rede, `429` ou o `403`/Cloudflare já vistos no app para o usuário voltar a ver **"0 animes em suas listas"** por cima de um cache local bom. O v1 corrige a query, mas deixa a Home com um modo de falha idêntico ao sintoma original. Plano v2 trata.

### E3 — Teste de regressão proposto é frágil e incompleto

O Passo 3 do v1 propõe "verificar a string da query (o `nextAiringEpisode` deve aparecer depois de `media {`, não no nível de `entries`)". Problemas:

1. **Indexação bruta sobre string** é quebradiça: qualquer reformatação/renomeação dos blocos muda posições sem mudar o sentido — ou pior, deixa de detectar uma regressão que inverta a ordem em outra aninhamento.
2. **Não valida o pipeline completo**: só a forma da query. Não testa que `getUserAnimeList()` parseia uma resposta real AniList em `AniListGroup`s com `progress`, `status` e `nextAiringEpisode` corretamente extraídos de `media`.
3. **Não protege o segundo sintoma** (logout/400): nenhum teste cobre `_graphQL` 400 vs 401 vs 429 (classificação `lastErrorStatus` + `logout()`).
4. **Trata o teste de contrato com o schema real como "opcional"**, quando o bug inteiro é exatamente um query-vs-schema — deve ser peça central e rodável (via script) no QA, além do teste estrutural na CI.

### E4 — Passo 2 do v1 incompleto na camada de UI

O v1 manda "ajustar `_classifyFailure` para não marcar 400 como `authError`", mas não mapeia o efeito no banner. Com a remoção do logout apenas, um `400` ainda classificaria `AniListStatus.authError` (linha 91-94 de `_classifyFailure`) e o `AniListStatusBanner` exibiria "Sessão expirada, faça login" — **mentira para o usuário** (é bug de cliente). A remoção tem de ser da raiz: remapear `400` para um status não-autoriz.

### E5 — Aceite vago + sem ordem de rollback

"A confirmar contador correto" não define o número mínimo nem o comportamento of-line. Não define uma ordem de mitigação com rollback 1-commit. O v2 fixa critérios numéricos e sequência.

### E6 — Passo 5 (higiene de cache) não decide a fonte única

O v1 identifica a divergência `getCachedAnimeLists` (global) vs `ProfileStore.lists_cache.json` (por perfil), mas propõe apenas "escrever também". O problema real é **duplo-cache com fonte não definida**. O plano v2 define que a fonte é o perfil (o resto do app já migrou o token/usuário para perfil em `68f1777`) e o global vira leitura curta — mesmo padrão do `AnilistAuthService`.

### 4 — Risco do V1 impreciso na tabela de riscos

"Sem o Passo 2, o problema de '0 animes' vira deslogue" — correto apenas se `400` voltar a ocorrer; com a query certa e sem outro bug o `400` não acontece. Imprecisão menor, mas contamina o leitor sobre se o Passo 2 é bloqueante. O Passo 2 é bloqueante por **robustez** (não deslogar por erro de cliente é princípio), não por este rebote específico.

---

## 3. O que o v1 acertou (manter no v2)

1. **Causa raiz provada** com a API real (400 ↔ 200) — replicada nesta revisão.
2. **Regressão** apontada corretamente para o commit `b81de7e`.
3. **Model parceiro** `AniListEntry.fromJson` já lê o campo de `media.next` (o model estava certo, a query errada).
4. **Efeito colateral de logout por 400** identificado e sua explicação ("app desloga sozinho").
5. A ordem "corrigir query → não deslogar → teste → QA" é a correta como sequência, mas execução tem os erros acima.

---

## 4. PLANO DE IMPLEMENTAÇÃO v2 (melhorado)

### Fase 0 — Baseline de verificação (antes de mexer)

```bash
flutter pub get
dart analyze
flutter test
```

Registrar o resultado atual (`flutter test`) como referência. Espera-se que passe — os testes atuais **não** cobrem o fluxo de lista (ver E3) e, por isso, a regressão `b81de70` passou.

### Fase 1 — Correção da query (causa raiz)

**Arquivo:** `lib/core/anilist/anilist_service.dart` (`_fetchAnimeList`).

- Mover `nextAiringEpisode { episode timeUntilAiring }` de dentro de `entries` para dentro do bloco `media { … }`.

```graphql
entries {
  progress
  status
  media {
    id
    title { romaji english native }
    coverImage { large extraLarge }
    bannerImage
    episodes
    format
    status
    nextAiringEpisode { episode timeUntilAiring }   # movido de entries para media
  }
}
```

- **Extract a query como constante testável** e expor para teste (sem quebrar o `const`):
  ```dart
  @visibleForTesting
  static const listQuery = '''…query corrigida…''';
  ```
  O teste de regressão e o script de contrato (Fase 5) apontam para **essa** string — um único lugar muda a query, e duas camadas de verificação pegam se ela divergir do schema/integridade.

**Verificação:** executar a query corrigida com um `userId` real (via curl, Fase 5) e confirmar 200 + grupos.

### Fase 2 — `400` não desloga; remap de status

**Arquivo:** `lib/core/anilist/anilist_service.dart` — `_graphQL` (linhas 527-540) e `_classifyFailure` (linhas 82-104).

1. Em `_graphQL`: `logout()` **somente** em `401`. Em `400`, registrar `res.body` no log e retornar `null` sem deslogar.
2. Em `_classifyFailure`: `400` deixa de mapear para `authError`; mapeia para `serverError` (mensagem "erro de cliente/validação" no banner, sem estado de "sessão expirada"). `401` continua `authError`.
3. **Regra do th error:** manter tr//error do v1: `429` → `rateLimited`, `403/1020` → `ipBlocked`, `>=500` → `serverError`, timeout/socket → `offline`.

**Justificativa:** o fix de 400 poderia teoricamente não ser chamado por queries válidas, mas princípio antibomba: nunca derruba sessão por erro de validação/variação (bug de cliente é nosso).

### Fase 3 — Home: não apagar cache bom por falha de rede

**Arquivo:** `lib/features/home/home_screen.dart` (`_checkAnimeList`).

- Guard: se `getUserAnimeList()` retornar vazio **e** `AniListService.lastErrorStatus != AniListStatus.ok`, **manter** o cache já pintado (não sobrescrever com `[]`).
- Só sobrescrever com `[]` quando a resposta foi de fato **sucesso com zero entries** (`lastErrorStatus == ok`) — nesse caso limpa o cache pq o usuário zerou.
- Isso mata o E2: "0 animes" por rede (`429`/`offline`/Cloudflare) deixa de aparecer sobre cache bom.

Observação: `getUserAnimeList()` hoje não distingue vazio-sucesso de vazio-falha; a distinção é obtida pela leitura de `lastErrorStatus` (efeito colateral já existente no serviço). Não introduzir enum novo agora.

### Fase 4 — Testes de regressão (fecha E3)

**Novo arquivo:** `test/anilist_list_test.dart`.

Usar o mesmo setup de perfil da `test/anilist_persistence_test.dart` (perfil AniList criado + `httpOverride` + `SharedPreferences.setMockInitialValues`). Fonte de rede via `httpOverride`.

| # | Teste | O que falhou antes |
|---|---|---|
| T1 | **Shape da query** — `AniListService.listQuery` contém `nextAiringEpisode` e a posição dele é **posterior a** `media {` (e nenhum outro `entries {` o precede sem `media` antes) | Query regredida para o nível errado |
| T2 | **Parse fim-a-fim** — mock 200 com resposta realista (grupos com `media.nextAiringEpisode` no lugar) → `getUserAnimeList()` devolve `AniListGroup`s com entries e `nextEpisode`/`timeUntilarring` extraídos de `media` | Quebra na camada de serviço/modelo |
| T3 | **400 não desloga** — mock 400 → `getUserAnimeList()` retorna `[]`, `lastErrorStatus != authError`, token do perfil continua presente (`getToken() == token`) | Regressão do Passo 2 |
| T4 | **401 desloga** — mock 401 → `logout()` chamado (`getToken() == null`) | Regressão do Passo 2 |
| T5 | **429** — mock 429 → `[]`, `lastErrorStatus == rateLimited`, **não limpa** token | Classificação corriável |

O T2 deve usar **resposta capturada da API real** (ex.: o payload de `/tmp/corrected.json` que rodei nesta revisão) — não um JSON inventado, para o parse casar com o formato verdadeiro.

### Fase 5 — Verificação de contrato com o schema real (robustez de nova regressão)

**Novo script:** `.qa/validate_anilist_queries.sh` (README no topo).

- POST em `https://graphql.anilist.co` com as **strings literais** das queries do serviço (incluindo `AniListService.listQuery`, query de `enrich`, `getEpisodesV2`, catalog) — via o mesmo extractor que o T1 usa (a const), copiada para o script ou gerada.
- Assert: `HTTP 200` + `errors == null`.
- Rodar **como parte do QA manual** (Fase 6), pois não pode entrar no `flutter test` offline (testes Flutter bloqueiam rede).

Isto fecha a alavanca do v1 que chamou de "opcional": a razão do bug foi *exatamente* query vs schema; aí o guard t vira peça obrigatório do processo.

### Fase 6 — QA manual (Firestick) com critérios numéricos

1. Instalar build corrigido, logar com a conta real.
2. **Home:** contador `> 0` (o número deve bater com a lista real ≈ 325 p/ usuário de teste; para a conta do usuário, o número do AniList Web).
3. Seções "Continue assistindo" e "Planejados" populadas.
4. **Reinício do processo:** continuar logado (regressão do logout em 400 não ocorrer).
5. **Off-line:** desligar rede; reabrir → a Home deve **manter** o cache (contador ≠ 0); religar rede e fazer refresh → volta a atualizar.
6. Rodar `.qa/validate_anilist_queries.sh` — todos 200.

### Fase 7 — Higiene de cache (opcional, ordenada depois)

- Definir **fonte = perfil** (`ProfileStore`); `AnilistAuthService` mantém só o espelho de leitura curta (mesmo padrão já adotado para token, `lib/core/anilist/anilist_auth_service.dart:5-10`).
- `_persistListsCache` escreve no perfil e, em segundo plano, espelha no global. `getCachedAnimeLists` lê o perfil primeiro; o global fica apenas fallback de compatibilidade.
- Não fazer antes de Fases 1-6; é só divide, não é causa.

---

## 5. Sequência de mitigação e rollback

Ordem fixa → **cada fase é um commit independente** para reversão fácil:

1. Fase 1 (query) → commit `fix(anilist): move nextAiringEpisode to media in list query`.
2. Fase 2 (auth mapping) → commit `fix(anilist): no logout on 400, reclassify to serverError`.
3. Fase 3 (Home cache) → `fix(home): keep cache on failed AniList refresh`.
4. Fases 4-5 (testes+script) → `test(anilist): list query + auth mapping regression`.
5. Fase 6 (QA) e Fase 7 (higiene) só depois.

Rollback: Fase 1 é auto (a query volta à forma anterior); as Fases 2-3 são retrocompatíveis.

---

## 6. Critérios de aceite (definition of done)

1. `dart analyze` sem erros novos.
2. `flutter test` verde, incluindo os T1-T5 novos de `test/anilist_list_test.dart`.
3. A query exportada via `AniListService.listQuery` passa no `validate_anilist_queries.sh` (200, sem `errors`).
4. Contador > 0 na Home com a conta real e cache preservado em modo offline (Passo 6.5).
5. `logout()` só ocorre com `401` documentado (nenhum outro path desloga).

---

## 7. Riscos residuais

| Item | Risco | Mitigação |
|---|---|---|
| Teste T1 (shape) frágil por formatação | Regressão tipo banner | A const `listQuery` é fixa; reindexar formatação muda a const e re-detecta. Contrato real cobre o que T1 não vê. |
| `lastErrorStatus` global como sinal de falha | Race quando duas requests paralelas | Estado é monotônico por chamada única (listas), aceitável; anotado em código. |
| Offline + cache bom | Contador fica 0 se perfil zerado de verdade? Não: caso 200-vazio limpa, mas com `lastErrorStatus==ok`. | Testado por T5/T3-Fase3. |

---

## 8. Resumo

O v1 acertou **o quê** (query errada, logout inadvertido, commit culpado) e errou/omitiu **como** garantir e não regredir. O v2:

1. Corrige terminologia (E0) e adiciona o caminho de falha de rede → `0` (E4).
2. Converte teste frágil de string em **bateria T1-T5** com parser fim-a-fim e separação 400/401/429.
3. Acerta o logout com remapeamento de `400` stopauth para `serverError`+banner honesto (E3/E1).
4. Define **fonte única de cache** e um guard de contrato (script real da API) que roda no QA — fechando a porta que deu origem ao bug.
5. Estrutura em commits 1:1 com critérios de aceite numéricos.