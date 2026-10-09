#ifndef KT_AUDIOCPP_BRIDGE_H
#define KT_AUDIOCPP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

/* Smallest bridge from Swift to audio.cpp's C ABI (include/audiocpp.h) for the kitten_tts2 preset-TTS
 * path: load a single GGUF -> offline "tts" session on the CPU backend -> synthesize mono float PCM.
 * Every function returns 0 on success; on failure it writes the full native error text into `err`. */

typedef struct kt_engine kt_engine;

typedef struct kt_audio {
    float *samples; /* malloc'd; release with kt_audio_free */
    size_t frames;
    int sample_rate;
    int channels;
} kt_audio;

/* Runtime description: audio.cpp build/ABI version and the family list compiled in. */
int kt_runtime_info(char *out, size_t cap);

/* Bytes the app may still allocate before iOS terminates it (os_proc_available_memory); 0 if unknown. */
uint64_t kt_available_memory(void);

/* Truncates `path` and sends native stderr (ggml/audio.cpp logging) there so the UI can show it. */
int kt_redirect_stderr(const char *path);

/* A GGML_ASSERT/ggml_abort ends in abort() (SIGABRT): Swift/C++ error handling cannot intercept it. This hook
 * only records the assertion text on stderr (prefix KT_NATIVE_ABORT:) before the process dies. */
void kt_install_abort_hook(void);

/* Loads the model at `path` (family hint kitten_tts2) and creates a CPU TTS session. */
int kt_load(const char *path, int threads, kt_engine **out, char *describe, size_t describe_cap,
            char *err, size_t err_cap);

/* Runs preset TTS. `seed` < 0 means "do not set a seed". Blocks until the whole text is synthesized;
 * the native call cannot be interrupted. */
int kt_synthesize(kt_engine *engine, const char *text, const char *voice_id, int64_t seed, kt_audio *out,
                  char *err, size_t err_cap);

/* Voice cloning (audio.cpp task "clon"): `reference` is mono float PCM (1-30 s, `reference_rate` Hz) and
 * `transcript` is what is said in it (the runtime does not transcribe). The engine holds ONE session at a time:
 * switching between preset TTS and cloning frees the previous session before creating the other, so the weights are
 * never loaded twice. Blocks until done; not interruptible. */
int kt_synthesize_clone(kt_engine *engine, const char *text, const float *reference, size_t reference_frames,
                        int reference_rate, const char *transcript, int64_t seed, kt_audio *out, char *err,
                        size_t err_cap);

/* 1 when this build links the real audio.cpp runtime (-DKT_NATIVE_LINKED=1), 0 for the UI-only stub build. */
int kt_runtime_linked(void);

void kt_audio_free(kt_audio *audio);
void kt_unload(kt_engine *engine);

#endif
