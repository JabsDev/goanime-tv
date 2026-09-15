# Plano de ação v5 — `dlopen OrtGetApiBase`: pivô llama.cpp com gate executável

Revisão após 4ª crítica (v4: 8/10). Fecha: referências do gate coladas
(juiz reproduzível), teto de produto além do tripwire, direção JA→EN do
LFM2 evidenciada, cadeia fim-a-fim dentro do gate, teto de disco/download,
comparativo com marcas de estimativa, pins/licenças, CI com assert verneed,
números restantes com lastro. Estimativas marcadas com [EST].

## 0. Diagnóstico (evidência; proveniência de cada medida declarada)

Forense no APK debug local (build verde c/ mesmos inputs do CI):
- `lib/arm64-v8a/libonnxruntime.so` empacotado: sha256
  `7a2fb9…24a9a` ≠ oficial (`f826d8…0acc`) ≠ sherpa (`33847a…cf2d`);
  22.249.552 bytes (≈ fork 22.249.560 − strip); nó `VERS_1.28.2`,
  `OrtGetApiBase@@VERS_1.28.2` no endereço `0x5cdd2c` (idêntico ao fork).
  v7a idem (`VERS_1.28.2`, 15.359.576 vs 15.359.592 bytes).
- Nós `VERS_1.28.0` observados SOMENTE nos arquivos do AAR oficial
  (`nm -D` em `/tmp/opencode/ortjni/...`, extraído do AAR do Maven):
  `OrtGetApiBase@@VERS_1.28.0` em `0xa3f3b0`; ponte `4j_jni` exige
  `U OrtGetApiBase@VERS_1.28.0`. (Correção à v4: o APK contém um só
  provedor; o outro lado da comparação vive nos artefatos de origem.)
- Experimento controlado: `libonnxruntime.so` oficial em
  `src/main/jniLibs` foi IGNORADO pelo merge (módulo vence local p/ mesmo
  path; removido após medir).
- Loaders: `System.loadLibrary("onnxruntime"+"onnxruntime4j_jni")`
  (strings no bytecode `OnnxRuntime.class`); Dart abre
  `libsherpa-onnx-c-api.so` por filename (`init_native.dart:24`).
- Conclusão: instalado elegeu o fork (STT vivo, ORT-Java morto). Válido
  para as builds medidas (debug local; release usa o mesmo mecanismo
  verneed, mas release NÃO foi verificada — declarado).
- Prova de insatisfatibilidade restrita a **processo único + artefatos
  stock** (processo `:remote` satisfaria tecnicamente; descartado por
  custo de binder — [EST] dias, não medido).

## 1. A vs B (comparativo com marcas; critério defendido)

Critério declarado e defendido: **minimizar código novo de inferência**,
porque o risco realizado neste projeto foi exatamente esse (sessões
debugando ORT/JNI threading, tensores e KV-cache sem referência local),
enquanto integração de runtime pronto tem histórico limpo aqui. É escolha
de valor explícita, não fato.

| Eixo | A. JNI própria sobre o fork | B. llama.cpp + GGUF (RECOMENDADO) |
|---|---|---|
| Reaproveita | `.onnx` catalogados; Marian rápido mantido | Zero código de inferência (llama.cpp oficial já roda LFM2-GGUF, flag `-sys` documentada) |
| Escreve | Driver ORT-C em C + BPE + SP + dlopen/dlsym + JNI — [EST] ~1000 linhas, vários dias p/ dev NDK | CMake + JNI fino (load/generate/free) + prompts — [EST] 2–4 dias + validação; JNI fino e prompts SÃO código novo (pequeno, com sample oficial como referência) |
| Risco central | Bugs sem referência + teste ARM só no dia 2 | EN→PT via LLM (gate abaixo) + velocidade no stick |
| Custo produto | Nenhum (Rota S intacta) | **REGRESSÃO DECLARADA**: Rota S vira GGUF (mais lenta que Marian); EN→PT genérico até solução dedicada. Dono aceita ou barra o pivô. |
| Downloads novos | Zero | LFM2 Q4 229.310.240 bytes + Qwen Q4 428.730.208 bytes (medidos, §2) |

