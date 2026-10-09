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
xcodebuild \
  -project "$ROOT/KittenTTS2App/KittenTTS2App.xcodeproj" \
  -scheme "$APPNAME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  GCC_PREPROCESSOR_DEFINITIONS="KT_NATIVE_LINKED=1" \
  HEADER_SEARCH_PATHS="\$(inherited) $ROOT/NativeAudioCpp $SRC/include $SRC/external/ggml/include" \
  OTHER_LDFLAGS="$LDFLAGS" \
  build

APP="$OUT/DerivedData/Build/Products/Release-iphoneos/$APPNAME.app"
test -d "$APP" || { echo "missing $APP" >&2; exit 1; }

echo "== linked native symbols =="
nm "$APP/$APPNAME" > "$OUT/app.syms"
for sym in _audiocpp_model_load _audiocpp_session_run _kt_load _kt_synthesize _kt_synthesize_clone; do
  grep -q " T $sym\$" "$OUT/app.syms" || { echo "symbol $sym is not linked into the app" >&2; exit 1; }
done
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
