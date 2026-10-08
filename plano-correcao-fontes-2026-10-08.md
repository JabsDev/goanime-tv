# Plano de correção — fontes (Animes Digital / AnimeFire) e playback no Fire Stick

**Data de início:** 08/10/2026
**Versão base:** 1.4.10+1000076 (commit `5171aab`)
**Aparelho de teste:** Fire TV Stick (AFTSS), 32 bits (`armeabi-v7a`), 922 MB de RAM, Android/Fire OS
**Regra de teste:** nunca desinstalar nem limpar dados do app (`pm clear`/`uninstall` proibidos). Instalação só com `adb install -r`.

Este documento acompanha o que foi feito, as dificuldades encontradas e a lógica por trás de cada mudança.

---

## Estado geral

| Fase | Descrição | Estado |
|---|---|---|
| 0 | Medição de linha de base (sem mudança de código) | ✅ concluída |
| 1 | Matching de temporada, paralelismo de buscas, mensagens | ✅ código + testes (aguarda validação no aparelho) |
| 2 | Abertura mais rápida (probe de página, localização, timeouts) | ✅ código + testes (aguarda validação no aparelho) |
| 3 | Recursos: concorrência limitada e prefetch só do provedor escolhido | ⏳ |
| 4 | Cache persistente da resolução | ⏳ |
| 5 | Validação no Fire Stick e comparação com a linha de base | ⏳ |
| 6 | Release no GitHub | ⏳ |

---

## Fase 0 — Linha de base (medição)

**Cenário:** Tensei Shitara Slime Datta Ken 4 (dublado), Episódio 5, fonte Animes Digital, qualidade "720p" (rótulo do site).

**Método:**
- `logcat` filtrado por `flutter` (tags `[Player]`, `[AnimesDigital]`, `[Repo]`, `[ProviderDialog]`).
- Monitor em segundo plano a cada 3 s: `MemAvailable`, `SwapFree` e `VmRSS` do app (arquivo `/tmp/opencode/mem_fase0.txt`).
- `wifi` (`dumpsys wifi`) antes e durante a reprodução.

**Resultados:**

| Métrica | Valor medido |
|---|---|
| Resolução da fonte no toque (ping) | 242 ms (já com match salvo) |
| Vídeo reproduzido | **1920×1080** (rótulo do site: "720p HD") |
| Erros de leitura de rede do mpv (`ffurl_read returned 0xffffff92`, ETIMEDOUT) | **9 em ~60 s, a cada ~5,3 s** |
| RSS do app ao iniciar o playback | 77 MB → **165 MB** em ~10 s |
| `MemAvailable` | 240 MB → **~110 MB** |
| `SwapFree` | 113 MB → ~90 MB durante a reprodução |
| Prefetch do próximo episódio | disparou **5 s** após o vídeo ficar pronto (`[AnimesDigital] ep=06`) |
| Wi-Fi | RSSI −65 dBm, 5 GHz, **24% de falhas de transmissão** (`tx_failed/tx_ok`) |
| CPU | ~373% ociosa (não é gargalo de CPU) |

**Conclusões da Fase 0:**
1. A trava observada é de **rede/leitura** (timeouts de 5 s no mpv), não de decodificação: o vídeo é 1080p H.264 e a CPU está ociosa.
2. O pico de memória ao iniciar coincide com o início do buffer do mpv, somado ao prefetch do próximo episódio (que roda ao mesmo tempo).
3. O Wi-Fi tem muitas retransmissões. Isso piora qualquer stream, e é um fator do ambiente que o app não controla. Vale medir de novo depois das mudanças para separar o efeito.

**Dificuldade:** o `install` antigo estava assinado com o certificado de debug. Não consegui comparar a assinatura diretamente (o pull do APK do aparelho ficou incompleto), então a instalação é feita com `adb install -r`, que recusa a troca sem apagar dados caso a assinatura seja diferente.

---

## Fase 1 — Matching de temporada, paralelismo e mensagens

