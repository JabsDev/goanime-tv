#!/bin/bash
# update_firestick.sh - atualiza o GoAnime TV no Fire Stick PRESERVANDO dados
# do usuário (login, listas, favoritos, progresso de episódios).
#
# Nunca desinstala nem roda `pm clear` — usa `install -r` (in-place). O update
# só funciona quando o APK novo é assinado com a MESMA chave do instalado
# (política do repo: chave DEBUG oficial). Se as chaves divergirem, o Android
# rejeita com INSTALL_FAILED_UPDATE_INCOMPATIBLE — e aí NÃO há como atualizar
# sem desinstalar (perdendo dados); este script avisa nesse caso.
#
# Uso:
#   update_firestick.sh [device] [apk]
#     device  IP:porta do Fire Stick (padrão 100.66.110.37:5555)
#     apk     caminho do APK; se ausente, usa o release APK local; se também
#             ausente, baixa o APK da última release do GitHub via `gh`.
set -eu
D="${1:-100.66.110.37:5555}"
DIR=/home/jabs/codes-ai/goanime-tv
LOCAL_APK="$DIR/build/app/outputs/flutter-apk/app-release.apk"
APK="${2:-}"
PKG=com.example.goanime_tv
TMP_APK=

if [ -n "$APK" ] && [ ! -f "$APK" ]; then
  echo ">> ERRO: APK '$APK' não encontrado." >&2
  exit 1
fi
if [ -z "$APK" ]; then
  if [ -f "$LOCAL_APK" ]; then
    APK="$LOCAL_APK"
    echo ">> APK local: $APK"
  else
    echo ">> APK release local ausente — baixando última release do GitHub..."
    TMP_APK="$(mktemp -d)/goanime-tv-latest.apk"
    gh release download --pattern 'goanime-tv-*.apk' -D "$(dirname "$TMP_APK")"
    mv "$(dirname "$TMP_APK")"/goanime-tv-*.apk "$TMP_APK"
    APK="$TMP_APK"
  fi
fi

echo ">> conectando em $D"
adb connect "$D" >/dev/null 2>&1 || true

OLD="$(adb -s "$D" shell dumpsys package "$PKG" 2>/dev/null | grep -oE 'versionCode=[0-9]+' | head -1 | cut -d= -f2 || true)"
if [ -z "$OLD" ]; then
  echo ">> app não está instalado — instalando do zero (sem dados a preservar)"
fi

echo ">> instala APK novo (install -r — preserva dados do usuário)"
if ! adb -s "$D" install -r "$APK"; then
  echo
  echo ">> FALHA na instalação." >&2
  echo "   Se o erro for INSTALL_FAILED_UPDATE_INCOMPATIBLE, a assinatura do APK" >&2
  echo "   difere da versão instalada — não dá para atualizar preservando dados." >&2
  echo "   Opções: instalar um APK assinado com a mesma chave, ou desinstalar" >&2
  echo "   (perdendo login/listas/progresso) e instalar de novo." >&2
  rm -rf "$(dirname "${TMP_APK:-/dev/null}")" 2>/dev/null || true
  exit 1
fi

echo ">> versão instalada:"
adb -s "$D" shell dumpsys package "$PKG" | grep -E "versionName|versionCode|primaryCpuAbi" | head -3

echo ">> abre o app"
adb -s "$D" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

rm -rf "$(dirname "${TMP_APK:-/dev/null}")" 2>/dev/null || true
echo ">> pronto — dados preservados (login, listas, favoritos, progresso)."
