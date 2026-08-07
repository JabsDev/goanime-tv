# Relatório de Diagnóstico — Fire Stick "busca a lista pelas fontes" após refactor

**Data:** 07/08/2026
**Device:** Fire Stick 4K (`100.66.110.37:5555`, model `AFTSS`/`sheldon`, armeabi-v7a)
**Refactor:** `188349f` — AniList catalog decoupled from provider video resolution
**Tipo:** Diagnóstico (nenhuma mudança de código aplicada)

---

## 1. Resumo Executivo

O problema **não é** o catálogo voltar a buscar no scraper, e **não é** rede/device.
O catálogo já vem 100% do AniList (verificado em device). O problema real: **ao tocar
num episódio, TODAS as fontes resolvem `0 providers`**, e a causa é **falha de
matching de título** (o `resolveAnime`/`bestMatch` não encontra a página correta da
série na fonte). Isso se reproduz **no host** para "One Piece" — logo é bug lógico do
adapter/matching, independente da rede do Fire Stick.

---

## 2. O que foi verificado e funcionou (AniList = OK)

| Área | Resultado | Evidência |
|------|-----------|-----------|
| APK instalado é pós-refactor | OK | SHA1 do `base.apk` == `app-release.apk` (built 07/08 00:23); strings `resolveAnime/resolveVideo/getCatalogEpisodes/getEpisodesV2` presentes, `sourceOptions/_SourceSelector` ausentes |
| Home "Em Alta" | ✅ vem do AniList | `graphql.anilist.co` reachable; sem logs `[AnimeScraper]` no boot home; screenshots estáveis |
| Detail (grade de episódios) | ✅ do AniList | `[Detail] Loaded 12 canonical episodes` |
| Gravação no device | n/a | sources via `source_registry.dart`: AnimeFire(0), Goyabu(1), DooPlay(2), AnimePlayer(3), AllAnime(4; `implemented=false`) |

---

## 3. O sintoma real (a ponta)

Ao tocar num episódio (`lib/features/detail/detail_screen.dart:730` →
`resolveProvidersForEpisode`):

```
[ProviderDialog] resolved 0 providers best=null
```

→ UI mostra "Nenhuma fonte disponível". Ou seja, **o catálogo funciona; a resolução
de vídeo por provider retorna vazio**.

---

## 4. Causa raiz (confirmada no HOST, independente de device)

`lib/core/sources/anime_source_adapter.dart:48` — `resolveAnime`:
faz `search(cleanSearchQuery(anime.name))` (nome romaji do AniList) e passa o
resultado para `bestMatch` (`anime_source_adapter.dart:96`).

Probe hostada (`test/live_probe_one_test.dart`, host Linux) para **"One Piece"**:

```
search OK: 24 results
  - Koisuru One Piece           <- spin-off (página "todos-os-episodios")
  - One Piece: Gyojin Tou-hen
  - One Piece Film: Red
  - ...
[Koisuru One Piece] resolveAnime -> animefire.io/animes/koisuru-one-piece-todos-os-episodios
   EP1 video: 0                    <- página certa? não; 0 episódios/vídeo
[One Piece: Gyojin Tou-hen] resolveAnime -> NULL
[One Piece Film: Red]       resolveAnime -> NULL
[One Piece Film: Z]         resolveAnime -> NULL
```

Conclui-se (host, sem rede do device):

- A busca da fonte por "One Piece" **não retorna a série principal** no topo.
- `bestMatch` escolhe o **spin-off** ("Koisuru One Piece", ganho via
  `a.url.contains('todos-os-episodios') +15`, `anime_source_adapter.dart:115`).
- A série principal → `resolveAnime NULL` para todos os itens do catálogo.

Logo `AnimeRepository.resolveProvidersForEpisode` (`anime_repository.dart:67`)
retorna mapa vazio → `resolved 0 providers` no device. **Mesmo erro no host.**

> Isso explica por que "parece que ainda busca a lista pelas fontes": o app faz o
> `search` de cada provider em `resolveAnime`/`resolveVideo` por episódio, e esse
> search/title-matching falha para títulos que a fonte não lista por nome romaji.

---

## 5. Achados secundários

- **"Loaded 0 canonical episodes"** (alguns animes, ex.: "Kimi no…3rd Season"):
  algumas obras têm 0 episódios no catálogo AniList — fora da resolução provider.
- Probe antiga (`live_sources_probe_test.dart`) estourou timeout de 30s: são
  4 animes × 5 fontes × busca+resolve+5 eps = 60+ chamadas em paralelo na rede.
  Timeout é do runner de teste, não do app.

---

## 6. Diagnóstico final

- ✅ Refactor aplicado e catálogo corrigido (AniList). Não há "busca da lista
  nas fontes" no carregamento.
- ❌ **Resolução de episódio (provider) é que falha**: `resolveAnime`/`bestMatch`
  não resolvem o título correto na fonte → `0 providers` → "Nenhuma fonte disponível".
- Causa raiz = **algoritmo de matching (`bestMatch`) + telefonema de search que não
  retorna a série principal**; é lógica de adapter, reproduz no host e despree
  device/`rede`.

---

### Próximos passos (propostas, não aplicadas)

1. Ajustar `bestMatch` para penalizar spin-offs/filmes/OVAs **antes** do bônus
   "todos-os-episodios", e favorecer o título exato/prefixo da série principal.
2. Persistir o match (já existe `ProviderMatchStore`); evitar re-scan a cada ep.
3. Tratar, no catálogo, títulos com `0 canonical episodes`.

Nenhuma dessas mudanças foi aplicada — este relatório é só diagnóstico.
## Investigação complementar — por que só o animeFire aparece como fonte

Probe live no host (2026-08-07) para os 3 adapters não-animeFire:

| adapter | busca (?s=) | getEpisodes | extração de vídeo |
|---|---|---|---|
| goyabu | 200 ok | 220 eps ok | `layersData` só contém token `video.g` (blogger); adapter só aceita `videohls.php`/`.m3u8` → 0 |
| dooPlay | 200 ok | 500 eps ok | `wp-json/dooplayer/v2` devolve embed jwplayer; página `jwplayer/?...` não tem mp4/m3u8 estático (token preenchido via JS) → 0 |
| animePlayer | 200 ok | 220/500 eps ok | página nova usa `traffic.thatwebsite.com.br/api/index.php?token=<base64 blog>`; adapter procura padrão `thatwebsite...jax` e `infra.thatwebsite` antigo → 0 |

Conclusão: NÃO é bloqueio Cloudflare nos 3 (as buscas e páginas respondem 200 no host). É **mudança de markup/estrutura nos sites** — os resolvedores internos (goyabu: aceitar video.g; dooPlay: resolver token jwplayer via admin-ajax; animePlayer: novo `/api/index.php?token=`) estão defasados em relação ao HTML atual. O animeFire continua funcionando porque seu parser ainda casa com o markup atual.

### Decisão (2026-08-07)

Os 3 adapters não-animeFire (goyabu, dooPlay, animePlayer) foram **desativados da investigação**:
todos convergem para tokens `https://www.blogger.com/video.g?token=<...>` cujo stream só é
recuperável via SPA JavaScript anti-bot (`/_/BloggerVideoPlayerUi`), que não expõe a URL do
m3u8 no HTML estático (nem via redirect/Accept/Range/UA). Recuperar o stream sem um browser
headless no app é frágil e de alta manutenção. Mantém-se apenas o animeFire como fonte única de
vídeo. Se um resolvedor de Blogger for desejado, exige um subprocesso headless — fora de escopo.
