#!/usr/bin/env bash
# NOTE: UI-only build (KittenTTS 2 runtime NOT linked). For the full app use scripts/build_app_ipa.sh.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$PROJECT_DIR/KittenTTS2App/KittenTTS2App.xcodeproj"
SCHEME="KittenTTS2App"
CONFIGURATION="Release"
APP_OUTPUT_DIR="$PROJECT_DIR/build/Release-iphoneos"
IPA_OUTPUT="$PROJECT_DIR/build/KittenTTS2App-unsigned.ipa"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required but not found. This script must run on macOS with Xcode installed." >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/build"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_STYLE=Automatic \
  build

APP_PATH="$APP_OUTPUT_DIR/KittenTTS2App.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Expected app at $APP_PATH" >&2
  exit 1
fi

rm -rf "$PROJECT_DIR/build/unsigned_payload"
mkdir -p "$PROJECT_DIR/build/unsigned_payload/Payload"
cp -R "$APP_PATH" "$PROJECT_DIR/build/unsigned_payload/Payload/"

pushd "$PROJECT_DIR/build/unsigned_payload" >/dev/null
zip -qr "$IPA_OUTPUT" Payload
popd >/dev/null

echo "Unsigned IPA created at: $IPA_OUTPUT"
