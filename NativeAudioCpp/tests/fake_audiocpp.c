#include "audiocpp.h"

#include <stdlib.h>
#include <string.h>

fake_counters fake;
static const char *last_error = "";

struct audiocpp_registry { int x; };
struct audiocpp_model { int x; };
struct audiocpp_session { char task[8]; };
struct audiocpp_request { int has_audio; };
struct audiocpp_result { float samples[8]; };

uint32_t audiocpp_abi_version(void) { return 0; }
const char *audiocpp_build_version(void) { return "fake"; }
const char *audiocpp_last_error(void) { return last_error; }
const char *audiocpp_status_string(audiocpp_status s) { return s == AUDIOCPP_ERR_OUT_OF_MEMORY ? "out of memory" : s == AUDIOCPP_ERR_RUNTIME ? "runtime error" : "status"; }
audiocpp_status audiocpp_registry_create(const char *c, audiocpp_registry **out) { (void)c; *out = calloc(1, sizeof **out); fake.registries++; return AUDIOCPP_OK; }
void audiocpp_registry_free(audiocpp_registry *r) { if (r) fake.registries--; free(r); }
audiocpp_status audiocpp_model_load(audiocpp_registry *r, const char *p, const audiocpp_model_config *c, const audiocpp_options *o, audiocpp_model **out) {
    (void)r; (void)p; (void)c; (void)o; *out = calloc(1, sizeof **out); fake.models++; return AUDIOCPP_OK;
}
void audiocpp_model_free(audiocpp_model *m) { if (m) fake.models--; free(m); }
const char *audiocpp_model_family(const audiocpp_model *m) { (void)m; return "kitten_tts2"; }
const char *audiocpp_model_description(const audiocpp_model *m) { (void)m; return "fake"; }
int audiocpp_model_supports(const audiocpp_model *m, const char *task, const char *mode) { (void)m; (void)mode; return strcmp(task, "tts") == 0 || strcmp(task, "clon") == 0; }
audiocpp_status audiocpp_session_create(const audiocpp_model *m, const char *task, const char *mode, const audiocpp_backend_config *b, const audiocpp_options *o, audiocpp_session **out) {
    (void)m; (void)mode; (void)b; (void)o;
    if (fake.fail_next_session_create) {
        fake.fail_next_session_create = 0;
        last_error = "std::bad_alloc";
        return AUDIOCPP_ERR_OUT_OF_MEMORY;
    }
    strncpy(fake.last_session_task, task, sizeof fake.last_session_task - 1);
    *out = calloc(1, sizeof **out);
    strncpy((*out)->task, task, sizeof (*out)->task - 1);
    strncpy(fake.live_session_task, task, sizeof fake.live_session_task - 1);
    if (strcmp(task, "tts") == 0) fake.tts_creates++; else fake.clon_creates++;
    fake.sessions++; fake.sessions_created++;
    if (fake.sessions > fake.peak_sessions) fake.peak_sessions = fake.sessions;
    return AUDIOCPP_OK;
}
void audiocpp_session_free(audiocpp_session *s) { if (s) { fake.sessions--; fake.live_session_task[0] = 0; } free(s); }
const char *audiocpp_session_family(const audiocpp_session *s) { (void)s; return "kitten_tts2"; }
audiocpp_status audiocpp_session_run(audiocpp_session *s, const audiocpp_request *r, audiocpp_result **out) {
    *out = NULL;
    fake.runs++;
    if (strcmp(s->task, r->has_audio ? "clon" : "tts") != 0) fake.task_mismatches++;
    if (r->has_audio) fake.clone_runs++;
    if (fake.fail_next_run) {
        fake.fail_next_run = 0;
        last_error = "failed to initialize HiFT backend graph context";
        return AUDIOCPP_ERR_RUNTIME;
    }
    *out = calloc(1, sizeof **out);
    fake.results++;
    return AUDIOCPP_OK;
}
audiocpp_request *audiocpp_request_create(void) { fake.requests++; return calloc(1, sizeof(struct audiocpp_request)); }
void audiocpp_request_free(audiocpp_request *r) { if (r) fake.requests--; free(r); }
audiocpp_status audiocpp_request_set_text(audiocpp_request *r, const char *t, const char *l) { (void)r; (void)t; (void)l; return AUDIOCPP_OK; }
audiocpp_status audiocpp_request_set_voice_audio(audiocpp_request *r, const float *s, size_t f, int sr, int c) { (void)s; (void)f; (void)sr; (void)c; r->has_audio = 1; return AUDIOCPP_OK; }
audiocpp_status audiocpp_request_set_voice_id(audiocpp_request *r, const char *v) { (void)r; (void)v; return AUDIOCPP_OK; }
audiocpp_status audiocpp_request_set_option(audiocpp_request *r, const char *k, const char *v) { (void)r; (void)k; (void)v; return AUDIOCPP_OK; }
void audiocpp_result_free(audiocpp_result *r) { if (r) fake.results--; free(r); }
audiocpp_status audiocpp_result_audio(const audiocpp_result *r, const float **s, size_t *f, int *rate, int *ch) {
    *s = r->samples; *f = 8; *rate = 24000; *ch = 1; return AUDIOCPP_OK;
}
