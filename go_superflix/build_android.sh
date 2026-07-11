#!/bin/bash
# Build Go shared library for Android (arm64-v8a and x86_64)
set -e

export GOROOT=${GOROOT:-/home/jabs/go}
export GOPATH=${GOPATH:-/home/jabs/go_path}
export PATH=$GOROOT/bin:$PATH
export GOTOOLCHAIN=local

NDK=${NDK:-/home/jabs/Android/Sdk/ndk/28.2.13676358}
SRCDIR="$(dirname "$0")"

echo "==> Building libsuperflix.so for arm64-v8a..."
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang"
OUTDIR="$SRCDIR/build/android/arm64-v8a"
mkdir -p "$OUTDIR"
cd "$SRCDIR" && CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$CC" \
  go build -buildmode=c-shared -ldflags="-s -w" -o "$OUTDIR/libsuperflix.so" .
echo "    arm64-v8a: $OUTDIR/libsuperflix.so ($(ls -lh "$OUTDIR/libsuperflix.so" | awk '{print $5}'))"

echo "==> Building libsuperflix.so for x86_64..."
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android21-clang"
OUTDIR="$SRCDIR/build/android/x86_64"
mkdir -p "$OUTDIR"
cd "$SRCDIR" && CGO_ENABLED=1 GOOS=android GOARCH=amd64 CC="$CC" \
  go build -buildmode=c-shared -ldflags="-s -w" -o "$OUTDIR/libsuperflix.so" .
echo "    x86_64: $OUTDIR/libsuperflix.so ($(ls -lh "$OUTDIR/libsuperflix.so" | awk '{print $5}'))"

echo "==> Copying to Flutter jniLibs..."
JNIDIR="$SRCDIR/../android/app/src/main/jniLibs"
cp "$SRCDIR/build/android/arm64-v8a/libsuperflix.so" "$JNIDIR/arm64-v8a/libsuperflix.so"
cp "$SRCDIR/build/android/x86_64/libsuperflix.so" "$JNIDIR/x86_64/libsuperflix.so"
echo "    Done!"
