# 02 — Review Arquitetural da Fase 2

**Data:** 06/08/2026
**Papel:** Arquiteto de Software Sênior independente
**Escopo:** revisão crítica da proposta `01_Plano_Refatoracao.md`, confrontada com o
código atual. **Nenhum código foi alterado.**

---

## 1. Resumo do plano analisado

O plano propõe **desacoplar a lista de episódios dos providers**. Hoje o
`AnimeScraper.getEpisodes` monta a lista escavando os providers (AnimeFire, Goyabu) e
fazendo merge de metadados do AniList; a grade de episódios muda conforme o provider
escolhido (`EpisodesResult.sourceOptions` + `_SourceSelector`). O plano propõe que:

1. O **catálogo** (AniList) seja a única fonte da lista canônica `1..N` (metadados +
   `episodesV2` opcional), sem conhecer providers.
2. Os **providers** passem a responder apenas "você tem o ep N?" → resoluções de vídeo,
   via novo verbo `resolveEpisode(anime, episodeNumber)` na interface `AnimeSourceAdapter`.
3. A **resolução** aconteça sob demanda no tap, consultando os providers em paralelo
   (fan-out isolado por erro, timeout, cache por `(animeId, ep)`).
4. A **UI** troque o `_SourceSelector` por um fluxo `Episódio → Provider → Qualidade` em um
   único dialog de dois níveis.
5. Migração não-destrutiva em etapas, cada uma terminando com `flutter analyze` +
   `flutter test` verdes.

**Veredito geral:** a direção está **correta e necessária**. O acoplamento entre "quem
define a grade" e "quem serve vídeo" é real, e o desacoplamento é a melhoria certa. Esta
revisão **não invalida o plano**; ela refina pontos-chave (dois são mudanças recomendadas)
e derruba uma decisão que seria um erro (a modelagem `ProviderEpisode`).

---

## 2. Decisões arquiteturais revisadas

### D1 — Contrato dos providers: `resolveEpisode` pertence ao adapter (endossado), com refinamento da entrada

**O plano** propõe `AnimeSourceAdapter.resolveEpisode(Anime animeRef, int episodeNumber)`.

**Alternativa avaliada (enunciada na revisão):** os providers permanecem com
`search`/`getEpisodes`/`getVideoSources` e toda a orquestração move para um
`EpisodeResolverService` externo.

**Análise por dimensão:**

| Dimensão | `resolveEpisode` no adapter (plano) | Serviço externo só com `getEpisodes`/`getVideoSources` |
|---|---|---|
| Acoplamento | Baixo: o provider encapsula "numeração → url → vídeo" | **Alto**: o serviço precisa entender a paginação/numeração de cada provider para chegar ao ep N |
| SRP | O adapter é dono do mapeamento (dado privado da fonte) | O serviço orquestra e, indiretamente, entende o modelo interno de cada fonte (vazamento) |
| Novos providers | Adicionar = implementar "resolve N" | Adicionar = expor `getEpisodes`/paginação/numeração coerentes para o serviço funcionar |
| Reutilização | Sem exposição de grade; consumo enxuto | Para resolver o ep N via `getEpisodes`, o serviço baixa a **lista inteira** a cada tap |
| Testabilidade | Mock de 1 método | Mock de lista + seleção + vídeo (mais superfície) |
| Desempenho | 1 página de anime (cacheada) + 1 de vídeo por provider | Página de lista inteira + página de vídeo — mais rede |
| Simplicidade | 1 verbo novo | 2–3 verbos + serviço coordenando índices internos |

**Decisão:** manter o contrato no **adapter**, conforme o plano. A alternativa "serviço
externo que só lê listas" é **inferior**: ela apenas empurra o mesmo problema para um
orquestrador, que passa a ter que entender a numeração/paginação interna de cada fonte —
o cúmulo do acoplamento. Quem sabe como o número N vira a página de cada provider é o
próprio provider.

**Refinamento recomendado (mudança na assinatura).** Não passe o catálogo cru (`Anime`)
que o provider precisará re-buscar a cada chamada. Divida em duas responsabilidades que
vivem **dentro do adapter**, para que a parte cara (localizar a página do anime) seja
resolvida **uma única vez e cacheada/persistida** (ver §2.4):

