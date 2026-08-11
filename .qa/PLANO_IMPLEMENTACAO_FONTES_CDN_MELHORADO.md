# Plano (revisado) — Fontes Novas via CDN Direta (mangas.cloud / animeflix.blog)

**Data:** 10/08/2026
**Objetivo:** corrigir os problemas encontrados na validação do plano
`PLANO_IMPLEMENTACAO_FONTES_CDN.md` com animes fora da amostra original
(One Piece / Black Clover), tornando-o executável e honesto sobre os limites.

---

## Parte 1 — Resultado dos testes com animes novos (como foi testado)

### 1.1. Amostra testada (todas `http` + `html`, sem browser)

| Anime testado | Fonte | Resultado |
|---|---|---|
| **Solo Leveling** (ep 1–4) | animesonline.cloud | ⚠️ `dooplayer/v2` alterna: ep1 opção 2 = mp4 (mangas.cloud), opções 1/3/4 = iframe (blogger / animeshd / strp2p) |
| **Solo Leveling Dublado** (ep1) | animesonline.cloud | ✅ `source=mangas.cloud/.../Solo Leveling/Dub/01.mp4` (subpasta `/Dub/`) |
| **Jujutsu Kaisen** (ep1) | animesonline.cloud | ⚠️ opção 1 = blogger iframe; **opção 2** = mp4 mangas.cloud |
| **Jujutsu Kaisen** (ep1) | animesdrive.online / animeq.blog | ✅ mesmos post id e JSON do cloud |
| **Kimetsu no Yaiba: Hashira Geiko-hen** (ep1–3) | animesonline.cloud | ✅ 1ª opção mp4 direto (animeflix.blog `01-sd.mp4`); outras opções mangas.cloud e `cldup.com` (CDN de terceiros) |
| **Naruto Shippuden** (ep1, ep220) | animesonline.cloud | ✅ ep1: `data-post=70682`; **ep220: `data-post=71049`** (id é por episódio). source mp4 mangas.cloud |
| **One Piece Dublado** (ep1, ep100) | animesonline.cloud | ✅ mp4 direto, **padding de 3 dígitos** (`001.mp4`, `099.mp4`, `100.mp4`) |
| **One Punch Man** (ep1–3) | animesonline.cloud | ❌ **`source=` do dooplayer aponta para URLs mortas (404 na CDN)** — nem Camada A nem Camada B resolvem |
| **One Punch Man / OPM** | mangas.cloud + animeflix.blog | ❌ todas as variantes de título testadas dão 404 |
| Solo Leveling (ep3/4) | animesonline.cloud | ⚠️ opções virarem `type=iframe` → animeshd.cloud / animes.strp2p.com (SPA, sem `source=`) |
| animesonline.io (Naruto) | — | anime page sem episódios no DOM (555 KB de CSS) — confirmado SPIKE |
| animesonline.blue | — | busca sem resultados úteis — SPIKE |
| sushianimes.com.br | — | `?s=` devolve catálogo, não filtra — SPIKE |
| animes.tokyo | — | Homepage 544 KB, `wp-json/search` → `[]` — SPIKE |
| dattebayo-br.com | — | `/animes/letra/n/` → **301 para homepage**; URLs são hashes, não slugs |
| donghuanosekai.com | — | busca traz donghua (não anime) — **fora da amostra** |
| **animeplay.cloud** | Solo Leveling ep1 | ✅ **NÃO está quebrada** — viu-se verdadeira causa (abaixo) |

### 1.2. Fato-chave descoberto nos testes (diferente do plano original)

1. **`data-post` é por episódio, não por anime** (Naruto ep1=70682, ep220=71049).
   O plano tratava o post como se fosse do anime.
2. **A página de episódio tem de 1 a 4 *player options*** (`player-option-N`,
   `data-nume='1'..'4'`). `nume` é **índice da opção**, não número do episódio.
3. **Só algumas opções devolvem `type=mp4` com `source=`**; as outras devolvem
   `type=iframe` → blogger / animeshd / strp2p (SPA, inalcançável sem JS).
   O mp4 **não está sempre na 1ª opção** (Jujutsu/Solo Leveling têm blog na 1ª e mp4 na 2ª).
4. **`animeplay.cloud` funciona** via `wp-admin/admin-ajax.php` com
   `action=doo_player_ajax` (mesmo JSON dos irmãos). A rest `dooplayer/v2` vazia é
   porque o tema daquele clone roda com `play_method=admin_ajax`, não `wp_json`.
