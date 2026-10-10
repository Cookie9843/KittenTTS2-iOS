# KittenTTS2-iOS

An on-device text-to-speech app for **iPhone and iPad (iOS 16.4+)** with two model families. Speech is generated offline once a model is on the device.

- **KittenTTS 2** (community single-file audio.cpp package, [`dignome/kitten_tts2`](https://huggingface.co/dignome/kitten_tts2)): 48 preset voices (compact picker), multilingual presets and **voice cloning** (separate screen) from a 1–30 s reference plus the text spoken in it. Get the model by **downloading** it from Hugging Face or by **importing** a compatible file you already have from Files.
- **KittenTTS 0.8** (the original lightweight Nano/Micro/Mini models; often colloquially called "KittenTTS 1" - there is no official 1.0 release): 8 voices, speed control. Direct links to the official `KittenML/kitten-tts-*-0.8` Hugging Face repositories are in the Models tab.

Screens: **Speak**, **Voices**, **Models** (download/import, licenses and credits, advanced diagnostics), **History**.

## Importing your own KittenTTS 2 file

Models tab → KittenTTS 2 → *Import a KittenTTS 2 file from Files…*. Only the audio.cpp single-GGUF package is compatible (GGUF architecture `audiocpp`, `audiocpp.model_spec.family = kitten_tts2`); other GGUFs are rejected with an explanation. KittenML's own `model-tq2_1.gguf` is a different, unsupported runtime. The file is validated from its header (memory-mapped, never loaded into memory as a whole), checked for free space, streamed in chunks to a staging folder on the install volume, hashed, and only then moved into place. If it has the published size its SHA-256 must match the published checksum; a different export is accepted but not labelled as verified. Invalid, failed or cancelled imports leave the installed model untouched. Security-scoped access to the picked file is held only while it is read.

The Models tab shows whether the installed model was **downloaded** (verified against the published checksum) or **imported** (with original name and checksum status).

## Storage checks

Required space = bytes still to be written + 128 MiB working headroom (nothing extra when a partial download is already complete). A resumed download only counts the missing bytes; an import counts a full copy. Capacity is read on the volume that holds the staging folder using the larger of iOS's "important usage" and "available" capacity values (a reported value of 0 is not trusted over the other one). Capacity that the system does not report is treated as unknown, not as "full". Errors state required, available and already-downloaded numbers. `swift test` covers these rules, including boundary equality, overflow and unavailable capacity.

## Status messages

Each operation owns its message (`OperationStatus`): model download, model import, synthesis, reference audio/microphone, playback for KittenTTS 2; model setup, synthesis, playback and history for 0.8. Starting an action clears only that action's previous message.

## Status and evidence (kept separate on purpose)

| Claim | Evidence |
| --- | --- |
| Download manifest, SHA-256/size verification, resume, atomic install, import validation, storage rules, status scoping, clone input rules, WAV decoding | `swift test` (Linux, mock transport and fixtures; no real Hugging Face traffic) |
| The app UI and native runtime compile and link for iOS | CI only; see the workflow run for the commit (the UI code cannot be built on Linux) |
| KittenTTS 2 load + preset synthesis on real hardware | **Observed on one iPad (iPad16,5, iOS 27.0), not CI:** load 10.55 s, 75,360 samples at 24 kHz in 7.42 s, 2.52 GB reported available. Other devices are unverified; resources vary and iOS may terminate the app |
| Voice cloning, own-GGUF import, storage checks, KittenTTS 0.8 on device | **User-tested by Cookie9843** (their own device and setup; exact device/OS not recorded here for these flows). Not exercised by CI and not a claim about other devices, memory profiles, signing methods or locales |
| Second and later generations on one loaded model | The failure `failed to initialize ggml graph context for S3 flow decoder` was reported on a device after the first generation. The fix (`scripts/patches/audiocpp-s3-flow-decoder-metadata-arena.patch`) comes from source analysis and CI build; **a repeated-generation retest on a device is still required**. `scripts/run_two_synth_probe.sh` runs two syntheses on one session when pointed at a local model |
| macOS, Android | Not supported |

The model is **never bundled** in the repository, CI or IPA. The published file is 3,282,123,776 bytes (3.28 GB, SHA-256 `e97920ca5053f9fcd4de638dcd8114ed2510d4291a93257473a8843c3ff349ad`). It is memory-mapped, so its size is not the same as resident memory, but devices with limited free memory may still fail; the app shows warnings based on `os_proc_available_memory`, not guarantees.

Limitations: generation cannot be interrupted once started; downloads pause/resume only while the app is open; no named clone profiles.

## Install and signing

CI produces an **unsigned** IPA (artifact `KittenTTS-unsigned-ipa`, workflow *iOS audio.cpp runtime + full app IPA*). It must be signed with your own Apple ID or certificate and provisioning profile using any signing or sideloading tool you trust before it will install on an iPhone or iPad. The bundle identifier (`com.cookie9843.KittenTTS2App`) can be changed by your signing tool to one you own. The app needs the microphone permission only when you record a cloning reference; Files access uses the system picker. The workflow fails if a `.gguf` ends up inside the IPA. Provenance: runtime `dignome/audio.cpp-custom` @ `ad1473cd460177480e8a0dc625bd46f76ea49aae`, `AUDIOCPP_MODELS=kitten_tts2`, CPU only, plus the patches in `scripts/patches/`.

Platforms: iPhone and iPad (device families 1 and 2). `Package.swift` lists macOS only so `swift test` runs there.

## Development

- `swift test` – `Sources/KittenCore` (formats, validation, downloader, importer, storage, status, history, WAV).
- `KittenTTS2App/KittenTTS2App.xcodeproj` – SwiftUI app (local `KittenCore` package and `KittenML/KittenTTS-swift` 0.1.0). The runtime C bridge is `NativeAudioCpp/kt_audiocpp_bridge.c`.
- `build_unsigned_ipa.yml`: `swift test` + UI-only compile (device and simulator; uploads no IPA). `ios_audiocpp_kitten2.yml`: builds the audio.cpp runtime and the **full** app IPA, checks that the runtime symbols are linked.
- `scripts/build_audiocpp_ios.sh` (runtime), `scripts/build_app_ipa.sh` (full app IPA), `scripts/build_unsigned_ipa.sh` (UI-only local build).

## Licensing / provenance

App code: MIT. KittenTTS 2 weights are a community conversion of KittenML / Stellon Labs' model under the **Stellon Labs Community License** (embedded LICENSE/NOTICE); models are licensed separately from code. All notices and credits are in the app under Models → Licenses and credits (source: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)); the download sheet asks for a short consent and links there. See also [docs/KITTENTTS2_IOS_FEASIBILITY.md](docs/KITTENTTS2_IOS_FEASIBILITY.md) for the unsupported TQ2_1 runtime.

## Repeated-generation reliability (native lifecycle)

Reported on a device: `audiocpp_session_create failed … std::bad_alloc` after a few generations, and sometimes `failed to initialize HiFT backend graph context`. Findings from the pinned audio.cpp source and this app's bridge (not yet confirmed on a device):

- **HiFT context**: upstream's `BackendRunner` asks `ggml_init` for 512 MiB + 4 MiB per mel frame whenever the text length changes (≈2.5 GiB for 10 s of speech). The context is `no_alloc` (headers only; topology is independent of length), so this was a length-dependent `malloc` reservation that fails intermittently on a memory-constrained device. `scripts/patches/audiocpp-hift-backend-graph-arena.patch` caps it at 128 MiB and frees the context if graph building throws (a throwing constructor never ran its destructor).
- **Session churn**: a session creation instantiates every weight set again. The bridge used one session per task and freed/recreated it every time the user switched between a preset and a cloned voice. The bridge now keeps ONE `tts` session for the model's lifetime for both (the kitten_tts2 session treats a request carrying reference audio as a clone). A session whose request failed is freed and rebuilt before the next request, never retried blindly. Errors now include the memory still available to the app, and Diagnostics shows session create/reset/failure counters.
- Evidence: `swift test` (arena model) and `scripts/run_bridge_lifecycle_test.sh` (bridge policy against a fake audio.cpp ABI: one session across alternating preset/clone calls, discard-and-rebuild, no leaked requests/results). These do not measure the real runtime's memory; please retest on a device and share Diagnostics.

## Automatic transcript for cloned voices

After you record or choose a reference clip, the app drafts a transcript with Apple's on-device speech recognition (`requiresOnDeviceRecognition`; if a language has no on-device model it reports that and you type the text instead). The draft is editable and **must be reviewed**: a cloned voice cannot be used until you edit the text or tap “It matches”. Text you typed yourself is never overwritten by a recognition result unless you tap Transcribe again. Nothing is uploaded.