```
abstract class AnimeSourceAdapter {
  AnimeSource get source;
  bool get implemented => true;

  /// Localiza a página própria do provider para [catalogRef] (uma busca/rede por obra),
  /// cacheável e persistível. Representa o "match" no acervo do provider.
  Future<ScraperResult<ProviderMatch?>> resolveAnime(AnimeRef catalogRef);

  /// A partir de um [match] já resolvido, resolve os streams (qualidades) do ep N.
  Future<ScraperResult<List<VideoSource>>> resolveVideo(ProviderMatch match, int episodeNumber);
}
```

`AnimeRef` é a fatia do catálogo (name/englishName/anilistId), sem url/source de vídeo.
`ProviderMatch` é o identificador interno do provider (url da página, `animeId`, etc.).
O orquestrador (repositório/serviço) chama `resolveAnime` **uma vez por obra** e
cacheia/persiste o `match`; `resolveVideo` fica barato e repetível.

> Resposta à revisão: a alternativa "orquestração em um serviço externo de providers
> locators" **não é superior** — ela reintroduz o vazamento de numeração/modelo interno
> dos providers no orquestrador e custa uma grade inteira por tap. A parte que *faz
> sentido* centralizar (fan-out, timeout, isolamento de erro, cache, ordem de exibição)
> fica no repositório/orquestrador — que é exatamente o que o `AnimeRepository` já faz
> hoje com `getVideoSources` + fallback.

### D2 — Modelagem de episódios: separar catálogo × provider (mudança necessária)

**O plano** reutiliza o modelo `Episode` atual e mantém `sourceOptions` durante a transição.

**Problema real no código:** `Episode` (em `episode.dart`) tem `url` **obrigatório
não-nulo** e campos `source`/`owner`. Um episódio **canônico** de catálogo **não tem url
nem fonte** — não há representação sem um sentinela `url: ''` propagado por todo o fluxo.
Reutilizar `Episode` para a grade canônica é a fonte desse conflito.

**Análise das alternativas:**

| Modelo | Vantagens | Desvantagens |
|---|---|---|
| Reusar `Episode` (catálogo + provider) | Zero mudança de modelo | `url` obrigatório vira sentinela vazia; `source`/`owner` vazam no catálogo |
| `CatalogEpisode` + reutilizar `VideoSource` | Catálogo puro (number/title/thumb); provider só produz `VideoSource`; sem sentinela | Novo modelo (pequeno) |
| `CatalogEpisode` + `ProviderEpisode` | Mais "tipado" | **Over-engineering**: o provider não precisa de um modelo de episódio — ele resolve o vídeo direto, retornando `VideoSource` |

**Decisão.** Ter **dois modelos, não três**:

- `CatalogEpisode` (catálogo): `number`, `title`, `thumbnail`, `description` — sem `url`,
  sem `source`, sem `owner`. É a representação da grade e do watch-progress.
- Reutilizar `VideoSource` **já existente** como saída da resolução (provider → qualidade →
  url/headers). **Nenhum `ProviderEpisode`**: ele duplicaria o que `VideoSource` já
  representa.

O antigo `Episode` (com url/owner) fica restrito ao interior dos adapters durante a
migração e é removido na limpeza (Etapa 5). Bônus: `AniListEpisode`
(`lib/data/models/anilist_models.dart:212`) já tem os campos do catálogo — a conversão
para `CatalogEpisode` reutiliza o parsing de `getEpisodesV2`.

> Resposta à revisão: reutilizar `Episode` **não é** a melhor opção — esbarra no `url`
> não-nulo e vaza provider no catálogo. Modelos distintos (catálogo + `VideoSource`) são
> superiores em SRP e eliminam a sentinela. `ProviderEpisode` não deve existir.

### D3 — Estratégia de resolução: sob demanda + cache, sem preload obrigatório

**Decisão:** manter o **fan-out sob demanda** (todos os providers em paralelo, isolado por
erro, timeout curto, ordem por prioridade), como o plano, com os seguintes cache obrigatórios:

- **Cache/persistência do `ProviderMatch`** (a página do anime por provider) — é o cache
  que *realmente* derruba o custo: muda o custo do tap de `busca + listagem + vídeo` para
  apenas `vídeo` a partir do segundo tap (§2.4).
- Cache de **disponibilidade** por `(animeId, ep)` (quais providers têm o ep) e de
  **resoluções** por `(provider, animeId, ep)`, com TTL curto (10–30 min, urls expiram).
- Manter o **serial-throttle do AnimeFire** (já implementado em `anime_fire_adapter.dart`)
  e o tratamento de 429, como o plano já determina.

