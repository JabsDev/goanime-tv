# Como rodar o fluxo de auditoria no celular (retomar depois)

Estado em 2026-10-01: **tudo pronto; é só reconectar o aparelho e rodar.**

## O que foi implementado

Fluxo completo, 4 estágios, com os SRTs de cada um salvos para comparação:

```
STT (student whisper-small destilado)
  → auditar JA   (Heretic gemma-3 1B uncensored)
  → traduzir     (Qwen3-0.6B anime JA→PT)
  → auditar PT   (mesmo auditor)
  → 4 arquivos .srt
```

Arquivos gerados (em `/sdcard/Download/`, senão `/data/local/tmp/`):
```
ep3_1_bruto_ja.srt    transcrição crua
ep3_2_audit_ja.srt    após auditoria do japonês
ep3_3_bruto_pt.srt    tradução crua
ep3_4_audit_pt.srt    após auditoria do português
```

## Antes de rodar (aparelho plugado)

1. Verificar device: `adb devices`
2. Os modelos **já estão no aparelho** (não precisa re-subir):
   - `/data/local/tmp/jav03/` → STT (mel/encoder/decoder/tokens/vad) + `ep3.pcm` + `ep3_trecho.pcm`
   - `/data/local/tmp/models_stage/` → `auditor.gguf` (Heretic), `Qwen3-0.6B-JA-PT-Anime-Q4_K_M.gguf`
   - Se o aparelho foi reiniciado e `/data/local/tmp` sumiu, ver **Repor** abaixo.

## Rodar

```bash
export PATH="$PATH:/home/jabs/.cache/flutter_sdk/bin"
export JAVA_HOME=/home/jabs/tools/jdk-21
cd /home/jabs/work/goanime-tv-fresh

# trecho de 2 min (rápido, ~5 min no total) — valida o fluxo inteiro
flutter test integration_test/audit_flow_test.dart -d <SERIAL>

# EP3 completo (23 min; trocar o caminho p/ 'ep3.pcm' no teste)
```

O teste imprime `STT_OK / AUDIT_JA_OK / MT_OK / AUDIT_PT_OK` e amostras
`L0 JA / L0 AJ / L0 PT / L0 AP`. Puxar os SRTs:

```bash
adb pull /sdcard/Download/ep3_1_bruto_ja.srt /tmp/opencode/
adb pull /sdcard/Download/ep3_2_audit_ja.srt /tmp/opencode/
adb pull /sdcard/Download/ep3_3_bruto_pt.srt /tmp/opencode/
adb pull /sdcard/Download/ep3_4_audit_pt.srt /tmp/opencode/
```

## Repor (se o aparelho for reiniciado e /data/local/tmp sumir)

```bash
D=/data/local/tmp/models_stage; adb shell "mkdir -p $D"
adb push /tmp/opencode/student-final/mel.onnx $D/
adb push /tmp/opencode/student-final/encoder_model.int8.onnx $D/
adb push /tmp/opencode/student-final/encoder_model.int8.onnx.data $D/
adb push /tmp/opencode/student-final/decoder_model.int8.onnx $D/
adb push /tmp/opencode/student-final/decoder_model.int8.onnx.data $D/
adb push /tmp/opencode/student-final/tokens.txt $D/
adb push /tmp/opencode/heretic-q4km.gguf $D/auditor.gguf
adb push /home/jabs/work/models_push/Qwen3-0.6B-JA-PT-Anime-Q4_K_M.gguf $D/
adb push /tmp/opencode/vad.onnx /data/local/tmp/jav03/vad.onnx
adb push /tmp/opencode/ep3_trecho.pcm /data/local/tmp/jav03/ep3_trecho.pcm
adb push /tmp/opencode/ep3.pcm /data/local/tmp/jav03/ep3.pcm
```

## Bug corrigido no caminho (para não repetir)

A auditoria era **pulada em silêncio** porque o `mb` do catálogo dos
auditores era maior que o arquivo real (ex.: heretic 812 vs 769 MB) e o
`ModelManager.isValidGguf` exige ≥95%. `mb` agora bate com o arquivo:
heretic 769, qwen3 767, lfm25-dist 146, lfm12b 540.

## O que já se sabe (medido, mas vale rever com anime real)

O protocolo no host mostrou que este auditor **piora** a transcrição no
galgame (CER 21% → 30%). O teste no celular é para ver se, num episódio real
e no olho, o resultado compensa. Se não compensar, a recomendação do
`RELATORIO-AUDITORIA-LEGENDA.md` é desligar (chave fica `off` por padrão).
