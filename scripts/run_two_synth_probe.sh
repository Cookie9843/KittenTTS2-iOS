#!/usr/bin/env bash
# Native regression test for the "second generation fails" bug: builds the pinned audio.cpp (with scripts/patches/) for
# THIS machine (CPU only), then synthesizes several texts on one loaded model/session via NativeAudioCpp/tests/two_synth_probe.c.
# Requires an explicit local model: KT_MODEL_PATH=/path/to/kitten-tts2-native-q8-multilingual.gguf. The multi-GB model is
# never downloaded here and this script is not run in CI. A host run is evidence about the host, not about an iPhone.
set -euo pipefail
: "${KT_MODEL_PATH:?set KT_MODEL_PATH to a local KittenTTS 2 .gguf}"
test -f "$KT_MODEL_PATH" || { echo "no such file: $KT_MODEL_PATH" >&2; exit 2; }
AUDIOCPP_REPO="${AUDIOCPP_REPO:-https://github.com/dignome/audio.cpp-custom}"
AUDIOCPP_REF="${AUDIOCPP_REF:-ad1473cd460177480e8a0dc625bd46f76ea49aae}"
WORK="${WORK:-$(mktemp -d)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$WORK/src"; BLD="$WORK/build"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

mkdir -p "$SRC"
git -C "$SRC" init --quiet
git -C "$SRC" remote add origin "$AUDIOCPP_REPO" 2>/dev/null || true
git -C "$SRC" fetch --quiet --depth 1 origin "$AUDIOCPP_REF"
git -C "$SRC" checkout --quiet --force FETCH_HEAD
for name in audiocpp-weight-store-metadata-arena audiocpp-s3-flow-encoder-metadata-arena audiocpp-s3-flow-decoder-metadata-arena audiocpp-hift-backend-graph-arena ggml-init-return-null-on-oom; do
  git -C "$SRC" apply "$ROOT/scripts/patches/$name.patch"
done
cmake -S "$SRC" -B "$BLD" -DCMAKE_BUILD_TYPE=Release -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=kitten_tts2 \
  -DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_HIP=OFF -DENGINE_ENABLE_VULKAN=OFF -DENGINE_ENABLE_METAL=OFF \
  -DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF -DAUDIOCPP_BUILD_C_API=OFF
cmake --build "$BLD" --target engine_runtime --parallel "$JOBS"
LIBS=$(find "$BLD" -name '*.a' | sort | tr '\n' ' ')
EXTRA=""; if [ "$(uname)" = Darwin ]; then EXTRA="-framework Accelerate"; fi
${CXX:-c++} -c -std=c++17 -O2 -I"$SRC/include" -I"$SRC/external/ggml/include" -DAUDIOCPP_VERSION_STRING='"probe"' \
  "$SRC/src/capi/audiocpp.cpp" -o "$WORK/audiocpp.o"
${CC:-cc} -c -O2 -I"$SRC/include" "$ROOT/NativeAudioCpp/tests/two_synth_probe.c" -o "$WORK/probe.o"
# shellcheck disable=SC2086
${CXX:-c++} "$WORK/probe.o" "$WORK/audiocpp.o" $LIBS $EXTRA -lpthread -o "$WORK/two_synth_probe"
"$WORK/two_synth_probe" "$KT_MODEL_PATH"
