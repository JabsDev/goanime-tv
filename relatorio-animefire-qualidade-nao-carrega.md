# Relatório — AnimeFire: botão único `480p/720p/1080p` + "não carrega"

Data da investigação: 10/09/2026 (probes ao vivo contra `api.animefire.io` + leitura de código).
Escopo: somente diagnóstico. Nenhum código foi alterado.
Relatório anterior (contexto): `relatorio-bugs-episodios-animefire.md` (09/09/2026) — migração do site para SPA + API.

---

## TL;DR

1. **Botão único `480p/720p/1080p` — causa raiz encontrada, 100% reproduzível em código:** `lib/core/sources/anime_fire_adapter.dart:244` faz `qualities.join('/')`. Quando a API devolve um stream com `qualities: ["480p","720p","1080p"]`, o adapter cria **1 único `VideoSource`** com `quality: "480p/720p/1080p"`. O diálogo de qualidade (`detail_screen.dart:1490-1500` e `player_screen.dart:1247-1289`) renderiza 1 botão por `VideoSource` — logo, 1 botão com o texto concatenado. Verificado ao vivo: Solo Leveling S1E1 dublado retorna exatamente esse array (ver §2).
2. **O `join('/')` é conceitualmente errado:** a URL do stream é um **manifesto DASH adaptativo único** (`content-type: application/dash+xml`, servido como `/m.jpg` em `akumast.net`) contendo as 3 representações (480p/720p/1080p) + áudio dentro dele (ver §3). Não existem 3 URLs — fatiar o mesmo URL em 3 botões não faria sentido; o correto é **1 fonte por áudio com rótulo "Auto/Adaptativo"** (ou a maior qualidade como hint), deixando o mpv adaptar.
3. **Efeito colateral do `join` no auto-picker:** `qualityScore("480p/720p/1080p")` (`quality_picker.dart:35-42`) captura o **primeiro** número via regex (`480`), então o "Melhor qualidade" (`detail_screen.dart:1486`) e o `sortBestFirst` (`player_screen.dart:211`) pontuam o manifesto multi-bitrate como se fosse 480p. Com fonte única, `bestQualityIndex` é no-op (`length <= 1 → 0`).
4. **"Não carrega" — causa raiz principal (provada): numeração por temporada vs. absoluta.** `getEpisodes` (`anime_fire_adapter.dart:165-193`) descarta `season` e guarda só `number`; `resolveVideo` (`anime_source_adapter.dart:65-90`) casa por `int.tryParse(e.number) == episodeNumber` (número absoluto do catálogo AniList). Em animes multi-temporada a API numera **por temporada** (ex.: Naruto: 219 entradas, `max(number) = 61`, ver §4). Qualquer episódio absoluto > 61 **nunca casa** → `[]` → `matchedUnavailable` → diálogo "Episódio sem vídeo disponível" / player "Não foi possível carregar o vídeo". Isso é independente da qualidade e explica "não carrega" mesmo quando o manifesto está saudável.
5. **"Não carrega" — agravantes do playback DASH (hipóteses a confirmar no aparelho, ver §5):** manifesto com extensão `.jpg` (detecção de demuxer do mpv por extensão vs. `content-type`), `_playSource` (`player_screen.dart:270-272`) só força `hls-bitrate=highest` (nada para DASH), timeout de 20 s com **fonte única = sem fallback** (`_advanceSource` retorna cedo quando `index == length-1`), e streams `is_offline:true` com `url:null` que o adapter descarta corretamente mas que reduzem as opções de áudio (ex.: Naruto S1E51 legendado offline → só dublado sobrevive).
6. **Por que os testes não pegaram:** fixtures em `test/resolve_provider_states_test.dart:32-38` usam sempre `qualities: ["480p"]` — o branch multi-quality do `join` nunca é exercitado; `quality_picker_test.dart` só testa rótulos simples (`480p`, `1080p`, `Auto`).

---

## 1. Fluxo completo (onde cada sintoma aparece)

