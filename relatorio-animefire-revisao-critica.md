# Revisão crítica — relatório AnimeFire (`480p/720p/1080p` + "não carrega")

Data da revisão: 10/09/2026. Objeto: `relatorio-animefire-qualidade-nao-carrega.md` (mesmo dia).
Método: re-probes ao vivo + releitura do código + docs mpv. Nada foi alterado no código.
Veredito geral: **o diagnóstico do botão único está correto; o diagnóstico de temporada acerta o sintoma mas erra o mecanismo e o plano; o bloco de playback DASH contém 1 sugestão que provavelmente quebra (propriedade inexistente) e 1 descarte prematuro de causa.**

---

## 1. Veredito por alegação do relatório anterior

| # | Alegação anterior | Status | Resumo do problema na alegação |
|---|---|---|---|
| A1 | `join('/')` em `anime_fire_adapter.dart:244` causa o botão único | **Confirmado** | Nenhum erro. Prova com Solo Leveling S1E1 (`["480p","720p","1080p"]`) procede. |
| A2 | `qualityScore` captura o 1º número → 480 | **Confirmado** | Correto. |
| A3 | URL é DASH adaptativo único; correto é 1 fonte por áudio | **Direção certa, proposta incompleta** | Sugestão `'1080p · Auto'` como hint assume ordem e reintroduz número fantasioso; não trata perda de seleção manual nem limitação do modelo `VideoSource` (§3). |
| A4 | "Não carrega" = `number` por temporada vs. absoluto; `max=61` vs 219 entradas (Naruto) | **Sintoma confirmado, mecanismo incompleto, generalização indevida** | Prova com 1 anime só; ignorou o campo que resolve o problema: `seasons[].first_episode_number` (§2). Exemplo "EP 53 por coincidência" estava errado — o match ingênuo devolve episódio *totalmente* errado, não "por sorte funciona". |
| A5 | Plano: casar por índice ordenado; `_episodeCountFromProviders`: "somar por temporada ou usar `length` quando `max < length`" | **Errado / perigoso se implementado** | Índice ordenado toca episódio errado em silêncio quando AniList ≠ API (filmes, especiais, faltas); heurística `max<length` reintroduz o bug de paginação que o commit `33400dc` acabara de fechar (§2.4). |
| A6 | `sort` de episódios irrelevante | **Omissão** | `getEpisodes` ordena só por `number` (`l.191-192`), embaralhando temporadas iguais — destrói até a base do fix por índice e precisa ser corrigido junto (§2.3). |
| A7 | Setar `dash-bitrate` no player; `hls-bitrate` é no-op para DASH | **Sugestão errada** | Não existe `dash-bitrate` para DASH nativo (ffmpeg `dash` demuxer faz ABR próprio; `hls-bitrate` é do gancho ytdl/HLS — docs mpv §4). `setProperty` em propriedade inexistente pode lançar/retornar erro no `media_kit` (§4). |
| A8 | Headers descartados como causa (curl 200 com/sem `Referer`) | **Descarte prematuro** | curl prova o CDN, não o mpv: nada garante que `Media(url, httpHeaders:)` propague headers aos segmentos DASH pedidos pelo demuxer ffmpeg (§4). |
| A9 | `completed` espúrio/`_gotPlayback` interage mal com DASH | **Especulação com confiança alta demais** | Sem log de device (`Completed event`, `videoParams`, `Duration`) não dá para afirmar; foi apresentado como risco concreto (§4). |
| A10 | `is_offline` descartado = "correto" | **Incompleto** | Não tratou UX ("só tem dublado" vs "falhou"), nem o `seen` por URL (colapsaria áudios se URLs coincidirem), nem que `search` descarta `audio` (inviabiliza o plano "ponderar áudio no match") (§5). |
| A11 | "Ponderar `audio`/`season` no `bestMatch`" | **Inexequível como escrito** | `search` (`l.99-112`) não persiste `audio`; o match não tem de onde ponderar sem mudar modelo/fluxo (§5). |
| A12 | Cache não mencionado no plano | **Omissão** | `AppCaches.resolutions` TTL 30 min (`app_caches.dart:39-42`) manteria rótulos `join` e resoluções vazias/erradas pós-deploy sem invalidação (§5). |
| A13 | Fallback de grade "morde com frequência" com AnimeFire em 1º | **Exagerado** | Fallback só roda com `anime.episodes` nulo/0 (`anime_repository.dart:90-91`); com AniList saudável é raro. AnimeFire ser prioridade 0 (`source_registry.dart:20-21,53-56`) aumenta exposição *quando* o fallback roda, não a frequência (§5). |

