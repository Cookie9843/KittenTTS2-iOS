#!/usr/bin/env bash
# Builds the FULL KittenTTS app (SwiftUI, KittenTTS 0.8 SDK + KittenTTS 2) for iPhone/iPad as an UNSIGNED IPA, linking the
# audio.cpp kitten_tts2 runtime built by scripts/build_audiocpp_ios.sh (same WORK dir). The same C bridge
# (NativeAudioCpp/kt_audiocpp_bridge.c) is compiled into the app; -DKT_NATIVE_LINKED=1 switches it from the UI-only stub to
# the real runtime. No model weights are bundled. macOS + Xcode required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:?set WORK to the build_audiocpp_ios.sh work dir}"
OUT="${OUT:-$ROOT/build/app-ipa}"
SRC="$WORK/src"
APPNAME=KittenTTS2App

test -s "$WORK/libs.txt" && test -f "$WORK/capi/audiocpp.o" || { echo "run build_audiocpp_ios.sh first" >&2; exit 1; }
LDFLAGS="$WORK/capi/audiocpp.o"
while read -r lib; do LDFLAGS="$LDFLAGS $lib"; done < "$WORK/libs.txt"
LDFLAGS="$LDFLAGS -lc++ -framework Accelerate"

rm -rf "$OUT"; mkdir -p "$OUT"
DIAG="$OUT/diagnostics"; mkdir -p "$DIAG"

# Every override below is shared by all targets (SwiftPM targets included). LD_MAP_FILE_PATH is deliberately NOT set:
# Xcode's default is per target ($(TARGET_TEMP_DIR)/...-LinkMap-...txt), so a global LD_GENERATE_MAP_FILE=YES cannot make
# several targets write the same file ("Multiple commands produce").
XCB_ARGS=(
  -project "$ROOT/KittenTTS2App/KittenTTS2App.xcodeproj"
  -scheme "$APPNAME"
  -configuration Release
  -destination "generic/platform=iOS"
  -derivedDataPath "$OUT/DerivedData"
  CODE_SIGNING_ALLOWED=NO
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) KT_NATIVE_LINKED=1'
  AUDIOCPP_SOURCE_ROOT="$SRC"
  OTHER_LDFLAGS="$LDFLAGS"
  LD_GENERATE_MAP_FILE=YES
)

# Runs on ANY exit (success, xcodebuild failure, failed symbol check). Never changes the exit status.
collect_diagnostics() {
  local rc=$?
  set +e
  OUT="$OUT" DIAG="$DIAG" APPNAME="$APPNAME" ROOT="$ROOT" \
    bash "$ROOT/scripts/collect_app_link_diagnostics.sh" -- "${XCB_ARGS[@]}" >"$DIAG/collect.log" 2>&1 \
    || echo "diagnostic collection reported errors (see $DIAG/collect.log)" >&2
  exit $rc
}
trap collect_diagnostics EXIT

xcodebuild "${XCB_ARGS[@]}" build 2>&1 | tee "$DIAG/xcodebuild.log"

APP="$OUT/DerivedData/Build/Products/Release-iphoneos/$APPNAME.app"
test -d "$APP" || { echo "missing $APP" >&2; exit 1; }

echo "== linked native symbols =="
nm "$APP/$APPNAME" > "$OUT/app.syms"
for sym in _audiocpp_model_load _audiocpp_session_run _kt_runtime_linked _kt_load _kt_synthesize _kt_synthesize_clone; do
  grep -q " T $sym\$" "$OUT/app.syms" || { echo "symbol $sym is not linked into the app" >&2; exit 1; }
done
grep -Eq " [A-Za-z] _kt_bridge_build_variant\$" "$OUT/app.syms" && strings -a "$APP/$APPNAME" | grep -q "kt-bridge-variant:native-linked" \
  || { echo "the app's bridge was NOT compiled with KT_NATIVE_LINKED=1 (see $DIAG)" >&2; exit 1; }
grep -q "make_kitten_tts2_loader" "$OUT/app.syms" || { echo "kitten_tts2 loader is not linked into the app" >&2; exit 1; }
lipo -info "$APP/$APPNAME"
if [ -n "$(find "$APP" -iname '*.gguf')" ]; then echo "a .gguf ended up inside the app" >&2; exit 1; fi

mkdir -p "$APP/Licenses"
cp "$ROOT/LICENSE" "$APP/Licenses/KittenTTS2-iOS-LICENSE.txt"
for f in LICENSE external/ggml/LICENSE external/sentencepiece/LICENSE external/cJSON/LICENSE external/libyaml/License external/libyaml/LICENSE; do
  if [ -f "$SRC/$f" ]; then cp "$SRC/$f" "$APP/Licenses/audio.cpp-$(echo "$f" | tr '/' '_')"; fi
done

mkdir -p "$OUT/ipa/Payload"
cp -R "$APP" "$OUT/ipa/Payload/"
(cd "$OUT/ipa" && /usr/bin/zip -qry "$OUT/KittenTTS-unsigned.ipa" Payload)
ls -l "$OUT/KittenTTS-unsigned.ipa"
echo "RESULT: unsigned full-app IPA linked against audio.cpp kitten_tts2 runtime: $OUT/KittenTTS-unsigned.ipa"