## 2. Fase 0 — spike com gate executável por terceiro

Passo 0: confirmar URLs + tamanhos (medidos, HTTP 200, sem auth):
- `https://huggingface.co/LiquidAI/LFM2-350M-ENJP-MT-GGUF/resolve/main/LFM2-350M-ENJP-MT-Q4_K_M.gguf` → **229.310.240 bytes**
- `https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_0.gguf` → **428.730.208 bytes**
  (filename minúsculo; `Q4_0` maiúsculo dá 404 — medido).
- Direção JA→EN do LFM2-MT é USO DOCUMENTADO (não reverso): model card
  "bidirectional English-Japanese translation"; doc oficial mostra as duas
  direções com `-sys "Translate to Japanese."` / implícito EN; CLI
  comunitário usa ambos os prompts. System do gate: "Translate to English.".
- LFM2-350M base NÃO serve p/ EN→PT (idiomas oficiais sem PT — model card);
  por isso o Qwen. Total dos dois: **658.040.448 bytes (~627,6 MiB)**.

Dia 1 (PC x86_64, `llama-cli`, sem NDK): itens fixos abaixo.
JA→EN (LFM2-GGUF, `-sys "Translate to English."`, greedy):
1. おはよう、今日はいい天気だね。 REF: "Good morning, it's nice weather today, isn't it?"
2. 先輩、その本を取っていただけますか。 REF: "Senpai, could you please hand me that book?"
3. まさか、こんなところで会うなんて…。 REF: "I never thought I'd run into you here…"
EN→PT (Qwen, prompt "Translate to Brazilian Portuguese:"):
4. Good morning, the weather is nice today. REF: "Bom dia, o tempo está bom hoje."
5. Could you please hand me that book? REF: "Você poderia me passar aquele livro, por favor?"
6. I can't believe I'm running into you here... REF: "Não acredito que estou te encontrando aqui..."
7. CADEIA (fim-a-fim, o caminho real do usuário): item 2 → EN do LFM2 → PT
   do Qwen; julgar o PT final contra REF 2-PT: "Senpai, você poderia me passar aquele livro, por favor?"
**Procedimento de julgamento (reproduzível):** saídas embaralhadas sem
identificar engine; juiz (dono) marca PASS por item se (i) sentido da REF
preservado e (ii) zero conteúdo alucinado. **GO exige ≥6/7.**
**Tetos (propostos; dono ajusta ANTES do spike):** shippability mediana
≤20 s/frase no aparelho-alvo (dia 2); tripwire duro = qualquer frase >60 s
OU pico >1,2 GB OU não caber em disco (modelos + 1 GB livre) → NO-GO.
Sem GO escrito, Fase 1 não começa. (Barras e tetos são PROPOSTA, não física.)

## 3. Stopgaps imediatos

1. `friendlyError` p/ `dlopen`/`UnsatisfiedLinkError`/`OrtGetApi` → PT-BR
   curta + sem stack (padrão existente). Risco de runtime desprezível
   (só string exibida; regex nova numa função pura). Estado atual
   verificado: genérico truncado + stack.
2. **Recomendação: OCULTAR a linha LFM até o pivô** (diff pequeno,
   reversível; default = ocultar salvo objeção do dono). Motivo: oferecer
   ~316 MB (soma dos arquivos do catálogo `lfm-ja-en`) que nunca funcionam
   queima banda e confiança.
3. Comentário `build.gradle.kts` → estado real medido.

## 4. Fase 1 (SÓ se GO)