**Por que "consultar todos no tap" é aceitável e por que não adotar preload agora:** com o
`match` cacheado, um tap resolve ~1 página de vídeo por provider (AnimeFire, por exemplo,
lista todos os eps numa página só; a resolução usa a página de vídeo). Compare com o
**hoje**: abrir o detalhe já dispara `_findBySource` + `getEpisodes` de 2+ providers. Ou
seja, a mudança **redistribui** a rede (move de "abrir" para "tap") e o cache a amortiza.
O **pré-carregamento inteligente** (resolver em idle os episódios próximos ao atual) é uma
otimização **pós-v1** — adicionar somente se o QA em Fire TV mostrar latência
inaceitável (plano §13.8). Não deve virar requisito da Etapa 3.

**Resolução incremental** ("resolver um provider por vez até achar") também não é
necessária agora: o fan-out paralelo com cache já é suficiente, e incremental só agrega se
houver dezenas de providers (não é o caso — 4–5 registrados). Estratégia híbrida (fan-out
com resposta incremental) é refinamento futuro, não requisito.

### D4 — Mapeamento AniList ↔ providers: persistente, não só cache (melhora principal)

**O plano trata como "cache" (em RAM).** Insuficiente. O passo frágil e caro é
"encontrar a página do provider pelo nome do catálogo" (`_findBySource` + `bestMatch` +
Cloudflare). Recriá-lo via cache RAM a cada execução é: caro, instável entre sessões e
**o que alimenta o 429 do AnimeFire**. Um cache em RAM se perde no reboot da TV e o usuário
paga a busca de novo no primeiro tap de cada anime.

**Decisão:** adicionar uma camada **persistente simples** de mapeamento:

- Chave: `anilistId` (estável) → `{ source: { url/id do provider } }` (o `ProviderMatch`).
- Gravação: no primeiro `resolveAnime` bem-sucedido.
- Leitura: antes de qualquer busca por nome; fallback para busca + `bestMatch` apenas em
  miss (primeira resolução mais lenta, senão instantânea).

Implementação mínima: um mapa JSON em `shared_preferences` (já é dependência do projeto).

**Impacto:**
- **Desempenho**: o tap residual passa de "busca por nome + rede" para "lookup local + 1
  rede".
- **Rate-limit/429**: elimina as buscas repetidas por nome que são o gatilho do bloqueio —
  consequência direta do risco §10.6 do plano.
- **Manutenção**: um mapa simples, com atualização/purge quando o provider retornar 404.

Não é um banco relacional: é um Key-Value de descoberta. Se o nº de providers crescer
muito, evolui para uma tabela — por ora o mapa é a solução certa.

### D5 — Fluxo da interface: Episódio → Provider → Qualidade (endossado, com auto-play)

Abordagens possíveis:

| Fluxo | Prós | Contras |
|---|---|---|
| Nível único (provider do anime decide) | 0 escolhas | Mantém o acoplamento atual; usuário não escolhe por ep |
| Flat (só qualidades, qualquer provider) | — | Ambíguo: a fonte vira caixa de surpresa |
| **2 níveis: Episódio → Provider → Qualidade** (plano) | Explícito; mostra quais providers "têm!"; ideal p/ agregador | 2 passos de escolha por play (custo no controle de TV) |
| Auto-play (default implícito) | Menos taps | Esconde as fontes disponíveis |

**Decisão:** adotar o fluxo de **2 níveis** do plano, **em um único dialog**, com:

1. **Auto-play default**: após resolver, preseleciona o provider de maior prioridade que
   tenha o ep (mostrando o dialog já preenchido com "Iniciar de AnimeFire ✔"), ou inicia
   direto. Persistir o **último provider escolhido por obra** como default dos próximos
   taps — reduz passos redundantes sem remover poder de escolha.
2. Um dialog `ProviderQualidadeDialog` com providers em lista/tabs; ao escolher o provider,
   mostra as qualidades.

Manter o **re-resolve/fallback do player** já existente em `player_screen.dart`: a
estratégia de auto-avançar para o próximo provider com o ep continua válida (cobre URL
expirada/403 entre o tap e a reprodução — o plano §10 já pede validar).

Assim a UX de TV não é penalizada (controle remoto) e se preserva a proposta de que o
provider é uma "alternativa de vídeo", não a verdade do anime.

---

## 3. Problemas encontrados (no plano e no código)

1. **`Episode.url` é non-null** (`episode.dart:4`) — a lista canônica de catálogo não tem
   url; reutilizar `Episode` força sentinela vazia e vaza `source`/`owner` para o catálogo.
