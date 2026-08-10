# Relatório — Home mostra "0 animes em suas listas" mesmo com usuário logado no AniList (Firestick)

**Data:** 2026-08-08
**Escopo:** Diagnóstico (sem alteração de código)
**Resultado:** Causa raiz **provada com a API real do AniList**. Bug de regressão introduzido no commit `b81de7e`.

---

## 1. Sumário executivo

O app monta uma query GraphQL **inválida** para buscar a lista do usuário no AniList. O campo
`nextAiringEpisode` foi colocado no nível errado do schema (dentro de `entries`, que é um
`MediaList`), quando o schema do AniList só aceita esse campo dentro de `media`. O AniList
rejeita a query inteira com **HTTP 400 + `errors`** em **toda** chamada, o serviço interpreta
isso como falha, retorna lista vazia e a Home renderiza `"0 animes em suas listas"`.

A query foi validada manualmente contra `https://graphql.anilist.co`:

- **Query atual do app (quebrada):** `400 Cannot query field "nextAiringEpisode" on type "MediaList".`
- **Query com `nextAiringEpisode` movido para dentro de `media` (corrigida):** `200`, retorna os
  grupos (Planning, Watching, Completed…) e as entradas normalmente.

Além disso, existe um **efeito colateral agravante**: `_graphQL()` trata qualquer `400` como erro
de autenticação e chama `logout()`, apagando o token do perfil a cada boot — sintoma secundário
de "app desloga sozinho".

---

## 2. Sintoma relatado

- Ambiente: Android TV / **Firestick**.
- Usuário **logado** no AniList pelo app (a Home mostra "Olá, `<nome>`" e o avatar).
- A Home exibe **`0 animes em suas listas`** (contador no topo).
- As seções do AniList ("Continue assistindo", "Planejados", grupos "AniList: …") ficam vazias.
- O usuário confirma que **tem animes** na lista da conta AniList (web/site).

---

## 3. Caminho de código envolvido

Fluxo da Home ao renderizar a contagem:

1. `lib/features/home/home_screen.dart:53` — `initState` pinta o cache local
   (`getCachedAnimeLists()`).
2. `lib/features/home/home_screen.dart:73-101` — `_checkAnilist()`:
   - valida login (`isLoggedIn()` → token do perfil ativo);
   - busca o usuário (`getUser()`);
   - `setState(_anilistLoggedIn = true, _anilistUser = user, _anilistLists = cached)`;
   - `await AniListService.getUserAnimeList()` (linha 98) → atualiza `_anilistLists`.
3. `lib/features/home/home_screen.dart:443` — contador:
   ```dart
   '${_anilistLists.fold(0, (sum, l) => sum + l.entries.length)} animes em suas listas',
   ```
   Se `_anilistLists` estiver vazio, mostra **0**.

4. `lib/core/anilist/anilist_service.dart:364-370` — `getUserAnimeList()` → `_fetchAnimeList(token)`.
5. `lib/core/anilist/anilist_service.dart:474-525` — `_fetchAnimeList()` monta a **query com defeito**
   e chama `_graphQL(query, token, variables: {userId})`.
6. `lib/core/anilist/anilist_service.dart:527-554` — `_graphQL()`:
   - `res.statusCode != 200` → `return null` (e para `400`/`401` ainda chama `logout()`, linhas 536-537).

Quando `_fetchAnimeList` devolve `[]`, a Home fica com a lista vazia → contador 0.

---

## 4. A query defeituosa

`lib/core/anilist/anilist_service.dart:485-505`:

```graphql
query ($userId: Int) {
  MediaListCollection(userId: $userId, type: ANIME) {
    lists {
      name
      entries {
        progress
        status
        nextAiringEpisode { episode timeUntilAiring }   # <-- ERRO (linha 492)
        media {
          id
          title { romaji english native }
          coverImage { large extraLarge }
          bannerImage
          episodes
          format
          status
        }
      }
    }
  }
}
```

No schema do AniList:
- `MediaListCollection.lists` → `MediaList`
- `MediaList.entries` → `MediaList` (a entrada da lista)
- `MediaList.nextAiringEpisode` **não existe** → o campo pertence a `Media`
  (o anime), que é filho de `MediaList.media`.

