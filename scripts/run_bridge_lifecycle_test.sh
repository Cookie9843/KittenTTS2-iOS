#!/usr/bin/env bash
# Host test of the C bridge's session/request lifecycle (NativeAudioCpp/kt_audiocpp_bridge.c) against a fake audio.cpp C ABI.
# No model, no network. Proves the bridge's policy (one shared session, discard-and-rebuild after a failure, no leaks); it
# does not measure the real runtime's memory behaviour.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$ROOT/NativeAudioCpp/tests"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
${CC:-cc} -std=c11 -Wall -Wextra -Werror -DKT_NATIVE_LINKED=1 -I"$T/fake" -I"$ROOT/NativeAudioCpp" \
  "$ROOT/NativeAudioCpp/kt_audiocpp_bridge.c" "$T/fake_audiocpp.c" "$T/lifecycle_test.c" -o "$OUT/lifecycle_test"
"$OUT/lifecycle_test"
