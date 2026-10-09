#ifndef PROBE_SHIM_H
#define PROBE_SHIM_H

#include <stddef.h>

/// Reads only the GGUF header (no tensor data) via the fork-built ggml. Returns 0 on success.
/// Writes a human-readable report into `out`.
int kp_read_header(const char *path, char *out, size_t cap);

/// Loads the model with the fork-built llama (CPU only) and tokenizes a short fixed string.
/// Returns 0 on success. This is a load test only: no context is created and no audio is produced.
int kp_load_model(const char *path, char *out, size_t cap);

#endif