Logo, `nextAiringEpisode` tem de ficar **dentro do bloco `media { … }`**, e não no nível de `entries`.

---

## 5. Evidência — teste contra a API real

### 5.1 Query atual do app (réplica exata) → FALHA

```bash
curl -s -X POST https://graphql.anilist.co \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"query":"query ($userId: Int) { MediaListCollection(userId: $userId, type: ANIME) { lists { name entries { progress status nextAiringEpisode { episode timeUntilAiring } media { id title { romaji english native } } } } } }","variables":{"userId":2}}'
```

Resultado (HTTP **400**):

```json
{
  "errors": [
    {
      "message": "Cannot query field \"nextAiringEpisode\" on type \"MediaList\".",
      "status": 400,
      "locations": [{ "line": 1, "column": 115 }]
    }
  ],
  "data": null
}
```

O GraphQL valida a query estaticamente antes de executar. Como o campo não existe no tipo
`MediaList`, a requisição inteira é rejeitada — **não importa o token nem o usuário**. Ou seja:
100% das chamadas de `getUserAnimeList()` falham sempre.

### 5.2 Query corrigida (campo movido para dentro de `media`) → FUNCIONA

```bash
curl -s -X POST https://graphql.anilist.co \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"query":"query ($userId: Int) { MediaListCollection(userId: $userId, type: ANIME) { lists { name entries { progress status media { id title { romaji english native } coverImage { large extraLarge } bannerImage episodes format status nextAiringEpisode { episode timeUntilAiring } } } } } }","variables":{"userId":2}}'
```

Resultado: `200`, `errors: None`, com grupos reais (`Planning`, `Watching`, `Completed`, …) e
**325 entradas** para o usuário de teste. O parsing do app lê o campo do lugar correto
(`media['nextAiringEpisode']`, ver abaixo), então a correção da query é suficiente.

### 5.3 O próprio model espera o campo dentro de `media`

`lib/data/models/anilist_models.dart:79-90` (comentário `ponytail` do autor do código):

```dart
// ponytail: nextAiringEpisode pertence a MediaList.media no schema AniList,
// não ao entry. Lendo do mapa aninhado para casar com a query GraphQL.
factory AniListEntry.fromJson(Map<String, dynamic> json) {
    final media = (json['media'] as Map?)?.cast<String, dynamic>() ?? const {};
    final next = media['nextAiringEpisode'] as Map?;   // lê de media.nextAiringEpisode
    ...
```

O **model já espera** `nextAiringEpisode` dentro de `media` (local correto), mas a **query pede
no local errado** (`entries`). Incoerência interna que corrobora o diagnóstico.

---

## 6. Quando o bug foi introduzido

- `git log -S 'nextAiringEpisode' -- lib/core/anilist/anilist_service.dart`
  → commits: `3f27c06` e `b81de7e`.
- Commit **`b81de7e`** (`feat(home): seção 'Planejados' do AniList + logs diagnósticos watching`)
  adicionou `nextAiringEpisode { episode timeUntilAiring }` no nível de `entries`, quebrando a query.
- Antes desse commit, a query era:
  ```graphql
  entries {
    media { id title coverImage episodes format }
  }
  ```
  sem o campo problemático — ou seja, a listagem **funcionava** até aí.

**Classificação: regressão de código**, não problema de rede/configuração do Firestick.

---

## 7. Efeitos secundários encontrados

1. **Logout automático por 400** (`anilist_service.dart:536-537`):
   ```dart
   if (res.statusCode == 401 || res.statusCode == 400) {
     await logout();
   }
   ```
   Como a query sempre devolve 400, **toda carga da Home desloga o usuário** (apaga token do
   perfil). A UI continua mostrando "logado" na sessão atual (o estado do widget não é
   reavaliado), mas no próximo boot `isLoggedIn()` já retorna `false`. Isso explica relatos de
   "deslogou sozinho" e mascara a causa real (parece problema de sessão, é problema de query).

2. **`400` ≠ token inválido**: no GraphQL, `400` é erro de **sintaxe/validação da query** ou de
   variável, não de autenticação. Tratar `400` como `authError` e derrubar a sessão é uma
   decisão de design incorreta (`_classifyFailure` também marca `authError`, linha 91-94).

