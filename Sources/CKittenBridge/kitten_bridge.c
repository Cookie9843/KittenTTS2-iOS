#include "kitten_bridge.h"

/* Define these from the build once the real components are linked and verified on iOS. */
#ifndef KITTEN_BRIDGE_HAVE_LLAMA_FORK
#define KITTEN_BRIDGE_HAVE_LLAMA_FORK 0
#endif
#ifndef KITTEN_BRIDGE_HAVE_TQ2_1
#define KITTEN_BRIDGE_HAVE_TQ2_1 0
#endif
#ifndef KITTEN_BRIDGE_HAVE_DECODER
#define KITTEN_BRIDGE_HAVE_DECODER 0
#endif
#ifndef KITTEN_BRIDGE_HAVE_NORMALIZER
#define KITTEN_BRIDGE_HAVE_NORMALIZER 0
#endif

int32_t kitten_bridge_abi_version(void) { return KITTEN_BRIDGE_ABI_VERSION; }

kitten_bridge_capabilities kitten_bridge_get_capabilities(void) {
    kitten_bridge_capabilities caps;
    caps.llama_fork_linked = KITTEN_BRIDGE_HAVE_LLAMA_FORK;
    caps.tq2_1_supported = KITTEN_BRIDGE_HAVE_TQ2_1;
    caps.decoder_linked = KITTEN_BRIDGE_HAVE_DECODER;
    caps.text_normalizer_linked = KITTEN_BRIDGE_HAVE_NORMALIZER;
    return caps;
}

const char *kitten_bridge_status_message(kitten_bridge_status status) {
    switch (status) {
    case KITTEN_BRIDGE_OK: return "ok";
    case KITTEN_BRIDGE_ERR_INVALID_ARGUMENT: return "invalid argument";
    case KITTEN_BRIDGE_ERR_UNAVAILABLE:
        return "KittenTTS 2 native runtime is not linked in this build (llama.cpp TQ2_1 fork, decoder and normalizer are unverified on iOS)";
    }
    return "unknown status";
}

kitten_bridge_status kitten_bridge_generate(const char *model_dir, const char *text,
                                            float *out_samples, size_t capacity, size_t *out_count) {
    (void)out_samples;
    (void)capacity;
    if (out_count) *out_count = 0;
    if (!model_dir || !text || !out_count) return KITTEN_BRIDGE_ERR_INVALID_ARGUMENT;
    kitten_bridge_capabilities caps = kitten_bridge_get_capabilities();
    if (!(caps.llama_fork_linked && caps.tq2_1_supported && caps.decoder_linked && caps.text_normalizer_linked)) {
        return KITTEN_BRIDGE_ERR_UNAVAILABLE;
    }
    /* Real inference is not implemented; refuse rather than produce fake audio. */
    return KITTEN_BRIDGE_ERR_UNAVAILABLE;
}