2. **Falta de persistência do mapeamento AniList↔provider** (riscos 4 e 6 do plano) — sem
   ela, a busca frágil por nome se repete e alimenta o 429; "só cache" não resolve de
   forma durável.
3. **A assinatura única `resolveEpisode(anime, n)` não separa "encontrar a página do
   anime" de "resolver o ep N"** — sem cache, cada chamada re-negocia a página (custo na
   primeira vez e exposição a Cloudflare/rate-limit).
4. **`ProviderEpisode` é desnecessário** — a resolução pode devolver `VideoSource` direto;
   um terceiro modelo de episódio adiciona complexidade sem ganho.
5. **A grade usa `_selectedSource` na chave do grid** (`ValueKey('$_selectedSource_$i')` em
   `detail_screen.dart:562`) — com a grade canônica, o índice fica estável e a chave deve
   ser simplificada.
6. **Dead code / estado vazio:** `anime_repository_new.dart` está **vazio**; o
   `AniListAdapter` existe mas **não está registrado** em `SourceRegistry` (o plano pede
   ajustes nele, mas ele não participa de busca/vídeo e `implemented=false` já o exclui —
   confirmar se ainda é consumido). `bestMatch/normalize/mergeEpisodes` do `AnimeScraper`
   devem migrar para o caminho de `resolveAnime`, não ser duplicados.
7. **O plano §8.2 sugere reuso de `Anime` enriquecido e `List<Episode>` para o catálogo** —
   conflita com o item 1 (url/owner do `Episode`). A saída é `CatalogEpisode` (conversão
   via `AniListEpisode` já existente).
8. **Paginação por provider:** o AnimeFire lista todos os eps numa página, mas não se pode
   assumir o mesmo para todos os providers. O `resolveVideo` deve lidar com
   página/índice por provider e documentar essa particularidade por fonte (evitar que
   `getEpisodes` "resolva" a listagem completa por tap).

---

## 4. Melhorias propostas

1. **Contrato do provider em duas etapas** — `resolveAnime(catalogRef)` →
   `ProviderMatch` (descoberta da página, cacheável e persistível) e
   `resolveVideo(match, n)` → `List<VideoSource>`. Em vez do `resolveEpisode(anime, n)`
   cego.
2. **Criar `CatalogEpisode`** e **reutilizar `VideoSource`** como saída da resolução;
   **não criar `ProviderEpisode`**. Restringir `Episode` (url/owner) ao interior dos
   adapters durante a migração e removê-lo depois.
3. **Persistência do mapeamento** (shared_preferences, chave `anilistId`) como fonte
   primária de descoberta; busca por nome apenas em miss. Resolve os riscos 4 e 6 do plano.
4. **Caches**: `catalogEpisodes` (por anilistId), `providerMatches` (persistente),
   `episodeResolutions` (provider, anilistId, ep, TTL curto). Manter fan-out paralelo +
   timeout + serial AnimeFire.
5. **UX**: dialog único `Provider → Qualidade` com auto-play default e preferência do
   último provider; manter fallback do player.
6. **Limpeza**: remover `_SourceSelector`, `_selectedSource`, `sourceOptions`,
   `anime_scraper.getEpisodes` (merge), o `anime_repository_new.dart` vazio e o
   `AniListAdapter` não registrado (após confirmar que nada o consome).

---

## 5. Comparação: arquitetura original × revisada

| Aspecto | Original (plano) | Revisada (este documento) |
|---|---|---|
| Resolução do ep N | Provider via `resolveEpisode(anime, n)` | Provider via 2 métodos: `resolveAnime` (uma vez) + `resolveVideo(match, n)` |
| Modelo da grade | `Episode` (com url/owner) | `CatalogEpisode` (sem url) |
| Modelo de resolução | `ProviderEpisode` (opcional) | `VideoSource` — sem terceiro modelo |
| Mapeamento AniList↔provider | Cache em RAM | **Mapa persistente** (chave anilistId) + cache de resoluções TTL |
| Orquestração | No repo/orchestrator; fan-out paralelo | Igual — repo/orchestrator centraliza fan-out + timeout + cache; provider só resolve |
| Fluxo UX | Episódio → Provider → Qualidade em 2 passos | Mesmo fluxo, **um dialog** com auto-play default e preferência persistida |
| Custo por tap | busca por nome + vídeo (sem cache) | `ProviderMatch` cacheado → vídeo; TTL curto |
| Preload | deixa em aberto/futuro | Mantida como entrada futura; não é requisito |

