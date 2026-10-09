# KittenTTS2-iOS

Generate speech with [KittenTTS](https://github.com/KittenML/KittenTTS) **entirely on-device** on iPhone/iPad.

The app uses the official KittenML Swift SDK, [`KittenML/KittenTTS-swift`](https://github.com/KittenML/KittenTTS-swift) (v0.1.0, Apache-2.0), which runs the ONNX models with ONNX Runtime. Nothing is faked: text is phonemized, run through the model and the resulting audio is saved and played back locally.

## Features

- Model readiness: download an official model, or import your own `.onnx` + `voices.npz`; files are validated before use
- Voice list built from the voices that are **actually present** in the model's `voices.npz` (and supported by the SDK)
- Editable text, speed control, Generate / Cancel, progress and error states
- Local playback, stop, and share/export of the generated WAV (24 kHz, 16-bit mono)
- Persisted recent generations (last 25, with audio) that can be replayed, shared or deleted
- VoiceOver labels/hints, Dynamic Type friendly standard controls

## Models, SDK compatibility and licenses

| Model (SDK `KittenModel`) | Hugging Face repo | Approx. download (model + voices) |
| --- | --- | --- |
| Nano fp32 (`.nano`, default) | `KittenML/kitten-tts-nano-0.8` | ~59 MB |
| Nano int8 (`.nanoInt8`) | `KittenML/kitten-tts-nano-0.8-int8` | ~28 MB |
| Micro (`.micro`) | `KittenML/kitten-tts-micro-0.8` | ~44 MB |
| Mini (`.mini`) | `KittenML/kitten-tts-mini-0.8` | ~83 MB |

- **Minimum platform:** iOS 16.0 (SDK requirement), Swift 5.9 / Xcode 15+.
- **Voices (SDK):** Bella, Jasper, Luna, Bruno, Rosie, Hugo, Kiki, Leo (`expr-voice-{2..5}-{f,m}`). The app only lists those present in the loaded model's `voices.npz`.
- **Licenses:** the app code is MIT. The SDK is Apache-2.0. **Model weights are distributed separately under their own license** — check the model card of the repo you use (see [KittenML/KittenTTS](https://github.com/KittenML/KittenTTS)) before redistributing them. This repository does **not** contain any model files.
- **Phonemizer data:** the SDK's default built-in phonemizer (`EPhonemizer`) downloads the GPL-v3 licensed `en_rules`/`en_list` data files at runtime on first use; they are not bundled in this app or repository.
- **Language:** the SDK's built-in phonemizer is English only.

### Limitations

- First use needs internet: the model (unless imported) **and** the phonemizer data files are downloaded once, then everything is cached and works offline.
- Importing a model still downloads the phonemizer data on first load.
- The SDK has no cancellation API: *Cancel* stops waiting and discards the result, but the sentence currently being synthesized finishes in the background. Progress is reported per generated sentence (the SDK does not expose a total).
- Only the SDK's eight known voice IDs are usable; other embeddings in a custom `voices.npz` are ignored.
- The CI IPA is **unsigned**; installing it on a device requires re-signing (e.g. with your own Apple Developer account).
- This code has been unit tested for the logic layer only (see below); the UI/inference path needs to be exercised on a device or simulator. Larger models (mini) need more memory and time.

## Getting model assets

**Option A – in-app download (simplest):** choose a model, tap *Download and load model*. The SDK fetches `voices.npz` and the `.onnx` file from `https://huggingface.co/KittenML/<model>`.

**Option B – import files:**
1. From the model's Hugging Face page (e.g. `KittenML/kitten-tts-nano-0.8`) download the `.onnx` file (`kitten_tts_nano_v0_8.onnx`, `kitten_tts_micro_v0_8.onnx` or `kitten_tts_mini_v0_8.onnx`) and `voices.npz`. Only use assets whose license allows your use.
2. Put them in the Files app (iCloud Drive or *On My iPhone*).
3. In the app, pick the matching model in the **Model** picker, tap *Import model files…* and select **both** files at once. They are validated (extension, size, valid `.npz` containing supported voices) and copied into the app's sandbox. Then tap *Load model*.

## Build and run

1. Open `KittenTTS2App/KittenTTS2App.xcodeproj` in Xcode 15+ (Swift Package dependencies, `KittenML/KittenTTS-swift` and its ONNX Runtime dependency, resolve automatically).
2. Run on a simulator or device (iOS 16+).

Without Xcode: build with GitHub Actions (below). Locally on macOS, `scripts/build_unsigned_ipa.sh` produces `build/KittenTTS2App-unsigned.ipa`.

## Tests

The model-independent logic (ZIP/NPZ voice discovery, model-file validation, voice catalog, WAV encoding, text validation, history persistence) lives in `KittenTTS2App/KittenTTS2App/Core` and is tested through the root `Package.swift`:

```sh
swift test
```

No model assets are needed. The same Core files are compiled into the app target by the Xcode project.

## CI and getting the IPA

`.github/workflows/build_unsigned_ipa.yml` runs on pull requests, pushes to `main` and manually (*Actions → Build Unsigned IPA → Run workflow*). It runs `swift test`, builds the app with `xcodebuild` (`CODE_SIGNING_ALLOWED=NO`, derived data in `$RUNNER_TEMP/DerivedData`), packages `Release-iphoneos/KittenTTS2App.app` into `KittenTTS2App-unsigned.ipa` and uploads it. To download: open the workflow run → **Artifacts** → `KittenTTS2App-unsigned-ipa`.

## License

MIT (app code). See the licenses of the KittenTTS SDK and model weights above.
