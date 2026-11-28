#include "CAudioBridge.h"
#include "audiocpp.h"
#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#define AUDIO_FUNCTIONS(X) \
    X(last_error) X(registry_create) X(registry_free) X(model_load) X(model_free) \
    X(options_create) X(options_set) X(options_free) X(session_create) X(session_free) \
    X(session_run) X(request_create) X(request_free) X(request_set_text) X(request_set_option) \
    X(result_free) X(result_audio) X(result_artifact_count) X(result_artifact)

struct yu_engine {
    void *library;
    audiocpp_registry *registry;
    audiocpp_model *model;
    audiocpp_session *session;
    audiocpp_status (*session_run_pcm)(audiocpp_session *, const audiocpp_request *, yu_pcm_callback,
                                       void *, audiocpp_result **);
    audiocpp_status (*session_run_observed)(audiocpp_session *, const audiocpp_request *, yu_pcm_callback,
                                            yu_progress_callback, void *, audiocpp_result **);
#define DECLARE(name) __typeof__(&audiocpp_##name) name;
    AUDIO_FUNCTIONS(DECLARE)
#undef DECLARE
};

struct yu_result {
    yu_engine *engine;
    audiocpp_result *raw;
    const float *samples;
    size_t frames;
    int rate;
    int channels;
    const void *tokens;
    size_t token_bytes;
    const void *score;
    size_t score_bytes;
};

static _Thread_local char error[768];

const char *yu_error(void) { return error; }

static void fail(const char *operation, const char *detail) {
    snprintf(error, sizeof(error), "%s: %s", operation, detail ? detail : "no details");
}

void yu_close(yu_engine *engine) {
    if (!engine) return;
    if (engine->session) engine->session_free(engine->session);
    if (engine->model) engine->model_free(engine->model);
    if (engine->registry) engine->registry_free(engine->registry);
    if (engine->library) dlclose(engine->library);
    free(engine);
}

static int supports_compact_attention_cache(const yu_engine *engine) {
    __typeof__(&audiocpp_model_option_count) count = dlsym(engine->library, "audiocpp_model_option_count");
    __typeof__(&audiocpp_model_option) option = dlsym(engine->library, "audiocpp_model_option");
    if (!count || !option) return 0;
    const size_t session_options = count(engine->model, AUDIOCPP_OPTION_SCOPE_SESSION);
    for (size_t i = 0; i < session_options; ++i) {
        const char *name = NULL;
        if (option(engine->model, AUDIOCPP_OPTION_SCOPE_SESSION, i, &name,
                   NULL, NULL, NULL, NULL, NULL, NULL) == AUDIOCPP_OK && name &&
            strcmp(name, "yue2.compact_kv") == 0) return 1;
    }
    return 0;
}

yu_engine *yu_open(const char *library, const char *weights, const char *spec, int preview) {
    return yu_open_configured(library, weights, spec, preview, 0);
}

yu_engine *yu_open_configured(const char *library, const char *weights, const char *spec,
                              int preview, int compact_attention_cache) {
    return yu_open_with_models(library, weights, spec, preview, compact_attention_cache,
                               "yue2-3b-q4_0.gguf", "yue2-vae-f16.gguf");
}