CMake llama.cpp CPU-only (pin de release/tag A DEFINIR no spike; registrar
commit; licença MIT; GGUFs baixados em runtime — sem redistribuição nossa;
licenças lfm1.0/Qwen-Apache-2.0 permitem uso) + `LlmTranslator.kt` (mesmo
esqueleto: thread + `catch Throwable`) + catálogo + cadeia inalterada +
REMOÇÃO da dep `onnxruntime-android` e dos 3 tradutores ORT-Java.
CI: `libllama.so` presente, `libonnxruntime4j_jni.so` ausente, E
`nm -D` no conjunto empacotado mostrando **exatamente UM provedor de
`OrtGetApiBase`** (assert verneed — o que importa).
Checklist aparelho: STT tiny + sensevoice, Rota S GGUF fim-a-fim, cadeia
5+ frases, cold-start pós-update. 32-bit: cobertura desconhecida (sem
aparelho aqui).

## 5. Custos e fallback

- Medido (época LFM+Qwen): GGUFs 658.040.448 bytes; superado abaixo.
- Medido (Hy-MT2): Q4_K_M 1.133.080.448 bytes (modelo ÚNICO p/ JA→PT e EN→PT).
- [EST] (não usar como especificação): `libllama.so` dezenas de MB/ABI;
  CI +minutos; integração 2–4 dias.
- Fallback se NO-GO no dia 2: A (§1) ou congelar tradutores — com evidência.
- Custo afundado: o spike. Declarado de antemão.

## 6. Resultado do spike dia 1 (2026-09-15, PC 16 threads, llama.cpp commit d1d3c33)

**Descoberta que muda o plano:** Tencent Hy-MT2-1.8B (Apache-2.0, 36 idiomas
c/ JA+PT) tem GGUF oficial e roda em llama.cpp (`hunyuan-dense.cpp`).
Testado Q4_K_M (`tencent/Hy-MT2-1.8B-GGUF`, **1.133.080.448 bytes**, HTTP 200
sem auth): **6/6 PASS** — JA→PT direto 3/3 (sem pivô!) e EN→PT 3/3 (corrige
"morning"→"noite" e a recusa do Qwen0.5B). Steady-state PC: ~0,7 s/frase;
load 9 s. Ressalva: leve sabor PT-PT ("encontrar-nos").
**1.25bit-GGUF (461.860.800 bytes) NÃO carrega** em llama.cpp stock
(offset mismatch — formato AngelSlim exótico): descartado.
Qwen0.5B: 0/3 (recusa + erros) — descartado. Qwen1.5B extra: 2,5/3 mas
1,07 GB — superado pelo Hy-MT2 em tudo.
**Veredito atualizado:** GO para pivô llama.cpp + **Hy-MT2-Q4 único**
(JA→PT direto e EN→PT Rota S, sem cadeia). Dia 2 (aparelho-alvo: tempo/
RAM) continua obrigatório antes da Fase 1.
**Quants menores (mesma sessão):** 2bit e 1.25bit oficiais NÃO carregam em
llama.cpp stock (offset mismatch, formato AngelSlim) — sem como fazer
funcionar sem fork. Requant caseiro de Q8: Q2_K (741 MB) COLAPSA em loop
(item 1) — reprovado; Q3_K_M (907 MB) passa nos itens testados (2 JA→PT) —
candidato a opção "leve" (~20% menor que Q4), pendente hospedagem
(publicar 907 MB exige conta HF/token do dono ou release GitHub) e gate
completo (EN→PT + item restante).
**Dono publicou: `Jabs2/Hy-MT2-1.8B-Q3_K_M-GGUF`
(`Hy-MT2-1.8B-Q3_K_M.gguf`, 951.021.408 bytes — idêntico ao validado;
download anônimo OK). Gate completo posterior: 6/6 PASS (nota: "Boa manhã"
no item 4). Catálogo (`hymt-ja-pt-q3km`, normalizado p/ `model.gguf`) +
linha em Settings prontos; runtime llama.cpp (Fase 1) pendente.**
