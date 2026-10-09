# KittenTTS2-iOS

An iOS app that imports, validates and (where technically possible) runs KittenML's Kitten TTS models on-device, with generation history, playback and WAV export.

## Which model is which (verified against upstream docs)

Sources: [KittenML/KittenTTS](https://github.com/KittenML/KittenTTS), its [ONNX docs](https://github.com/KittenML/KittenTTS/blob/main/docs/onnx-models.md), [KittenML/kitten-tts-2-cpp](https://github.com/KittenML/kitten-tts-2-cpp) and [KittenML/KittenTTS-swift](https://github.com/KittenML/KittenTTS-swift).

| Family in this app | Upstream name | Format | Size | On-device synthesis in this app |
| --- | --- | --- | --- | --- |
| **KittenTTS 2 (1.7B, GGUF)** | KittenTTS 2, `KittenML/kitten-tts-2` | GGUF (`cpp/model-tq2_1.gguf`) + TorchScript `decoder.pt` + `voices.json` + `config.json` | 1.03 GB (TQ2_1), 1.45 GB (Q4_0), ~3.47 GB (FP16 reference export) | **Not available** – see blocker below |
| **KittenTTS 0.8 / original (ONNX)** | "lightweight legacy models" 0.8 (Nano/Micro/Mini). Upstream has no product called "KittenTTS 1"; this is the family people mean by "1/original". | `.onnx` + `voices.npz` | 25–80 MB | **Yes**, via the KittenTTS-swift SDK 0.1.0 (ONNX Runtime) |

### The ~3 GB file

Upstream's official KittenTTS 2 weights are ~1 GB (947 MiB Python weights / 1.03 GB GGUF). The only ~3 GB artifact documented upstream is the **FP16 reference GGUF (3.47 GB)** exported by `kitten-tts-2-cpp`. The app therefore cannot tell positively what your file is: **please share the model link or filename in the PR notes/issue** if validation says it is not recognised. The importer reports GGUF architecture and quantization it reads from the header, and rejects (with a specific message) ONNX/`.npz` (0.8 family), safetensors checkpoints, non-GGUF files and GGUFs of other architectures. A GGUF is never treated as loadable merely because of its extension.

### Verified blocker for KittenTTS 2 on iOS

KittenTTS 2 inference requires upstream's `kitten-tts-2-cpp`: a custom llama.cpp fork (the `TQ2_1` format cannot be loaded by stock llama.cpp), a **CPU LibTorch TorchScript decoder**, and the `kitten-text-processing` normalizer. Upstream documents it only as a desktop CPU CLI (needs C++20, CMake, LibTorch; "The runtime is a batch CLI"). There is no published iOS build, LibTorch-for-iOS decoder export, or Swift/C API. Even the compact export needs ~1 GB of storage plus several hundred MB of RAM for the LM, plus the decoder; the FP16 export (3.47 GB) is not realistic on phones. So this app **validates and stores** KittenTTS 2 files but **disables synthesis with an explanation** rather than faking output or contacting a server. Porting it would need an iOS build of the fork and a non-LibTorch (or LibTorch-Lite) decoder, which is outside what upstream publishes. Not claimed to work: voice cloning (needs offline Python preparation + transcript upstream) and streaming (not implemented upstream).

### Prototype status

See [docs/KITTENTTS2_IOS_FEASIBILITY.md](docs/KITTENTTS2_IOS_FEASIBILITY.md): a C bridge stub, bundle verifier, memory heuristic and an experimental CI probe for the iOS build of the TQ2_1 llama.cpp fork. **This is a feasibility spike, not production-ready; KittenTTS 2 audio has not been generated on iOS.**

## audio.cpp KittenTTS 2 single-GGUF test IPA (`dignome/kitten_tts2`)

The community file `kitten-tts2-native-q8-multilingual.gguf` (3,282,123,776 bytes, SHA-256 `e97920ca5053f9fcd4de638dcd8114ed2510d4291a93257473a8843c3ff349ad`) is **not** KittenML's TQ2_1 file: its architecture is `audiocpp`, it has zero TQ2_1 tensors, and it embeds the model, tokenizer/config, decoder, speaker encoders and 48 prepared voices. It runs on [audio.cpp's](https://github.com/dignome/audio.cpp-custom/tree/kittentts2) native C++/GGML `kitten_tts2` family (no Python/LibTorch/ONNX). Upstream validates CPU on Windows, **not iOS**.

`NativeAudioCpp/` is a separate test app (workflow *iOS audio.cpp KittenTTS 2 test IPA*, artifact `KittenTTS2AudioCppTest-unsigned-ipa`). It links the real audio.cpp runtime (pinned `ad1473cd460177480e8a0dc625bd46f76ea49aae`, `AUDIOCPP_MODELS=kitten_tts2`, CPU only, ARMv8.2+dotprod+fp16) through a small C bridge over `audiocpp.h` (`kt_load` / `kt_synthesize`). Evidence levels, kept separate on purpose:

| Stage | Where it is shown |
| --- | --- |
| Metadata validation (arch `audiocpp`, `audiocpp.model_spec.family=kitten_tts2`, Q8 mixed tensors, embedded assets, size, optional SHA-256) | `swift test` fixtures + the app's diagnostics |
| Native build/link | CI logs (`RESULT:` lines are required) |
| Model load on iOS | only if the app's diagnostics say `NATIVE MODEL LOAD: OK` on your device |
| Audio generation | only if they say `AUDIO GENERATED: YES` (non-silent mono 24 kHz PCM from audio.cpp, exportable as WAV) |

**Try it (LiveContainer or any sideloader):**
1. Keep the single file `kitten-tts2-native-q8-multilingual.gguf` somewhere in Files (the app never downloads or bundles it).
2. Download the CI artifact, unzip, and install/sign `KittenTTS2AudioCppTest-unsigned.ipa` (unsigned IPAs may be constrained by LiveContainer; that is not tested here).
3. Open the app, *Choose GGUF…*, pick the file. Check the validation and resource lines (optional: SHA-256).
4. Tap *Load* (memory-maps 3.28 GB; it may be slow or iOS may terminate the app: this is empirical and the app records the stage so the next launch explains it), then *Synthesize*.
5. Tap *Copy* (or *Export*) in the Diagnostics box and send the text. No Xcode or device logs are needed.

The native call cannot be interrupted: *Cancel* waits for it to finish and discards the result. Models stay user-provided and out of CI; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the Stellon Labs Community License / NOTICE and audio.cpp licensing. The older `NativeProbe/` app is only for KittenML's upstream `model-tq2_1.gguf`.

**2 GiB `ggml_init` abort (`insufficient memory (attempted to allocate 2048.00 MB)`).** Root cause in the pinned source: `load_s3_flow_decoder_weights` (`src/models/chatterbox/s3gen_flow.cpp`) builds a `BackendWeightStore` with `context_bytes = 2 GiB`; the store calls `ggml_init({context_bytes, nullptr, no_alloc=true})`, which `malloc`s the whole arena up front and `GGML_ASSERT`s on failure. With `no_alloc=true` that arena holds only tensor headers (~0.4 KB each; the whole GGUF has 2856 tensors, so ~1 MB), not weights. Other stores ask for 0.5–1 GiB each. `scripts/patches/audiocpp-weight-store-metadata-arena.patch` (applied by `build_audiocpp_ios.sh`) caps the arena at 64 MiB; exceeding it makes `ggml_new_tensor` fail into a normal C++ exception. Weights still go to a real backend buffer, and the decoder/vocoder/encoders request F32 storage, so the *actual* weight memory is unchanged and not yet verified on a device. A `GGML_ASSERT` is a `SIGABRT`: Swift cannot catch it, and iOS apps cannot spawn a child process to isolate it, so the app only records the assertion text (`KT_NATIVE_ABORT:`) and labels it as a previous run on next launch. Diagnostics are reset on every new file selection/load, so old crash logs are never shown as the current attempt.

## Import steps

1. Open the **Models** tab and choose the family.
2. **KittenTTS 0.8:** choose the variant (Nano / Nano int8 / Micro / Mini), then either tap *Download* (explicit network use, Hugging Face), or *Choose file(s)* and select the `.onnx` **and** `voices.npz` together from the matching `KittenML/kitten-tts-*-0.8` repo.
3. **KittenTTS 2:** *Choose file(s)* and select `model-tq2_1.gguf` (or your GGUF), ideally together with `decoder.pt`, `voices.json`, `config.json` from the same repository. Ensure free storage ≥ total file size (+5%).
4. Files are validated, copied in chunks with progress (cancellable) into a staging folder, and only then replace the previous install. A failed, rejected or cancelled import leaves the existing model untouched.

Wrong-family files get an explanation of what was detected, what is expected, and which family to switch to.

## Limitations

- 0.8 backend: first use fetches small phonemizer data files (EPhonemizer) from the network if absent; generation cannot be cancelled once started; English text only; 8 voices.
- No voice cloning or expression tags (KittenTTS 2 features) – requires the unavailable runtime.
- iOS 16+; unsigned IPA needs signing to install on a device.

## Development

- `swift test` – tests for file-format detection, validation, atomic import, history and WAV encoding (`Sources/KittenCore`).
- `KittenTTS2App/KittenTTS2App.xcodeproj` – SwiftUI app (depends on the local `KittenCore` package and `KittenML/KittenTTS-swift` 0.1.0).
- GitHub Actions (`.github/workflows/build_unsigned_ipa.yml`) runs `swift test`, `xcodebuild`, and uploads `KittenTTS2App-unsigned-ipa`.
- `scripts/build_unsigned_ipa.sh` – local macOS build.

## Licensing / provenance

App code: MIT. KittenTTS code: Apache-2.0. **KittenTTS 2 weights are under the [Stellon Labs Community License](https://huggingface.co/KittenML/kitten-tts-2/blob/main/LICENSE.md)** – check it before redistributing; models are licensed separately from code. kitten-tts-2-cpp builds on DeepGrove's llama.cpp fork (MIT). KittenTTS-swift and ONNX Runtime keep their own licenses. No model files are bundled in this repository.
