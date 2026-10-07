// main/audio/cues.c — see cues.h.
#include "audio/cues.h"

#include <string.h>

#include "bsp_audio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "sdkconfig.h"

static const char *TAG = "cues";

#define CUE_RATE_HZ      16000
#define CUE_CHUNK_BYTES  960          // 30 ms at 16 kHz mono 16-bit
#define CUE_IDLE_MS      2000         // codec sleeps after this much silence

extern const uint8_t _binary_celebrate_pcm_start[] asm("_binary_celebrate_pcm_start");
extern const uint8_t _binary_celebrate_pcm_end[]   asm("_binary_celebrate_pcm_end");
extern const uint8_t _binary_tick_pcm_start[]      asm("_binary_tick_pcm_start");
extern const uint8_t _binary_tick_pcm_end[]        asm("_binary_tick_pcm_end");
extern const uint8_t _binary_connect_pcm_start[]   asm("_binary_connect_pcm_start");
extern const uint8_t _binary_connect_pcm_end[]     asm("_binary_connect_pcm_end");

typedef struct { const char *name; const uint8_t *start; const uint8_t *end; } cue_desc_t;
static const cue_desc_t CUES[CUE_COUNT] = {
    [CUE_CELEBRATE] = { "celebrate", _binary_celebrate_pcm_start, _binary_celebrate_pcm_end },
    [CUE_TICK]      = { "tick",      _binary_tick_pcm_start,      _binary_tick_pcm_end },
    [CUE_CONNECT]   = { "connect",   _binary_connect_pcm_start,   _binary_connect_pcm_end },
};

static QueueHandle_t s_queue;
static bool s_awake;

bool cues_id_from_name(const char *name, cue_id_t *out)
{
    if (!name || !out) return false;
    for (int i = 0; i < CUE_COUNT; i++) {
        if (strcmp(name, CUES[i].name) == 0) { *out = (cue_id_t)i; return true; }
    }
    return false;
}

bool cues_play(cue_id_t id)
{
    if (!s_queue || id >= CUE_COUNT) return false;
    return xQueueSend(s_queue, &id, 0) == pdTRUE;
}

static void play(cue_id_t id)
{
    if (!s_awake) {
        if (bsp_audio_wake() != ESP_OK) { ESP_LOGE(TAG, "codec wake failed"); return; }
        s_awake = true;
    }
    if (bsp_audio_set_format(CUE_RATE_HZ, 16, 1) != ESP_OK) {
        ESP_LOGE(TAG, "set_format failed");
        return;
    }
    bsp_audio_set_volume(CONFIG_CARD_CUE_VOLUME);
    const uint8_t *p = CUES[id].start;
    const uint8_t *end = CUES[id].end;
    while (p < end) {
        size_t n = (size_t)(end - p) < CUE_CHUNK_BYTES ? (size_t)(end - p) : CUE_CHUNK_BYTES;
        if (bsp_audio_write(p, n) != ESP_OK) { ESP_LOGW(TAG, "write failed"); break; }
        p += n;
    }
}

static void cues_task(void *arg)
{
    (void)arg;
    // Boot: nothing is playing, so put the codec into its verified low-power state now.
    if (bsp_audio_sleep() != ESP_OK) ESP_LOGW(TAG, "initial codec sleep failed");
    s_awake = false;
    for (;;) {
        cue_id_t id;
        TickType_t wait = s_awake ? pdMS_TO_TICKS(CUE_IDLE_MS) : portMAX_DELAY;
        if (xQueueReceive(s_queue, &id, wait) == pdTRUE) {
            play(id);
        } else if (s_awake) {
            if (bsp_audio_sleep() != ESP_OK) ESP_LOGW(TAG, "codec sleep failed");
            s_awake = false;
        }
    }
}

esp_err_t cues_start(void)
{
    if (s_queue) return ESP_OK;
    s_queue = xQueueCreate(4, sizeof(cue_id_t));
    if (!s_queue) return ESP_ERR_NO_MEM;
    if (xTaskCreate(cues_task, "cues", 3072, NULL, 4, NULL) != pdPASS) {
        vQueueDelete(s_queue);
        s_queue = NULL;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "cues ready: celebrate=%u tick=%u connect=%u bytes",
             (unsigned)(CUES[0].end - CUES[0].start), (unsigned)(CUES[1].end - CUES[1].start),
             (unsigned)(CUES[2].end - CUES[2].start));
    return ESP_OK;
}
