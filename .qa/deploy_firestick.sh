#!/bin/bash
# deploy_firestick.sh - força a instalação no Fire Stick limpando dados/cache.
# O APK novo só instala se incluir libs ARM (armeabi-v7a/arm64-v8a) — o
# abiFilters x86_64 (emulador) impede isso; removido do build.gradle.kts.
# Usage: deploy_firestick.sh [device]
set -eu
D="${1:-100.66.110.37:5555}"
DIR=/home/jabs/codes-ai/goanime-tv
APK="$DIR/build/app/outputs/flutter-apk/app-release.apk"
PKG=com.example.goanime_tv

cd "$DIR"
[ -f "$APK" ] || { echo ">> APK ausente, buildando..."; flutter build apk --release; }

echo ">> desinstala versão anterior (limpa dados/cache)"
adb -s "$D" uninstall "$PKG" || true

echo ">> instala APK novo (-r -d)"
adb -s "$D" install -r -d "$APK"

echo ">> limpa cache/dados do app"
adb -s "$D" shell pm clear "$PKG"

echo ">> valida versão instalada"
adb -s "$D" shell dumpsys package "$PKG" | grep -E "versionName|primaryCpuAbi" || true

echo ">> abre o app"
adb -s "$D" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
