/* Host stand-in for the subset of audio.cpp's C ABI the bridge calls. Same names and signatures as include/audiocpp.h;
 * fake_audiocpp.c implements it with allocation counters and failure injection (see lifecycle_test.c). */
#ifndef FAKE_AUDIOCPP_H
#define FAKE_AUDIOCPP_H
#include <stddef.h>
#include <stdint.h>

#define AUDIOCPP_ABI_VERSION_MAJOR 0
typedef enum audiocpp_status {
    AUDIOCPP_OK = 0, AUDIOCPP_ERR_INVALID_ARGUMENT = 1, AUDIOCPP_ERR_UNSUPPORTED_FAMILY = 2, AUDIOCPP_ERR_LOAD_FAILED = 3,
    AUDIOCPP_ERR_RUNTIME = 4, AUDIOCPP_ERR_OUT_OF_MEMORY = 5, AUDIOCPP_ERR_OUT_OF_RANGE = 6, AUDIOCPP_ERR_NOT_AVAILABLE = 7
} audiocpp_status;
typedef struct audiocpp_registry audiocpp_registry;
typedef struct audiocpp_model audiocpp_model;
typedef struct audiocpp_session audiocpp_session;
typedef struct audiocpp_options audiocpp_options;
typedef struct audiocpp_request audiocpp_request;
typedef struct audiocpp_result audiocpp_result;
typedef struct audiocpp_model_config { const char *family_hint, *config_id, *weight_id, *model_spec_override; } audiocpp_model_config;
typedef struct audiocpp_backend_config { const char *backend; int device; int threads; } audiocpp_backend_config;

uint32_t audiocpp_abi_version(void);
const char *audiocpp_build_version(void);
const char *audiocpp_last_error(void);
const char *audiocpp_status_string(audiocpp_status status);
audiocpp_status audiocpp_registry_create(const char *, audiocpp_registry **);
void audiocpp_registry_free(audiocpp_registry *);
audiocpp_status audiocpp_model_load(audiocpp_registry *, const char *, const audiocpp_model_config *, const audiocpp_options *, audiocpp_model **);
void audiocpp_model_free(audiocpp_model *);
const char *audiocpp_model_family(const audiocpp_model *);
const char *audiocpp_model_description(const audiocpp_model *);
int audiocpp_model_supports(const audiocpp_model *, const char *task, const char *mode);
audiocpp_status audiocpp_session_create(const audiocpp_model *, const char *task, const char *mode, const audiocpp_backend_config *, const audiocpp_options *, audiocpp_session **);
void audiocpp_session_free(audiocpp_session *);
const char *audiocpp_session_family(const audiocpp_session *);
audiocpp_status audiocpp_session_run(audiocpp_session *, const audiocpp_request *, audiocpp_result **);
audiocpp_request *audiocpp_request_create(void);
void audiocpp_request_free(audiocpp_request *);
audiocpp_status audiocpp_request_set_text(audiocpp_request *, const char *, const char *);
audiocpp_status audiocpp_request_set_voice_audio(audiocpp_request *, const float *, size_t, int, int);
audiocpp_status audiocpp_request_set_voice_id(audiocpp_request *, const char *);
audiocpp_status audiocpp_request_set_option(audiocpp_request *, const char *, const char *);
void audiocpp_result_free(audiocpp_result *);
audiocpp_status audiocpp_result_audio(const audiocpp_result *, const float **, size_t *, int *, int *);

/* test controls */
typedef struct fake_counters {
    int registries, models, sessions, requests, results; /* currently alive */
    int sessions_created, peak_sessions, runs, clone_runs;
    int fail_next_session_create, fail_next_run;
    char last_session_task[8];
} fake_counters;
extern fake_counters fake;
#endif