---

## 2. O erro mais importante: o campo `first_episode_number` existe — o plano antigo é desnecessário e perigoso

### 2.1 O que o relatório anterior perdeu

O payload `GET /anime/{id}` contém, além de `episodes[]`, o array `seasons[]` com o deslocamento absoluto. O relatório anterior documentou `episodes[]` e ignorou `seasons[]`.

Probes 10/09/2026:

**Naruto (`eU7t5IvcNKU`, 219 entradas):**

```json
"seasons": [
  {"number": 1, "first_episode_number": 1},
  {"number": 2, "first_episode_number": 53},
  {"number": 3, "first_episode_number": 105},
  {"number": 4, "first_episode_number": 159}
]
```

**Demon Slayer (`iG8UkXblGr_`, 56 entradas, `Counter({1:26, 2:18, 3:11, 4:1})`):**

```json
"seasons": [
  {"title": "Tanjiro Kamado, Arco de Determinação Inabalável", "number": 1, "first_episode_number": 1},
  {"title": "Arco do Trem Mugen e Arco do Distrito de Entretenimento", "number": 2, "first_episode_number": 27},
  {"title": "Arco da Vila do Espadachim", "number": 3, "first_episode_number": 45},
  {"title": "Arco de Treinamento Hashira", "number": 4, "first_episode_number": 56}
]
```

**Solo Leveling (`i0i1t0BT9B1`, 25 entradas):** 1 temporada, `first_episode_number: 1` (caso degenerado — por isso não sofre o bug).

Regra (validada nos 3: cobertura absoluta contígua — Naruto 1..219, DS 1..56):

```
absoluto = first_episode_number(season) + number - 1
```

Exemplos: Naruto abs 53 = S2E1 (53+1-1); abs 100 = S2E48; abs 219 = S4E61. DS abs 30 = S2E4.

### 2.2 Correção do exemplo "EP 53" do relatório anterior

O relatório dizia: "EP 53 existe por coincidência (S3/S4 têm 53)". **Errado.** O correto é S2E1. O match ingênuo (`number == "53"`) devolve o **primeiro** `number==53` da lista ordenada só-por-número (S3E53 ou S4E53, conforme estabilidade do sort) — episódio, temporada e arco completamente errados, sem nenhum sinal na UI. "Por sorte funciona" deveria ser "em silêncio toca o episódio errado". A gravidade foi subestimada.

### 2.3 Omissão do `sort`: `getEpisodes` embaralha temporadas

```dart
episodes.sort((a, b) =>
    (int.tryParse(a.number) ?? 0).compareTo(int.tryParse(b.number) ?? 0));
```

Com números repetidos por temporada, ordenar só por `number` agrupa todos os "1"s, todos os "2"s etc., destruindo a ordem `(season, number)` da API. Consequências que o plano antigo não viu:

- Qualquer fix "por índice na lista ordenada" operaria sobre lista já embaralhada.
- A ordem de exibição/debug da lista de episódios do provider perde o sentido.
- O `sort` precisa virar `(season, number)` — o que exige **guardar `season`**, coisa que o código atual descarta (`l.166-182` monta `Episode` sem campo de temporada).

### 2.4 Por que o plano antigo quebraria se implementado

| Proposta antiga | O que aconteceria na prática |
|---|---|
| Casar absoluto por **posição** na lista ordenada | Silenciosamente errado sempre que API ≠ AniList: filmes/OVAs/recaps como animes separados (`relations`), eps faltantes, especiais, diferenças de contagem (Naruto API 219 vs AniList 220). Trocar "não carrega" (visível) por "toca o episódio errado" (invisível) — regressão de severidade. |
| `_episodeCountFromProviders`: "usar `length` quando `max < length`" | Reabre o bug fechado em `33400dc`: provider com página parcial/paginada (`length` pequeno) vs. provider por-temporada (`max < length`) são indistinguíveis por essa heurística. O critério correto para AnimeFire é `seasons.last.first_episode_number + count(season.last) - 1` (ou `length` **somente** quando os offsets provarem cobertura contígua), nunca `length` genérico. |
| "Somar por temporada" (vago) | Sem os offsets, soma de contagens por temporada só acerta se não houver buraco; com offsets, a soma é redundante — o total é o fim da última temporada. A proposta mandava implementar a versão fraca do que a API já dá de graça. |

