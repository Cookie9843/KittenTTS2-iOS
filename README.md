# KittenTTS2-iOS

Make speech right on your **iPhone or iPad** with this offline text-to-speech app. Once a model is on your device, speech is generated there too—no account or cloud service needed.

- **KittenTTS 2** offers 48 preset voices, several languages, and voice cloning from a short recording.
- **KittenTTS 0.8** is smaller and faster, with the original Nano, Micro, and Mini models, 8 voices, and a speed control.

> **A note about AI and attribution:** This app and repository were created with substantial help from GitHub Copilot and OpenAI models. Final product decisions and testing were done by the repository owner, [@Cookie9843](https://github.com/Cookie9843). The model weights come from upstream KittenTTS / Stellon Labs work (and the community conversion linked below), and the speech runtime is upstream [audio.cpp](https://github.com/0xShug0/audio.cpp) via a community fork. Neither the weights nor the runtime were created by AI in this repository; see [License and provenance](#license-and-provenance).

## Contents

1. [QuickStart](#quickstart)
2. [Detailed guide](#detailed-guide)
   1. [Get and install the app](#1-get-and-install-the-app)
   2. [Before you begin](#2-before-you-begin)
   3. [Set up a model](#3-set-up-a-model)
   4. [Make and manage speech](#4-make-and-manage-speech)
   5. [Manage models](#5-manage-models)
   6. [Privacy and permissions](#6-privacy-and-permissions)
   7. [Troubleshooting](#7-troubleshooting)
   8. [Technical notes and testing](#8-technical-notes-and-testing)
   9. [License and provenance](#license-and-provenance)
   10. [Build and publish (maintainers)](#build-and-publish-maintainers)

## QuickStart

New to TTS and don’t have model files yet? You don’t need to find or prepare a model yourself: install the app, then download one from its **Models** tab.

1. Download the newest unsigned IPA from the [Releases page](https://github.com/Cookie9843/KittenTTS2-iOS/releases), sign it with a signing/sideloading tool you trust, and install it on your iPhone or iPad.
2. Open **Models** and download **KittenTTS 2** for multilingual voices and voice cloning, or **KittenTTS 0.8** for a smaller, faster download.
3. Open **Speak**, select the model and a preset voice, enter text, and tap **Speak**.
4. To use your own voice as a reference, KittenTTS 2 can clone from a short, clear speech recording; see [Clone a voice with KittenTTS 2](#clone-a-voice-with-kittentts-2).

KittenTTS makes speech, not singing. The app doesn’t train a model from a singing method or recording. The [detailed guide](#detailed-guide) covers installation, downloads, imports, voice cloning, and troubleshooting.

## Detailed guide

### 1. Get and install the app

Head to the **[Releases page](https://github.com/Cookie9843/KittenTTS2-iOS/releases)** and download `KittenTTS-<version>-unsigned.ipa` from the newest release. A `.sha256` file is provided alongside it if you want to check the download. Releases are created from version tags such as `v1.0.0`.

The IPA is **unsigned**, so iOS cannot install it as-is. Sign it with your own Apple ID or developer certificate using a signing or sideloading tool you trust, then install it on your device. Signing is up to you: this project does not sign, host, or distribute signed builds, and the app does not depend on a particular signing tool.

For normal installs, use the **Release IPA** from the Releases page. It includes the full app with the speech engine linked in. Workflow runs may also provide a temporary development artifact named `KittenTTS-unsigned-ipa`; use the release instead for a regular install.

The bundle identifier is `com.cookie9843.KittenTTS2App`. Your signing tool may change it to one you own.

### 2. Before you begin

- You’ll need an **iPhone or iPad running iOS 16.4 or later**, plus a way to sign and sideload an IPA. A free Apple ID or paid developer account can be used; free signing profiles expire and need to be renewed under Apple's signing rules.
- For **KittenTTS 2**, plan for a **3.28 GB** download (3,282,123,776 bytes) and about **3.5 GB of free storage** while downloading. Importing a model you already have also needs roughly that much space because a second copy is made during verification. KittenTTS 0.8 models are around 25–80 MB.
- KittenTTS 2 needs plenty of **available RAM** for generation. It has been observed working on one iPad with about 2.5 GB reported available to the app, but devices with less free memory may run out. You can check the app’s estimate in **Models → Advanced: memory and diagnostics**. Close other apps before generating; see [Troubleshooting](#7-troubleshooting) for more tips.
- Use **Wi-Fi** for the first large download unless you have a data plan that can handle it. The app asks before using mobile data for KittenTTS 2.

### 3. Set up a model

When you open the app, you’ll see four tabs: **Speak**, **Voices**, **Models**, and **History**. Start in **Models** and choose whichever setup works for you.

### Download KittenTTS 2

1. Go to **Models → KittenTTS 2 → Download from Hugging Face (3.28 GB)**.
2. Read and accept the license notice, then choose **Download on Wi-Fi only** or **Allow mobile data too**. The dialog shows the storage you still need.
3. Let the app finish downloading, checking the file’s SHA-256 checksum, and installing it. You can leave the screen open, but keep the app running; downloads stop when you quit the app.
4. On the model page, look for **Downloaded from Hugging Face … Verified against the published checksum.**

### Import a KittenTTS 2 file

1. Go to **Models → KittenTTS 2 → Import a KittenTTS 2 file from Files…** and choose your `.gguf` file.
2. The supported file is the audio.cpp single-file package [`kitten-tts2-native-q8-multilingual.gguf`](https://huggingface.co/dignome/kitten_tts2) (`audiocpp` architecture, `kitten_tts2` family). Other GGUF files are not compatible. In particular, KittenML’s `model-tq2_1.gguf` uses a different runtime.
3. The app checks the file and copies it to a staging folder before installing it. If its size matches the published file, its SHA-256 must match too. Other compatible exports are accepted and marked as not checksum-verified.
4. If you cancel or an import fails, your existing model stays untouched. You can simply try again.

### Download or import KittenTTS 0.8

1. Go to **Models → KittenTTS 0.8**, choose **Nano (fp32)**, **Nano (int8)**, **Micro**, or **Mini**, then tap **Download**. The files come from the official `KittenML/kitten-tts-*-0.8` repositories on Hugging Face; links are in the Models tab.
2. Or choose **Import files you already have…** and select the `.onnx` model and its `voices.npz` file together.
3. The first time you generate speech, the app may also download small phonemizer data files if they aren’t already available.

### 4. Make and manage speech

#### Choose a voice and speak

On **Speak**, choose KittenTTS 2 or 0.8, then select a preset from the **Voice** menu. KittenTTS 2 has 48 presets, including multilingual presets named for a language. KittenTTS 0.8 has 8 voices and a speed slider.

Type or paste your text and tap **Speak**. The first KittenTTS 2 run loads the model and may take 10–30 seconds. Generation can’t be interrupted once it starts. When it’s ready, the result plays automatically and is saved to **History**.

#### Clone a voice with KittenTTS 2

On the **Voices** tab, in the cloning section:

1. Add **1–30 seconds** of clear speech: record with **Record with microphone**, or choose a clip using **Choose an audio file…**. A quiet recording with one speaker works best.
2. Apple’s on-device speech recognition drafts a transcript. You can instead type one yourself; your text won’t be overwritten unless you tap **Transcribe** again.
3. **Listen to the clip and review both the words and punctuation.** Automatic recognition can mishear words or leave out and misplace punctuation. Correct the transcript, then tap **Words and punctuation are correct** (or edit the text). A recognized transcript must be edited or confirmed before it can be used. An inaccurate transcript can make the cloned voice sound worse.
4. Turn on **Speak with my cloned voice**, then tap **Speak** on the Speak tab.

If on-device recognition isn’t available for your language, the app will let you know so you can type the transcript. Your recording is never uploaded.

#### Play, export, or delete a recording

**History** lists the speech you’ve generated. Tap **Play** to listen, and use **Save or share WAV** or **Export WAV** to save or share it. Swipe an item to delete it, or choose **Clear all**. Your history stays on your device.

### 5. Manage models

You can manage downloads and installed models from **Models**:

| Action | KittenTTS 2 | KittenTTS 0.8 |
| --- | --- | --- |
| Pause a download | **Pause** keeps the partial file; **Resume download** continues from where it stopped. The file is checked again at the end. | Not available; the original downloader can’t pause or resume. |
| Cancel a download | Choose **Cancel and remove partial download**, or **Discard partial download** after pausing. | Choose **Cancel download and remove partial files**. The file currently in progress finishes first (25–80 MB), then the download’s files are removed. |
| Cancel an import | **Cancel import** leaves your current model untouched. | Choose **Cancel import**. |
| Free memory | **Free memory** unloads the model from RAM without deleting it. | — |
| Remove a model | **Remove from this device** unloads the engine first, then deletes downloaded, imported, and partial files. | **Remove from this device** removes only the selected model size. |

You can’t remove a model while it’s loading, generating, downloading, or being imported.

### 6. Privacy and permissions

Your text, recordings, and generated speech stay on your device.

- **Microphone:** used only when you record a voice-cloning reference.
- **Speech recognition:** used when you tap **Transcribe** or when the app drafts a transcript for a new reference clip. Recognition is on-device; your recording is never sent to a server. If recognition isn’t available for a language, you can type the transcript yourself.
- **Files:** accessed through Apple’s file picker. The app keeps access to a selected file only while it reads it.
- **Network:** used to download models and small data files from Hugging Face when you ask. There’s no analytics or account.

### 7. Troubleshooting

| What you see | What to try |
| --- | --- |
| *Out of memory* / `std::bad_alloc` / *failed to allocate … buffer* / *failed to initialize … graph context* | Your device is short on available memory. Close other apps and try **Speak** again; after a failed request, the app rebuilds its engine session, so you don’t need to restart the app. If it keeps happening, try **Models → KittenTTS 2 → Free memory**. Restarting the device is the most effective way to free RAM. Then retry, and include **Advanced: memory and diagnostics** if you report the problem. Very little available memory may not be enough for voice cloning. |
| *Not enough free storage* when downloading or importing | The message shows how much space you need and how much is available. Free up that space and try again. A partial download needs only the remaining bytes, and your existing model won’t be changed. |
| *Unsupported GGUF* / *not a compatible KittenTTS 2 package* | Use `kitten-tts2-native-q8-multilingual.gguf` from [`dignome/kitten_tts2`](https://huggingface.co/dignome/kitten_tts2). KittenML’s TQ2_1 GGUF and other architectures aren’t compatible. |
| Import failed | The message identifies the failed step and includes the system error code, free storage, and available memory. Your installed model stays in place and the temporary copy is removed, so you can pick the file again without restarting the app. If the file is in iCloud, download it in Files first. If another task is running, wait for it or cancel it. Please include the full message if you report the problem. |
| Download stopped (network) | Your progress is saved. Tap **Resume download** to continue. |
| *The downloaded file failed its integrity check* | The partial file was discarded. Start the download again. |
| *Automatic transcription unavailable* | On-device recognition may not be offered for your language or device, or its permission may be off. Check **Settings → Privacy & Security → Speech Recognition**, or type the transcript yourself. |
| *Microphone access is off* | Turn it on in **Settings → Privacy & Security → Microphone**, or choose an audio file instead. |
| *This build does not include the KittenTTS 2 speech engine* | This build doesn’t include the speech engine. Install the Release IPA instead. |
| App closed by iOS during generation | This is usually caused by memory pressure. After you reopen the app, check **Advanced diagnostics** for a note about the previous run. |

### 8. Technical notes and testing

This section is for anyone curious about what has been checked so far. Automated tests can cover app logic and builds, but they can’t guarantee inference will work on every device.

- **How KittenTTS 2 was made to build for iOS:** the app uses a pinned community `audio.cpp` fork and its `ggml` CPU backend, not KittenML’s llama.cpp-based TQ2_1 runtime. `scripts/build_audiocpp_ios.sh` cross-compiles the KittenTTS 2 runtime as iOS arm64 static libraries with the iOS 16.4 deployment target, CPU-only settings, and only the `kitten_tts2` model implementation enabled. It also compiles audio.cpp’s C API, which the app connects through a small native C bridge; the IPA build links those pieces into the app and checks that the runtime symbols are present.
- **iOS-specific work:** small, pinned patches bound large ggml metadata and graph allocations and turn an allocation failure into a recoverable error instead of an assertion. The build and bridge lifecycle are checked in CI, but compilation/linking does not prove that inference works on every device.
- **About the custom llama.cpp route:** an earlier experiment tried KittenML’s TQ2_1 package with a llama.cpp fork and desktop LibTorch, but that route was removed; its decoder has no iOS build in this project. The supported KittenTTS 2 package is the audio.cpp-compatible community conversion described in [runtime notes](docs/KITTENTTS2_IOS_FEASIBILITY.md).
- **Automated checks (CI and `swift test` on Linux):** download manifest, resume and SHA-256 verification, atomic install, import validation and recovery after failed or cancelled imports, storage rules, per-operation status messages, clone input rules, transcript review rules, legacy model delete/cancel cleanup, and the native bridge session lifecycle against a fake audio.cpp interface. CI also builds the full-app IPA and checks that the real runtime symbols are linked.
- **Observed by the owner on their own device:** KittenTTS 2 model loading and preset synthesis on one iPad (iPad16,5, iOS 27.0): load time 10.55 seconds; 75,360 samples at 24 kHz generated in 7.42 seconds; 2.52 GB reported available. Voice cloning, GGUF import, storage checks, and KittenTTS 0.8 were also tried, but exact device and OS versions for those flows weren’t recorded.
- **Not verified:** other devices, memory sizes, signing methods, or locales; every preset voice; repeated-generation stability across hardware; and the new KittenTTS 0.8 cancel/remove controls, transcript wording, and import changes on a real device. CI can’t prove on-device inference. macOS and Android aren’t supported.

### License and provenance

- **App code:** MIT; see [LICENSE](LICENSE).
- **KittenTTS 2 weights:** a community conversion from KittenML / Stellon Labs’ KittenTTS 2, available at [`dignome/kitten_tts2`](https://huggingface.co/dignome/kitten_tts2). It is licensed under the **Stellon Labs Community License**; the license and NOTICE are embedded in the model file and published with it. Models are licensed separately from this code. By downloading or importing one, you agree to follow its license. This is not an official KittenML release or format.
- **KittenTTS 0.8 models:** available from official KittenML repositories on Hugging Face. Follow the license on each model page.
- **Runtime:** [audio.cpp](https://github.com/0xShug0/audio.cpp), using the community branch `dignome/audio.cpp-custom` at `ad1473cd460177480e8a0dc625bd46f76ea49aae` (`AUDIOCPP_MODELS=kitten_tts2`, CPU only), plus small patches in `scripts/patches/`.
- Find all notices and credits in the app under **Models → Licenses and credits**, or read [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). For why KittenML’s TQ2_1 format isn’t supported, see [docs/KITTENTTS2_IOS_FEASIBILITY.md](docs/KITTENTTS2_IOS_FEASIBILITY.md).
- Model weights are not included in this repository, CI, or the IPA. Workflows fail if a `.gguf` file ends up in the IPA.

### Build and publish (maintainers)

To build the app, you’ll need macOS with Xcode. `swift test` can run on macOS or Linux.

```sh
swift test                                     # KittenCore: formats, validation, downloader, importer, storage, status, history, WAV
scripts/run_bridge_lifecycle_test.sh           # native bridge session policy against a fake audio.cpp ABI (no model)
for f in scripts/*.sh; do bash -n "$f"; done   # check shell syntax
scripts/build_audiocpp_ios.sh                  # build the audio.cpp kitten_tts2 runtime for iOS arm64 (sets up $WORK)
WORK=… scripts/build_app_ipa.sh                # build the full unsigned IPA; fails if native symbols are missing
```

#### Workflows

- `workflow_guard.yml` checks that release and CI workflows build the real audio.cpp runtime and that there is no UI-only build.
- `ios_audiocpp_kitten2.yml` runs `swift test` and the bridge lifecycle test, builds the runtime and full app IPA, verifies linked symbols, and uploads the temporary `KittenTTS-unsigned-ipa` artifact.
- `release.yml` runs on tags matching `v*`.

#### Publishing a release

1. Make sure `main` is green.
2. Create and push an annotated version tag on a commit in `main`, for example: `git tag -a v1.0.0 -m "v1.0.0" && git push origin v1.0.0`. Tags with a hyphen (such as `v1.0.0-rc1`) are published as pre-releases.
3. `release.yml` runs `swift test` and the bridge lifecycle test, builds the real runtime and full app, and refuses to continue unless `_audiocpp_model_load`, `_audiocpp_session_run`, and the bridge symbols are in the packaged binary and no `.gguf` file is inside. It then creates a GitHub Release with `KittenTTS-<tag>-unsigned.ipa` and its `.sha256` file. The UI-only build is never attached.
4. Add release notes if you like. Users sign the IPA themselves; the project does not.

Running the workflow manually (`workflow_dispatch`) builds and checks the app but does not publish a release.
