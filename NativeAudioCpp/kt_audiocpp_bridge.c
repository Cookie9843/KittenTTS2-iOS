#include "kt_audiocpp_bridge.h"

#include <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Build-variant marker: readable from the object file / final executable (strings, nm) so CI can prove which branch of
 * this file was actually compiled, independent of what flags the build invocation was given. */
#ifdef KT_NATIVE_LINKED
__attribute__((used)) const char kt_bridge_build_variant[] = "kt-bridge-variant:native-linked";
#else
__attribute__((used)) const char kt_bridge_build_variant[] = "kt-bridge-variant:ui-only-stub";
#endif

#ifdef KT_NATIVE_LINKED
#include "audiocpp.h"
#include "ggml.h"

struct kt_engine {
    audiocpp_registry *registry;
    audiocpp_model *model;
    audiocpp_session *session;
    int threads;
    char task[8]; /* task of `session`: "tts" or "clon" */
};

static void set_err(char *err, size_t cap, const char *stage, audiocpp_status status) {
    if (!err || cap == 0) return;
    snprintf(err, cap, "%s failed: %s (status %d): %s", stage, audiocpp_status_string(status), (int)status,
             audiocpp_last_error());
}

int kt_runtime_linked(void) { return 1; }

int kt_runtime_info(char *out, size_t cap) {
    if (!out || cap == 0) return 1;
    uint32_t abi = audiocpp_abi_version();
    snprintf(out, cap, "audio.cpp build %s, C ABI %u.%u.%u", audiocpp_build_version(), abi >> 16, (abi >> 8) & 0xFF,
             abi & 0xFF);
    return 0;
}
#else
int kt_runtime_linked(void) { return 0; }

int kt_runtime_info(char *out, size_t cap) {
    if (!out || cap == 0) return 1;
    snprintf(out, cap, "audio.cpp runtime NOT linked into this build");
    return 0;
}
#endif

uint64_t kt_available_memory(void) { return (uint64_t)os_proc_available_memory(); }

int kt_redirect_stderr(const char *path) {
    if (!path) return 1;
    if (!freopen(path, "w", stderr)) return 2;
    setvbuf(stderr, NULL, _IOLBF, 0);
    return 0;
}

void kt_audio_free(kt_audio *a) {
    if (!a) return;
    free(a->samples);
    memset(a, 0, sizeof *a);
}

#ifdef KT_NATIVE_LINKED
static void abort_hook(const char *message) {
    fprintf(stderr, "KT_NATIVE_ABORT: %s\n", message ? message : "(no message)");
    fflush(stderr);
}

void kt_install_abort_hook(void) { ggml_set_abort_callback(abort_hook); }

void kt_unload(kt_engine *e) {
    if (!e) return;
    audiocpp_session_free(e->session);
    audiocpp_model_free(e->model);
    audiocpp_registry_free(e->registry);
    free(e);
}

/* Creates the session for `task` ("tts" or "clon"). At most one session exists at a time: an existing session of a
 * different task is freed first so the model's weights are never instantiated twice. */
static int ensure_session(kt_engine *e, const char *task, char *err, size_t err_cap) {
    if (e->session && strcmp(e->task, task) == 0) return 0;
    if (e->session) {
        audiocpp_session_free(e->session);
        e->session = NULL;
        e->task[0] = 0;
    }
    if (!audiocpp_model_supports(e->model, task, "offline")) {
        if (err && err_cap)
            snprintf(err, err_cap, "model family '%s' does not report offline '%s' support", audiocpp_model_family(e->model), task);
        return 4;
    }
    audiocpp_backend_config backend = { "cpu", 0, e->threads > 0 ? e->threads : 1 };
    audiocpp_status st = audiocpp_session_create(e->model, task, "offline", &backend, NULL, &e->session);
    if (st != AUDIOCPP_OK) {
        e->session = NULL;
        set_err(err, err_cap, "audiocpp_session_create", st);
        return 5;
    }
    snprintf(e->task, sizeof e->task, "%s", task);
    return 0;
}

