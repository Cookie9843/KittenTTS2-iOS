#include "probe_shim.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "gguf.h"
#include "ggml.h"
#include "llama.h"

/* Tensor type id of GGML_TYPE_TQ2_1 in the pinned KittenML/kitten-tts-2-cpp fork (stock llama.cpp has no such type). */
#define KP_TQ2_1 ((enum ggml_type)43)

static void append(char *out, size_t cap, size_t *len, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static void append(char *out, size_t cap, size_t *len, const char *fmt, ...) {
    if (*len >= cap) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(out + *len, cap - *len, fmt, ap);
    va_end(ap);
    if (n > 0) *len += (size_t)n < cap - *len ? (size_t)n : cap - *len - 1;
}

int kp_read_header(const char *path, char *out, size_t cap) {
    size_t len = 0;
    if (!path || !out || cap == 0) return 1;
    out[0] = 0;
    struct gguf_init_params params = { /* no_alloc */ true, /* ctx */ NULL };
    struct gguf_context *g = gguf_init_from_file(path, params);
    if (!g) {
        append(out, cap, &len, "FAIL: gguf_init_from_file could not parse the file as GGUF.\n");
        return 2;
    }
    int64_t n_tensors = gguf_get_n_tensors(g);
    append(out, cap, &len, "GGUF version: %u\nKV pairs: %lld\nTensors: %lld\n",
           gguf_get_version(g), (long long)gguf_get_n_kv(g), (long long)n_tensors);
    int64_t arch = gguf_find_key(g, "general.architecture");
    if (arch >= 0 && gguf_get_kv_type(g, arch) == GGUF_TYPE_STRING) {
        append(out, cap, &len, "general.architecture: %s\n", gguf_get_val_str(g, arch));
    }
    long long tq = 0;
    for (int64_t i = 0; i < n_tensors; i++) {
        if (gguf_get_tensor_type(g, i) == KP_TQ2_1) tq++;
    }
    append(out, cap, &len, "Tensors stored as TQ2_1: %lld\n", tq);
    gguf_free(g);
    if (tq == 0) {
        append(out, cap, &len, "NOTE: no TQ2_1 tensors - this is not a TQ2_1 KittenTTS 2 GGUF.\n");
        return 3;
    }
    append(out, cap, &len, "OK: header parsed by the fork-built ggml.\n");
    return 0;
}

int kp_load_model(const char *path, char *out, size_t cap) {
    size_t len = 0;
    if (!path || !out || cap == 0) return 1;
    out[0] = 0;
    llama_backend_init();
    struct llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    struct llama_model *model = llama_model_load_from_file(path, mp);
    if (!model) {
        append(out, cap, &len, "FAIL: llama_model_load_from_file returned NULL (see Xcode/device console for llama logs).\n");
        llama_backend_free();
        return 2;
    }
    char desc[256];
    llama_model_desc(model, desc, sizeof desc);
    append(out, cap, &len, "Model: %s\nParams: %llu\nModel size: %llu bytes\nn_embd: %d\n",
           desc, (unsigned long long)llama_model_n_params(model),
           (unsigned long long)llama_model_size(model), llama_model_n_embd(model));
    const struct llama_vocab *vocab = llama_model_get_vocab(model);
    const char *text = "Hello world.";
    llama_token toks[64];
    int n = llama_tokenize(vocab, text, (int32_t)strlen(text), toks, 64, false, true);
    append(out, cap, &len, "Vocab tokens: %d\nTokenized \"%s\" -> %d tokens\n", llama_vocab_n_tokens(vocab), text, n);
    llama_model_free(model);
    llama_backend_free();
    append(out, cap, &len, "OK: model loaded by the fork-built llama. No inference or audio was attempted.\n");
    return 0;
}
