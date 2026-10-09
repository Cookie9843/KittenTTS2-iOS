#include "kt_audiocpp_bridge.h"

#include <os/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audiocpp.h"

struct kt_engine {
    audiocpp_registry *registry;
    audiocpp_model *model;
    audiocpp_session *session;
};

static void set_err(char *err, size_t cap, const char *stage, audiocpp_status status) {
    if (!err || cap == 0) return;
    snprintf(err, cap, "%s failed: %s (status %d): %s", stage, audiocpp_status_string(status), (int)status,
             audiocpp_last_error());
}

int kt_runtime_info(char *out, size_t cap) {
    if (!out || cap == 0) return 1;
    uint32_t abi = audiocpp_abi_version();
    snprintf(out, cap, "audio.cpp build %s, C ABI %u.%u.%u", audiocpp_build_version(), abi >> 16, (abi >> 8) & 0xFF,
             abi & 0xFF);
    return 0;
}

uint64_t kt_available_memory(void) { return (uint64_t)os_proc_available_memory(); }

int kt_redirect_stderr(const char *path) {
    if (!path) return 1;
    if (!freopen(path, "a", stderr)) return 2;
    setvbuf(stderr, NULL, _IOLBF, 0);
    return 0;
}

void kt_unload(kt_engine *e) {
    if (!e) return;
    audiocpp_session_free(e->session);
    audiocpp_model_free(e->model);
    audiocpp_registry_free(e->registry);
    free(e);
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
    audiocpp_status st = audiocpp_registry_create(NULL, &e->registry);
    if (st != AUDIOCPP_OK) { set_err(err, err_cap, "audiocpp_registry_create", st); kt_unload(e); return 2; }

    audiocpp_model_config config = { "kitten_tts2", NULL, NULL, NULL };
    st = audiocpp_model_load(e->registry, path, &config, NULL, &e->model);
    if (st != AUDIOCPP_OK) { set_err(err, err_cap, "audiocpp_model_load", st); kt_unload(e); return 3; }

    if (!audiocpp_model_supports(e->model, "tts", "offline")) {
        if (err && err_cap) snprintf(err, err_cap, "model family '%s' does not report offline TTS support", audiocpp_model_family(e->model));
        kt_unload(e);
        return 4;
    }
    audiocpp_backend_config backend = { "cpu", 0, threads > 0 ? threads : 1 };
    st = audiocpp_session_create(e->model, "tts", "offline", &backend, NULL, &e->session);
    if (st != AUDIOCPP_OK) { set_err(err, err_cap, "audiocpp_session_create", st); kt_unload(e); return 5; }

    if (describe && describe_cap) {
        snprintf(describe, describe_cap, "family=%s; session family=%s; description=%s; backend=cpu; threads=%d",
                 audiocpp_model_family(e->model), audiocpp_session_family(e->session), audiocpp_model_description(e->model),
                 backend.threads);
    }
    *out = e;
    return 0;
}

int kt_synthesize(kt_engine *e, const char *text, const char *voice_id, int64_t seed, kt_audio *out, char *err,
                  size_t err_cap) {
    if (!e || !text || !out) {
        if (err && err_cap) snprintf(err, err_cap, "invalid arguments");
        return 1;
    }
    memset(out, 0, sizeof *out);
    audiocpp_request *req = audiocpp_request_create();
    if (!req) {
        if (err && err_cap) snprintf(err, err_cap, "audiocpp_request_create returned NULL");
        return 2;
    }
    audiocpp_result *result = NULL;
    audiocpp_status st = audiocpp_request_set_text(req, text, NULL);
    const char *stage = "audiocpp_request_set_text";
    if (st == AUDIOCPP_OK && voice_id && *voice_id) { stage = "audiocpp_request_set_voice_id"; st = audiocpp_request_set_voice_id(req, voice_id); }
    if (st == AUDIOCPP_OK && seed >= 0) {
        char buf[32];
        snprintf(buf, sizeof buf, "%lld", (long long)seed);
        stage = "audiocpp_request_set_option(seed)";
        st = audiocpp_request_set_option(req, "seed", buf);
    }
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

void kt_audio_free(kt_audio *a) {
    if (!a) return;
    free(a->samples);
    memset(a, 0, sizeof *a);
}