```
DetailScreen (grade 1..N do AniList)
  → tap no EP → _ProviderQualityDialog (_resolveProviders, detail_screen.dart:1128)
    → AnimeRepository.resolveProvidersForEpisode(anime, N, partial:true) (anime_repository.dart:205)
      → AnimeFireAdapter.resolveAnime → search (api /animes/pesquisar)
      → AnimeFireAdapter.getEpisodes (api /anime/{id}) → lista Episode(number, url=/episode/{epId})
      → AnimeFireAdapter.resolveVideo(match, N): casa number == N (anime_source_adapter.dart:71)
      → AnimeFireAdapter.getVideoSources → GET /episode/{epId} → streams[] → List<VideoSource>
    → diálogo renderiza: 1 seção "Fonte" por provider + 1 botão "Melhor qualidade"
      + 1 botão por VideoSource (detail_screen.dart:1475-1500)  ← BOTÃO ÚNICO AQUI
  → tap na qualidade → PlayerScreen(initialSources, initialIndex) (detail_screen.dart:1199)
    → sortBestFirst + _playSource(index) (player_screen.dart:205-217, 227)
    → seletor de qualidade no player (player_screen.dart:1232-1295)  ← BOTÃO ÚNICO AQUI TAMBÉM
```

Cada `VideoSource` = `{url, quality, headers}` (`episode.dart:50-60`). O texto do botão é literalmente `src.quality`. Logo, qualquer concatenação no adapter vira concatenação na UI, sem mais transformação.

---

## 2. Causa do botão único — evidência ao vivo + código

### 2.1 Código

`lib/core/sources/anime_fire_adapter.dart:239-254`:

```dart
final qualities = (item['qualities'] is List)
    ? (item['qualities'] as List).map((q) => q.toString()).toList()
    : const <String>[];
// Rótulo numérico ("480p") para o quality picker pontuar; áudio
// (dublado/legendado) vai junto quando há mais de um stream.
var quality = qualities.isNotEmpty ? qualities.join('/') : 'Auto';  // <-- BUG
```

Intenção original do comentário era dar um "rótulo numérico para o picker pontuar", mas `join('/')` produz o oposto: um rótulo multi-numérico que o picker pontua errado (ver §2.3).

### 2.2 Payloads reais (10/09/2026)

| Anime / episódio | `GET /episode/{id}` → `streams[]` | O que o adapter gera hoje |
|---|---|---|
| Naruto S1E1 (`WCrJufyJmQn`) | dublado `qualities: ["480p"]`, legendado `qualities: ["480p"]` (2 URLs distintas) | 2 fontes: `480p · dublado` / `480p · legendado` — correto por acidente |
| Naruto S1E51 (`8NP5APooc5O`) | dublado `["480p"]` url válida; legendado `is_offline:true, url:null, qualities:["480p"]` | 1 fonte (offline descartada em l.238: `if (url.isEmpty ...) continue`) |
| **Solo Leveling S1E1 (`xVkmI3eoCtD`)** | **dublado `["480p","720p","1080p"]`** (1 URL), legendado `["480p","720p"]` (1 URL) | **1 fonte `480p/720p/1080p · dublado` + 1 fonte `480p/720p · legendado`** — o sintoma reportado |
| Solo Leveling E13 / E25 | dublado `["360p","720p"]`, legendado `["480p","720p"]` | `360p/720p · dublado`, `480p/720p · legendado` |

Comandos usados (reproduzíveis):

```bash
curl -s -A "Mozilla/5.0" -H "Accept: application/json" \
  "https://api.animefire.io/animes/pesquisar?q=solo%20leveling" -o /tmp/af_search2.json
curl -s -A "Mozilla/5.0" -H "Accept: application/json" \
  "https://api.animefire.io/anime/i0i1t0BT9B1" -o /tmp/af_solo.json
curl -s -A "Mozilla/5.0" -H "Accept: application/json" \
  "https://api.animefire.io/episode/xVkmI3eoCtD"
```

Animes antigos/upscales SD (Naruto dublado, 480p único) **não** exibem o bug — por isso o relato parece intermitente: só títulos com encode multi-bitrate (lançamentos recentes) mostram o botão concatenado.

### 2.3 Efeito no `quality_picker`

`lib/core/utils/quality_picker.dart:35-42`:

```dart
int qualityScore(String quality) {
  final n = RegExp(r'(\d{3,4})').firstMatch(quality);  // pega o PRIMEIRO número
  ...
}
```

Simulação (código real, executado na investigação):

| Rótulo | `qualityScore` |
|---|---|
| `480p/720p/1080p` | **480** (deveria ser 1080) |
| `480p/720p/1080p · dublado` | **480** |
| `480p` | 480 |
| `Auto` | 0 |

Consequências:

