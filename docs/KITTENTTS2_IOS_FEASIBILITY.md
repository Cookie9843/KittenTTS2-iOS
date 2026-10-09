# KittenTTS 2 on iPadOS – feasibility spike (not production-ready)

**Status: generation is NOT working and remains disabled.** Nothing here has produced KittenTTS 2 audio on iOS.

## What upstream is (inspected at `KittenML/kitten-tts-2-cpp` @ `1ce0bb5`)
- A full fork of llama.cpp (MIT, ggml authors) adding tensor type `GGML_TYPE_TQ2_1`; `tools/kitten-tts/` holds the CLI.
- `tools/kitten-tts/CMakeLists.txt`: `find_package(Torch REQUIRED)`; `decoder.cpp` calls `torch::jit::load` on `decoder.pt` (CPU, full TorchScript, 4 tensor inputs: tokens, prompt tokens, 80-dim prompt features, embedding). Output is a float waveform.
- Text frontend: `vendor/kitten-text-processing` submodule (C++17).
- The fork inherits llama.cpp's `build-xcframework.sh`, so the LM half is plausibly cross-compilable; upstream does not claim or test iOS.
- Licensing: runtime code MIT (llama.cpp) / Apache-2.0 (`tools/kitten-tts/LICENSE-KITTENTTS`); **model weights are under the Stellon Labs Community License** (read before redistributing; the app bundles no weights). LibTorch is BSD-style but large (hundreds of MB).

## Seams and their status
| Seam | Status |
| --- | --- |
| Custom llama.cpp fork (TQ2_1) for iOS arm64 | **Cross-compiles** (probe run #4, `c970cb6`, actions run 37960445167): the build reached `[202/202]`, the script's final verification ran and printed `RESULT:`, exit code 0 after 109 s, and `libllama.a`, `libggml.a`, `libggml-cpu.a`, `libggml-base.a` were all arm64. The job's green status is not evidence by itself (the old job had `continue-on-error`, now removed; the workflow now also greps for `RESULT:`). **On-device load/inference is still unverified.** |
| Native load probe app (`NativeProbe/`, `scripts/build_native_probe_ipa.sh`) | **Built in CI as an unsigned IPA, not yet run on a device.** Links exactly the fork-built static libs; reads a user-supplied GGUF header (counts `TQ2_1` tensors) and loads it with the fork's `llama_model_load_from_file`, then tokenizes a fixed string. No context, no inference, no audio, no Generate button. |
| Swift ↔ C bridge | **Done (stub).** `Sources/CKittenBridge` exposes ABI version, per-component capabilities and `kitten_bridge_generate`, which refuses (`ERR_UNAVAILABLE`, 0 samples) unless every component is linked. `KittenRuntime` protocol + `NativeKittenRuntime` wrap it; tests use a mock. |
| `decoder.pt` execution on iOS | **Blocked / unverified.** Full TorchScript (`torch::jit::load`) needs desktop LibTorch; no supported iOS build exists. PyTorch Mobile's lite interpreter loads `.ptl` files and is no longer maintained; TorchScript is deprecated; ExecuTorch would require re-exporting the S3 decoder (flow + vocoder) and proving operator coverage; a hand-port to Core ML/ggml is a large separate project. None has been attempted with real weights. JIT is not used as a workaround. |
| Text normalizer | Pure C++17 submodule; expected portable, not yet built for iOS. |
| Asset import & verification | **Done.** Importer + `BundleVerifier` check architecture (`qwen3`), quantization, `config.json` type and `cpp` manifest sizes, `decoder.pt` is a TorchScript archive, `voices.json` parses. Tokenizer data is embedded in the GGUF and is *not* verified by metadata checks. |

## The "~3 GB" file
Upstream sizes: TQ2_1 GGUF ≈ 1.03 GB, Q4_0 ≈ 1.45 GB, FP16 reference export ≈ 3.47 GB. A ~3 GB file is almost certainly the FP16 reference (or a Python checkpoint); the verifier warns and points to `cpp/model-tq2_1.gguf` in `KittenML/kitten-tts-2`. If it is something else, please send the filename/link.

## M4 iPad Pro expectations
8 GB RAM (256/512 GB models) or 16 GB (1/2 TB). iOS limits per-app memory (undocumented; roughly half of RAM by default, more with the `com.apple.developer.kernel.increased-memory-limit` entitlement, which needs a provisioning profile that an unsigned/sideloaded IPA may not carry). `DeviceBudget` encodes this heuristic: TQ2_1 (~1 GB + overhead) should fit; FP16 (3.5 GB) is marginal on 8 GB and unproven. CPU speed of the M4 is not the limiting factor; decoder availability is. No performance numbers exist yet.

## Device test instructions
1. Install the CI-built IPA (`KittenTTS2App-unsigned-ipa`, needs signing).
2. Models tab → KittenTTS 2 → choose `model-tq2_1.gguf`, `decoder.pt`, `voices.json`, `config.json`.
3. Open the Models tab: the "Installed files" section shows the verification report, memory estimate and why generation is disabled. Please report that text, your iPad model and the real filenames/sizes.
4. Remaining unverified: fork on-device load, decoder execution, normalizer, end-to-end audio.

## Native load probe IPA (device test)
Artifact `KittenTTS2NativeProbe-unsigned-ipa` of workflow *iOS native probe (experimental)*. It is **unsigned**: install requires re-signing with your own Apple ID/certificate and provisioning profile (e.g. Sideloadly, AltStore, or `zsign`/Xcode "Devices" with your free/paid developer account; bundle id `com.cookie9843.KittenTTS2NativeProbe` may need to be changed to one you own). No signing secrets are used or stored in this repo. Then: open the app, choose `model-tq2_1.gguf` (≈1.03 GB, from `cpp/` in `KittenML/kitten-tts-2`), tap "1. Read header", then "2. Load model" and report the text shown. A successful load proves only that the fork's TQ2_1 loader runs on the device; it does not prove speech works. No model assets are downloaded in CI.

## Complete audio path assessment
Still **not buildable** today: the decoder (`decoder.pt`, TorchScript via `torch::jit::load`) has no supported iOS runtime (no LibTorch-for-iOS full-JIT build; PyTorch Mobile is unmaintained and needs `.ptl`), and the S3 decoder would have to be re-exported (ExecuTorch/Core ML) and parity-checked against real weights, which cannot be done in CI without the model assets. The text normalizer is also unbuilt for iOS, and the sampling loop in upstream `main.cpp` is not ported. The app's Generate action therefore stays disabled.

## Next steps
1. Read the probe workflow result; if green, add a tiny C++ shim loading a GGUF header via the fork and bump `KITTEN_BRIDGE_HAVE_LLAMA_FORK`/`TQ2_1` only after a device load test.
2. Spike decoder export to ExecuTorch (or `.ptl`) on a desktop with real weights; compare against the TorchScript output (upstream ships `check_parity.py`).
3. Only then wire normalizer + decoder and verify audio on the iPad.