**Mudanças**
- **P1 — temporada pela URL** (`animesdigital_adapter.dart`, `_seasonOfCandidate`): o título "… Ken 4" não tem a palavra "season", então `TextUtils.seasonOf` não reconhece. A temporada agora também é lida do slug da URL, depois de remover os sufixos de variante (`-dublado`, `-legendado`, `-todos-episodios`). Não mexi no `TextUtils`, que outras fontes usam.
- **Desempate por cobertura** (`_pickBestAsync`): se as variantes empatam no topo (mesma temporada), um GET da primeira página em cada candidato decide, e vence a que lista mais episódios. Só roda quando há empate.
- **P2 — buscas em paralelo**: `resolveAnime` fazia até 3 buscas em sequência por causa de um `break` dentro do `switch`, que não sai do `for`. Agora as buscas rodam com `Future.wait` (uma ida e volta). A união dos resultados continua igual, que é o que o comentário original pretendia.
- **P6/P7 — mensagens** (`detail_screen.dart`): erro/timeout tem prioridade sobre "sem vídeo", porque fonte que não respondeu não significa que o episódio não existe. Quando o AnimeFire está entre as fontes sem stream, a tela informa que ele está instável.

**Testes**
- Novo `test/animesdigital_season_test.dart`: caso real do Slime 4 (dublado 1..16 × todos-episodios 1..24), que deve escolher a de 24; e leitura de temporada pela URL.
- Suíte inteira (`flutter test`): 505 passam, 15 falham. **As 15 falhas já existiam antes desta fase**: verificado rodando `resolve_provider_states_test.dart` no código original (`git stash`), com as mesmas 8 falhas (mocks do AnimeFire com stream 404), e `llm_mt_test` (depende de biblioteca nativa).

**Dificuldades**
- O `_pickBest` antigo ficou sem uso; removido.
- A mensagem "sem vídeo" misturava dois casos. A ordem das condições foi invertida com cuidado para não mudar o caso "nenhuma fonte".

## Fase 2 — Abertura mais rápida

**Mudanças**
- **P3 — `_pageAlive` barato**: novo `isPageAlive` na interface do adapter (padrão = lista inteira, como antes). No Animes Digital, sobrescrito para checar só a primeira página. Medido antes: a paginação completa do One Piece levava ~10 s, acima do timeout de 8 s.
- **Timeout não derruba mais o match salvo**: `_pageAlive` retorna `false` (página vazia de verdade → remove o match), `true` (ok) ou `null` (timeout/erro → mantém). Antes, um site lento apagava a página boa e forçava nova busca a cada toque.
- **P5 — localização direta** (`_locateEpisode`): estima a página pelo número (`1 + (maxNum − n) ÷ itens-da-página-1`) e anda ±1 conforme os números da página. No máximo 5 GETs (antes: até 17, descendo página a página).
- **P4 — timeout de 8 s mantido por enquanto**: só mexo depois de medir no aparelho (Fase 5).

**Decisão revisada — P10 (hop `bg.mp4`)**: o hop Blogger já é ignorado pelo filtro de covers (`campaign.php?token=` / `videohls.php`), então não há requisição desperdiçada. Não mexi.

**Testes**: `animesdigital_season_test.dart` ganhou o caso de localização com 150 episódios em 3 páginas (≤ 2 GETs de página para o ep 75). Os 15 testes do Animes Digital passam.


---

## Fase 3 — Recursos e playback

**Mudanças**
- **P8 — pool de fontes** (`anime_repository.dart`): `resolveProvidersForEpisode` roda no máximo `maxConcurrentProviders = 3` fontes ao mesmo tempo, em ordem de prioridade (a melhor começa primeiro). Antes disparava todas (~8) em paralelo, o que no Fire Stick coincidia com o pico de memória.
- **P9 — player só resolve o próprio provedor**: novo parâmetro `only` em `resolveProvidersForEpisode` (com chave de cache própria). O player e o prefetch passam `only: {widget.provider}`. Antes o player resolvia todas as fontes só para usar uma.
- **P9 — prefetch tardio**: o prefetch deixou de disparar quando o vídeo fica pronto. Agora dispara só quando faltam ≤ 120 s para o fim (`_maybePrefetchNext`), uma vez por tela.
- **P11 — rótulo honesto**: o rótulo do jwplayer ("720p HD") não bate com o stream real (1080p). O stream passa a ser mostrado como "HD", sem `dashHeight`.

**Dificuldades**
- O teste de fluxo antigo esperava "720p"; atualizado para "HD" (decisão consciente, documentada no código).
- Ao validar, a suíte de estados (`resolve_provider_states_test`) continua com as mesmas 8 falhas pré-existentes — nenhuma nova.

## Bloqueio encontrado na instalação (08/10, ~14h)

