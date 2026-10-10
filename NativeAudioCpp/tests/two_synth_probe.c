/* Native regression probe: loads one KittenTTS 2 model, creates ONE offline "tts" session and synthesizes several
 * texts of different length on it (the app keeps the session alive between generations, see kt_audiocpp_bridge.c).
 * Run by scripts/run_two_synth_probe.sh, only when KT_MODEL_PATH points at a local model; never in CI.
 * Exit code 0 only if every run returned audio. */
#include "audiocpp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *kTexts[] = {
    "Hello there.",
    "The second generation on the same loaded model must not fail while building the flow decoder graph.",
    "A third, short one.",
    "And a fourth sentence that is long enough to need a different number of decoder frames than the previous one.",
};

static int fail(const char *stage, audiocpp_status st) {
    fprintf(stderr, "FAIL %s: %s (status %d): %s\n", stage, audiocpp_status_string(st), (int)st, audiocpp_last_error());
    return 1;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : getenv("KT_MODEL_PATH");
    if (!path || !*path) { fprintf(stderr, "usage: two_synth_probe <model.gguf> (or set KT_MODEL_PATH)\n"); return 2; }
    audiocpp_registry *registry = NULL;
    audiocpp_model *model = NULL;
    audiocpp_session *session = NULL;
    audiocpp_status st = audiocpp_registry_create(NULL, &registry);
    if (st != AUDIOCPP_OK) return fail("audiocpp_registry_create", st);
    audiocpp_model_config config = { "kitten_tts2", NULL, NULL, NULL };
    st = audiocpp_model_load(registry, path, &config, NULL, &model);
    if (st != AUDIOCPP_OK) return fail("audiocpp_model_load", st);
    audiocpp_backend_config backend = { "cpu", 0, 4 };
    st = audiocpp_session_create(model, "tts", "offline", &backend, NULL, &session);
    if (st != AUDIOCPP_OK) return fail("audiocpp_session_create", st);

    int rc = 0;
    for (size_t i = 0; i < sizeof kTexts / sizeof *kTexts; ++i) {
        audiocpp_request *req = audiocpp_request_create();
        audiocpp_result *result = NULL;
        st = req ? audiocpp_request_set_text(req, kTexts[i], NULL) : AUDIOCPP_ERR_INVALID_ARGUMENT;
        if (st == AUDIOCPP_OK) st = audiocpp_session_run(session, req, &result);
        const float *samples = NULL;
        size_t frames = 0;
        int rate = 0, channels = 0;
        if (st == AUDIOCPP_OK) st = audiocpp_result_audio(result, &samples, &frames, &rate, &channels);
        if (st != AUDIOCPP_OK || !samples || frames == 0) {
            fprintf(stderr, "run %zu: ", i + 1);
            rc = fail("audiocpp_session_run", st);
        } else {
            printf("run %zu OK: %zu frames at %d Hz, %d channel(s)\n", i + 1, frames, rate, channels);
        }
        audiocpp_result_free(result);
        audiocpp_request_free(req);
        if (rc) break;
    }
    audiocpp_session_free(session);
    audiocpp_model_free(model);
    audiocpp_registry_free(registry);
    if (rc == 0) printf("RESULT: repeated synthesis on one session succeeded\n");
    return rc;
}
