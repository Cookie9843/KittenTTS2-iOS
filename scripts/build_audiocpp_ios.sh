#!/usr/bin/env bash
# Cross-compiles the actual audio.cpp KittenTTS 2 native CPU runtime (pinned revision of the community
# branch dignome/audio.cpp-custom@kittentts2) as static libraries for iOS arm64, plus audio.cpp's C ABI
# (src/capi/audiocpp.cpp). macOS + Xcode + cmake required. No model file is read or downloaded here.
set -euo pipefail

AUDIOCPP_REPO="${AUDIOCPP_REPO:-https://github.com/dignome/audio.cpp-custom}"
# Tip of branch kittentts2 when this test was written ("Scope Kitten TTS 2 integration and move headers under include").
AUDIOCPP_REF="${AUDIOCPP_REF:-ad1473cd460177480e8a0dc625bd46f76ea49aae}"
WORK="${WORK:-$(mktemp -d)}"
LOG_DIR="${LOG_DIR:-$WORK/logs}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$WORK/src"
BLD="$WORK/build"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MINOS=16.4
# Conservative CPU target: Apple A13 / M-series class (ARMv8.2 + dot product + fp16 vector arithmetic).
ARM_ARCH="${ARM_ARCH:-armv8.2-a+dotprod+fp16}"
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
  for f in CMakeFiles/CMakeError.log CMakeFiles/CMakeOutput.log .ninja_log; do
    if [ -f "$BLD/$f" ]; then cp "$BLD/$f" "$LOG_DIR/$(basename "$f")" || true; fi
  done
}
trap report EXIT
echo "audio.cpp: $AUDIOCPP_REPO @ $AUDIOCPP_REF; generator: $GENERATOR; jobs: $JOBS; arm arch: $ARM_ARCH; work: $WORK"

LAST_STEP="fetch"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC"
  git -C "$SRC" init --quiet
  git -C "$SRC" remote add origin "$AUDIOCPP_REPO"
fi
git -C "$SRC" fetch --quiet --depth 1 origin "$AUDIOCPP_REF"
git -C "$SRC" checkout --quiet --force FETCH_HEAD
test "$(git -C "$SRC" rev-parse HEAD)" = "$AUDIOCPP_REF" || { echo "pinned revision mismatch" >&2; exit 1; }
echo "== source =="; git -C "$SRC" log -1 --format='%H %s'
grep -n "kitten_tts2" "$SRC/CMakeLists.txt" | head -3

echo "== configure (iOS arm64, CPU only, kitten_tts2 only) =="
LAST_STEP="configure"
cmake -G "$GENERATOR" ${CCACHE_ARGS[@]+"${CCACHE_ARGS[@]}"} -S "$SRC" -B "$BLD" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$MINOS -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PROJECT_INCLUDE="$ROOT/scripts/cmake/ios_stubs.cmake" \
  -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=kitten_tts2 \
  -DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_HIP=OFF -DENGINE_ENABLE_VULKAN=OFF -DENGINE_ENABLE_METAL=OFF \
  -DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF -DENGINE_ENABLE_NATIVE_CPU=OFF \
  -DGGML_CPU_ARM_ARCH="$ARM_ARCH" \
  -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF -DAUDIOCPP_BUILD_C_API=OFF 2>&1 | tee "$LOG_DIR/configure.log"
grep -q "audio.cpp model composite: custom selected \[kitten_tts2\]" "$LOG_DIR/configure.log" \
  || { echo "kitten_tts2 was not selected by CMake" >&2; exit 1; }

echo "== build engine_runtime (+ggml, sentencepiece, cJSON, libyaml) =="
LAST_STEP="build engine_runtime"
cmake --build "$BLD" --target engine_runtime --parallel "$JOBS" 2>&1 | tee "$LOG_DIR/build.log"

echo "== compile audio.cpp C ABI facade =="
LAST_STEP="compile capi"
mkdir -p "$WORK/capi"
xcrun --sdk iphoneos clang++ -c -std=c++17 -O2 -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MINOS \
  -I"$SRC/include" -I"$SRC/external/ggml/include" -DAUDIOCPP_VERSION_STRING="\"ios-test-${AUDIOCPP_REF:0:7}\"" \
  "$SRC/src/capi/audiocpp.cpp" -o "$WORK/capi/audiocpp.o" 2>&1 | tee "$LOG_DIR/capi.log"

echo "== artifacts =="
LAST_STEP="verify"
find "$BLD" -name '*.a' | sort > "$WORK/libs.txt"
while read -r lib; do lipo -info "$lib"; done < "$WORK/libs.txt"
while read -r lib; do lipo -info "$lib" | grep -q arm64 || { echo "$lib is not arm64" >&2; exit 1; }; done < "$WORK/libs.txt"
for lib in libengine_runtime.a libggml.a libggml-base.a libggml-cpu.a; do
  grep -q "/$lib\$" "$WORK/libs.txt" || { echo "MISSING expected static library: $lib" >&2; exit 1; }
done
# Dump symbols to files first: `nm | grep -q` would trip pipefail via SIGPIPE.
RUNTIME_LIB="$(grep '/libengine_runtime.a$' "$WORK/libs.txt" | head -n1)"
nm "$RUNTIME_LIB" > "$WORK/runtime.syms" 2>/dev/null || true
grep -q "make_kitten_tts2_loader" "$WORK/runtime.syms" || { echo "kitten_tts2 loader is not in libengine_runtime.a" >&2; exit 1; }
nm "$WORK/capi/audiocpp.o" > "$WORK/capi.syms"
grep -q " T _audiocpp_session_run" "$WORK/capi.syms" || { echo "C ABI missing audiocpp_session_run" >&2; exit 1; }
echo "RESULT: audio.cpp kitten_tts2 CPU runtime + C ABI built for iOS arm64. This proves compilation only; load/inference on a device is unverified."