5. **O `source=` pode ser duplo-encodado** (`Solo%2520Leveling`), ou conter
   sufixo `-sd` (animeflix), ou subpasta `/Dub/` — e em **OPM o source está
   morto (404)**. Ou seja: **Camada A também precisa de probe 206 antes de oferecer.**
6. **Título do folder CDN diverge do título do site** (ex.: One Piece legendado =
   pasta `OnePiece` sem espaço; One Piece Dublado = `One Piece Dublado` com
   espaço e padding 3; Solo Leveling Dublado = função `/Dub/`). → Camada B/C é
   frágil; **sempre `source=` do agregador**, e `camada B` degradada a "último recurso".
7. **`betteranime`/animesRoll não é beneficiado pelo "extrair `source=`"**:
   no betteranime o `source=` é **token ofuscado base64**, não mp4. A afirmação do
   plano ("beneficia betterAnime") **não procede** — o extractor precisa detectar
   o formato e cair no resolvedor legado.
8. **Busca devolve filmes** (`/filme/…`) e **resultados fuzzy/irrelevantes**
   (buscar "demon slayer" retornou *Frieren*; "naruto" retornou *Love Live*,
   *Fuufu Ijou*, *Cike Wu Liuqi*). O parser da busca precisa **filtrar `/anime/`**
   e o `bestMatch` precisa rejeitar ruído.

---

## Parte 2 — Problemas encontrados no plano original

### P1. `dooplay_v2_extractor` pega apenas a 1ª player option (BLOQUEANTE)
O plano e o `DooPlayAdapter` existente fazem `regExp` que casa o **primeiro**
`data-post/data-nume`. Na prática o mp4 pode estar na **2ª/3ª opção**, e a 1ª
pode ser iframe SPA. **Correção:** iterar `player-option-1..N` e escolher a
primeira `type=mp4` com `source=`; validar com probe 206; manter as demais mp4
como opções extras de qualidade.

### P2. Tratar sem distinção `type=iframe` (BLOQUEANTE)
Blogger (`video.g?token`), `animeshd.cloud/#hash` e `animes.strp2p.com/#hash`
são SPA/comportamento JS. O plano diz "não precisa resolver o player" — mas para
os `type=iframe` isso é falso. **Correção:** por opção, se `type=mp4` → decodificar
`source`; se `type=iframe` → tentar próximo nume; se terminarem as opções, rodar
Camada B (probe CDN) e só então reportar falha.

### P3. `animeplay.cloud` rotulado como "broken / dooplayer v2 vazio" (INFERÊNCIA ERRADA)
O teste mostrou `admin-ajax` com `action=doo_player_ajax` devolvendo o **mesmo
JSON** dos irmãos (inclusive opção 2 = mp4 mangas). A regra do plano de "deixar
fora do cluster inicial / fallback" **descarta uma fonte que funciona**.
**Correção:** ler `dtAjax.play_method` da página (episódio/anime) e rotear o
pedido para `wp-json/dooplayer/v2/<post>/<type>/<nume>` **ou**
`admin-ajax?action=doo_player_ajax` conforme o tema. Mecanismo único de transporte.

### P4. `decodeUrlComponent(query['source'])` só uma vez (NUANCE)
`source` no JSON vem com duplo-encode (`%2520`, `%253A`). `URLSearchParams` /
`Uri.queryParameters` já decodifica UMA vez → fica `Solo%20Leveling` (funciona,
206). Decodificar **duas** vezes vira espaço literal → `HTTP 000`. **Correção:**
usar o valor do query param **sem decodificação adicional**; não deixar o client
reencodificar o path (se usar `Uri` em Dart, preservar o `%20` do path).

### P5. `jwplayer` page não contém o mp4 → extração via regex no plano era ilusória
A página `https://<site>/jwplayer?source=…&type=mp4` retorna 5 KB de SPA **sem**
nenhum `.mp4`. O plano afirmava que dava para extrair o mp4 da página do player.
**Correção:** não fetchar a página jwplayer para achar o vídeo nos clones — o
mp4 **está no query string** do `source`. (Vale para os 4 clones; o jwplayer só
interessa ao betteranime via token ofuscado, caminho já existente.)

### P6. `source=` morto: OPM (BLOQUEANTE)
OPM (ep 1–3) devolve do dooplayer URLs que **404 na CDN**. O plano não previa
validação da Camada A. **Correção:** todo mp4 candidato passa por probe range
`0-0` → `206` antes de virar `VideoSource`; se falhar, tenta as demais opções e
a Camada B. Só expõe se algo responder 206.

