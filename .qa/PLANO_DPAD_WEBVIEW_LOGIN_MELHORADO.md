# Análise Crítica e Plano Melhorado: Navegação D-pad no WebView de Login AniList

## 1. Resumo Executivo

O plano original é **tecnicamente acertado na direção** (injeção de JS + foco
espacial replicando mouse via D-pad) e está respaldado por experimentação real
no dispositivo. Porém ele é **imcompleto como documento de execução**: mistura
decisão com suposição, não define a flag `--dart-define`, não prevê a captura de
KeyEvents no Flutter, e terceiriza o Turnstile sem um caminho concreto. O plano
melhorado mantém a ideia central, mas prioriza uma **prova de conceito mínima
(STAB + Enter)** antes do motor de foco espacial completo, e fecha cada fase com
critério de aceite verificável e risco.

## 2. Análise Crítica do Plano Atual

### 2.1 Pontos Positivos (manter)

- **Decisão correta de rejeitar preenchimento automático de credenciais**
  (opção já existente no código via `ANILIST_TEST_EMAIL/PASS`): o Turnstile
  depende de interação real; preserva segurança.
- **Não confiar em `dispatchKeyEvent` nativo** — reconhecido como inconsistente
  entre TVs. Correto.
- **Modos complementares (foco + cursor)** com toggle via MENU: cobre 95% e o
  caso marginal sem complexidade desproporcional.
- **Usar infraestrutura existente** (`runJavaScript` + `addJavaScriptChannel`),
  sem plugin nativo novo. Minimal correto.
- **Limitação cross-origin do Turnstile inteiramente descrita** — honesto e
  realista: `click()` não alcança iframe cross-origin.
- Escrita no próprio arquivo reflete experimentação no hardware alvo (foco
  abre IME) — isso já está validado.

### 2.2 Falhas Identificadas

#### Falha 1: O problema real não está isolado (Categoria: ideia)
- **Descrição**: A premissa é "o D-pad não foca os inputs" — mas não se sabe
  **por quê**. O plano avança direto para um motor de foco espacial sem isolar
  se é: (a) falta de focus no `Focus` do widget WebView, (b) a WebView não
  recebe `KEYCODE_DPAD` como `keydown`, ou (c) o HTML não tem tabindex/vidia
  traversal.
- **Impacto**: Podemos de hoje o problema, e construir um sistema de foco
  completo para um bug que um `Focus(autofocus: true)` + `TAB` resolveria.
- **Correção**: Fase 0 de diagnóstico medido antes de qualquer motor: injetar
  listener de `keydown`, reportar `document.activeElement` após cada seta,
  verificar `keyCode` recebido no Darwin. Só então decide entre motor espacial
  e abordagem mínima.

#### Falha 2: Não define o mecanismo de captura de teclado no Flutter (Categoria: implementação)
- **Descrição**: O plano chama "verificar foco do WebView recebe setas" (Fase
  1) mas não diz COMO o app vai receber o D-pad — precisa interceptar KeyEvents
  do Flutter (`KeyboardListener`/`Focus.onKeyEvent` no widget, ou
  `RawKeyEvent`) e traduzi-los em `runJavaScript`. Sem isso, o JS nunca recebe
  a entrada.
- **Impacto**: A Fase 2 não é implementável sem este contrato definido.
- **Correção**: Definir explicitamente: `KeyboardListener` em volta do
  `WebViewWidget`, mapear setas→`move`, OK→`click`, MENU→toggle cursor, e
  descrever a ordem Dart→JS (as setas são consumidas no Dart antes de chegar a
  interção interna do WebView?).

#### Falha 3: Faltam critérios de aceite verificáveis por fase (Categoria: estrutura)
- **Descrição**: Só Fase 2 tem critério ("preencher email/senha sem scrcpy").
  Fases 0/1/3/4 descrevem atividades, não "pronto quando". Unable rollout tar
  sem saber quando um fase acabou.
- **Impacto**: Execução ad-hoc; risco de Fase 4 integrar com comportamento não
  medido.
- **Correção**: Cada fase tem ID, entregável, critério de aceite e forma de
  verificação (ver Plano Melhorado abaixoa).

#### Falha 4: Alternativa mais simples não avaliada (Categoria: ideia/arquitetura)
- **Descrição**: O plano vai direto para a busca geométrica por cone de 45°,
  mas Chromium/WebView já tem coalescência espacial nativa se os inputs tiverem
  foco/traversal. Não há teste de rota simples: dar `focus()` no primeiro input
  e subir com `evento` TAB/Enter via JS — o DOM já ordena formulário por padrão.
