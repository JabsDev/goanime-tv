# Plano: Navegação D-pad no WebView de Login AniList

## Contexto / Problema

No login embarcado do AniList pelo WebView (Fire TV), o usuário não tem como
interagir com o formulário: o D-pad do controle chega ao WebView mas não faz
foco ótimo nos inputs HTML, e abrir o IME exige que um elemento de texto receba
foco. O único fluxo usável hoje é via scrcpy (mouse do PC) — inviável para o
usuário final.

A experimentação real mostrou: **ao clicar no input (mouse), o teclado do Fire
Stick abre normalmente**. Ou seja, o bloqueio não é o IME — é chegar o foco onde
o HTML espera.

## Ideia

Não preencher credenciais do lado do app (opção rejeitada: o Turnstile do
Cloudflare depende de interação real com a página). Em vez disso, **replicar o
mouse via D-pad**: uma camada JS injetada na página que move um cursor virtual
com as setas e "clica" via `elementFromPoint` + `click()`, e navega por foco
espacial (elementos clicáveis, como o AutodartsTV faz).

## Arquitetura alvo

- `navigation_layer.js`: JS injetado no WebView após cada `onPageFinished`.
  - Coleta os clicáveis (`button`, `a[href]`, `[role=button]`, `input:not([type=hidden])`, `[contenteditable]`).
  - Modo **foco espacial** (padrão): seta → busca geométrica (mesma linha/coluna
    → cone 45° → semi-plano), destaca o alvo (box/glow), `el.focus()` entra.
  - Modo **cursor livre** (toggle via MENU): move um indicador em passos de px;
    OK → `elementFromPoint(x, y)` + `click()`.
  - Enter/OK no alvo focavel com texto → `el.focus()` dispara o IME nativo
    (comprovado no teste real).
  - `MutationObserver` re-cata clicáveis após rota/línguagem SPA.
  - Não confia em `dispatchKeyEvent` do WebView nativo (inconsistente entre
    gerações de TV).

## Decisões tomadas

| Decisão | Escolha | Motivo |
|---|---|---|
| Injeção | JS único (`navigation_layer.js`) | Reusa infra existente (`runJavaScript`), sem plugin nativo novo |
| Canal Flutter↔JS | `addJavaScriptChannel` (já usado p/ `FillLog`) | Sem MethodChannel custom |
| Foco vs cursor | Modos complementares | Foco resolve 95% (formulário); cursor cobre resto (Turnstile/iframe) |
| Turnstile | Deixar o Cloudflare resolver com interação REAL via foco/Enter | Injeção de captcha é barril de pólvora; sem try de bypass |

## Limitações conhecidas

- **Turnstile/iframe cross-origin**: o checkbox do Cloudflare vive em iframe de
  outro domínio → o JS da página NÃO consegue `click()` dentro dele
  (same-origin). Terá de ser enderecida via `iframe.focus()` + Enter do usuário
  (interação real, aceitável para um captcha).
- **JS `click()` não é "trusted event"**: handlers React/nativos reagem, mas
  nenhum bypass de Turnstile é tentado por design.
- **Teclado**: sem IME do sistema, o teclado virtual do Fire Stick aparece
  apenas com foco real em `<input>` — nosso `focus()` cobre isso.

## Fases de implementação

### Fase 1 — Infraestrutura de teste (sem alterar o fluxo atual)
- Branch mocka; manter `--dart-define` ATUAL intacto como fallback.
- Adicionar flag `--dart-define` para ligar a camada de navegação apenas na
  tela de login do WebView (hoje `AnilistWebLoginScreen`).
- Verificar foco do WebView recebe setas como `keydown` (padronizar com
  `Focus`/`Autofocus` no widget).

### Fase 2 — Modo foco espacial
- `navigation_layer.dart`: injetar JS (seletores + busca geométrica + destaque).
- D-pad entra. Tela: setas → move highlight; OK → `click()` no alvo;
  foco em input abre IME no real.
- Critério de aceite: preencher email/senha apenas com o remoto na TV do
  dev (sem scrcpy).

### Fase 3 — Modo cursor livre (fallback)
- Toggle via MENU: cursor + setas movem posição, OK → `elementFromPoint`+click.
- Critério: caçar elementos que o foco não alcança (p.ex. captura Turnstile).

### Fase 4 — Integração final
- Remover/encapsular o código de teste (`--dart-define` vira só logout de QA).
- Decidir UX: manter os 3 fluxos (QR / webview / token manual)? Adicionar
  ativa config do "modo TV"?
- Teste religioso em hardware real + emulador Android TV (o teclado toca mas
  sem IME é esperado).

## Riscos

- **Chrome/WebView do Fireer**: comportamento de `Document.elementFromPoint`
  e IME varia; validar no dispositivo alvo (usuário testou Fire).
- **Turnstile**: se puxar do foco+Enter não aparece, manter o QR login como
  rota para móvel; webview vira caminho para quem tem mouse/teclado físico.
- **Tempo**: é uma camada de navegação nova — manter fora do fluxo padrão
  até Fase 4 estar estável.

## Referências

- AutodartsTV (WebView Android TV → foco espacial + cursor) — inspiração
  central.
- Chromium/Android WebView: D-pad → `keydown` quando há foco nativo.
- androidx WebView hybrid composition resolve eventos de teclado em WebViews
  (flutter #75322).