#!/usr/bin/env bash
# Guard: no UI-only app build in CI, and the release path builds the real audio.cpp runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "workflow guard: $*" >&2; exit 1; }
[ ! -e .github/workflows/build_unsigned_ipa.yml ] || fail "UI-only workflow must not exist"
[ ! -e scripts/build_unsigned_ipa.sh ] || fail "UI-only build script must not exist"
grep -rlE "scripts/build_unsigned_ipa|-scheme \"?KittenTTS2App" .github/workflows && fail "workflow compiles the app outside build_app_ipa.sh" || true
for w in release ios_audiocpp_kitten2; do
  grep -q "scripts/build_audiocpp_ios.sh" .github/workflows/$w.yml || fail "$w.yml does not build the audio.cpp runtime"
  grep -q "scripts/build_app_ipa.sh" .github/workflows/$w.yml || fail "$w.yml does not build the full app IPA"
done
grep -q "refusing to publish a UI-only build" .github/workflows/release.yml || fail "release.yml lost its native symbol check"
echo "workflow guard OK"
