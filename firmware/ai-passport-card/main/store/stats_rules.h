// main/store/stats_rules.h — pure rules for the stats object: dedup by ts and the
// follower-count text shown in the dynamic strip. Host-tested.
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "card_types.h"

// True when incoming must replace stored: strictly newer ts (protocol: ts <= stored
// is ignored but still acknowledged ok).
bool stats_rules_accept(const card_stats_t *stored, const card_stats_t *incoming);

// Follower count for the digits-only font ("0-9 . + - k 万 ▲ ▼"):
//   < 10000  -> "4313"
//   >= 10000 -> "1.2万" (one decimal, truncated) or "12万" when the decimal is 0
// Negative counts render as "0". Returns the length written (buf is NUL-terminated).
int stats_format_followers(char *buf, size_t cap, int32_t followers);
