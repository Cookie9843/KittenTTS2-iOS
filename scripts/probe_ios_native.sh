#!/usr/bin/env bash
# Experimental feasibility probe (macOS only): cross-compiles upstream's custom llama.cpp fork
# (KittenML/kitten-tts-2-cpp, TQ2_1 support) as static libraries for iOS arm64.
# This does NOT build the decoder (LibTorch has no supported iOS path) and does NOT produce audio.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/KittenML/kitten-tts-2-cpp}"
UPSTREAM_REF="${UPSTREAM_REF:-1ce0bb504e5452795b52ca9a3c3950e982d82bb1}"
WORK="${WORK:-$(mktemp -d)}"
LOG_DIR="${LOG_DIR:-$WORK/logs}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then GENERATOR="Ninja"; fi
CCACHE_ARGS=()
if command -v ccache >/dev/null 2>&1; then
  CCACHE_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi
mkdir -p "$LOG_DIR"
START=$SECONDS
LAST_STEP="init"
report() {
  local rc=$?
  echo "== elapsed: $((SECONDS - START))s, exit code: $rc, last step: $LAST_STEP =="
  if command -v ccache >/dev/null 2>&1; then ccache -s || true; fi
  if [ -f "$WORK/build/.ninja_log" ]; then cp "$WORK/build/.ninja_log" "$LOG_DIR/" || true; fi
  if [ -f "$WORK/build/CMakeFiles/CMakeError.log" ]; then cp "$WORK/build/CMakeFiles/CMakeError.log" "$LOG_DIR/" || true; fi
  if [ -f "$WORK/build/CMakeFiles/CMakeOutput.log" ]; then cp "$WORK/build/CMakeFiles/CMakeOutput.log" "$LOG_DIR/" || true; fi
}
trap report EXIT
echo "upstream: $UPSTREAM_REPO @ $UPSTREAM_REF; generator: $GENERATOR; jobs: $JOBS; work: $WORK"

git clone --quiet "$UPSTREAM_REPO" "$WORK/src"
git -C "$WORK/src" checkout --quiet "$UPSTREAM_REF"

echo "== TQ2_1 present in fork's ggml.h =="
grep -n "TQ2_1" "$WORK/src/ggml/include/ggml.h" | head -3

echo "== configure (iOS arm64, $GENERATOR, no signing needed) =="
LAST_STEP="configure"
cmake -G "$GENERATOR" "${CCACHE_ARGS[@]}" -S "$WORK/src" -B "$WORK/build" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4 -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=OFF \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_MTMD=OFF

echo "== build libllama + ggml =="
LAST_STEP="build: cmake --build $WORK/build --target llama --parallel $JOBS"
echo "+ cmake --build $WORK/build --target llama --parallel $JOBS"
cmake --build "$WORK/build" --target llama --parallel "$JOBS" --verbose 2>&1 | tee "$LOG_DIR/build.log"

echo "== artifacts =="
LAST_STEP="verify"
find "$WORK/build" -name '*.a' -print -exec lipo -info {} \;
for lib in libllama.a libggml.a libggml-base.a libggml-cpu.a; do
  f="$(find "$WORK/build" -name "$lib" | head -n1)"
  if [ -z "$f" ]; then echo "MISSING expected static library: $lib" >&2; exit 1; fi
  lipo -info "$f" | grep -q arm64 || { echo "$lib is not arm64" >&2; exit 1; }
done
echo "RESULT: llama fork (TQ2_1) static libs built for iOS arm64. Generation still unverified (decoder, normalizer, runtime glue not built)."
