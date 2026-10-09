#!/usr/bin/env bash
# Links the SwiftUI test app against the audio.cpp runtime built by scripts/build_audiocpp_ios.sh (same WORK dir)
# and packages an UNSIGNED device IPA. The IPA contains no model weights. macOS + Xcode required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:?set WORK to the build_audiocpp_ios.sh work dir}"
OUT="${OUT:-$ROOT/build/audiocpp-test}"
SRC="$WORK/src"
APPNAME=KittenTTS2AudioCppTest
APP="$OUT/Payload/$APPNAME.app"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MINOS=16.4
REV="$(git -C "$SRC" rev-parse HEAD)"

test -s "$WORK/libs.txt" && test -f "$WORK/capi/audiocpp.o" || { echo "run build_audiocpp_ios.sh first" >&2; exit 1; }
LIBS=()
while read -r lib; do LIBS+=("$lib"); done < "$WORK/libs.txt"

rm -rf "$OUT"; mkdir -p "$APP" "$OUT/obj"
xcrun --sdk iphoneos clang -c -std=c11 -O2 -DKT_NATIVE_LINKED=1 -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MINOS \
  -I"$SRC/include" -I"$SRC/external/ggml/include" -I"$ROOT/NativeAudioCpp" "$ROOT/NativeAudioCpp/kt_audiocpp_bridge.c" -o "$OUT/obj/bridge.o"

xcrun --sdk iphoneos swiftc -parse-as-library -O -target arm64-apple-ios$MINOS -sdk "$SDK" \
  -import-objc-header "$ROOT/NativeAudioCpp/bridging.h" -I"$ROOT/NativeAudioCpp" \
  "$ROOT/NativeAudioCpp/AudioCppTestApp.swift" "$ROOT/Sources/KittenCore/AudioCppGGUF.swift" "$ROOT/Sources/KittenCore/AudioCppDiagnostics.swift" "$ROOT/Sources/KittenCore/WAVEncoder.swift" \
  "$OUT/obj/bridge.o" "$WORK/capi/audiocpp.o" "${LIBS[@]}" \
  -Xlinker -dead_strip -Xlinker -lc++ -framework Accelerate -framework SwiftUI -framework UniformTypeIdentifiers -framework AVFoundation \
  -o "$APP/$APPNAME"

cp "$ROOT/NativeAudioCpp/Info.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :KTAudioCppRevision $REV" "$APP/Info.plist"

mkdir -p "$APP/Licenses"
cp "$ROOT/LICENSE" "$APP/Licenses/KittenTTS2-iOS-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Licenses/"
for f in LICENSE external/ggml/LICENSE external/sentencepiece/LICENSE external/cJSON/LICENSE external/libyaml/License external/libyaml/LICENSE; do
  if [ -f "$SRC/$f" ]; then cp "$SRC/$f" "$APP/Licenses/audio.cpp-$(echo "$f" | tr '/' '_')"; fi
done

echo "== linked native symbols =="
nm "$APP/$APPNAME" > "$OUT/app.syms"
grep -E " _(audiocpp_model_load|audiocpp_session_run|kt_load|kt_synthesize)$" "$OUT/app.syms" | sort
for sym in _audiocpp_model_load _audiocpp_session_run _kt_load _kt_synthesize; do
  grep -q " T $sym\$" "$OUT/app.syms" || { echo "symbol $sym is not linked into the app" >&2; exit 1; }
done
grep -q "make_kitten_tts2_loader" "$OUT/app.syms" || { echo "kitten_tts2 loader is not linked into the app" >&2; exit 1; }
lipo -info "$APP/$APPNAME"
if [ -n "$(find "$OUT/Payload" -iname '*.gguf')" ]; then echo "a .gguf ended up inside the IPA" >&2; exit 1; fi
(cd "$OUT" && /usr/bin/zip -qry "$OUT/KittenTTS2AudioCppTest-unsigned.ipa" Payload)
ls -l "$OUT/KittenTTS2AudioCppTest-unsigned.ipa"
echo "RESULT: unsigned test IPA linked against audio.cpp kitten_tts2 runtime: $OUT/KittenTTS2AudioCppTest-unsigned.ipa"