3. **Cache de listas inconsistente (menor):** `getCachedAnimeLists()` lê a chave global do
   `SharedPreferences` (`anilist_lists_cache`), enquanto `ProfileStore` mantém um cache por
   perfil em `lists_cache.json` que o fluxo AniList nunca escreve. Não causa o "0", mas é um
   ponto de confusão futura.

4. **Cobertura de teste insuficiente:** os testes usam `httpOverride` (mock de HTTP) e **nunca
   validam a query contra o schema real** — retornam 200 fabricado. Por isso a regressão do
   `b81de7e` passou sem ser detectada.

---

## 8. Plano de ação

### Passo 1 — Corrigir a query (correção raiz, diff mínimo)
**Arquivo:** `lib/core/anilist/anilist_service.dart` (bloco `_fetchAnimeList`, linhas ~485-505)

Mover `nextAiringEpisode { episode timeUntilAiring }` do nível `entries` para dentro do bloco
`media { … }`:

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
    nextAiringEpisode { episode timeUntilAiring }   # <- movido para cá
  }
}
```

**Verificação:** rodar a query corrigida com a conta real do usuário (ou com um token de teste)
e confirmar `200` + entradas. Espera-se: contador correto na Home, "Continue assistindo",
"Planejados" e grupos "AniList: …" preenchidos.

### Passo 2 — Parar de deslogar por `400`
**Arquivo:** `lib/core/anilist/anilist_service.dart` (`_graphQL`, linhas ~532-539)

- `401` → token inválido/expirado → manter `logout()`.
- `400` → erro de validação da query (bug de cliente) → **não** deslogar; retornar `null`
  e registrar o body (`errors`) no log para diagnóstico.
- Ajustar `_classifyFailure` para não marcar `400` como `authError`.

### Passo 3 — Teste de regressão que pegue esse tipo de bug
- Adicionar um teste de unidade para `_fetchAnimeList`/`getUserAnimeList` que verifique a
  **string da query** enviada (ex.: `nextAiringEpisode` deve aparecer depois de `media {`,
  não no nível de `entries`).
- Opcional: teste de contrato contra o schema real (fetch do schema AniList e `graphql`
  validation), se o app vier a depender disso com frequência.

### Passo 4 — Verificação manual no Firestick (QA)
1. Instalar build corrigido e logar na conta real.
2. Abrir Home e confirmar: contador > 0, "Continue assistindo"/"Planejados" populados.
3. Reiniciar o app (matar processo) e confirmar que **continua logado** (regressão do Passo 2).
4. Testar com conta de lista **privada** e **pública** (garantir que o token do próprio usuário
   retorna os dados nos dois casos).

### Passo 5 (opcional, higiene)
- Unificar o cache de listas: escrever também em `ProfileStore.setCurrentProfileListsCache` para
  o espelho por perfil não divergir da chave global.

---

## 9. Riscos e impacto

| Item | Impacto |
|---|---|
| Query inválida (causa raiz) | Bloqueia todas as features baseadas na lista AniList da Home/Detalhe (progresso, continue assistindo, planejados). |
| `logout()` em 400 | Perda de sessão a cada boot; usuário precisa refazer login (e, sem o Passo 2, o problema de "0 animes" reapareceria mesmo com query correta — só que agora com deslogue). |
| Sem teste de schema | Risco de nova regressão do mesmo tipo em qualquer evolução da query GraphQL. |

---

## 10. Resumo

1. **Causa raiz:** `nextAiringEpisode` fora do lugar na query `MediaListCollection` →
   HTTP 400 → lista vazia → `"0 animes em suas listas"`.
2. **Prova:** réplica exata da query → `400 Cannot query field "nextAiringEpisode" on type "MediaList"`;
   versão corrigida → `200` com 325 entradas.
3. **Regressão:** commit `b81de7e` (adicionou o campo no nível errado).
4. **Agravante:** `_graphQL` desloga o usuário em qualquer `400`.
5. **Plano:** (1) mover o campo na query, (2) não deslogar em `400`, (3) teste de regressão,
   (4) QA manual no Firestick, (5) higiene de cache.