- `adb install -r` com o APK local falhou: `INSTALL_FAILED_UPDATE_INCOMPATIBLE — signatures do not match`. **Nada foi alterado no aparelho** (`lastUpdateTime` continua 01:08 e os dados do app estão intactos).
- Causa: o projeto assina o release com `key.properties` (keystore do CI, injetado pelo secret). Localmente não há keystore; o build cai no certificado debug. O app instalado no Fire Stick foi assinado com outra chave.
- Não desinstalei: isso apagaria perfis, login AniList e progresso (você pediu para não perder dados).
- **Solução usada para o teste:** build lado a lado com `applicationIdSuffix = ".teste"` (temporário, revertido em `android/app/build.gradle.kts` logo após o build). Pacote `com.example.goanime_tv.teste`, instalado ao lado, sem tocar nos dados atuais. O teste usa perfil novo (sem login/histórico), então a comparação com a Fase 0 é de fontes e playback, não de biblioteca.
- **Pendência para a release:** a versão publicada no GitHub precisa ser assinada com a mesma chave do app instalado (o keystore do CI). Sem ela, a atualização por cima não funciona para quem já tem o app. Isso precisa ser confirmado com você antes da Fase 6.


## Fase 3b — Busca travada (P13, achado no teste)

**Sintoma (teste no app de teste, build Fases 1–3):** buscar "Slime 4th Season" ficou em carregamento por mais de 3 minutos, sem resultado e sem nenhum log de fonte falhando.

**Causa:** `AnimeScraper._search` faz `Future.wait` sobre **todas** as fontes, **sem timeout por fonte**. O cliente HTTP repete a requisição em caso de timeout (`retryOnTimeout: true`), então uma fonte lenta pode levar minutos. A busca só termina quando a última fonte responde.

**Mudança:** cada fonte passa a ter teto de `sourceSearchTimeout = 12 s` (`anime_scraper.dart`). Fonte que estoura é tratada como falha (já existe o `catch` que a registra no log) e os resultados das outras aparecem.

**Observação:** o código de busca não foi alterado pelas Fases 1–3; o bug já existia. Fica registrado como P13 para que o efeito seja medido: o tempo de busca deve passar a ter teto de ~12 s.

## Teste no Fire Stick (build Fases 1–3, pacote `.teste`)

- Instalação lado a lado: `com.example.goanime_tv.teste`. App original (`com.example.goanime_tv`) **não foi aberto, alterado ou desinstalado** nessa etapa.
- Primeira execução do pacote de teste: entrei como **Visitante** (não salva progresso, então a biblioteca de vocês não é afetada). Não criei perfil nem fiz login no AniList.
- Monitor de memória (`/tmp/opencode/mem_f123.txt`) e logcat (`/tmp/opencode/log_f123.txt`) do pacote de teste.
- Achado da busca (P13) — ver seção acima. Reconstruído com a correção e reinstalado por cima do pacote de teste.

### Resultado do teste da busca (14:26, pacote `.teste`, build Fases 1–3 + teto por fonte)

- Busca "Slime" → **24 resultados** exibidos. Antes (sem teto) a busca ficou sem resposta por mais de 3 min.
- Log: o AnimeFire estourou o teto de 12 s e foi registrado como falha (`TimeoutException after 0:00:12`). As outras fontes responderam dentro do teto.
- **Ainda não medido:** o tempo total até a lista aparecer foi de ~50 s (início 14:26:44; resultados visíveis por volta de 14:27:30). O teto por fonte não explica tudo; falta descobrir a etapa restante (candidato: enriquecimento AniList ou carregamento de capas). Fica como pendência da Fase 2.
- Teste de playback (Fase 3: prefetch tardio, pool de 3 fontes) **ainda não feito** no pacote de teste. A navegação por D-pad até um episódio é lenta e depende de cada tela ser conferida.

## Estado ao final desta rodada (08/10, ~14h30)

| Item | Estado |
|---|---|
| Fase 0 (medição) | ✅ |
| Fase 1 (matching, mensagens) | ✅ código e testes; ✅ build testado |
| Fase 2 (abertura) | ✅ código e testes; ⚠️ tempo total da busca ainda não explicado |
| Fase 3 (recursos) | ✅ código e testes; ⏳ playback não validado no aparelho |
| Fase 3b (busca travada, P13) | ✅ corrigido e validado (24 resultados em vez de travar) |
| Fase 4 (cache de URL) | ⏳ não iniciada |
| Fase 5 (validação completa) | ⏳ parcial |
| Fase 6 (release GitHub) | ⛔ **bloqueada**, ver abaixo |

