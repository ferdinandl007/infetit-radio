#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct yu_engine yu_engine;
typedef struct yu_result yu_result;

enum { YU_PREVIEW_WINDOW_FRAMES = 100, YU_PREVIEW_OVERLAP_FRAMES = 16 };

yu_engine *yu_open(const char *library, const char *weights, const char *spec, int preview);
yu_engine *yu_open_configured(const char *library, const char *weights, const char *spec,
                              int preview, int compact_attention_cache);
yu_engine *yu_open_with_models(const char *library, const char *weights, const char *spec,
                               int preview, int compact_attention_cache, const char *model, const char *vae);
void yu_close(yu_engine *engine);
const char *yu_error(void);

yu_result *yu_render(yu_engine *engine, const char *lyrics, const char *style,
                     uint64_t seed, int frames, int steps, int minimum_frames, const char *prefix);
typedef int (*yu_pcm_callback)(void *context, const float *samples, size_t frames,
                               int sample_rate, int channels, size_t offset, size_t total);
enum { YU_PROGRESS_SYNTHESIS = 0, YU_PROGRESS_WAVEFORM = 1 };
typedef int (*yu_progress_callback)(void *context, int stage, int completed, int total);
int yu_supports_pcm(const yu_engine *engine);
int yu_supports_progress(const yu_engine *engine);
yu_result *yu_render_observed(yu_engine *engine, const char *lyrics, const char *style,
                              uint64_t seed, int frames, int steps, int minimum_frames,
                              const char *prefix, const char *guidance_scale, int plan_score, const char *score,
                              yu_pcm_callback pcm, yu_progress_callback progress,
                              void *context);
const float *yu_samples(const yu_result *result);
size_t yu_frames(const yu_result *result);
int yu_channels(const yu_result *result);
int yu_sample_rate(const yu_result *result);
const uint8_t *yu_tokens(const yu_result *result, size_t *size);
const uint8_t *yu_score(const yu_result *result, size_t *size);
void yu_result_close(yu_result *result);
