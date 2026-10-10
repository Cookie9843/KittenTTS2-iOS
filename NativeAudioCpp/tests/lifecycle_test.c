/* Host regression test for the bridge's resource lifecycle (kt_audiocpp_bridge.c compiled with KT_NATIVE_LINKED against
 * the fake audio.cpp C ABI in fake/). It proves the bridge's own policy: preset requests run on a "tts" session and clone
 * requests on a "clon" session; switching frees the old session before creating the next (never two alive); a failed
 * request discards only the session it ran on and the next request rebuilds it after the old one was freed; a failed rebuild leaves nothing allocated and is recoverable; no request/result is leaked on any path.
 * It says nothing about the real runtime's memory use (that needs the model on a device). */
#include "kt_audiocpp_bridge.h"
#include "audiocpp.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "CHECK failed line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

static int preset(kt_engine *e, char *err) {
    kt_audio a;
    int rc = kt_synthesize(e, "hello", "Bruno", -1, &a, err, 512);
    if (rc == 0) kt_audio_free(&a);
    return rc;
}
static int clone(kt_engine *e, char *err) {
    static const float ref[2400] = { 0.1f };
    kt_audio a;
    int rc = kt_synthesize_clone(e, "hello", ref, 2400, 24000, "hello there", -1, &a, err, 512);
    if (rc == 0) kt_audio_free(&a);
    return rc;
}

int main(void) {
    char err[512] = "", describe[256];
    kt_engine *e = NULL;
    CHECK(kt_load("/fake.gguf", 4, &e, describe, sizeof describe, err, sizeof err) == 0 && e);
    CHECK(fake.sessions == 1 && fake.sessions_created == 1 && strcmp(fake.live_session_task, "tts") == 0);

    /* repeated requests of one kind reuse the session */
    for (int i = 0; i < 3; ++i) CHECK(preset(e, err) == 0);
    CHECK(fake.sessions_created == 1);

    /* the first clone switches to a "clon" session: the "tts" one is freed first; repeats reuse it */
    CHECK(clone(e, err) == 0);
    CHECK(fake.sessions_created == 2 && fake.sessions == 1 && strcmp(fake.live_session_task, "clon") == 0);
    for (int i = 0; i < 3; ++i) CHECK(clone(e, err) == 0);
    CHECK(fake.sessions_created == 2 && fake.clon_creates == 1 && fake.tts_creates == 1);

    /* alternating preset and clone: every switch recreates the right task, never two sessions, no leaks */
    for (int i = 0; i < 6; ++i) {
        CHECK(preset(e, err) == 0 && strcmp(fake.live_session_task, "tts") == 0);
        CHECK(clone(e, err) == 0 && strcmp(fake.live_session_task, "clon") == 0);
    }
    CHECK(fake.peak_sessions == 1 && fake.sessions == 1);
    CHECK(fake.tts_creates == 7 && fake.clon_creates == 7);
    CHECK(fake.task_mismatches == 0);
    CHECK(fake.requests == 0 && fake.results == 0);

    /* a failed run reports the native stage and text, plus the memory headroom, and leaks nothing */
    fake.fail_next_run = 1;
    CHECK(clone(e, err) == 3);
    CHECK(strstr(err, "audiocpp_session_run failed") && strstr(err, "HiFT backend graph context") && strstr(err, "available to app: 1234 MiB"));
    CHECK(fake.requests == 0 && fake.results == 0);
    CHECK(fake.sessions == 1); /* kept until the next request */

    /* a clone after a failed clone rebuilds a "clon" session (old one freed first) */
    unsigned before = (unsigned)fake.sessions_created;
    CHECK(clone(e, err) == 0);
    CHECK((unsigned)fake.sessions_created == before + 1 && fake.sessions == 1 && strcmp(fake.live_session_task, "clon") == 0);

    /* a failed clone only invalidates the clone session: the next preset switches to a fresh "tts" one */
    fake.fail_next_run = 1;
    CHECK(clone(e, err) == 3);
    CHECK(preset(e, err) == 0);
    CHECK(strcmp(fake.live_session_task, "tts") == 0 && fake.sessions == 1 && fake.peak_sessions == 1);

    /* a healthy session is not touched by an unrelated failure: failed preset invalidates the "tts" session only */
    fake.fail_next_run = 1;
    CHECK(preset(e, err) == 3);
    before = (unsigned)fake.sessions_created;
    CHECK(preset(e, err) == 0);
    CHECK((unsigned)fake.sessions_created == before + 1 && strcmp(fake.live_session_task, "tts") == 0);

    /* failed rebuild while switching: reported as a session_create failure, nothing stays allocated (no stale task or
     * session), and the next request of either kind recovers */
    fake.fail_next_session_create = 1;
    CHECK(clone(e, err) == 5);
    CHECK(strstr(err, "audiocpp_session_create failed") && strstr(err, "out of memory") && strstr(err, "std::bad_alloc"));
    CHECK(fake.sessions == 0 && fake.live_session_task[0] == 0);
    CHECK(clone(e, err) == 0);
    CHECK(fake.sessions == 1 && strcmp(fake.live_session_task, "clon") == 0);
    fake.fail_next_session_create = 1;
    CHECK(preset(e, err) == 5);
    CHECK(fake.sessions == 0);
    CHECK(preset(e, err) == 0);
    CHECK(fake.sessions == 1 && fake.peak_sessions == 1 && fake.requests == 0 && fake.results == 0);
    CHECK(fake.task_mismatches == 0);

    kt_stats stats;
    kt_engine_stats(e, &stats);
    CHECK(stats.sessions_created == (unsigned)fake.sessions_created && stats.failures == 5);

    kt_unload(e);
    CHECK(fake.sessions == 0 && fake.models == 0 && fake.registries == 0);

    /* a failing first session leaves the engine unloaded and frees everything */
    fake.fail_next_session_create = 1;
    e = NULL;
    CHECK(kt_load("/fake.gguf", 4, &e, describe, sizeof describe, err, sizeof err) == 5 && !e);
    CHECK(fake.sessions == 0 && fake.models == 0 && fake.registries == 0);

    if (failures == 0) printf("RESULT: bridge lifecycle test passed\n");
    return failures ? 1 : 0;
}