int kt_load(const char *path, int threads, kt_engine **out, char *describe, size_t describe_cap, char *err,
            size_t err_cap) {
    if (!path || !out) {
        if (err && err_cap) snprintf(err, err_cap, "invalid arguments");
        return 1;
    }
    *out = NULL;
    if ((audiocpp_abi_version() >> 16) != AUDIOCPP_ABI_VERSION_MAJOR) {
        if (err && err_cap) snprintf(err, err_cap, "audio.cpp C ABI major version mismatch");
        return 1;
    }
    kt_engine *e = calloc(1, sizeof *e);
    if (!e) {
        if (err && err_cap) snprintf(err, err_cap, "out of memory allocating engine");
        return 1;
    }
    e->threads = threads > 0 ? threads : 1;
    audiocpp_status st = audiocpp_registry_create(NULL, &e->registry);
    if (st != AUDIOCPP_OK) { set_err(err, err_cap, "audiocpp_registry_create", st); kt_unload(e); return 2; }

    audiocpp_model_config config = { "kitten_tts2", NULL, NULL, NULL };
    st = audiocpp_model_load(e->registry, path, &config, NULL, &e->model);
    if (st != AUDIOCPP_OK) { set_err(err, err_cap, "audiocpp_model_load", st); kt_unload(e); return 3; }

    int rc = ensure_session(e, "tts", err, err_cap);
    if (rc != 0) { kt_unload(e); return rc; }

    if (describe && describe_cap) {
        snprintf(describe, describe_cap, "family=%s; session family=%s; description=%s; backend=cpu; threads=%d",
                 audiocpp_model_family(e->model), audiocpp_session_family(e->session), audiocpp_model_description(e->model),
                 e->threads);
    }
    *out = e;
    return 0;
}

/* Runs `req` on the engine's session and copies the mono/interleaved float result into `out`. Frees `req`. */
static int run_and_copy(kt_engine *e, audiocpp_request *req, audiocpp_status st, const char *stage, kt_audio *out,
                        char *err, size_t err_cap) {
    audiocpp_result *result = NULL;
    if (st == AUDIOCPP_OK) { stage = "audiocpp_session_run"; st = audiocpp_session_run(e->session, req, &result); }
    if (st != AUDIOCPP_OK) {
        set_err(err, err_cap, stage, st);
        audiocpp_request_free(req);
        return 3;
    }
    const float *samples = NULL;
    size_t frames = 0;
    int rate = 0, channels = 0;
    st = audiocpp_result_audio(result, &samples, &frames, &rate, &channels);
    if (st != AUDIOCPP_OK || !samples || frames == 0 || channels < 1 || rate < 1) {
        if (st != AUDIOCPP_OK) set_err(err, err_cap, "audiocpp_result_audio", st);
        else if (err && err_cap) snprintf(err, err_cap, "synthesis returned no audio (frames=%zu, rate=%d, channels=%d)", frames, rate, channels);
        audiocpp_result_free(result);
        audiocpp_request_free(req);
        return 4;
    }
    size_t n = frames * (size_t)channels;
    out->samples = malloc(n * sizeof(float));
    if (!out->samples) {
        if (err && err_cap) snprintf(err, err_cap, "out of memory copying %zu samples", n);
        audiocpp_result_free(result);
        audiocpp_request_free(req);
        return 5;
    }
    memcpy(out->samples, samples, n * sizeof(float));
    out->frames = frames;
    out->sample_rate = rate;
    out->channels = channels;
    audiocpp_result_free(result);
    audiocpp_request_free(req);
    return 0;
}

