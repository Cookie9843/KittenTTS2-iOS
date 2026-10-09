#!/usr/bin/env bash
# Builds an UNSIGNED device-targeted test IPA that links the fork-built static libraries from
# scripts/probe_ios_native.sh (set WORK to the same directory). The app only reads a GGUF header and
# loads a model; it never produces audio. Requires macOS + Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:?set WORK to the probe_ios_native.sh work dir}"
OUT="${OUT:-$ROOT/build/native-probe}"
SRC="$WORK/src"
BLD="$WORK/build"
APP="$OUT/Payload/KittenTTS2NativeProbe.app"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MINOS=16.4

LIBS=()
for lib in libllama.a libggml.a libggml-cpu.a libggml-base.a; do
  f="$(find "$BLD" -name "$lib" | head -n1)"
  if [ -z "$f" ]; then echo "MISSING fork-built library: $lib (run probe_ios_native.sh first)" >&2; exit 1; fi
  lipo -info "$f" | grep -q arm64 || { echo "$lib is not arm64" >&2; exit 1; }
  LIBS+=("$f")
done

rm -rf "$OUT"; mkdir -p "$APP" "$OUT/obj"
xcrun --sdk iphoneos clang -c -std=c11 -O2 -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MINOS \
  -I"$SRC/include" -I"$SRC/ggml/include" -I"$ROOT/NativeProbe" \
  "$ROOT/NativeProbe/probe_shim.c" -o "$OUT/obj/probe_shim.o"

xcrun --sdk iphoneos swiftc -parse-as-library -O -target arm64-apple-ios$MINOS -sdk "$SDK" \
  -import-objc-header "$ROOT/NativeProbe/bridging.h" -I"$ROOT/NativeProbe" \
  "$ROOT/NativeProbe/ProbeApp.swift" "$OUT/obj/probe_shim.o" "${LIBS[@]}" \
  -Xlinker -lc++ -framework Accelerate -framework SwiftUI -framework UniformTypeIdentifiers \
  -o "$APP/KittenTTS2NativeProbe"

cp "$ROOT/NativeProbe/Info.plist" "$APP/Info.plist"
echo "== linked fork symbols =="
nm "$APP/KittenTTS2NativeProbe" | grep -E " _(llama_model_load_from_file|gguf_init_from_file)$" \
  || { echo "fork symbols not linked into the probe binary" >&2; exit 1; }
lipo -info "$APP/KittenTTS2NativeProbe"
(cd "$OUT" && /usr/bin/zip -qry "$OUT/KittenTTS2NativeProbe-unsigned.ipa" Payload)
echo "Unsigned test IPA: $OUT/KittenTTS2NativeProbe-unsigned.ipa"
