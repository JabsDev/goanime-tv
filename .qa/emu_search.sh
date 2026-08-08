#!/bin/bash
# emu_search.sh - reliable search flow on Android TV emulator (GoAnime_TV)
# Usage: emu_search.sh <query> <outprefix>
set -u
DEV="emulator-5554"
Q="$1"
OUT="$2"
DIR=/home/jabs/codes-ai/goanime-tv/.qa/emu

shot() { adb -s $DEV exec-out screencap -p > "$DIR/$OUT$1.png" 2>/dev/null; }
key() { adb -s $DEV shell input keyevent "$1"; }

# ensure on Home of the app (relaunch app)
adb -s $DEV shell monkey -p com.example.goanime_tv -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 6
# Buscar button is focused on boot (autofocus B13) -> press select
key KEYCODE_DPAD_CENTER
sleep 2
shot _a1_search
# type query (no spaces)
adb -s $DEV shell input text "$Q"
sleep 2
# keyboard: press DOWN several times to get to bottom action row, then RIGHT to search
for i in $(seq 1 8); do key KEYCODE_DPAD_DOWN; sleep 0.25; done
for i in $(seq 1 7); do key KEYCODE_DPAD_RIGHT; sleep 0.25; done
key KEYCODE_DPAD_CENTER
sleep 10
shot _a2_results
