# Plano — Legenda IA 100% Offline On-Demand (GoAnime TV)

Premissas: 100% offline, sem nuvem/BYOK, sem Rust. Stack `Dart + Kotlin + ONNX Runtime`.
Fluxo: usuário opt-in por EP -> gera .srt uma vez -> toca com legenda pronta. Nunca tempo-real.
Ordem de custo: `Rota S (traduzir legenda existente) -> L1 (transcrever leve) -> L2 (NLLB qualidade)`.
Carga sequencial: STT descarrega antes de MT subir. Nunca os dois residentes.

## Rotas

- **S (fast-path, padrão quando há legenda):** baixa .srt/.vtt ou extrai track embutida, detecta idioma (tag > nome arquivo > picker manual EN/ES/JA), traduz só texto preservando timestamps. Sem áudio, sem Whisper. ~1min no stick fraco.
- **L1 (transcrever leve):** `Whisper tiny-ja fine-tuned (78MB)` task translate ja->en + `Marian en->pt int8 (~120MB)`. Total ~200MB disco, pico RAM <600MB. Roda em stick 1.5GB.
- **L2 (qualidade, opt-in aparelho forte):** `Whisper base (142MB)` transcribe ja + `NLLB-600M int8 (~1.28GB: encoder 400MB + decoder 450MB + decoder_with_past 425MB)`. Gated por RAM/disco. Não usar `decoder_merged` (crash Reshape no ONNX Runtime Android — usar decoder + decoder_with_past separados).

## Catálogo de modelos (catalog/models.json)

```json
{
  "whisper-tiny-ja": {"mb": 78, "sha256": "PINAR", "strongOnly": false},
  "whisper-base": {"mb": 142, "sha256": "PINAR", "strongOnly": false},
  "marian-en-pt-int8": {"mb": 120, "sha256": "PINAR", "strongOnly": false},
  "nllb-600M-int8": {"mb": 1280, "sha256": "PINAR", "strongOnly": true}
}
```
Download só Wi-Fi, com Range/resume, sha256, delete manual em Settings.

## Validade do .srt offline — TTL 5 dias

- Local: `appSupport/subs/{animeKey}/ep{N}.{srcLang}-{mt}.srt` + sidecar `.meta.json {createdAt, srcHash}`.
- Regra: `TTL = 5 dias corridos desde createdAt`. Sem sliding (acesso não renova — ponytail: 1 timestamp resolve).
- Leitura (`SubtitleStore.get`): se `now - createdAt > 5d` -> deleta `.srt + .meta` e retorna null (picker volta a mostrar "Gerar/Traduzir").
- Limpeza: `SubtitleStore.pruneExpired()` chamada em (1) `main()` após `LocalStorage.init`, (2) ao completar um job, (3) ao abrir Detail (fire-and-forget, throttle 24h via prefs). Varre só a pasta `subs/`, sem isolate.
- Sem LRU além disso. Settings mostra `espaço usado` + botão `Apagar legendas IA`.
- Constante única: `SubtitleStore.kSrtTtl = Duration(days: 5)` — mudar aqui muda tudo. Teste unitário cobre `get` expirado + `prune`.

```dart
// ponytail: validade por mtime do .meta, sem DB novo. Acesso não renova.
class SubtitleStore {
  static const kSrtTtl = Duration(days: 5);
  static File? get(animeKey, ep, tag) { // null se expirado (e deleta)
  static Future<void> pruneExpired() async {} // varredura subs/
}
```

## Fases

### Fase 0 — Plumbing legenda (3-5d)
`VideoSource.subtitleCandidates/subtitleUrls: List<SubtitleRef{label,lang,uri,isAI}>`, fiação mpv + ExoDash, picker + badge IA + delay ±500ms + disclaimer. Fixture `.en.srt` Archive. Aceite: EP toca com .srt externo.

### Fase 1 — Infra + Rota S (1 sem)
`SubtitleStore (com TTL acima) + ModelManager + AudioExtractChannel.kt (getSubtitleTracks + PCM 16kHz) + SrtParser + MtProvider Marian`. Aceite: EN->PT offline fim-a-fim, cache hit não retraduz, expirado some após 5d.

### Fase 2 — STT L1 (1-2 sem)
`sherpa_onnx` isolate + VAD silero + `SubtitleJobManager {translateOnly, transcribeL1}`. Aceite: JA cru gera PT-BR em stick fraco sem travar UI.

### Fase 3 — L2 NLLB opt-in (1-2 sem)
`NllbTranslator.kt` (2 decoders separados, SentencePiece puro-Kotlin), gating `!isLowEnd + disco>2GB`. Aceite: mesma EP com qualidade superior em Shield.

### Fase 4 — Polish TV (3d)
Diálogo D-pad (Gerar/Traduzir/Apagar), progresso/cancelar, Settings (STT tiny/base, MT leve/completa, espaço, apagar tudo). Aceite: fluxo só no controle remoto.

## Riscos
Espaço 8GB, decoder_merged crash, CER tiny vanilla (usar tiny-ja fine-tuned). Cortado: tempo-real, servidor, upload comunitário, Tower 7B, ffmpeg-kit, Rust.
