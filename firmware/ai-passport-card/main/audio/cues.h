// main/audio/cues.h — short audio cues (16 kHz 16-bit mono PCM embedded from
// assets/cues/*.pcm). A worker task owns the codec: wake -> set_format -> volume ->
// write in ~960-byte chunks -> bsp_audio_sleep() after 2 s without a cue.
// cues_play() only enqueues, so it is safe from the app task.
#pragma once

#include <stdbool.h>

#include "esp_err.h"

typedef enum {
    CUE_CELEBRATE = 0,   // ~1.0 s: two rising glints + soft major-chord tail
    CUE_TICK,            // 0.12 s chirp
    CUE_CONNECT,         // 0.3 s two-note rise
    CUE_COUNT,
} cue_id_t;

esp_err_t cues_start(void);              // call after bsp_audio_init(); no-op if audio failed
bool cues_play(cue_id_t id);             // non-blocking
bool cues_id_from_name(const char *name, cue_id_t *out);   // "celebrate"|"tick"|"connect"
