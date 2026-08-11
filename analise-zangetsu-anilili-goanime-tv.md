# Análise Comparativa: Zangetsu, Anilili e GoAnime-TV

Relatório técnico comparativo dos projetos [Zangetsu](https://github.com/Spyou/Zangetsu), [Anilili](https://github.com/kompoti121/Anilili) e GoAnime-TV, com foco em **arquitetura de providers**, **fontes PT-BR** e **ideias aproveitáveis** (dublagem, legendas, episódios).

> **Nota de escopo:** o repositório do Anilili não contém código-fonte — apenas `README.md`, assets e imagens de showcase. A análise do Anilili está, portanto, limitada ao que o README declara. Fatos não verificáveis estão marcados como **"Não confirmado"**.

---

## 1. Resumo Executivo

| Aspecto | Zangetsu | Anilili | GoAnime-TV |
|---|---|---|---|
| Linguagem/Stack | Flutter (Dart) + JS providers | Kotlin + Jetpack Compose | Flutter (Dart) |
| Público-alvo | Celular + TV (Fire TV) | Android 5.1+ / TV | Android TV |
| Plugin de mídia | media_kit (mpv) | — | media_kit (mpv) |
| Providers | Sistema à la CloudStream/Mihon: ~27 providers via repositório remoto (JSON index), extensões `.cs3` (CloudStream) e extensões Aniyomi/Mihon | **Não confirmado** | Scrapers nativos em Dart (5 fontes PT-BR) |
| Integração AniList | Sim (auth + listas) | Sim (auth + listas) | Sim (auth + listas) |
| Dublagem PT-BR | Sem providers PT-BR no repo oficial (EN/internacional) | **Não confirmado** | Foco de 4 de 5 fontes |
| Legendas | Busca/download automática por idioma, tradução automática, track menu | **Não confirmado** | Suporte aos streams embedded (sem busca de legendas) |
| Extra | Downloads, cast, skip intro/outro (TMDB), Discord RPC, backups | Downloads offline (README); código ausente | Perfis, catálogo canônico via AniList |

**Conclusão principal:** GoAnime-TV já vence em **fontes PT-BR nativas** (nenhum dos outros tem dublagem PT-BR no repo oficial), mas está bem atrás do Zangetsu em:

1. **Arquitetura de providers aberta** — o Zangetsu carrega/atualiza fontes de um repositório remoto (URL index.json) sem recompilar o app; o GoAnime-TV tem fontes travadas no código.
2. **Qualidade de vida de player** — histórico e retomada de reprodução, skip intro/outro via TMDB, legendas externas por idioma + tradução automática, enriquecimento de metadados (TMDB).
3. **Confiabilidade de fontes** — o Zangetsu mede a "saúde" de cada provider e reordena/skipa fontes quebradas; GoAnime-TV usa ordem fixa de prioridade PT-BR.

## 2. Tabela Comparativa Detalhada

| Critério | Zangetsu | GoAnime-TV |
|---|---|---|
| Motor de catálogo/peça | 100% providers externos | AniList (grid canônico `getCatalogEpisodes`) |
| Resolução de episódio | Provider retorna lista; health-aware | `EpisodeResolution`, 1ª fonte válida, `matchedUnavailable` |
| Cache | TTL amplo (episódios, metadados, saúde de fontes) | TTL (busca 30min, epis 1h, enrichment 24h, catálogo 24h, resoluções 30min) |
| Fallback de título | Listas/negotiação via AniList | Match por título + AniList |
| Multi-idioma | Sub/dub por provider, menu de faixas | Sub/dub fixo das fontes PT-BR |

### Anilili (somente README)

- Kotlin + Jetpack Compose, Android 5.1+, Android TV / Fire TV.
- Sincronização com **AniList** e **MyAnimeList**; downloads offline; APK distribuído via Telegram/GitHub Releases.
- **Nenhuma evidência de código verificada** — providers, dublagem e legendas **Não confirmados**.

## 3. Diferenças e Desvantagens do GoAnime-TV

1. **Fontes travadas no código** — qualquer quebra de fonte exige novo release + reinstalação; Zangetsu atualiza fontes por JSON remoto (jsDelivr mirror incluso).
2. **Sem health-check de fontes** — quando uma fonte PT-BR cai, o app tenta "à força" até cair no fallback; não há ordem dinâmica por confiabilidade.
3. **Sem histórico/retomada de reprodução** persistente por perfil (Zangetsu tem `watch_history`).
4. **Legendas limitadas** — não há busca de legendas externas nem tradução automática.
5. **Sem metadados extras** — sem posters TMDB, títulos de logo, pessoas/elenco, capa de episódio.
6. **Sem skip intro/outro** (créditos) que o Zangetsu resolve via TMDB.

## 4. Fontes PT-BR candidatas (achados dos projetos)

### Do repositório `zangetsu-providers` (via GitHub API)

| Fonte | PT-BR? | Classificação | Observação |
|---|---|---|---|
| `allanime.js` | Legendas gringas (EN/Multi) | **Possivelmente interessante** | API oficial, legendas por idioma (pt-BR existe via localized subs — não é dubla) |
| `hianime.js`, `animekai.js`, `animecube.js`, `anikoto.js` | Não (EN) | Não recomendada | Sites internacionais |
| `vegamovies.js`, `uhdmovies.js`, `multimovies.js`, `hdhub4u.js`, `fourkhdhub.js` | Não (EN/HD) | Não recomendada | Focadas em cinema/hollywood |
| Extensões CloudStream `.cs3` | Depende da extensão | **Possivelmente interessante** | Zangetsu executa `.cs3`; é o caminho p/ trazer fontes PT-BR (AnimeFire, etc.) via comunidade |

### Já implementadas no GoAnime-TV

| Fonte | PT | Status |
|---|---|---|
| AnimeFire (helper) | Sim | Ativo |
| Goyabu | Sim | Ativo |
| DooPlay / BetterAnime / AnimesRoll | Sim | Ativo |
| AnimePlayer (SP) | Sim | Ativo |
| AllAnime | Global (legendas) | Fallback |

> **Conclusão:** nenhum projeto analisado tem dublagem PT-BR nativa exceto o GoAnime-TV. O Zangetsu suporta legendas PT-BR via API da AllAnime, mas não dubla.

## 5. Recomendações Priorizadas para GoAnime-TV

### Alta prioridade

1. **Motor de providers como repositório externo** (padrão do Zangetsu/CloudStream): `index.json` remoto listando fontes; loader (Dart ou `.cs3`); cache de download + jsDelivr mirror. Passa de "recompilar para tudo" para "atualizar feeds".
2. **Priorização por saúde de fonte** (`SourceHealthStore` style): medir sucesso/falha por fonte e reordenar a lista de tentativas — reduz o impacto de `matchedUnavailable`.
3. **Skip intro/outro via TMDB + retomar reprodução** (`skip_service`, `watch_history`): alto valor percebido, baixo esforço, reutilizando media_kit.

### Média prioridade

4. **Legendas externas + tradução automática** (`subtitle_search_service`, `subtitle_translate_service`): preenche a lacuna de streams que não têm sub embutida.
5. **Enriquecimento de metadados (TMDB)** — título com logo, sinopse, capa/episódio, elenco e pessoas (`metadata`).
6. **Menu de faixas (áudio/legenda)** (`tv_track_menu`) para controlar sub/dub no player.

### Baixa prioridade

7. **Downloads offline** — requer infra (mirroring direto ou torrent); custo elevado.

### Não recomendado no curto prazo

- **Torrents como fonte padrão** (contencionalidade e suporte).
- **Cast para outro dispositivo / Discord RPC** (são extras fora do foco de TV doméstica).

## 6. Análise da Arquitetura de Providers

### GoAnime-TV (estado atual)

```
lib/core/scraper/        AnimeScraper.searchAnime (busca consolidada em paralelo)
lib/core/sources/        AnimeSource + adapters: anime_fire, goyabu, dooplay (BetterAnime/AnimesRoll), animeplayer, all_anime
lib/core/sources/source_registry.dart   prioridade: AnimeFire → Goyabu → DooPlay → AnimePlayer → AllAnime
lib/data/repositories/   AnimeRepository.getCatalogEpisodes — grid canônico via AniList
```

- **Busca consolidada:** dispara todas as fontes em paralelo, consolida resultados, fallback de título via AniList.
- **Resolução de episódio:** percorre as fontes na ordem de prioridade PT-BR até achar um vídeo (`EpisodeResolution`, com flag `matchedUnavailable`).
- **Cache TTL** em `lib/core/cache/ttl_cache.dart` + persistência de match fonte↔título em `provider_match_store.dart`.
- **Limitação:** fontes travadas no código e ordem fixa — sem health-check, qualquer atualização exige recompilar.

### Zangetsu (referência)

- **Repositórios de providers:** `index.json` remoto lista todos os providers; download direto de `raw.githubusercontent.com` com **mirror jsDelivr automático** (ISP que bloqueia raw ainda resolve).
- **Suporte a executáveis externos:** fontes `.cs3` (CloudStream) via MethodChannel + extensões **Aniyomi/Mihon** (download e execução) — é o mecanismo que permitiria plugar fontes PT-BR de terceiros.
- **Modelo de categorias sub/dub por provider** com menu de faixas no player (`tv_track_menu`), passando `AudioKind` (SUB/DUB) e delimitando idiomas suportados.
- **Health-aware:** `SourceHealthStore` registra sucesso/falha e reordena os providers na busca; providers quebrados entram em watchlist e são tratados.
- **Risco:** executa código remoto (JS/`.cs3`/extensões) — dependência de infra externa e superfície de segurança maior.

### Leções para o GoAnime-TV

1. Adotar **provedores como repositório externo** (index.json + loader `.cs3`) para tirar fontes do código compilado → manutenção de fontes vira OTA, sem release.
2. Implementar **health/failover por fonte** (métrica de sucesso/falha) para substituir a ordem fixa.
3. **Não voltar atrás** no grid canônico via AniList — é o que dá robustez sobre providers quebrados.

## 7. Integração AniList — Comparação

| Critério | GoAnime-TV | Zangetsu | Anilili |
|---|---|---|---|
| Autenticação | PKCE + pairing server | Auth OAuth | Autorização (README) |
| Catálogo canónico | **Sim** — `AnimeRepository.getCatalogEpisodes` com base AniList | **Não** (100% providers) | Não confirmado |
| Listas | Lista por perfil | Perfis | Sim (README) |
| Notas extras | — | Status/notas concluída | — |

**Lição:** o grid de episódios do GoAnime-TV ficou mais robusto que o do Zangetsu (que depende 100% dos providers para listar episódios). O Zangetsu compensa com enriquecimento TMDB que o GoAnime não tem.

## 8. Problemas e Limitações Encontradas

### GoAnime-TV
- Fontes hard-coded: sem mecanismo de atualização OTA de scraping.
- Sem histórico de retomada persistente.
- Sem legendas externas / tradução.
- Sem metadados de mídia (TMDB) detalhados.

### Zangetsu
- **Sem foco PT-BR** — nenhum provider no repositório oficial tem dublagem PT-BR.
- Execução de código remoto (JS `.cs3` / extensões) introduz risco de dependência; carece de confirmação de isolamento/sandbox.
- Providers e repositórios de extensões são baixados dinamicamente → dependência em infra externa (GitHub/CDNs).

### Anilili
- Sem código-fonte público (apenas README e screenshots) → avaliação limitada.
- Claims de recursos não verificáveis (dublagem, providers, downloads).

## 9. Tabela Final de Recomendações

| Ideia (referência) | Esforço | Impacto p/ PT-BR | Prioridade |
|---|---|---|---|
| Providers como repositório externo/JSON (atualizar sem recompilar) | Médio | Alto | 🔴 Alta |
| Saúde de fonte p/ priorização de fallback | Baixo | Alto | 🔴 Alta |
| Skip intro/outro (TMDB) | Baixo | Médio | 🔴 Alta |
| Retomar reprodução / histórico | Baixo | Alto | 🔴 Alta |
| Legendas externas + tradução | Média | Médio | 🟡 Média |
| Metadados TMDB (logo, epis de elenco) | Média | Médio | 🟡 Média |
| Menu de áudio/legenda no player | Baixo | Alto | 🟡 Média |
| Downloads offline | Alto | Médio | 🟢 Baixa |
| Torrents / cast / Discord RPC | Alto | Baixo | ⚪ Não recomendado |

---

## Fonte de Verificação

- **Zangetsu**: clone local `/tmp/opencode/zangetsu` (~295 arquivos Dart); `zangetsu-providers` listado via GitHub API (providers sem PT-BR).
- **Anilili**: clone local `/tmp/opencode/anilili` — apenas `README.md`, `assets/icon.png`, `showcase/*.webp`; **sem código-fonte**.
- **GoAnime-TV**: inspecionado em `/home/jabs/codes-ai/goanime-tv` (workspace do usuário): `lib/core/source/`, `lib/core/scraper/`, `lib/core/anilist/`, `lib/core/cache/`, `lib/core/storage/`, `lib/data/repositories/anime_repository.dart`.