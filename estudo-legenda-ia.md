# Estudo — Legenda por IA no GoAnime TV (inspirado no LegendAI)

Data: 14/09/2026. Escopo: só estudo, nenhum código alterado.
Pergunta: dá para pegar uma fonte japonesa sem legenda (ex. Haibane Renmei),
transcrever o áudio e traduzir para PT-BR com IA, no estilo do
[JabsDev/LegendAI](https://github.com/JabsDev/LegendAI)?

## Veredito

**Dá, mas não no aparelho fraco e não de graça.** O caminho viável é:
STT on-device (Whisper tiny/base via `sherpa_onnx`) + tradução NLLB on-device
só em aparelho forte, ou MT em nuvem nos demais — com plumbing de legenda
externa que o app hoje não tem (precisa construir). Aparelho fraco (sticks
1.5–2 GB) fica de fora do on-device total; para ele, só legenda pré-gerada
ou nuvem.

## 1. O que o LegendAI faz (e o que dá para reusar)

Pipeline 100% local em desktop (Tauri + Rust): ffmpeg extrai áudio →
**whisper.cpp** transcreve → **NLLB-200 (ONNX)** ou TowerInstruct traduz →
formata SRT/ASS (2 linhas, ~42 chars) → exporta. Modelos baixados na 1ª
execução via catálogo (`catalog/models.json`).

Reusável como **ideia + escolha de modelos**, não como código (Rust/Tauri
não roda no Flutter/Android TV):

| Peça | LegendAI | Equivalente Android TV |
|---|---|---|
| STT | whisper.cpp (`whisper-rs`) | `sherpa_onnx` (pub.dev, Apache-2.0, Android arm64/armeabi, `OfflineRecognizer` + VAD) |
| MT | NLLB-200 ONNX / Tower 7B | NLLB int8 via onnxruntime direto **ou** MT em nuvem (sherpa **não** tem tradução) |
| Áudio | ffmpeg sidecar | `MediaExtractor`+`MediaCodec` nativo via platform channel (sem ffmpeg-kit, que está abandonado) |
| Modelos | 78 MB (tiny) – 1.5 GB (medium); NLLB ~2–3 GB RAM | mesmos arquivos ggml/ONNX, baixados sob demanda |

## 2. Restrições do nosso app (levantadas no código)

- **Zero plumbing de legenda hoje**: `VideoSource` só tem `url/quality/headers`
  (`episode.dart`); nenhum `SubtitleTrack` no `PlayerScreen` (mpv) nem no
  `ExoDash`. O media_kit suporta (`SubtitleTrack.uri`), o ExoPlayer também
  (`SubtitleConfiguration`) — mas tudo precisa ser fiado do zero + UI.
- Fonte JA precisa existir e tocar: para Haibane, o mp4 JA do Archive toca —
  o gargalo era só a legenda, que este projeto resolve.
- Licenças OK: sherpa-onnx (Apache-2.0), Whisper (MIT), NLLB (CC-BY-NC — só
  distribuição do modelo; uso no app gratuito é aceitável, checar antes de
  publicar).

## 3. Desempenho estimado por tier (com dados medidos)

Referências públicas (whisper.cpp, CPU): i9-13980HX — tiny 5.6×, base 2.4×
tempo real; RK3588 (8× ARM A76/A55, bem mais forte que stick de TV) — tiny
~10×, base ~6×, small ~2× tempo real, com pico de RAM 300/410/890 MB.
Projeção para EP de 24 min (só STT, sem tradução):

| Aparelho | Ex. | tiny 78 MB | base 142 MB | NLLB int8 (~600 MB) |
|---|---|---|---|---|
| Fraco (stick A53, 1.5–2 GB RAM) | Fire Stick, Mi Box S | ~8–15 min, RAM no limite | inviável | inviável (sem RAM/disco) |
| Médio (A55/A76, 2–4 GB) | Stick 4K Max, Nokia 8010 | ~4–8 min | ~8–15 min | limite (só com 4 GB) |
| Forte (S922X/Tegra, 3–4 GB+) | Shield, Ugoos | ~2–4 min | ~4–8 min | viável (~minutos p/ EP) |

Tradução NLLB soma minutos (CPU) por EP; Tower 7B está fora (5–8 GB RAM).
Números são projeção — validar com benchmark real nos aparelhos (plano §6).

## 4. Rotas comparadas

| Rota | STT | MT | Prós | Contras |
|---|---|---|---|---|
| **A. On-device total** | sherpa+Whisper | NLLB int8 local | offline, sem custo recorrente, privacidade | só aparelho forte; ~1 GB em modelos; bateria/thermal |
| **B. Híbrida (recomendada p/ começar)** | sherpa+Whisper local | nuvem (API paga ou grátis c/ chave própria) | funciona no médio; modelos leves (~150 MB) | custo por uso ou chave do usuário; precisa internet |
| **C. Pré-gerada/comunidade** | feita uma vez (PC/nuvem) | idem | aparelho fraco assiste; custo zero após gerar | precisa servidor p/ distribuir + moderação; cinza legal |

Qualidade JA: tiny erra mais (nomes, músicas de OP/ED alucinam) — base é o
mínimo honesto; NLLB cobre `jpn→por` direto, sem pivô em inglês.

## 5. Peças a construir (qualquer rota)

1. **Extração de áudio**: channel nativo `MediaExtractor`→PCM 16 kHz mono.
2. **Worker STT isolado**: `sherpa_onnx` em isolate, progresso, cancelamento,
   VAD (silero) p/ segmentar; gera `.srt` com timestamps do Whisper.
3. **MT**: (A) onnxruntime + NLLB int8; (B) cliente HTTP p/ API configurável.
4. **Plumbing**: `VideoSource.subtitleUrls` (ou campo `subtitles`), fiação nos
   2 players, picker de legenda + badge **"IA"** + ajuste de delay (±500 ms).
5. **Cache**: `.srt` por (anime, EP, modelo) em disco; nunca regenera igual.
6. **Gating**: mede RAM/CPU (`DeviceCapability` já existe), opt-in por EP,
   aviso em aparelho fraco, download de modelo só no Wi-Fi.
7. **Disclosure**: texto fixo "legenda gerada por IA, pode conter erros".

## 6. Plano sugerido (fases, sem compromisso de prazo)

1. **Fase 0 — benchmark**: APK debug com whisper tiny/base num stick fraco e
   num box forte; mede tempo/EP e pico de RAM. Decide os gates com número,
   não palpite. (~1–2 dias)
2. **Fase 1 — plumbing**: legenda externa no mpv + picker + badge IA, usando
   o `.en.srt` do Archive como fixture. Habilita a feature sem IA. (~3–5 dias)
3. **Fase 2 — STT on-device**: sherpa + tiny/base, opt-in, cache. (~1–2 sem)
4. **Fase 3 — MT**: NLLB int8 (forte) e/ou API (médio). (~1–2 sem)
5. **Fase 4 (opcional) — C**: subir SRTs gerados p/ um endpoint e servir como
   "fonte de legenda" p/ aparelhos fracos.

## 7. Resposta direta: Haibane Renmei

O mp4 JA do Archive (13 EPs, ~140 MB cada) é a "fonte japonesa" pronta; o
pipeline acima geraria PT-BR por EP em minutos (forte) a dezenas de minutos
(fraco, se couber). Nada aqui depende das fontes atuais voltarem — é
independente de AnimeFire/Goyabu.
