# Third-party notices (KittenTTS app)

This file is bundled in the app. The unsigned IPA built by `scripts/build_app_ipa.sh` statically links native code and copies the upstream
licence files that exist in the pinned source tree into `Licenses/` inside the `.app`. It contains **no model
weights**; KittenTTS 2 is downloaded by the user from https://huggingface.co/dignome/kitten_tts2/tree/main or imported from a file the user already has (SHA-256 of the published file: `e97920ca5053f9fcd4de638dcd8114ed2510d4291a93257473a8843c3ff349ad`), and KittenTTS 0.8 models from KittenML's Hugging Face repositories.

| Component | Source | Licence |
| --- | --- | --- |
| audio.cpp (community branch `kittentts2`, pinned revision `ad1473cd460177480e8a0dc625bd46f76ea49aae`) | https://github.com/dignome/audio.cpp-custom (fork of https://github.com/0xShug0/audio.cpp) | see `LICENSE` in that repository |
| ggml | vendored in audio.cpp at `external/ggml` | MIT (see `external/ggml/LICENSE`) |
| sentencepiece, cJSON, libyaml, llama tokenizer | vendored in audio.cpp at `external/` | each keeps its own licence file in that directory |
| Chatterbox S3 components (S3 tokenizer, CAMPPlus, meanflow decoder) | used by audio.cpp's `kitten_tts2` | MIT (Resemble AI Chatterbox) |
| Kitten TTS 2 weights | https://huggingface.co/dignome/kitten_tts2 (conversion of https://huggingface.co/KittenML/kitten-tts-2) | **Stellon Labs Community License** plus the NOTICE/attribution and component licences shipped with the model |

## Model licence and attribution

The model file `kitten-tts2-native-q8-multilingual.gguf` is a community conversion of KittenML / Stellon Labs'
KittenTTS 2 ("Powered by Stellon Labs"). It embeds the model's licence and NOTICE files. Keep the `LICENSE`,
`NOTICE`, `native/LICENSE`, `speaker/LICENSE` and `SHA256SUMS` files published next to it in
`dignome/kitten_tts2` together with any copy you redistribute, and read the Stellon Labs Community License
before sharing audio or the model. Neither the repository nor CI downloads, stores or redistributes the model.