---

## 6. Justificativa técnica das alterações

1. **Dividir o contrato do provider** — a busca/localização da página é a operação cara e o
   gatilho de rate-limit (`_findBySource`/Cloudflare nos riscos do plano). Fazê-la **uma
   vez** e esconder o `match` atrás de `resolveAnime` preserva o SRP do provider (dono da
   própria numeração) e deixa `resolveVideo` barato e cacheável. Melhora a testabilidade:
   mocka-se `resolveAnime` uma vez e `resolveVideo` por episódio.
2. **`CatalogEpisode` + `VideoSource`** elimina a sentinela obrigatória (`Episode.url`),
   resolve o conflito de schema e mantém a grade pura — `source`/`owner` não vazam para a
   tela.
3. **Mapa persistente** é o ajuste que, sozinho, resolve os riscos 4 e 6 do plano
   (busca frágil repetida e custo/429), a baixo custo (um mapa JSON no `shared_preferences`,
   dependência já presente). Sem ele, o "cache" só funciona na mesma sessão e o primeiro
   tap de cada anime paga a busca.
4. **Manter a orquestração no repositório** (fan-out, isolamento, timeout, cache) é
   consistente com o que `AnimeRepository.getVideoSources` **já faz hoje**: é evolução do
   fallback atual, não um novo serviço abstrato. Menor superfície, menor risco de regressão.

---

## 7. Arquitetura final recomendada

```
         CATÁLOGO (AniList) — fonte única da grade
   AnimeCatalog / AniListService
     · metadados; total de episódios; (login+) episodesV2
     · constrói List<CatalogEpisode> 1..N   (sem url/source)
                                   │ tap episódio N
                                   ▼
    AnimeRepository (orquestra; fan-out paralelo)
      · resolveAnime de cada provider  → ProviderMatch (uma vez, PERSISTIDO)
      · resolveVideo(match, N)         → List<VideoSource>  (rede por provider)
      · cache: disponibilidade (animeId, ep), resoluções (provider, animeId, ep)
      · serial-throttle AnimeFire / timeout / isolamento por erro
                                   │ provider → List<VideoSource>
                                   ▼
    ProviderQualidadeDialog  (um dialog, 2 níveis)
      Provider (auto-play = prioridade + preferência)  ─►  Qualidade  ─►  Player
                                   ▼
    PlayerScreen (media_kit) — re-resolve/fallback de provider morto
```

**Contratos finais (nível de assinatura; não implementação):**

```
// Catálogo
class CatalogEpisode { String number; String? title; String? thumbnail; String? description; }

// Provider (adapter)
abstract class AnimeSourceAdapter {
  AnimeSource get source;
  bool get implemented => true;
  Future<ScraperResult<ProviderMatch?>> resolveAnime(AnimeRef catalogRef); // descoberta, cache/persist
  Future<ScraperResult<List<VideoSource>>> resolveVideo(ProviderMatch match, int episodeNumber);
}

// Orquestração (repo) — API para a UI
Future<Map<AnimeSource, List<VideoSource>>> resolveProvidersForEpisode(AnimeRef anime, int n);
Future<List<CatalogEpisode>> getCatalogEpisodes(AnimeRef anime); // 1..N canônico
```

---

## 8. Aprovação final

✅ **Plano estrutural APROVADO**, com os ajustes de contrato/modelagem descritos acima:

- **Bloqueadores (antes da Etapa 2):** adotar `CatalogEpisode` + `VideoSource` (e **não**
  criar `ProviderEpisode`); definir `resolveAnime` + `resolveVideo` em vez do
  `resolveEpisode` único, para viabilizar o cache/persistência do `match`.
- **Ponto 3 (estratégia de resolução):** fan-out + cache + persistência do `match`. Não
  implementar preload agora (medir antes de otimizar).
- **Ponto 4 (mapeamento):** sim — evoluir de "só cache" para **mapa persistente** antes de
  encerrar a Etapa 3; isso remove os riscos 1 e 6 do plano.
- **Ponto 5 (fluxo):** `Episódio → Provider → Qualidade` **em um dialog**, com auto-play
  default; fallback de provider no player mantido.

A ordem das etapas permanece praticamente a do plano (0→7), com a Etapa 2 incorporando a
modelagem nova e a Etapa 3 centralizando a orquestração e a persistência do `match`.

Sem bloqueadores de segurança ou de integridade. **Pronto para iniciar a implementação.**