- **Impacto**: Excesso de engenharia (analisador geométrico, destaque box/glow,
  MutationObserver) se o simples resolver.
- **Correção**: Marcar a fase "foco mínimo" (TAB traversal) como prerequisite;
  o motor geométrico só entra se a rota mínima falhar em inputs customizados.

#### Falha 5: Turnstile sem plano de saída (Categoria: riscos)
- **Descrição**: Tanto o plano atual quanto os riscos admitem que "se o
  foco+Enter não aparecer, manter o QR como rota". Mas o QR já é — a decisão
  de quando ABANDONAR o webview como primária da interação, e qual UX oferecer
  (mostrar o QR automaticamente?) não está codificada.
- **Impacto**: A Fase 4 pode ser vendida como concluída com um tecla de
  conversão inválida.
- **Correção**: Deadline explícito: se na Fase 4 real, após N tentativas com o
  usuário real, o Turnstile não ceder, o app auto-falha para o fluxo QR com
  mensagem clara — sem imagem do webview morto na tela.

#### Falha 6: `MutationObserver` ré-coleta sem estratégia de staleness (Categoria: implementação)
- **Descrição**: Após cada rejecção, os clicáveis são re-coletados, mas não se
  diz como o foco atual é preservado/reativo quando os inputs existem após o
  SPA montar (~300-500 ms no teste real).
- **Correção**: Estratégia: re-scans apenas em `debounce` após mutação; manter
  referência por âncora (atributo `data-nav-id`); nunca perda foco atual
  enquanto não for removido do DOM.

#### Falha 7: Sem estratégia de teste/validação de entrega (Categoria: estrutura)
- **Descrição**: Não há plano de teste em emulador vs hardware, giro de teclado
  virtual, nem uma matriz manuais entre fases. Só cita "teste religioso".
- **Correção**: Adicionar checklist manual de QA (Anexo) que percorre cada fase.