Plano correto (detalhes no §6): persistir `seasons[]` + `season` por episódio no adapter, mapear via `first_episode_number`, e **sobrescrever `resolveVideo` no `AnimeFireAdapter`** em vez de depender do default por `number`.

---

## 3. Rótulo `Auto`: direção certa, especificação errada

O relatório acertou o diagnóstico (1 manifesto = 1 fonte por áudio), mas a sugestão `'1080p · Auto'` como hint tem três defeitos:

1. **Assume ordem.** Nada no contrato garante `qualities` ascendente (observado ascendente em 5 probes, mas é amostra). "Maior = último" é heurística frágil; o correto é `max` via `qualityScore` sobre cada elemento, e mesmo assim só como hint.
2. **Reintroduz número fantasioso.** `'1080p · Auto'` sugere bitrate fixa; o manifesto é adaptativo (ffmpeg escolhe entre 2–8 Mbps conforme rede). Se a rede só sustenta 480p, o rótulo 1080p vira reclamação de "qualidade errada". `Auto` puro (+ áudio quando houver 2 streams) é honesto: `Auto · dublado` / `Auto · legendado`, `Auto` quando stream único.
3. **Esconde a perda real de função.** Hoje o usuário *acha* que escolhe bitrate; com DASH nativo ele nunca escolheu (as N opções seriam o mesmo URL). O modelo `VideoSource {url, quality, headers}` (`episode.dart:50-60`) não carrega opção mpv por fonte, então "1 botão por qualidade com mesmo URL" seria placebo — todos abririam o mesmo manifesto com o mesmo ABR. Se seleção manual for requisito, o trabalho é no **player** (faixa/representação via mpv), não no rótulo. O relatório anterior vendeu troca de rótulo como restauração de função.

Adicional não mencionado antes: o `seen` por URL (`l.234,238`) usa só `url` como chave. Se dois áudios um dia compartilharem URL (não observado, mas o esquema `akumast.net/i/.../m.jpg` é opaco), o segundo áudio seria descartado em silêncio. A chave deveria ser `(url, audio)` ou o descarte deveria logar.

---

## 4. Playback DASH: 1 sugestão errada + 1 descarte prematuro + especulação

### 4.1 `dash-bitrate` (sugestão do relatório anterior — NÃO implementar)

O relatório sugeriu "setar `dash-bitrate` junto do `hls-bitrate`". Verificação contra docs mpv (10/09/2026):

- `hls-bitrate` existe e serve à **seleção de faixas via gancho ytdl/HLS** (`ytdl_hook.lua`: `set hls-bitrate for dash track selection` — contexto youtube-dl, `all_formats`, `use_manifests`). Para DASH nativo aberto direto (nosso caso: URL do manifesto no `Media`), quem demuxa é o demuxer `dash` do lavf/ffmpeg, com ABR próprio — `hls-bitrate` é no-op.
- Não há `dash-bitrate` como propriedade de runtime para DASH nativo nos docs/options do mpv. `NativePlayer.setProperty` (`player_screen.dart:270-272`) em propriedade inexistente é, no melhor caso, no-op; no pior, erro propagado ou throw no `media_kit` — ou seja, a "correção" pode introduzir crash/regressão no open de **todos** os providers, não só AnimeFire.

Correção: **remover a expectativa sobre `hls-bitrate`** (manter ou remover a chamada é decisão de risco — hoje é harmless no-op para DASH e útil para HLS de outros providers; não mexer sem teste em device) e **não adicionar `dash-bitrate`**. ABR do DASH fica com o ffmpeg; documentar que a bitrate inicial é conservadora e sobe sozinha.

### 4.2 Headers: curl ≠ mpv (descarte prematuro)

Probes novos: manifesto **sem** `Referer` também retorna `200 application/dash+xml` (3538 B, igual ao com `Referer`); segmento sem `Referer` retorna `200 image/jpeg` (200 395 B). Isso prova o CDN, **não** o cliente. O app abre o manifesto via `Media(src.url, httpHeaders: {User-Agent, Referer})` (`player_screen.dart:273-279`); os segmentos subsequentes são pedidos pelo demuxer ffmpeg dentro do mpv — nada no código garante que esses `httpHeaders` sejam reaplicados a cada segmento. Em CDNs que validam `Referer`/`User-Agent` por segmento, o manifesto abriria e o vídeo travaria no 1º segmento (sintoma idêntico a "não carrega": spinner → timeout 20 s → erro). Aqui o CDN aceita sem headers, então o risco é baixo **neste** CDN, mas a inferência "descartado como causa" é inválida como método — precisa de teste em device (log de banda/segmento ou `videoParams` ausente com manifesto 200).