### P7. Camada B ("construir URL na CDN") supervalorizada
O folder na CDN é **inconstante**: `OnePiece` (sem espaço), `One Piece Dublado`
(espaço + padding 3), `Solo Leveling/Dub`, `Kimetsu no Yaiba: Hashira
Geiko-hen` (dois-pontos), `Black-Clover-Dublado` (hífen), `01-sd.mp4`. Para
títulos fora da amostra, reconstruir sozinho é loteria. **Correção:** mantê-la
como **fallback de último recurso**, com matriz de variantes (título display,
romaji, com/sem acento, `Dublado` como sufixo OU subpasta `/Dub/`, padding 1–3
dígitos, sufixo `-sd`), probe serializado com cache — **nunca** como camada
primária; e registrada como "best-effort, sujeita a 404".

### P8. "Extrair `source=` beneficia betteranime/animesRoll" (FALSO)
No betteranime, `dooplayer/v2` devolve `source=base64(obfuscado)` e `type` com
URL do jwplayer própria. O extractor genérico, ao ver um `source` que não é URL
(b64 com `=`/`+`/`-`), **deve repassar** ao fluxo legado do betteranime. Não
quebrar o comportamento atual.

### P9. Busca: `/filme/` e ruído fuzzy não tratados
`?s=solo leveling` retorna `/filme/…` (Second Awakening) junto de `/anime/…`.
`?s=demon slayer` devolve *Frieren*. **Correção:** no `search`, descartar hrefs
que não contêm `/anime/` (TV); na escolha via `bestMatch`, penalizar títulos sem
sobreposição de tokens (já existe mecanismo, mas a lista ruidosa precisa ser
filtrada antes de virar candidato).

### P10. dattebayo-br: catálogo errado no plano
`/animes/letra/n/` → 301 para a homepage; episódios são hash, `temporada`
aparece, mas não há `episodio/…` no padrão. **Correção:** manter o site fora
do escopo desta etapa (SPIKE separado), sem prometer catálogo `letra/`.

### P11. Qualidades múltiplas MASCULINAS
`01-sd.mp4` (animeflix) + `01.mp4` (mangas) + `cldup.com` (terceiros) mostram que
a CDN tem **mais de um bitrate/fonte**. O plano dizia "type=mp4 sugere 1
qualidade". **Correção:** ao iterar opções, colher todas as mp4 de hosts
distintos e expor como fontes de qualidade variada (sem prometer labels
exatos; usar "Auto/Alternativa" até o player decidir).

---

## Parte 3 — Estratégia revisada (3 camadas + transporte)

### Camada A — extrair mp4 via agregador (primário)
Fluxo por episódio (atenção: `data-post` é **por episódio**):
```
anime page (.episode-card, data-episode-number)
  → episódio page → <li class='dooplay_player_option' data-post='N' data-nume='K' data-type='tv'>
  → GET/POST transporte (ver abaixo) por cada nume K de 1..M
  → para cada opção:
        type == 'mp4' && source != null  → candidato
        tipo == 'iframe'                 → pular (SPA)
  → para cada candidato: probe range 0-0 → 206? aceita : próxima opção
  → VideoSource(url: source_1x_decoded, headers: {Referer: baseUrl, UA})
```
**Transporte (novo, resolve P3):**
ler `dtAjax = {"url", "player_api", "play_method"}` na página do episódio:
- `play_method == "wp_json"` → `GET <player_api><post>/<type>/<nume>`
- `play_method == "admin_ajax"` → `POST <url> action=doo_player_ajax&post=<post>&nume=<nume>&type=<type>`
cobre animesonline.cloud / animesdrive.online / animeq.blog / **animeplay.cloud**.

### Camada B — probe na CDN (fallback, best-effort)
Só quando a Camada A esgotar opções. `buildCdnUrl` + **variantes** (P7): título
display do agregador, romaji/english do AniList, com/sem acento, `Dublado` como
sufixo ou `/Dub/`, padding `{1,2,3}` dígitos, sufixo `-sd`; probe serializado,
cache por (título, ep). Nunca ofertar o que não respondeu 206.

### Camada C — melhor seleção de opção
Ao iterar opções, preferir a que responde 206 **e** tenha tamanho maior no
`Content-Range` (proxy barato de qualidade). Hosts `mangas.cloud` e
`animeflix.blog` primeiro; `cldup.com` e afins junto.

---

## Parte 4 — Arquitetura / integração no app (com as correções)

Novos arquivos/mudanças **propostas** nestas revisões:

