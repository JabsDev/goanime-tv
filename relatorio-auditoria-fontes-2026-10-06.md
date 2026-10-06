# Auditoria das fontes — 06/10/2026

Data do probe: 06/10/2026. Escopo: verificar ao vivo cada fonte integrada, identificar
mudanças do lado dos sites e corrigir o que dependesse do app.

Diagnóstico anterior relacionado: `relatorio-animefire-qualidade-nao-carrega.md` (10/09/2026),
`relatorio-animefire-revisao-critica.md` (10/09/2026), `relatorio-bugs-episodios-animefire.md` (09/09/2026).
Esta auditoria é a primeira após a migração de domínio do AnimeFire.

---

## TL;DR

1. **AnimeFire estava 100% quebrada** por **duas** mudanças do site:
   - migração `animefire.io` → **`animefire.one`** (301); o antigo subdomínio
     **`api.animefire.io` não resolve mais no DNS**;
   - o JSON de busca trocou o campo plano `title` por um mapa localizado
     **`titles: {BR, JP, US…}`** — sem ajuste, mesmo com a API nova a busca retornaria 0.
   **Corrigido** (adapter + testes + validação ao vivo).
2. **Goyabu caiu** atrás de desafio Cloudflare (`403 cf-mitigated: challenge`) em todas as rotas.
   Sem JS o `http.Client` não passa → **desativada no fan-out**.
3. **AnimesOnline HDK** não completa o handshake TLS (`tlsv1 alert internal error`) na origem →
   **desativada no fan-out**.
4. Bases velhas que ainda funcionavam por redirect foram apontadas para o host canônico:
   `animesdrive.online → animesdrive.cloud`, `animeq.blog → animeq.cloud`,
   `animeplayer.com.br → anreyalp.vip`, e `anroll.tv → animes.tokyo` (AnimesRoll, fora do fan-out).
5. Demais fontes ativas respondendo: BetterAnime/DooPlay, AnimesOnline Cloud, Animes Orion,
   AnimesHD, AnimePlayer, ArchiveJP, AnimeGG.

---

## Resultado do probe (HTTP + parse)

| Fonte | HTTP | Status | Observação |
|---|---|---|---|
| **AnimeFire** | 200 (`api.animefire.one`) | ❌→✅ | DNS antigo morto; schema de busca mudou. Corrigida. |
| **Goyabu** | 403 | ❌ | Cloudflare `cf-mitigated: challenge` em todas as rotas. Desativada. |
| BetterAnime / DooPlay | 200 | ✅ | `.result-item` presente. |
| AnimesOnline Cloud | 200 | ✅ | `.result-item` presente. |
| AnimesDrive | 200 (final `.cloud`) | ✅ | 301 `animesdrive.online → animesdrive.cloud`. Base atualizada. |
| AnimeQ | 200 (final `.cloud`) | ✅ | 301 `animeq.blog → animeq.cloud`. Base atualizada. |
| AnimePlay | 503 | ⏸️ | Já desativada no código (`implemented => false`). |
| **AnimesOnline HDK** | — | ❌ | Handshake TLS falha (`tlsv1 alert internal error`). Desativada. |
| Animes Orion | 200 | ✅ | `.result-item` presente. |
| AnimesHD | 200 | ✅ | `.result-item` presente. |
| AnimePlayer | 200 (final `anreyalp.vip`) | ✅ | 301 `animeplayer.com.br → anreyalp.vip`; hrefs absolutos. Base atualizada. |
| AnimesOnline IO | — | ⏸️ | Já desativada (file do Google Video dá 403). |
| AllAnime | 403 | ⏸️ | Já desativada (captcha). |
| ArchiveJP | 200 | ✅ | — |
| AnimeGG | 200 | ✅ | 55 cards no parse de `search/?q=naruto`. |

> `AnimesRoll` (`anroll.tv`) → 301 → `animes.tokyo` e responde 522; **não** está no fan-out do app.

---

## 1. AnimeFire — causa raiz

O site foi rebuildado e migrou de domínio. Evidências ao vivo:

- `https://animefire.io/` → **301 → `https://animefire.one/`**.
- `api.animefire.io` **sem registro DNS** (`curl` erro 6 / `dig` vazio). O único host vivo é
  `api.animefire.one` (200).
- Payload de `/animes/pesquisar?q=naruto` (antes × depois):

```jsonc
// antes (09/09/2026) — campo plano
{ "data": [ { "id": "eU7t5IvcNKU", "title": "Naruto", "audio": "Dublado & Legendado" } ] }

// agora (06/10/2026) — mapa localizado; `title` não existe mais
{ "data": [ { "id": "eU7t5IvcNKU", "titles": { "BR": "Naruto" }, "audio": "Dublado & Legendado" } ] }
```

`/anime/{id}` e `/episode/{id}` **não mudaram** (mesmos `seasons[]`, `episodes[]`,
`streams[].{audio,url,qualities}`). Logo o conserto ficou restrito a: base URL + leitura do `titles`.

### Correção aplicada

`lib/core/sources/anime_fire_adapter.dart`:
- `_apiBase` → `https://api.animefire.one`; `_siteBase` → `https://animefire.one`.
- Novo helper `_titleOf(Map)`: prefere `titles['BR']` → `US` → `EN` → primeiro valor não vazio;
  cai no `title` plano legado quando o mapa não existe (fixtures/cache antigos continuam válidos).
