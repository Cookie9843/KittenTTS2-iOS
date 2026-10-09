# KittenTTS2-iOS

Run KittenTTS 2 locally on your iDevice.

This repository is a minimal iOS app scaffold for porting KittenTTS 2 to iPhone/iPad. The app provides a basic SwiftUI interface for selecting a local model directory and generating speech on-device. The model download is intentionally kept separate so the repository remains lightweight.

## Goals

- Port the KittenTTS 2 inference workflow to iOS
- Keep everything local on-device
- Support model download separately
- Produce an unsigned IPA build in GitHub Actions for CI testing

## Repository contents

- `KittenTTS2App/` — the iOS application
- `.github/workflows/build_unsigned_ipa.yml` — workflow that builds an unsigned IPA and attaches it to a GitHub release
- `scripts/build_unsigned_ipa.sh` — local macOS build script

## Local development

1. Open the Xcode project:
   - `KittenTTS2App/KittenTTS2App.xcodeproj`
2. Build and run on a simulator or physical device
3. Download the KittenTTS 2 model files separately
4. Point the app at the model directory and use the local generation UI

## Note on signing

This project is designed to build without code signing locally or in CI when using the `CODE_SIGNING_ALLOWED=NO` path. An unsigned IPA is useful for testing packaging workflows, but App Store or device installation still requires a valid Apple Developer certificate and provisioning profile.

## GitHub releases

Push a version tag such as `v1.0.0` to build the unsigned IPA on a macOS GitHub Actions runner and create a GitHub release with `KittenTTS2App-unsigned.ipa` attached. The workflow requires the repository's default `GITHUB_TOKEN` to have permission to create releases.

## License

MIT