| Arquivo | Mudança (revisada) |
|---|---|
| `lib/core/sources/dooplay_v2_extractor.dart` (novo) | irá: parse das `li.dooplay_player_option` (TODAS); transporte por `play_method`; decode **único** de `source`; probe 206; lista de `VideoSource`. Falha tipada `NoPlayableOption` quando nada responder 206. |
| `lib/core/sources/cdn_resolver.dart` (novo) | probe range + cache + **matriz de variantes** (P7); taxa de sucesso baixa e aceita como best-effort. |
| `lib/core/sources/animesonline_adapter.dart` (novo) | cluster parametrizado por `baseUrl` (cloud/drive/q.blog/animeplay). `search` filtra `/anime/`; `getEpisodes` usa `.episode-card`; `getVideoSources` = Camada A → B. |
| `lib/core/sources/dooplay_adapter.dart` | ganha o caminho "mvp direct" quando `type=mp4`; **mantém o fluxo betteranime legado** (P8). |
| `lib/data/models/anime.dart`, `source_registry.dart` | novos `AnimeSource` + registry/priority. Prioridade deve **reavaliar** com fan-out (a CDN é direta, sem anúncio; mas hoje os testes mostram muitos episódios sem source válido → não subir antes do AnimeFire sem métrica, ver P12). |
| `lib/data/models/episode.dart` | `VideoSource(headers)` já pronto (Referer/UA p/ CDN). Sem mudança. |

Nenhuma mudança em `AnimeRepository.resolveProvidersForEpisode` / `AnimeScraper` —
adapters entram como `implemented` e participam do fan-out.

---

## Parte 5 — Fases de implementação (revisadas)

### Fase 0 — Diagnósticos finais (fechar antes de codar)
- Confirmar `play_method` em todos os episódios dos 4 clones (P3 validado ⇒
  animeplay entra no cluster). Probar 3–4 animes de média/longa duração.
- Definir se `betteranime` ganha realce de "mvp direct" **apenas** quando
  `source` for URL mp4 (não b64).
- animesonline.io / animesonline.blue / sushianimes / animes.tokyo /
  dattebayo-br / donghuanosekai → deixar como SPIKE documentado (não prometer).

### Fase 1 — Helpers compartilhados
1. `dooplay_v2_extractor.dart`: iteração de opções + transporte duplo +
   decode-único + probe 206. Testes com `MockClient` para:
   - 1ª opção iframe e 2ª mp4 (Solo Leveling / Jujutsu).
   - `play_method=admin_ajax` (animeplay) e `wp_json` (cloud).
   - source com `%2520` / `%253A`.
   - todas as opções iframe/404 → `NoPlayableOption`.
2. `cdn_resolver.dart`: variantes + probe/cache. Testes com `MockClient`
   (porta 206/404), validação da matriz `OnePiece` vs `One Piece` vs padding.

### Fase 2 — Adapter do cluster
3. `animesonline_adapter.dart` (`baseUrls` p/ 4 clones + tradução de transporte).
4. Wire-up em `anime.dart` e `source_registry.dart`. Prioridade **inicial** como
   P5/P6 na ordem (acima de AnimePlayer, abaixo de DooPlay existente) até medir
   taxa de sucesso real (P12).

### Fase 3 — Fallback CDN
5. Camada B ligada no `getVideoSources` (único lugar), rate-limit serializado
   + cache (padrão AnimeFire).

### Fase 4 — Testes
6. Fixtures: HTML de busca/anime page/episódio (cloud + animeplay + jjw mp4) e
   JSON do dooplayer (todas as variantes: mp4, iframe, b64, `null`) e `-sd`.
7. `ptbr_adapters_test.dart` estendido (mock) cobrindo P1–P9.
8. `live_sources_probe_test.dart`: adicionar os 4 clones; validar que **nenhum
   `VideoSource` ofertado falha com 404** (regressão do P6).

### Fase 5 — QA (Fire Stick)
9. Buscar e reproduzir (via CDN): Kimetsu, Naruto Shippuden ep 220, One Piece
   Dublado, Solo Leveling — conferir seek (206) e log limpo.
10. Confirmar que fontes com anúncio nunca são acionadas p/ vídeo além do cupom.

---

## Parte 6 — Riscos e decisões abertas (revistos)

| Risco/Decisão | Impacto | Ação |
|---|---|---|
| `source=` morto/404 (OPM, episódios órfãos) | ep falha silenciosamente | probe 206 obrigatório; fallback p/ outras opções e Camada B; não expor 404 |
| Opções virarem todas `type=iframe` (SPA) | ep sem mp4 | tentar Camada B; senão reportar episódio ausente (não travar fan-out) |
| `play_method` muda (tema update) | clone inteiro morre | ler de `dtAjax` por request; config para forçar `wp_json` |
| Título CDN imprevisível | Camada B erra | Camada A primeiro; Camada B com variantes; cache de acertos |
| betteranime token base64 | extractor genérico devolve lixo | detectar `source` não-URL → delegar ao resolvedor legado (P8) |
| Busca ruidosa/filmes | bestMatch pega série errada | filtrar `/anime/` no `search`; penalizar ruído no `bestMatch` |
| Qualidade múltipla não rotulável | UI mostra "Auto/Alternativa" | expor múltiplas mp4 de hosts distintos sem labels rígidos |
| Prioridade vs fontes atuais | ordenação do seletor | decidir com métrica de sucesso P12; início conservador |