- `lib/core/constants/app_constants.dart`: `baseSiteUrl` → `https://animefire.one` (Referer de imagem).

### Validação ao vivo (adapter real, não curl)

```
SEARCH n=30 first="Naruto" url=https://animefire.one/anime/eU7t5IvcNKU
EPISODES n=219 first=1 url=https://api.animefire.one/episode/WCrJufyJmQn
VIDEO n=2 first=480p audio=dublado host=akumast.net
```

---

## 2. Goyabu — desativada

`goyabu.io` responde `403` com `cf-mitigated: challenge` (desafio JS do Cloudflare) em **todas**
as rotas, independente do `User-Agent`. O `http.Client` puro do app não executa JavaScript, então
busca e episódios nunca passam. Alternativa real exigiria WebView/cookies ou serviço tipo
FlareSolverr — fora do escopo de um fix rápido.

`lib/core/sources/goyabu_adapter.dart`: `implemented => false` (adaptador e testes preservados
para religar se o site voltar a servir HTML direto).

## 3. AnimesOnline HDK — desativada

A origem `animesonlinehdk.com` resolve no DNS (`2.57.91.91`) mas **falha o handshake TLS**:
`TLSv1.3 (IN), TLS alert, internal error (592)` / `tlsv1 alert internal error`. Nenhuma rota
completa — problema de servidor, não do app.

Investigação extra (06/10/2026): em HTTP puro a raiz responde 200 com o título
**"Parked Domain name on Hostinger DNS system"** — ou seja, o domínio está **parked/expirado**, e
não há site atrás. Conclusão: não existe substituição confirmada; **não** faz sentido apontar para
HTTP. Desativada no fan-out.

`lib/core/sources/dooplay_adapter.dart`: `implemented => _source != AnimeSource.animesOnlineHdk`.

## 3b. AnimesRoll — base canônica atualizada

`anroll.tv` responde **301 → `animes.tokyo`** (confirmado no header `location`). O host novo está
atrás de Cloudflare e hoje devolve **522** (origem fora do ar), mas é o destino oficial do
redirect. Atualizado em `DooPlayAdapter.baseUrls` e no `SourcePingService`. A fonte continua **fora
do fan-out** (nunca esteve em `fallbackOrder`), então a mudança é só de higiene de base.

## 3c. AnimePlay — sem base nova

`animeplay.cloud` segue 503. `animeplay.site` (que aparece em buscas) é outro site (EN,
"Watch Anime Online Free in HD"), **não** o AnimePlay PT-BR — não foi usado. Permanece desativada.

## 4. Bases velhas (redirect) — atualizadas

| Fonte | Antes | Agora |
|---|---|---|
| AnimesDrive | `https://animesdrive.online` | `https://animesdrive.cloud` |
| AnimeQ | `https://animeq.blog` | `https://animeq.cloud` |
| AnimePlayer | `https://animeplayer.com.br` | `https://anreyalp.vip` |
| AnimesRoll | `https://anroll.tv` | `https://animes.tokyo` |

Também em `source_ping_service.dart` (domínio do medidor de latência) e, no caso do AnimeFire,
em `app_constants.baseSiteUrl`.

---

## 5. Arquivos alterados

```
lib/core/constants/app_constants.dart         baseSiteUrl .one
lib/core/sources/anime_fire_adapter.dart      api/site .one + parse de `titles`
lib/core/sources/animesonline_adapter.dart    bases .cloud
lib/core/sources/animeplayer_adapter.dart     base anreyalp.vip
lib/core/sources/dooplay_adapter.dart         HDK implemented=false
lib/core/sources/goyabu_adapter.dart          implemented=false
lib/core/sources/source_ping_service.dart     domínios de ping
test/resolve_anime_regression_test.dart       hosts .one + teste do schema `titles`
test/resolve_provider_states_test.dart        host .one
test/animesonline_adapter_test.dart           bases .cloud
test/dooplay_new_sources_test.dart            HDK fora do fan-out
README.md                                     fontes ativas × desativadas
```

## 6. Testes

- `flutter analyze` sem issues nos arquivos alterados.
- Testes de fontes/adaptação verdes (resolve_anime_regression, resolve_provider_states,
  animesonline_adapter, dooplay_new_sources, ptbr_adapters, sources_corrections,
  dash_manifest_proxy, animeplayer_episode_number, anime_gg_adapter, archive_jp_adapter).
- Falhas restantes na suíte: **7 em `test/llm_mt_test.dart`**, pré-existentes e sem relação com
  esta auditoria (o teste não chama `TestWidgetsFlutterBinding.ensureInitialized()` e quebra em
  `Glossary.load`). Nenhum arquivo desta auditoria é importado por ele.

---

## 7. Pendências / como religar

- **Goyabu / AnimesOnline HDK**: quando os sites voltarem, basta reverter a linha de
  `implemented` (os adaptadores e testes seguem intactos).
- **AnimePlay**: idem, quando `animeplay.cloud` voltar a 200.
- A disponibilidade das fontes muda sem aviso; este relatório é um retrato de 06/10/2026.
