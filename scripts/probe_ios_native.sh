#!/usr/bin/env bash
# Experimental feasibility probe (macOS only): cross-compiles upstream's custom llama.cpp fork
# (KittenML/kitten-tts-2-cpp, TQ2_1 support) as static libraries for iOS arm64.
# This does NOT build the decoder (LibTorch has no supported iOS path) and does NOT produce audio.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/KittenML/kitten-tts-2-cpp}"
UPSTREAM_REF="${UPSTREAM_REF:-1ce0bb504e5452795b52ca9a3c3950e982d82bb1}"
WORK="${WORK:-$(mktemp -d)}"

git clone --quiet "$UPSTREAM_REPO" "$WORK/src"
git -C "$WORK/src" checkout --quiet "$UPSTREAM_REF"

echo "== TQ2_1 present in fork's ggml.h =="
grep -n "TQ2_1" "$WORK/src/ggml/include/ggml.h" | head -3

echo "== configure (iOS arm64, Unix Makefiles, no signing needed) =="
cmake -S "$WORK/src" -B "$WORK/build" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=OFF \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_MTMD=OFF

echo "== build libllama + ggml =="
cmake --build "$WORK/build" --target llama --parallel

echo "== artifacts =="
find "$WORK/build" -name '*.a' -print -exec lipo -info {} \;
echo "RESULT: llama fork (TQ2_1) static libs built for iOS arm64. Generation still unverified (decoder, normalizer, runtime glue not built)."