yu_engine *yu_open_with_models(const char *library, const char *weights, const char *spec,
                               int preview, int compact_attention_cache, const char *model, const char *vae) {
    yu_engine *engine = calloc(1, sizeof(*engine));
    if (!engine) {
        fail("allocate YuE2 engine", NULL);
        return NULL;
    }
    // Metal can retain process-wide state. Keep the code mapped when releasing a model.
    engine->library = dlopen(library, RTLD_LOCAL | RTLD_NOW | RTLD_NODELETE);
    if (!engine->library) {
        fail("load audio.cpp Metal library", dlerror());
        goto failed;
    }
#define LOAD(name) \
    engine->name = (__typeof__(engine->name))dlsym(engine->library, "audiocpp_" #name); \
    if (!engine->name) { fail("load audiocpp_" #name, dlerror()); goto failed; }
    AUDIO_FUNCTIONS(LOAD)
#undef LOAD
    engine->session_run_pcm = (__typeof__(engine->session_run_pcm))dlsym(engine->library, "audiocpp_yue2_session_run_pcm");
    engine->session_run_observed = (__typeof__(engine->session_run_observed))dlsym(engine->library, "audiocpp_yue2_session_run_observed");

    audiocpp_model_config model_config = {.family_hint = "yue2", .model_spec_override = spec};
    audiocpp_backend_config backend = {.backend = "metal", .device = 0, .threads = 8};
    if (engine->registry_create(NULL, &engine->registry) != AUDIOCPP_OK ||
        engine->model_load(engine->registry, weights, &model_config, NULL, &engine->model) != AUDIOCPP_OK) {
        fail("load YuE2 weights", engine->last_error());
        goto failed;
    }
    audiocpp_options *options = engine->options_create();
    if (!options) {
        fail("allocate session options", engine->last_error());
        goto failed;
    }
    const char *session_options[][2] = {
        {"yue2.model_gguf", model}, {"yue2.vae_gguf", vae},
#if TARGET_OS_IOS
        // Keep the waveform graph within the mobile Metal allocation budget.
        {"yue2.vae_tile_frames", "256"},
#endif
    };
    audiocpp_status status = AUDIOCPP_OK;
    for (size_t i = 0; i < sizeof(session_options) / sizeof(session_options[0]); ++i) {
        status = engine->options_set(options, session_options[i][0], session_options[i][1]);
        if (status != AUDIOCPP_OK) break;
    }
    if (status == AUDIOCPP_OK && compact_attention_cache && !preview && supports_compact_attention_cache(engine)) {
        status = engine->options_set(options, "yue2.compact_kv", "true");
    }
    if (status == AUDIOCPP_OK && preview) {
        char window[16], overlap[16];
        snprintf(window, sizeof(window), "%d", YU_PREVIEW_WINDOW_FRAMES);
        snprintf(overlap, sizeof(overlap), "%d", YU_PREVIEW_OVERLAP_FRAMES);
        const char *preview_options[][2] = {
            {"yue2.mem_saver", "false"}, {"yue2.packed_projections", "true"},
            {"yue2.nar_prefix_cache", "true"},
            {"yue2.nar_window_frames", window}, {"yue2.nar_overlap_frames", overlap},
        };
        for (size_t i = 0; i < sizeof(preview_options) / sizeof(preview_options[0]); ++i) {
            status = engine->options_set(options, preview_options[i][0], preview_options[i][1]);
            if (status != AUDIOCPP_OK) break;
        }
    }
    if (status == AUDIOCPP_OK) {
        status = engine->session_create(engine->model, "gen", "offline", &backend, options, &engine->session);
    }
    if (status != AUDIOCPP_OK) fail("create Metal session", engine->last_error());
    engine->options_free(options);
    if (status == AUDIOCPP_OK) return engine;

failed:
    yu_close(engine);
    return NULL;
}

void yu_result_close(yu_result *result) {
    if (!result) return;
    if (result->raw) result->engine->result_free(result->raw);
    free(result);
}

yu_result *yu_render(yu_engine *engine, const char *lyrics, const char *style,
                     uint64_t seed, int frames, int steps, int minimum_frames, const char *prefix) {
    return yu_render_observed(engine, lyrics, style, seed, frames, steps, minimum_frames, prefix, "1.01", 0, NULL, NULL, NULL, NULL);
}

int yu_supports_pcm(const yu_engine *engine) { return engine->session_run_pcm != NULL || engine->session_run_observed != NULL; }
int yu_supports_progress(const yu_engine *engine) { return engine->session_run_observed != NULL; }

yu_result *yu_render_observed(yu_engine *engine, const char *lyrics, const char *style,
                              uint64_t seed, int frames, int steps, int minimum_frames,
                              const char *prefix, const char *guidance_scale, int plan_score, const char *score,
                              yu_pcm_callback pcm, yu_progress_callback progress,
                              void *context) {
    if (pcm && !yu_supports_pcm(engine)) {
        fail("stream YuE2 waveform", "this audio.cpp library does not expose PCM tiles");
        return NULL;
    }
    audiocpp_request *request = engine->request_create();
    yu_result *result = calloc(1, sizeof(*result));
    if (!request || !result) {
        fail("allocate generation request", NULL);
        if (request) engine->request_free(request);
        free(result);
        return NULL;
    }
    result->engine = engine;

    char frames_text[16], steps_text[16], minimum_text[16], seed_text[32];
    snprintf(frames_text, sizeof(frames_text), "%d", frames);
    snprintf(steps_text, sizeof(steps_text), "%d", steps);
    snprintf(minimum_text, sizeof(minimum_text), "%d", minimum_frames);
    snprintf(seed_text, sizeof(seed_text), "%" PRIu64, seed);
    const char *options[][2] = {
        {"style", style}, {"seed", seed_text}, {"cot", score ? "melody" : (plan_score ? "full" : "off")},
        {"abc", score}, {"guidance_scale", guidance_scale},
        {"num_inference_steps", steps_text}, {"semantic_min_tokens", minimum_frames > 0 ? minimum_text : NULL},
        {"semantic_max_tokens", frames_text}, {"export_semantic", "true"}, {"semantic_prefix", prefix},
    };
    if (engine->request_set_text(request, lyrics, NULL) != AUDIOCPP_OK) goto failed;
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); ++i) {
        if (options[i][1] && engine->request_set_option(request, options[i][0], options[i][1]) != AUDIOCPP_OK)
            goto failed;
    }
    audiocpp_status status;
    if ((pcm || progress) && engine->session_run_observed) {
        status = engine->session_run_observed(engine->session, request, pcm, progress, context, &result->raw);
    } else if (pcm) {
        status = engine->session_run_pcm(engine->session, request, pcm, context, &result->raw);
    } else {
        status = engine->session_run(engine->session, request, &result->raw);
    }
    if (status != AUDIOCPP_OK ||
        engine->result_audio(result->raw, &result->samples, &result->frames, &result->rate,
                             &result->channels) != AUDIOCPP_OK)
        goto failed;

    for (size_t i = 0; i < engine->result_artifact_count(result->raw); ++i) {
        const char *id = NULL;
        const void *payload = NULL;
        size_t size = 0;
        if (engine->result_artifact(result->raw, i, NULL, &id, &payload, &size) != AUDIOCPP_OK)
            goto failed;
        if (id && strcmp(id, "semantic") == 0) {
            result->tokens = payload;
            result->token_bytes = size;
        } else if (id && strcmp(id, "score") == 0 && payload && size > 0) {
            result->score = payload;
            result->score_bytes = size;
        }
        if (result->tokens && result->score) break;
    }
    if (plan_score && !score && !result->score) {
        fail("plan YuE2 song", "the model returned an empty score");
        engine->request_free(request);
        yu_result_close(result);
        return NULL;
    }
    engine->request_free(request);
    return result;

failed:
    fail("render YuE2 audio", engine->last_error());
    engine->request_free(request);
    yu_result_close(result);
    return NULL;
}

const float *yu_samples(const yu_result *result) { return result->samples; }
size_t yu_frames(const yu_result *result) { return result->frames; }
int yu_channels(const yu_result *result) { return result->channels; }
int yu_sample_rate(const yu_result *result) { return result->rate; }
const uint8_t *yu_score(const yu_result *result, size_t *size) {
    *size = result->score_bytes;
    return result->score;
}
const uint8_t *yu_tokens(const yu_result *result, size_t *size) {
    *size = result->token_bytes;
    return result->tokens;
}