### 4.3 `completed`/`_gotPlayback`/timeout com fonte única (especulação)

O relatório apresentou como risco concreto que a lógica anti-`completed`-espúrio (escrita para mp4 `lightspeedst.net`, `player_screen.dart:76-81,356-372`) "pode interagir mal" com DASH. Sem `adb logcat` com as linhas `[Player] Completed event / videoParams / Duration / Loading timeout`, isso é hipótese — e DASH tem timing sabidamente diferente (manifesto resolve rápido, `duration` só após demux, `playing` após 1º segmento). Manter como **pergunta aberta para instrumentação**, não como causa. O ponto estrutural que *é* fato: com 1–2 fontes, `_advanceSource` (`l.430-435`) não tem para onde avançar — timeout/erro vira erro final direto. Isso é desenho, não bug, mas explica por que AnimeFire "não carrega" de forma binária enquanto concorrentes com N mp4s degradam gradualmente.

---

## 5. Omissões que o plano antigo deixaria quebradas

1. **Cache pós-fix.** `AppCaches.resolutions` (TTL 30 min, `app_caches.dart:39-42`) guarda o mapa provider → fontes **só no happy-path** (`anime_repository.dart:281-284`), ou seja, rótulos `join` antigos sobrevivem até 30 min após o deploy do fix, e `catalog` (24 h) pode segurar grade subcontada. O plano precisa versionar a chave ou limpar `resolutions`/`catalog` de AnimeFire no upgrade — senão o usuário testa o fix e "continua quebrado" até o TTL expirar.
2. **`search` descarta `audio`.** O plano "ponderar áudio no `bestMatch`" é inexequível: `search` (`l.99-112`) persiste só `name/url/fallbackImageUrl`; `bestMatch` (`anime_source_adapter.dart:98-153`) nunca vê `audio`. Exigiria carregar `audio` no modelo `Anime` ou segunda chamada — custo não orçado. Sem isso, dublado/legendado continuam indistinguíveis no match (a API informa `audio: "Dublado & Legendado"` na busca, hoje jogado fora).
3. **Frequência do fallback exagerada.** O fallback `_episodeCountFromProviders` só executa com `anime.episodes` nulo/0 (`anime_repository.dart:90-91`). Com AniList saudável, a grade 1..N nunca consulta o AnimeFire para contar. A prioridade 0 do AnimeFire (`source_registry.dart:20-21`) amplia o estrago *nas* vezes em que o fallback roda (lançamentos, falha de enriquecimento), não "morde com frequência". O relatório anterior inverteu condicionante e consequente.
4. **Cobertura de testes insuficiente nos dois eixos.** Fixtures com `qualities: ["480p"]` (`resolve_provider_states_test.dart:32-38`) e `quality_picker_test.dart` só com rótulos simples deixam o branch multi-quality e o mapeamento por temporada sem cobertura — o plano de testes precisa dos dois fixtures (multi-quality + 2 temporadas com offsets), não só do primeiro.
5. **Casos não probados.** Filmes/OVAs como animes separados, `is_mtl`, `chapters`/`thumbnails`, paginação da busca (`links`/`meta` presentes no payload), 429/Cloudflare sob fan-out (o throttle de 250 ms é global ao adapter, mas o fan-out é paralelo entre providers — rajada contra a API em `partial` + prefetch pode estourar). Nenhum deles invalida o diagnóstico, mas nenhum foi verificado — o relatório anterior não marcou esses limites.

---

## 6. Plano de correção revisado (substitui o §7 do relatório anterior)

**Não fazer (riscos do plano antigo):** ❌ fatiar o mesmo manifesto em N `VideoSource`s por qualidade; ❌ `dash-bitrate`; ❌ mapeamento absoluto por posição; ❌ heurística `max < length → length`; ❌ "ponderar áudio no match" sem persistir áudio.

