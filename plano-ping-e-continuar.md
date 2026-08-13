# Plano — Ping nas fontes + "Continuar de onde parou"

> ✅ **Status: implementado + smoke test automatizado.** `flutter analyze` limpo
> (só deprecation pré-existente), **152 testes passando**, APK debug rodando no
> emulador `GoAnime_TV` sem FATAL/ANR. Validação visual fica por conta do teste
> manual (modelo sem visão). Documento de plano/execução das duas features.

## Feature 1 — Ping (ms) por fonte

**Objetivo**: na escolha de fonte (`_ProviderQualityDialog`, ao tocar num
episódio), exibir a latência de cada fonte em ms para o usuário escolher a
melhor para a sua internet.

**Decisão**: apenas **exibir** o ping. A ordenação (por prioridade) e a
auto-seleção (melhor prioridade) permanecem inalteradas.

### Implementação

- Novo `lib/core/sources/source_ping_service.dart`:
  - Mapa `AnimeSource → domínio` (animefire.io, goyabu.io, betteranime.io,
    anroll.tv, animeplayer.com.br, animesonline.cloud, animesdrive.online,
    animeq.blog, animeplay.cloud);
  - Medida via `Socket.connect(host, 443)` (handshake TCP = proxy de latência;
    leve, sem TLS/hTTP), timeout 3s;
  - Cache em memória com TTL de 60s + dedupe de pings em voo (não repinga por
    tap).
- No `_ProviderQualityDialogState`:
  - Disparar `SourcePingService.instance.ping(src)` em paralelo para os
    providers resolvidos;
  - Guardar em `Map<AnimeSource, int> _pings` (valor `-1` = timeout);
  - `_ProviderItem` ganha um parâmetro `ping` e renderiza `"42 ms"` ao lado do
    nome (`"--"` quando falhou, nada enquanto mede).
- Adapters não implementados (AllAnime) ficam de fora por não aparecerem.

### Critérios de aceite

- O dialog mostra `X ms` ao lado de cada fonte disponível;
- Fontes fora do ar mostram `--`;
- Abrir o dialog de novo (mesmo episódio) não repinga em menos de 60s.

---

## Feature 2 — Card "Continuar de onde parou"

**Objetivo**: na tela de detalhes, antes da lista de episódios, um card com o
próximo episódio a assistir (último assistido + 1). Ex.: parou no 106 → card
mostra o episódio 107 → botão "Continuar de onde parei" reproduz direto.

**Decisão**: quando o usuário já assistiu até o último disponível, o card é
**ocultado** (não há próximo episódio).

### Implementação

- `DetailScreen._nextEpisodeIndex()`: derivado do mesmo progresso que a grade
  usa (`getWatchProgress` → conjunto `watched` ∪ high-water `episode`).
  Retorna o índice do próximo episódio ou `null` (sem histórico / série
  concluída / lista vazia).
- Novo widget `_ContinueWatchingCard` (padrão `_EpisodeCard`: `Focus`,
  `FocusKeyHandler`, `AnimatedContainer`, border/glow primary e static para
  foguetes D-pad).
- `_buildSliverBody`: inserir o card entre os gêneros e o título "Episódios".
- Foco natural: quando o card aparece, ele recebe `autofocus` e o episódio 0
  da grade perde o `autofocus` (evita dois candidatos).

### Critérios de aceite

- Com histórico (ex.: E106 assistido), o card aparece com o E107 e reproduz E107;
- Sem histórico → sem card;
- Série concluída → sem card;
- Atualiza sozinho ao voltar do player (`didPopNext` já repinta com setState).

---

## Verificação

- `flutter analyze` sem novos issues; `flutter test` (152) verdes;
- **Smoke (rede real, host)**: `flutter test test/live_ping_probe_test.dart --dart-define=LIVE=1`:
  animeFire 61ms, goyabu 53ms, betterAnime 54ms, animesRoll 144ms, dooPlay 10ms,
  animePlayer 51ms, cloud 49ms, drive 47ms, animeQ 164ms, animePlay 166ms;
  `allAnime`/`anilist` → `--`; cache TTL confere (61 → 61);
- **Smoke (emulador AVD `GoAnime_TV`)**: APK debug instalado, app abre sem
  FATAL/ANR (processo ativo);
- **Manual (pendente de olhos)**: dialog com `X ms` por fonte, card
  "Continuar de onde parou" antes da grade, fluxo 1080p (fix do `completed`
  espúrio — player_screen.dart não mudou nesta etapa).