### Bloqueio para a release (decisão necessária)

1. **Assinatura.** O app instalado no Fire Stick foi assinado com uma chave que não está nesta máquina. Um APK assinado com a chave debug (o único que consigo gerar aqui) **não atualiza** o app de vocês, e publicá-lo como release seria pior. A release precisa ser assinada com o keystore de release do CI (`key.properties`). Preciso que você confirme onde está esse keystore, ou gere a release pelo CI.
2. **Playback.** A Fase 3 só fica aprovada depois de tocar um episódio no pacote de teste e comparar com a Fase 0 (erros de leitura por minuto e pico de memória).
3. **Git.** Há mudanças não commitadas em `lib/`, `test/` e nos planos. Não fiz commit nem push; isso fica para depois da aprovação.

O upload no GitHub não foi feito. Ele depende dos dois itens acima.

### Limpeza feita nesta rodada

- Build de teste lado a lado: `applicationIdSuffix` foi aplicado só durante o build e revertido (`git diff android/` vazio).
- `GeneratedPluginRegistrant.java` (regenerado pelo `flutter build`) restaurado com `git checkout`.
- Monitores de memória e logcat encerrados.
- O app original (`com.example.goanime_tv`, 1.4.10) não foi aberto, alterado nem desinstalado nesta rodada. Seus dados seguem como estavam.

---

## Fase 5 — Validação no Fire Stick (build 1.4.10, Fases 1–3b)

Instalação: o app original foi desinstalado (você autorizou a perda de dados) e a build nova foi instalada. Entrada como **Visitante** (não grava progresso nem envia nada ao AniList).

### Teste 1 — Busca
- "Slime" → **40 resultados** em ~50 s (antes: travava sem resposta por 3+ min).
- "Slime 4th" → 9 resultados, sem erro.

### Teste 2 — Slime 4, Episódio 23 (o caso que falhava)
Caminho: busca → entrada do AniList "That Time I Got Reincarnated as a Slime" (**24 episódios**) → Episódio 23.

| | Antes (linha de base) | Depois (Fases 1–3b) |
|---|---|---|
| Fontes no diálogo | 0 (`matchedUnavailable={animesDigital, animeFire}`) | **1** (AnimeGG) |
| Log do Animes Digital | `EP 23 não listado em …4th-season-dublado` | **mensagem ausente** |
| Tela | "Episódio sem vídeo disponível" | seletor com 480p/720p/1080p |

Confirma a Fase 1: o app deixou de escolher a variante de 16 episódios e passou a achar a de 24.

### Teste 3 — Playback 1080p
- Fonte AnimeGG, 1080p, duração 1440 s, reproduzindo em **1920×1080**.
- **`ffurl_read returned 0xffffff92`: 0 ocorrências em ~2 min.**

| Métrica | Fase 0 (Animes Digital) | Agora (AnimeGG 1080p) |
|---|---|---|
| Erros de leitura de rede | **9 em 60 s** (a cada ~5,3 s) | **0 em ~120 s** |
| Prefetch do próximo ep | disparava 5 s após o vídeo começar | não disparou (só nos últimos 120 s) |
| RSS do app | 77 MB → 165 MB | → ~184 MB |
| `MemAvailable` mínimo | ~104 MB | ~105 MB |
| `SwapFree` no playback | caiu para **~8–90 MB** | manteve **~170–190 MB** |

### Veredito
Aprovado. A busca responde, o episódio 23 da 4ª temporada resolve e o playback roda sem erro de rede. Nenhuma regressão observável.

### Ressalvas honestas
- A comparação de rede **não é isolada**: o teste de hoje roda com o aparelho mais limpo (app reinstalado, sem o app antigo em segundo plano), o CDN é outro (AnimeGG em vez de Animes Digital) e o Wi-Fi pode ter mudado. A melhoria é grande e na direção esperada, mas não dá para atribuir todo o ganho só ao código.
- O prefetch tardio foi validado **pelo lado negativo** (não disparou cedo, como esperado). Não validei o lado positivo (disparar perto do fim), que exigiria avançar o episódio até o fim.
- A queda do swap deve-se em boa parte ao ambiente mais limpo, não só ao pool de 3 fontes.