---

## Parte 7 — Critérios de aceite (revisados)

1. Cluster animesonline.cloud/drive/q.blog/animeplay resolve Kimetsu, Naruto
   Shippuden (ep alto), One Piece Dublado e Solo Leveling via mp4 (probe 206)
   no host e no Fire Stick.
2. **Nenhum `VideoSource` retornado tem URL que falhe no probe 206**
   (regressão explícita para OPM e órfãos).
3. `animeplay.cloud` participa do cluster via `admin_ajax` (P3 validado).
4. BetterAnime intacto: casos com `source` b64 seguem o fluxo legado (P8).
5. Fontes descartadas (smartanimes, animesonlinecc, SPIKEs) fora do fan-out com
   entrada no README.
6. `flutter analyze` limpo e testes de regressão verdes (incluindo novos
   fixtures mockando as variantes reais gravadas nesta validação).
7. UI/headless/qualidade intactos (nenhuma mudança fora dos adapters).

---

## Parte 8 — Evidências técnicas (para os fixtures/tests)

- Página de episódio (cloud) contém `N` opções:
  `player-option-1..N class='dooplay_player_option' data-type='tv' data-post='<ID_EP>' data-nume='1..N'`.
- `data-post` é do episódio: Solo Leveling ep1 = **1559**; Naruto ep1 = **70682**,
  **ep220=71049**; One Piece ep1 = **73213**; Kimetsu ep1 = **5301**.
- `dtAjax.play_method`: cloud/drive/q.blog=`wp_json`; animeplay=`admin_ajax`.
- JSON `type=mp4` (cópias literais):
  - `embed_url=https://animesonline.cloud/jwplayer?source=https%3A%2F%2Fmangas.cloud%2FAnimes%2FLetra-N%2FNaruto-Shippuuden%2F01.mp4&id=70682&type=mp4`
  - `embed_url=.../Kimetsu%2520no%2520Yaiba%253A%2520Hashira%2520Geiko-hen/01-sd.mp4...`
- JSON `type=iframe`:
  - `embed_url=https://www.blogger.com/video.g?token=AD6v5...` (SPA)
  - `embed_url=https://animeshd.cloud/#e9ntgf`
  - `embed_url=https://animes.strp2p.com/#osl9to`
- `data-nume` aparece também como `data-nume='1'..'4'` na página do episódio —
  nume é **opção**, não ep.
- Probes válidos (206): `mangas.cloud/Animes/Letra-N/Naruto-Shippuuden/01.mp4`,
  `mangas.cloud/Animes/Letra-S/Solo Leveling/01.mp4`,
  `mangas.cloud/Animes/Letra-O/One Piece Dublado/001.mp4` (padding 3),
  `animeflix.blog/Animes/Letra-O/One Piece Fan Letter/01.mp4`,
  `animeflix.blog/Animes/Letra-K/Kimetsu no Yaiba: Hashira Geiko-hen/01-sd.mp4`,
  `cldup.com/L0lfbQPB3R.mp4`.
- Probes mortos (404): `One Punch`/`One Punch Man` (todas as variantes),
  `OnePiece/010.mp4` (folder `OnePiece` só admite `01.mp4`? conferido 206 em `01`,
  404 em `010`), `mangas.cloud/.../001-sd.mp4`, `One Piece/01.mp4`.
  → Matriz de variantes precisa incluir **padding igual ao do arquivo real**
    apenas como tentativa; a Camada A é quem manda.

---

## Nota final
O plano original acertou no essencial (existe CDN direta; a família dooplay-clone
é a maior oportunidade; recomendo `source=` acima de reconstruir caminho). Mas a
implementação cega revela **três braçadeiras**: (1) iteração de *player options*
com transporte por `play_method`, (2) **probe 206 obrigatório também na Camada A**
e (3) `betteranime` não pode ser refatorado para "extrair source" sem detectar o
token b64. Com essas três correções o plano vira executável; sem elas, episódios
que hoje funcionam (Kimetsu, Naruto, One Piece Dublado) quebrariam nos primeiros
casos fora de One Piece/Black Clover.