int kt_synthesize(kt_engine *e, const char *text, const char *voice_id, int64_t seed, kt_audio *out, char *err,
                  size_t err_cap) {
    if (!e || !text || !out) {
        if (err && err_cap) snprintf(err, err_cap, "invalid arguments");
        return 1;
    }
    memset(out, 0, sizeof *out);
    int rc = ensure_session(e, "tts", err, err_cap);
    if (rc != 0) return rc;
    audiocpp_request *req = audiocpp_request_create();
    if (!req) {
        if (err && err_cap) snprintf(err, err_cap, "audiocpp_request_create returned NULL");
        return 2;
    }
    audiocpp_status st = audiocpp_request_set_text(req, text, NULL);
    const char *stage = "audiocpp_request_set_text";
    if (st == AUDIOCPP_OK && voice_id && *voice_id) { stage = "audiocpp_request_set_voice_id"; st = audiocpp_request_set_voice_id(req, voice_id); }
    if (st == AUDIOCPP_OK && seed >= 0) {
        char buf[32];
        snprintf(buf, sizeof buf, "%lld", (long long)seed);
        stage = "audiocpp_request_set_option(seed)";
        st = audiocpp_request_set_option(req, "seed", buf);
    }
    return run_and_copy(e, req, st, stage, out, err, err_cap);
}

int kt_synthesize_clone(kt_engine *e, const char *text, const float *reference, size_t reference_frames,
                        int reference_rate, const char *transcript, int64_t seed, kt_audio *out, char *err,
                        size_t err_cap) {
    if (!e || !text || !out || !reference || reference_frames == 0 || reference_rate < 1 || !transcript || !*transcript) {
        if (err && err_cap) snprintf(err, err_cap, "invalid arguments for voice cloning");
        return 1;
    }
    memset(out, 0, sizeof *out);
    int rc = ensure_session(e, "clon", err, err_cap);
    if (rc != 0) return rc;
    audiocpp_request *req = audiocpp_request_create();
    if (!req) {
        if (err && err_cap) snprintf(err, err_cap, "audiocpp_request_create returned NULL");
        return 2;
    }
    const char *stage = "audiocpp_request_set_text";
    audiocpp_status st = audiocpp_request_set_text(req, text, NULL);
    if (st == AUDIOCPP_OK) { stage = "audiocpp_request_set_voice_audio"; st = audiocpp_request_set_voice_audio(req, reference, reference_frames, reference_rate, 1); }
    if (st == AUDIOCPP_OK) { stage = "audiocpp_request_set_option(reference_text)"; st = audiocpp_request_set_option(req, "reference_text", transcript); }
    if (st == AUDIOCPP_OK && seed >= 0) {
        char buf[32];
        snprintf(buf, sizeof buf, "%lld", (long long)seed);
        stage = "audiocpp_request_set_option(seed)";
        st = audiocpp_request_set_option(req, "seed", buf);
    }
    return run_and_copy(e, req, st, stage, out, err, err_cap);
}
#else /* !KT_NATIVE_LINKED: UI-only build; every native entry point reports that the runtime is absent. */
static const char *kNotLinked =
    "This build does not include the audio.cpp runtime (it is a UI-only build). Use the CI IPA built by scripts/build_app_ipa.sh.";

void kt_install_abort_hook(void) {}
void kt_unload(kt_engine *e) { (void)e; }

int kt_load(const char *path, int threads, kt_engine **out, char *describe, size_t describe_cap, char *err,
            size_t err_cap) {
    (void)path; (void)threads; (void)describe; (void)describe_cap;
    if (out) *out = NULL;
    if (err && err_cap) snprintf(err, err_cap, "%s", kNotLinked);
    return 99;
}

int kt_synthesize(kt_engine *e, const char *text, const char *voice_id, int64_t seed, kt_audio *out, char *err,
                  size_t err_cap) {
    (void)e; (void)text; (void)voice_id; (void)seed;
    if (out) memset(out, 0, sizeof *out);
    if (err && err_cap) snprintf(err, err_cap, "%s", kNotLinked);
    return 99;
}

int kt_synthesize_clone(kt_engine *e, const char *text, const float *reference, size_t reference_frames,
                        int reference_rate, const char *transcript, int64_t seed, kt_audio *out, char *err,
                        size_t err_cap) {
    (void)e; (void)text; (void)reference; (void)reference_frames; (void)reference_rate; (void)transcript; (void)seed;
    if (out) memset(out, 0, sizeof *out);
    if (err && err_cap) snprintf(err, err_cap, "%s", kNotLinked);
    return 99;
}
#endif