#### Falha 8: Sem rollback / feature-flag de produção (Categoria: riscos)
- **Descrição**: A Fase 4 crescent proposta (`--dart-define` vira "só logout de
  QA") não define o comportamento do app em produção se a camada quebrar — a
  injeção não pode impossibilitar o login padrão.
- **Correção**: Flag DEFAULT-ON/OFF, kill-switch em run-time se `onWebResourceError`
  ou exceção de JS ocorrer. (Segurança: nunca injeta-se quando `_testEmail`
  fornecidos; o app remoto sem interação injetada).

## 3. Plano Melhorado

### 3.1 Contexto e Restrições

- **App**: GoAnime TV (Flutter), Android TV — Fire TV Stick com D-pad.
- **Problema**: WebView de login AniList não responde ao D-pad; único fluxo
  hoje é scrcpy (inviável p/ usuário final).
- **Stack**: `webview_flutter: ^4.7.0`, JS via `runJavaScript` +
  `addJavaScriptChannel`. AniList usa oauth Implicit Grant
  (`#access_token` interceptado em `onNavigationRequest`, nunca exposto).
- **Validado em hardware**: focar `<input>` real abre o IME do Fire Stick (não
  há bloqueio de IME, há bloqueio de alcance).
- **Ambientes verificáveis**: emulador Android TV (teclado aparece, sem IME) +
  Fire Stick real.
- **Restrições irremovíveis**: iframe cross-origin do Turnstile; foco nativo é
  a única interação "real"; nessa hoje 3 fluxos de login (QR, webview, manual)
  que devem seguir existindo sem interferência.

### 3.2 Solução Proposta

Executar por **camadas progressivas** — cada camada é auto-suficiente e só a
anterior falhar para subir de camada:

1. **Camada 0 (pré-requisito)**: receber o fluxo aD do Flutter → JS. Sem isso
   nenhuma camada funciona.
2. **Camada 1 — TAB/Enter nativo em JS**: manter `hidden` no HTML, mover o
   foco via `el.tabIndex`/TAB e Enter (`el.click()`). Uso da interação minimal
   do browser; covers a maioria dos formulários.
3. **Camada 2 — Motor de foco espacial**: quando a camada 1 falhar para
   elementos customizados/Fire SPA: coleta de clicáveis + busca geométrica
   (cone 45°) + highlight.
4. **Camada 3 — Cursor livre** (MENU): `elementFromPoint` + `click()` para
   conteúdo que foco não alcança (Turnstile checkpoint).
5. **Sem nunca bypass Turnstile**: interação real pelo usuário com foco+Enter.

Justificação por camada: máxima simplicidade primeiro; n moro na pilha até
necessário — em vez de montar tudo de uma vez.

### 3.3 Arquitetura

```
Flutter (AnilistWebLoginScreen)
  ├─ KeyboardListener / Focus.onKeyEvent ── captura DPAD (setas, OK, MENU, back)
  ├─ WebViewController
  │    ├─ runJavaScript(navigation_layer.js)   ── injeção a cada onPageFinished
  │    ├─ addJavaScriptChannel('NavCtl')       ── relatório estado/erro (preferível)
  │    └─ NavigationDelegate: intercepta callback oauth ANTES do render
  │         (token nunca exposto); bloqueia navegação fora de anilist.co
  └─ navigation_layer.js (no WebView)
       │   ● coleta clicáveis → índice (atributo csf-nav-id)
       │   ● modo foco: busca geométrica (linha/coluna → cone 45° → semi-plano)
       │   ● modo cursor: passo px + elementFromPoint
       │   ● MutationObserver re-coleta, preserva nav-id do alvo atual
       │   ● el.focus() em input → IME nativo (validado)
```

Contratos de integração (importantes):
- `NavCtl` recebe mensagens do JS: `{evt:'state',...}` p/ zer field none,
  `{evt:'hit',...}` p/ caso o Motor falhe (permite fallback programático).
- Setas/back do remoto **NUNCA** consomem back nav do WebView quando a camada
  ativa (controle compartilhado).

### 3.4 Fases de Implementação

#### Fase 0 — Prova de conceito (antes de qualquer engenharia)
- **Objetivo**: saber por que o D-pad não dirige os inputs — sem assumir.
- **Entregáveis**: probe JS reportando `document.activeElement.tagName` por
  `keydown`; log do JSON em `debugPrint`.
- **Critérios de aceite (escolha uma)**: (a) D-pad chega e foco moldável →
  veja Fase 1 direto; (b) D-pad não chega → confirmar captura Flutter Dado e
  repetir; (c) chega masHTML não reage → Fase 2 (motor).
- **Dependências**: nenhuma (só a tela existente). ~2h.

#### Fase 1 — Fluxo TAB mínimo (usa interação da WebView)
- **Objetivo**: navegar entre inputs usando TAB virtual antes de qualquer busca
  geométrica.
- **Entregáveis**: `navigation_layer.dart` + `navigation_layer_tab.js`
  (restringido a junção inicial e `login`/) com rota `focus`+(Enter real).
- **Critério de aceite**: preencher email e senha no Fire TV real com eram remoto
  (sem scrcpy e sem cursor) — sair da TV aquela rota de sucesso.
- **Dependências**: Fase 0. Flag `--dart-define=WEBVIEW_NAV=on` (local).

#### Fase 2 — Motor de foco espacial
- **Objetivo**: quando Tab falhar (SPA/anin de layout), mover entre clicáveis
  por geometria + highlight.
- **Entregáveis**: busca (linha/coluna → cone 45° → semi-plano), highlight box,
  `MutationObserver` com preservação de índice, `iframe.focus()` p/ Turnstile.
- **Critério de aceite**: todas as rotas do fluxo de login (erro de senha,
  "Outra pessoa", recuperar senha) termáveis por D-pad; percurso completo em
  8/10 Falha real sem tocar em Scrcpy.
- **Dependências**: Fase 1 desativada para a página sob teste (mede fallback).

#### Fase 3 — Modo cursor livre
- **Objetivo**: cobrir o que o foco não encontra (p.ex.panel Turnstile).
- **Entregáveis**: MENU toggle; passo 12px; OK → `elementFromPoint`+click.
- **Critério de aceite**: captura do checkbox Turnstile em Hardware real com
  cursor, sem `scrcpy`, EM < 5 tentativas.
- **Dependências**: Fase 2 ativa. Auto-desabilitar após sucesso da captcha.

#### Fase 4 — Integração final e decisão de UX
- **Objetivo**: production-safe, sem regressão nos outros fluxos.
- **Entregáveis**: flag `NAV` default (off para app, on p/ TV detection);
  kill-switch em erro de runtime (JS) retorna ao comportamento atual. A rota
  de fallback: se Turnstile não inference após N tentativas → **auto-abre
  diálogo QR** com mensagem ("use o celular").
- **Critérios de aceite**: (a) QR e token manual seguem 100%; (b) webview em
  produção quebra somente quando a camada desliga, não quando liga bem; (c)
  fluxo usou a camada completa na TV real de = uma pessoa n = 5 sessões sem
  scrcpu; (d) kill-switch ativa em falha de erro de rede, de navegação
  indevida, ou excesso de `fill`/`state` em JS (Log que pare de falapar).
- **Dependências**: Fados 1-3 estáveis; decisão final de manter 3 fluxos
  aprovada com o usuário (tem 3 hoje).

### 3.5 Estratégia de Teste

| O que | Como | Quando |
|---|---|---|
| Captura de eventos | `debugPrint` de `keydown` no device; compare emulator X real | F0 |
| Eficiência TAB | percurso manual email→senha→submit no dev TV | F1 |
| Geometria (foco) | índice de estado: entr / sair / erro—2 coletadas no script | F2 |
| Cursor | caçar captura Turnstile sem scrcpy | F3 |
| Regressão | fluxo QR + token manual intacto | F4 |
| Real vs simul | emerald teclado OK; Fire real IME aberto | totas |

Todos executáveis manualmente por 10 min; não criaraa automação end-to-end
neste plano (YAGNI para um fluxo de login de baixa frequência).

### 3.6 Matriz de Riscos

| Risco | Prob | Impacto | Mitigação |
|---|---|---|---|
| D-pad não chega no keydown Firefox (sem hack CNEX) | M | Alto | F0 valida antes de qualquer código; se falhar, usar híbrido (FlutterKey + JS); |
| Turnstile fica opaco ao foco/Enter | M | Médio | Cursor livre (F3); senão falha para QR (F4 auto-fallback) |
| SPA re-render perde foco | Alta | Baixo | MutationObserver re-cata e preserva índice por `nav-id` |
| click() no SPA não desencadeia handlers | M | Médio | JS reais (React) atendem most click; usar `dispatchEvent` fallback; validado em F2 |
| regressão dos outros 2 fluxos | Baixo | Alto | camada só ativa com a flag; kill-switch; F4 testa regressão |
| `runJavaScript` quebra após rotas | Media | Médio | re-injeção em `onPageFinished` de todas as rotas `anilist.co` |
| device específico (Android pre-7 combo) | Baixa | Baixo | documentar máx WebView; iframe.focus como rota |

### 3.7 Plano de Rollback

- **Fase ≤3**: a camada só existe sob `--darta-define` de dev — remover quantia
  não impacta build atual. Rollback = apagar.
- **Fase 4**: a camada entra como **opt-out em app**. If any `onWebResourceError`
  de código de rede, JS uncaught (`try/catch` no layer), ou
  `onLMTSomething` em runtime, a tela **desativa a camada** (flag memory only)
  e retorna ao fluxo de hoje; o QA o report. Não deploy fire-comunicado.
- **Recuperação funcional**: sempre deixar QR/Token usáveis — nunca single
  point of failure na camada.

### 3.8 Dependências Externas

| Dep | Tipo | Escuta |
|---|---|---|
| AniList oauth | API de terceiros | runtime; estado + callback nas SIP |
| Turnstile (Cloudflare) | Cross-origin iframe | runtime; interação apenas real; pode falhar |
| FireStick WebView / Hybrid composition | Platform | foco/key handling (varia entre gens) |
| `webview_flutter` ^4.7.0 | lib | API de runJavaScript/channel (já em uso) |
| Emulador vs real | QA env | teclado vs foco de comportamento |

### 3.9 Critérios de Conclusão

O plano está "pronto" quando:
1. F0 escolheu uma rota e ela é justificada no documento (sem assunção).
2. Um caminho de login completo (email → senha → checkTurnstile → grants) é
   feito na TV real **sem scrcpy e sem mouse**.
3. Os 3 fluxos de login seguem intactos e o kill-switch está testado ativo.
4. Rollback a partir de F4 é um flip de flag (sem revert de código).
5. Decisão de UX final coberta (manter 3 fluxos + fallback p/ QR documentado).

## Anexo — Checklist manual por dispositivo

- [ ] Emulador: setas se movem, OK abre IME virtual (sem teclado físico ok)
- [ ] Fire real: email/senha via D-pad (sem scrcpy)
- [ ] Fire real: captura Turnstile via foco+Enter (ou cursor F3)
- [ ] Fire real: login completo e app retorna com sessão
- [ ] Regressão: QR + token manual continuam funcionando
- [ ] Kill-switch: bloquear rede → app volta a funcionar autônomo

---

## Referências

- Flutter webview keyboard (flutter #75322) — híbrido + eventos D-pad.
- AutodartsTV WebView Android TV — motor de foco espacial + cursor na TV.
- `AnilistWebLoginScreen` em `lib/features/home/anilist_web_login_screen.dart`.