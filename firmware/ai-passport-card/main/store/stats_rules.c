// main/store/stats_rules.c — see stats_rules.h.
#include "store/stats_rules.h"

#include <stdio.h>

bool stats_rules_accept(const card_stats_t *stored, const card_stats_t *incoming)
{
    if (!incoming) return false;
    if (!stored) return true;
    return incoming->ts > stored->ts;
}

int stats_format_followers(char *buf, size_t cap, int32_t followers)
{
    if (cap == 0) return 0;
    if (followers < 0) followers = 0;
    int n;
    if (followers < 10000) {
        n = snprintf(buf, cap, "%ld", (long)followers);
    } else {
        long whole = followers / 10000;
        long tenth = (followers % 10000) / 1000;   // truncate, never overstate
        if (tenth == 0) n = snprintf(buf, cap, "%ld\xE4\xB8\x87", whole);          // "12万"
        else            n = snprintf(buf, cap, "%ld.%ld\xE4\xB8\x87", whole, tenth); // "1.2万"
    }
    if (n < 0) { buf[0] = '\0'; return 0; }
    if ((size_t)n >= cap) n = (int)cap - 1;
    return n;
}