- `bestQualityIndex` (`quality_picker.dart:10-22`) com fonte única retorna `0` sem comparar nada.
- `sortBestFirst` (`quality_picker.dart:27-33`) ordena pelo score errado; com 2 áudios multi-bitrate (ex.: `480p/720p` legendado = 480 vs `360p/720p` dublado = 360) a ordem "melhor primeiro" fica arbitrária.
- O atalho "Melhor qualidade" (`detail_screen.dart:1484-1487`) herda o erro.

---

## 3. O stream é DASH adaptativo — por que 1 URL é o comportamento certo

Probe do manifesto (Solo Leveling S1E1 dublado, 10/09/2026):

```bash
URL=$(python3 -c "import json; ...")  # streams[0].url (akumast.net/.../m.jpg)
curl -s -I -A "Mozilla/5.0" -H "Referer: https://animefire.io/" "$URL"
# → HTTP/2 200, content-type: application/dash+xml

curl -s -A "Mozilla/5.0" -H "Referer: https://animefire.io/" "$URL" -o /tmp/af_manifest.bin
# → MPD static, duration PT1420.003S, SegmentTemplate .../$RepresentationID$/$Number$.jpg
```

Representações dentro do MPD:

| `Representation id` | `mimeType` | Resolução | `bandwidth` |
|---|---|---|---|
| `E6PAQQDsHAI` | video/mp4 (avc1.64001f) | 854×480 | 2 111 798 |
| `E6DAQQDsHAI` | video/mp4 | 1280×720 | 3 628 622 |
| `E6HAQQDsHAI` | video/mp4 | 1920×1080 | 8 718 454 |
| `E6PAVgDsHAI` | audio/mp4 (mp4a.40.2, 44100 Hz) | — (lang `pt`) | 130 014 |

Ou seja: `qualities: ["480p","720p","1080p"]` **descreve as representações dentro do manifesto**, não URLs alternativas. O player adaptativo (mpv) escolhe a bitrate sozinho. Segmentos funcionam com e sem `Referer` (probe retornou `200 image/jpeg`, 200 395 bytes no segmento 1 — o `.jpg` é disfarce; o conteúdo é segmento `stypmsdh/sidx`, i.e. mp4 fragmentado).

Implicação para a correção: o adapter deve emitir **1 `VideoSource` por áudio** (`Dublado` / `Legendado`, ou `Auto · dublado`), nunca 1 por qualidade nem 1 com rótulo concatenado. (Sugestões concretas no §7.)

---

## 4. "Não carrega" — numeração por temporada (causa provada, independente da qualidade)

### 4.1 Código

- `getEpisodes` (`anime_fire_adapter.dart:166-193`): guarda `number` da API, **descarta `season`**.
- `resolveVideo` default (`anime_source_adapter.dart:65-90`): `if (int.tryParse(e.number) == episodeNumber)` — compara com o número **absoluto** do catálogo (AniList, grade 1..N).
- `_episodeCountFromProviders` (`anime_repository.dart:146-154`): usa `max(number)` — correto para lista absoluta, errado para lista por-temporada.

### 4.2 Prova com Naruto (`eU7t5IvcNKU`, 10/09/2026)

`GET /anime/eU7t5IvcNKU` → 219 episódios distribuídos por temporada: `{1: 52, 2: 52, 3: 54, 4: 61}` (números repetem por temporada). `unique(numbers) = 61`, `max = 61`, `total = 219`.

| Ep absoluto tocado (grade AniList) | Existe `e.number == N` na API? | Resultado no app |
|---|---|---|
| 1, 52 | sim | resolve |
| 53 | sim por coincidência (S3 tem 53, S4 tem 53…) — mas pode abrir o **episódio errado** (primeiro match do loop, sem considerar `season`) | vídeo errado ou "funciona" por sorte |
| 62, 100, 219 | **não** (`None`) | `resolveVideo → []` → `matchedUnavailable` → "Episódio sem vídeo disponível" / "Não foi possível carregar" |

Ou seja: em qualquer anime com >1 temporada e numeração reiniciada, **todos os episódios além do tamanho da maior temporada falham sempre**, e episódios com número repetido podem resolver para a temporada errada. Solo Leveling (25 eps, 1 temporada) não sofre — por isso o bug parece "só alguns animes não carregam".

Nota: o fallback de grade também subconta nesses casos — se `anime.episodes` (AniList) estiver nulo e o primeiro provider a responder for o AnimeFire, a grade nasce com 61 em vez de 219.

---

