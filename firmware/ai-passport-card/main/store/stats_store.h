// main/store/stats_store.h — NVS persistence, namespace "card":
//   followers/likes/notes/delta (i32), ts (i64), theme (str), boot (u32 counter).
// Loaded once at boot; stats are saved when a newer ts is accepted, the theme when
// it changes. All calls run on the app task (NVS writes block for a few ms).
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "card_types.h"
#include "esp_err.h"

esp_err_t stats_store_init(void);   // nvs_flash_init handled by main; this opens the namespace
// Fills defaults (card.json seed, theme "base") when nothing is stored; bumps and
// persists the boot counter.
void stats_store_load(card_stats_t *stats, char *theme, size_t theme_cap, uint32_t *boot);
esp_err_t stats_store_save_stats(const card_stats_t *stats);
esp_err_t stats_store_save_theme(const char *theme);
