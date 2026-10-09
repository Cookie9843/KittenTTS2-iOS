#ifndef KITTEN_BRIDGE_H
#define KITTEN_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Narrow C seam between Swift and the (not yet linked) KittenTTS 2 native runtime.
/// Components are reported individually so that nothing is claimed that has not been linked and verified.
#define KITTEN_BRIDGE_ABI_VERSION 1

typedef enum {
    KITTEN_BRIDGE_OK = 0,
    KITTEN_BRIDGE_ERR_INVALID_ARGUMENT = 1,
    /// A required native component is not linked into this build. No audio is produced.
    KITTEN_BRIDGE_ERR_UNAVAILABLE = 2,
} kitten_bridge_status;

typedef struct {
    /// DeepGrove/KittenML llama.cpp fork (TQ2_1) linked for this platform.
    int32_t llama_fork_linked;
    /// Fork's TQ2_1 tensor type available at runtime.
    int32_t tq2_1_supported;
    /// A runtime able to execute decoder.pt (TorchScript or a documented port) linked.
    int32_t decoder_linked;
    /// kitten-text-processing normalizer linked.
    int32_t text_normalizer_linked;
} kitten_bridge_capabilities;

int32_t kitten_bridge_abi_version(void);
kitten_bridge_capabilities kitten_bridge_get_capabilities(void);

/// Human-readable explanation of a status; never NULL.
const char *kitten_bridge_status_message(kitten_bridge_status status);

/// Synthesizes speech. Writes up to `capacity` mono float samples to `out_samples` and the count to `out_count`.
/// In this prototype it fails with KITTEN_BRIDGE_ERR_UNAVAILABLE unless every component is linked, and it
/// never fabricates samples (`out_count` is always set to 0 on failure).
kitten_bridge_status kitten_bridge_generate(const char *model_dir, const char *text,
                                            float *out_samples, size_t capacity, size_t *out_count);

#ifdef __cplusplus
}
#endif

#endif
