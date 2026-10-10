# KittenTTS 2 on iOS – runtime notes

Two different things are called "KittenTTS 2 GGUF"; only one runs in this app.

| Package | Runtime | Supported here |
| --- | --- | --- |
| Community single-file package from [`dignome/kitten_tts2`](https://huggingface.co/dignome/kitten_tts2) (GGUF architecture `audiocpp`, family `kitten_tts2`, Q8 mixed tensors, embedded assets) | [audio.cpp](https://github.com/dignome/audio.cpp-custom) native C++/ggml, CPU | **Yes** (download or import from Files) |
| KittenML's upstream `model-tq2_1.gguf` from `KittenML/kitten-tts-2` (`qwen3` + `TQ2_1` tensors, plus a TorchScript `decoder.pt`) | `kitten-tts-2-cpp` (llama.cpp fork + desktop LibTorch) | **No.** Different runtime; there is no iOS build of its decoder. The app says so when such a file is selected |

An earlier spike that cross-compiled the TQ2_1 llama.cpp fork and a probe app for it were removed from the app and CI: they were never part of the product and the supported path is audio.cpp.

## Evidence (kept separate)
- CI proves the audio.cpp runtime and the full app compile and link for iOS arm64 (`RESULT:` lines in the workflow log, symbols checked in the linked executable).
- On-device behaviour is observational: one iPad (iPad16,5) loaded the package and synthesized the preset voice "Bruno". This says nothing about other devices; memory limits and speed vary and iOS may terminate the app.
- Voice cloning and the other app flows were tested on the maintainer's own device(s) (Cookie9843); this is not CI evidence and not a claim about other devices.
