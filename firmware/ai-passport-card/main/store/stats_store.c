// main/store/stats_store.c — see stats_store.h.
#include "store/stats_store.h"

#include <string.h>

#include "esp_log.h"
#include "link/proto.h"
#include "nvs.h"

static const char *TAG = "store";
static nvs_handle_t s_nvs;
static bool s_ready;

esp_err_t stats_store_init(void)
{
    if (s_ready) return ESP_OK;
    esp_err_t e = nvs_open("card", NVS_READWRITE, &s_nvs);
    if (e != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open(card): %s", esp_err_to_name(e));
        return e;
    }
    s_ready = true;
    return ESP_OK;
}

static int32_t get_i32(const char *key, int32_t def)
{
    int32_t v = def;
    if (s_ready && nvs_get_i32(s_nvs, key, &v) != ESP_OK) v = def;
    return v;
}

void stats_store_load(card_stats_t *stats, char *theme, size_t theme_cap, uint32_t *boot)
{
    stats->followers = get_i32("followers", CARD_SEED_FOLLOWERS);
    stats->likes = get_i32("likes", CARD_SEED_LIKES);
    stats->notes = get_i32("notes", CARD_SEED_NOTES);
    stats->delta = get_i32("delta", 0);
    int64_t ts = 0;
    if (!s_ready || nvs_get_i64(s_nvs, "ts", &ts) != ESP_OK) ts = 0;
    stats->ts = ts;

    char t[CARD_THEME_ID_MAX] = "base";
    size_t n = sizeof(t);
    if (!s_ready || nvs_get_str(s_nvs, "theme", t, &n) != ESP_OK) strcpy(t, "base");
    strncpy(theme, proto_theme_normalize(t), theme_cap - 1);
    theme[theme_cap - 1] = '\0';

    uint32_t b = 0;
    if (s_ready) {
        if (nvs_get_u32(s_nvs, "boot", &b) != ESP_OK) b = 0;
        b++;
        if (nvs_set_u32(s_nvs, "boot", b) == ESP_OK) nvs_commit(s_nvs);
    }
    *boot = b;
    ESP_LOGI(TAG, "loaded followers=%ld ts=%lld theme=%s boot=%lu", (long)stats->followers,
             (long long)stats->ts, theme, (unsigned long)b);
}

esp_err_t stats_store_save_stats(const card_stats_t *s)
{
    if (!s_ready) return ESP_ERR_INVALID_STATE;
    esp_err_t e = nvs_set_i32(s_nvs, "followers", s->followers);
    if (e == ESP_OK) e = nvs_set_i32(s_nvs, "likes", s->likes);
    if (e == ESP_OK) e = nvs_set_i32(s_nvs, "notes", s->notes);
    if (e == ESP_OK) e = nvs_set_i32(s_nvs, "delta", s->delta);
    if (e == ESP_OK) e = nvs_set_i64(s_nvs, "ts", s->ts);
    if (e == ESP_OK) e = nvs_commit(s_nvs);
    if (e != ESP_OK) ESP_LOGE(TAG, "save stats: %s", esp_err_to_name(e));
    return e;
}

esp_err_t stats_store_save_theme(const char *theme)
{
    if (!s_ready) return ESP_ERR_INVALID_STATE;
    esp_err_t e = nvs_set_str(s_nvs, "theme", proto_theme_normalize(theme));
    if (e == ESP_OK) e = nvs_commit(s_nvs);
    if (e != ESP_OK) ESP_LOGE(TAG, "save theme: %s", esp_err_to_name(e));
    return e;
}