## 5. "Não carrega" — agravantes de playback DASH (a confirmar no aparelho)

Estes **não foram provados sem um device** (não há player aqui), mas são riscos concretos lidos no código + probes, listados para verificação com `adb logcat` / logs `[Player]`:

1. **Extensão `.jpg` vs. demuxer:** a URL termina em `/m.jpg` mas serve `application/dash+xml`. O comentário no adapter (`l.19-21`: "mpv handles it") assume sniffing correto. Se o mpv da build (`media_kit` + `media_kit_libs_android_video`) priorizar extensão, o open pode falhar ou demorar até o timeout de 20 s (`player_screen.dart:253`). **Verificar:** log `videoParams resolution` (`player_screen.dart:308`) e `Duration` (`l.334`); ausência de ambos + `Loading timeout for source` (`l.254`) após 20 s indica falha de demux.
2. **`hls-bitrate` sem equivalente DASH** (`player_screen.dart:267-272`): o código força `hls-bitrate=highest` (HLS), mas o stream AnimeFire é DASH (`dash-bitrate` no mpv). No-op aqui — provavelmente só começa em bitrate conservadora, não "não carrega", mas vale alinhar na correção.
3. **Fonte única = sem rede de segurança:** `_advanceSource` (`player_screen.dart:430-435`) retorna cedo se `index == length-1`. Com 1–2 fontes AnimeFire (vs. N mp4s dos concorrentes), timeout/erro/completed-com-`dur=0` (`l.359-372`) cai direto em "O servidor não está respondendo" (`l.260`). O tratamento de `completed` espúrio (`_gotPlayback`, `l.367`) foi escrito para mp4 `lightspeedst.net` — manifesto DASH tem timing de `Playing`/`duration` diferente e pode interagir mal (a confirmar em log `Completed event` / `Ignoring spurious completed`).
4. **Streams offline:** `is_offline:true, url:null` (visto em Naruto S1E51 legendado, S2E49 legendado) são descartados (`l.238`) — correto, mas significa que para esses eps **só existe dublado**. Se o usuário espera legendado, a ausência é "não carrega" do ponto de vista dele. O app não distingue "só tem dublado" de "falhou".
5. **Headers nos segmentos:** descartado como causa — segmentos retornam `200` com e sem `Referer` (probe §3). Os headers do `VideoSource` (`User-Agent`, `Referer`, `anime_fire_adapter.dart:250-253`) bastam para o manifesto; os segmentos são abertos pelo mpv sem bloqueio.

---

## 6. Como reproduzir

### Botão único (determinístico, sem device — só API + teste unitário)

1. `GET https://api.animefire.io/episode/xVkmI3eoCtD` (Solo Leveling S1E1) → observar `streams[0].qualities == ["480p","720p","1080p"]`.
2. Passar esse payload por `AnimeFireAdapter.getVideoSources` (ou ler `l.244`): `quality == "480p/720p/1080p"`.
3. Renderizar `providers[selected]` em `_buildProviderSelector` (`detail_screen.dart:1490`): 1 `_QualityItem` com esse texto (+ 1 para legendado `480p/720p`).
4. No aparelho: buscar "Solo Leveling" → EP 1 → fonte AnimeFire → seção Qualidade mostra "Melhor qualidade" + `480p/720p/1080p · dublado` (+ `480p/720p · legendado`) em vez de `1080p / 720p / 480p` ou `Auto`.

### Não carrega por temporada (determinístico)

1. Buscar "Naruto" → `GET /anime/eU7t5IvcNKU` → 219 entradas, números por temporada.
2. Tocar EP 100 (grade AniList) → `resolveVideo(match, 100)` → loop `l.70-75` não acha `number == "100"` → `[]` → `matchedUnavailable` → "Episódio sem vídeo disponível".
3. Mesmo fluxo para qualquer anime multi-temporada com N absoluto > max(temporada).

---

## 7. Plano de correção sugerido (não executado)

