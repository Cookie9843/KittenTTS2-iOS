/* Host stand-in for the one ggml symbol the bridge uses. */
typedef void (*ggml_abort_callback_t)(const char *);
static inline ggml_abort_callback_t ggml_set_abort_callback(ggml_abort_callback_t cb) { (void)cb; return 0; }
