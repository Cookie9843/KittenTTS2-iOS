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
DD="$OUT/DerivedData"
APP="$DD/Build/Products/Release-iphoneos/$APPNAME.app"

# Diagnostics are collected on every exit path (xcodebuild failure, missing symbol, ...) so CI can always upload them.
collect_diagnostics() {
  set +e
  local obj
  obj="$(find "$DD/Build/Intermediates.noindex/$APPNAME.build" -name 'kt_audiocpp_bridge.o' 2>/dev/null | head -n 1)"
  if [ -n "$obj" ]; then
    echo "$obj" > "$DIAG/bridge-object-path.txt"
    lipo -info "$obj" > "$DIAG/bridge-object-lipo.txt" 2>&1
    nm -m "$obj" > "$DIAG/bridge-object.nm.txt" 2>&1
    otool -l "$obj" > "$DIAG/bridge-object.otool-l.txt" 2>&1
  else
    echo "kt_audiocpp_bridge.o was NOT produced by the app target" > "$DIAG/bridge-object-path.txt"
  fi
  find "$DD/Build/Intermediates.noindex/$APPNAME.build" \( -name '*.resp' -o -name '*.LinkFileList' -o -name '*-linker-args.resp' \) \
    -exec cp {} "$DIAG/" \; 2>/dev/null
  find "$DD/Build/Intermediates.noindex/$APPNAME.build" -name '*.txt' -path '*LinkMap*' -exec cp {} "$DIAG/" \; 2>/dev/null
  if [ -f "$APP/$APPNAME" ]; then
    lipo -info "$APP/$APPNAME" > "$DIAG/app-lipo.txt" 2>&1
    nm -a "$APP/$APPNAME" > "$DIAG/app.nm-a.txt" 2>&1
    nm -m "$APP/$APPNAME" > "$DIAG/app.nm-m.txt" 2>&1
    otool -l "$APP/$APPNAME" > "$DIAG/app.otool-l.txt" 2>&1
    otool -L "$APP/$APPNAME" > "$DIAG/app.otool-L.txt" 2>&1
    grep -E "kt_|audiocpp_(model_load|session_run)|make_kitten_tts2_loader" "$DIAG/app.nm-m.txt" > "$DIAG/app.kt-symbols.txt" 2>&1
  else
    echo "missing $APP/$APPNAME" > "$DIAG/app-lipo.txt"
  fi
  echo "diagnostics written to $DIAG"
}
trap collect_diagnostics EXIT

xcodebuild \
  -project "$ROOT/KittenTTS2App/KittenTTS2App.xcodeproj" \
  -scheme "$APPNAME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) KT_NATIVE_LINKED=1' \
  AUDIOCPP_SOURCE_ROOT="$SRC" \
  OTHER_LDFLAGS="$LDFLAGS" \
  -showBuildSettings > "$DIAG/build-settings.txt" 2>&1 || true

xcodebuild \
  -project "$ROOT/KittenTTS2App/KittenTTS2App.xcodeproj" \
  -scheme "$APPNAME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) KT_NATIVE_LINKED=1' \
  AUDIOCPP_SOURCE_ROOT="$SRC" \
  OTHER_LDFLAGS="$LDFLAGS" \
  LD_GENERATE_MAP_FILE=YES \
  LD_MAP_FILE_PATH="$DIAG/link.map" \
  build 2>&1 | tee "$DIAG/xcodebuild.log"

test -d "$APP" || { echo "missing $APP" >&2; exit 1; }

echo "== linked native symbols =="
nm "$APP/$APPNAME" > "$OUT/app.syms"
missing=0
# Every symbol is reported with its actual nm entries (any case/visibility) so a failure explains itself.
for sym in _audiocpp_model_load _audiocpp_session_run _kt_runtime_linked _kt_load _kt_synthesize _kt_synthesize_clone; do
  if grep -q " T $sym\$" "$OUT/app.syms"; then
    echo "OK   $sym: $(grep " $sym\$" "$OUT/app.syms" | head -n 1)"
  else
    echo "MISSING global text symbol $sym; nm entries: [$(grep -E " $sym\$" "$OUT/app.syms" | tr '\n' ';')]" >&2
    missing=1
  fi
done
grep -q "make_kitten_tts2_loader" "$OUT/app.syms" || { echo "kitten_tts2 loader is not linked into the app" >&2; missing=1; }
# The bridge object must come from the real-runtime branch (it references audiocpp_* ), not the UI-only stub.
if [ -f "$DIAG/bridge-object.nm.txt" ] && ! grep -q "audiocpp_model_load" "$DIAG/bridge-object.nm.txt"; then
  echo "kt_audiocpp_bridge.o does not reference audiocpp_model_load: compiled WITHOUT KT_NATIVE_LINKED (UI-only stub)" >&2
  missing=1
fi
[ "$missing" -eq 0 ] || { echo "full-app link verification failed; see $DIAG" >&2; exit 1; }
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