1. **Adapter — 1 fonte por áudio, rótulo adaptativo** (`anime_fire_adapter.dart:233-255`): remover o `join('/')`; emitir `quality: 'Auto'` (ou `'Auto · dublado' / 'Auto · legendado'` quando `raw.length > 1`, ou a maior qualidade como hint, ex. `'1080p · Auto'`). Manter o descarte de `url` vazia/`is_offline` (comportamento atual correto). Opcional: expor `qualities` cruas em campo separado para debug, sem poluir o rótulo.
2. **Temporadas** (prioridade igual ao item 1 — é o "não carrega" real): guardar `season` no `Episode` (ou codificar `url`/`owner` com `season+number`), e dar ao `AnimeFireAdapter` um `resolveVideo` que mapeie número absoluto → (temporada, número-na-temporada) usando a ordem/offset das temporadas da API (`seasons` no payload). Alternativa mínima: casar por **índice ordenado** (posição na lista ordenada por `season,number`) em vez de `number` — funciona enquanto a API devolver a série completa e ordenável. Revisar também `_episodeCountFromProviders` para provedores por-temporada (somar por temporada ou usar `data.length` quando `max < length` — com cuidado para não reintroduzir o bug do `length` em paginação).
3. **Player DASH** (`player_screen.dart:267-272, 253, 359-372`): setar `dash-bitrate` junto do `hls-bitrate`; validar em device se URL `/m.jpg` abre (log `videoParams`/`Duration`); se o mpv implicar com a extensão, considerar override de formato via `Media`/`extras` do media_kit ou proxy de URL com extensão `.mpd`.
4. **Testes:** estender `resolve_provider_states_test.dart` com fixture multi-quality (`["480p","720p","1080p"]`, 2 áudios, 1 offline `url:null`) + asserts de rótulo (`Auto`, sem `/`) e contagem de fontes; adicionar teste de `resolveVideo` multi-temporada (fixture 2 temporadas × N reiniciado, resolve absoluto N2+1); adicionar `qualityScore('Auto · dublado') == 0` em `quality_picker_test.dart`.
5. **Limpeza legada:** o bônus `todos-os-episodios` em `bestMatch` (`anime_source_adapter.dart:129-133`) é morto desde a migração (URLs novas são `/anime/{id opaco}`); com áudio duplicado (`Dublado & Legendado` em quase tudo), ponderar `audio`/`season` no match.

---

## Anexos — arquivos/pontos citados

- `lib/core/sources/anime_fire_adapter.dart` — l.24-26 (contrato da API), l.140-202 (`getEpisodes`, perde `season`), l.204-271 (`getVideoSources`), **l.244 (`join('/')` — o bug do botão)**, l.238 (descarte de offline, correto)
- `lib/core/sources/anime_source_adapter.dart` — l.65-90 (`resolveVideo`, casa só por `number`), l.98-153 (`bestMatch`, bônus legado l.129-133)
- `lib/core/utils/quality_picker.dart` — l.10-22 (`bestQualityIndex`), l.27-33 (`sortBestFirst`), l.35-42 (`qualityScore`, primeiro número)
- `lib/data/repositories/anime_repository.dart` — l.133-164 (`_episodeCountFromProviders`), l.205-351 (`resolveProvidersForEpisode`), l.170-181 (`_pageAlive`)
- `lib/features/detail/detail_screen.dart` — l.1128-1148 (`_resolveProviders`), l.1475-1500 (botões de qualidade — 1 por `VideoSource`), l.1484-1487 (atalho "Melhor qualidade"), l.1199-1216 (`_navigateToPlayer`)
- `lib/features/player/player_screen.dart` — l.205-225 (ordenação + mapeamento de índice), l.227-301 (`_playSource`, timeout 20 s l.253, `hls-bitrate` l.270-272), l.356-401 (`completed`/`error`, `dur=0` l.359), l.430-435 (`_advanceSource`, sem fallback com fonte única), l.1232-1295 (seletor de qualidade), l.76-81 (`_gotPlayback`, escrito para mp4)
- `lib/data/models/episode.dart` — l.50-60 (`VideoSource`)
- `test/resolve_provider_states_test.dart` — l.32-38 (fixture sempre `["480p"]`), l.40-61 (mock)
- `test/quality_picker_test.dart` — só rótulos simples, sem caso `a/b/c`
- Probes brutos (regeráveis): `GET /animes/pesquisar?q=naruto|solo leveling`, `GET /anime/eU7t5IvcNKU` (219 eps, 4 temporadas), `GET /anime/i0i1t0BT9B1` (25 eps), `GET /episode/xVkmI3eoCtD` (multi-quality), `GET /episode/WCrJufyJmQn` (480p único), `akumast.net/.../m.jpg` (`dash+xml`, 4 representações), segmento `.../E6PAQQDsHAI/1.jpg` (`200 image/jpeg`, 200 395 B, com e sem `Referer`)