1. **Adapter — rótulo honesto (risco baixo).** `anime_fire_adapter.dart:239-254`: remover `join('/')`; 1 `VideoSource` por stream com URL válida; `quality = raw.length > 1 && audio.isNotEmpty ? 'Auto · $audio' : 'Auto'`. Chave de dedup `(url, audio)`. Manter descarte de `url` vazia/`is_offline` (comportamento correto). Logar descartes em `debugPrint` para distinguir "só tem dublado" de "falhou".
2. **Adapter — temporadas via offsets (risco médio, o fix real do "não carrega").** Persistir `seasons[]` (`number`, `first_episode_number`) do `GET /anime/{id}` e `season` por `Episode` (estender modelo interno ou carregar no `owner`/URL — sem mudar `CatalogEpisode`); ordenar episódios por `(season, number)` em vez de só `number`; **sobrescrever `resolveVideo` no `AnimeFireAdapter`**: `alvoAbsoluto → (season, number) = inverso de first_episode_number + number - 1` e então `getVideoSources` do `episodeId` correspondente. Fallback: se `seasons` ausente, comportamento atual (match por `number`) + log — nunca posição cega.
3. **Contagem de grade (risco baixo).** No caminho AnimeFire de `_episodeCountFromProviders`, preferir `seasons.last.first_episode_number + count(episódios da última temporada) - 1` quando `seasons` presente; senão `max(number)` atual. Não tocar a lógica dos demais providers.
4. **Player — não mexer em bitrate; instrumentar (risco baixo).** Não adicionar `dash-bitrate`; manter `hls-bitrate` como está (no-op para DASH, útil para HLS alheio). Em device, validar com `adb logcat`: `videoParams`, `Duration`, `Completed event`, `Loading timeout`, `Ignoring spurious completed`. Se DASH não abrir por extensão `.jpg`, avaliar override de demuxer/extensão no `media_kit` — só com evidência.
5. **Cache + migração (risco baixo, esquecido antes).** Versionar chave de `resolutions`/`catalog` para AnimeFire ou `clearByHost('animefire')`/`clear()` no primeiro boot pós-fix, para não servir rótulos `join` por 30 min.
6. **Testes (obrigatório).** Fixture multi-quality (`["480p","720p","1080p"]` + `["480p","720p"]` + 1 offline `url:null`) com asserts `!contains('/')`, contagem 2, rótulos `Auto`; fixture 2 temporadas com `first_episode_number` (ex.: S1→1, S2→53) com asserts `resolveVideo(53) == S2E1-id` e `resolveVideo(100) == S2E48-id`; `qualityScore('Auto · dublado') == 0`. Não quebrar `live_*` probes.

---

## Anexos — o que mudou em relação ao relatório anterior e onde verificar

- `lib/core/sources/anime_fire_adapter.dart` — l.24-26 (contrato), l.99-112 (`search` descarta `audio`), l.140-202 (`getEpisodes`: perde `season` l.166-182, sort só-por-`number` l.191-192), l.233-255 (`getVideoSources`: `join` l.244, dedup só-URL l.234/238)
- `lib/core/sources/anime_source_adapter.dart` — l.65-90 (`resolveVideo` default), l.98-153 (`bestMatch`, bônus morto l.129-133)
- `lib/core/utils/quality_picker.dart` — l.10-42 (scores; 1º número)
- `lib/data/repositories/anime_repository.dart` — l.90-91 (quando o fallback roda), l.133-164 (contagem), l.205-351 (fan-out), l.281-284 (só happy-path cacheia)
- `lib/core/sources/source_registry.dart` — l.20-21 (ordem), l.53-86 (prioridades; AnimeFire 0)
- `lib/core/cache/app_caches.dart` — l.33-42 (TTLs 24 h catalog / 30 min resolutions)
- `lib/features/detail/detail_screen.dart` — l.1475-1500 (1 botão por fonte), l.1484-1487 ("Melhor qualidade")
- `lib/features/player/player_screen.dart` — l.205-225 (sort+índice), l.253 (timeout 20 s), l.267-279 (`hls-bitrate` + open), l.356-435 (`completed`/`error`/`_advanceSource`), l.1232-1295 (seletor)
- `test/resolve_provider_states_test.dart` — l.32-38 (fixture só `["480p"]`); `test/quality_picker_test.dart` (sem caso `/`)
- Evidências novas: `GET /anime/eU7t5IvcNKU` (`seasons` 1/53/105/159, 219 eps, cobertura 1..219 contígua), `GET /anime/iG8UkXblGr_` (`seasons` 1/27/45/56, 56 eps, cobertura 1..56), `GET /anime/i0i1t0BT9B1` (1 temporada), `GET /episode/xVkmI3eoCtD` (multi-quality), manifesto `akumast.net/.../m.jpg` `200 dash+xml` com e sem `Referer`, 4 representações (480/720/1080 + áudio `pt`), segmento `200 image/jpeg` com e sem `Referer`; docs mpv (`hls-bitrate` = trilha ytdl/HLS, sem `dash-bitrate` para DASH nativo)
