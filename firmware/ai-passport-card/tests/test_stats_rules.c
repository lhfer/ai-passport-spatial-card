// Host test: stats dedup by ts and follower-count formatting.
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "store/stats_rules.h"

int main(void)
{
    card_stats_t stored = { 4313, 44000, 128, 0, 1758150000LL };
    card_stats_t newer = { 4318, 44012, 128, 5, 1758153600LL };
    card_stats_t same = { 9999, 1, 1, 1, 1758150000LL };
    card_stats_t older = { 1, 1, 1, 1, 1758100000LL };
    assert(stats_rules_accept(&stored, &newer));
    assert(!stats_rules_accept(&stored, &same));     // ts <= stored: ignored (still acked ok)
    assert(!stats_rules_accept(&stored, &older));
    assert(stats_rules_accept(NULL, &newer));
    assert(!stats_rules_accept(&stored, NULL));
    card_stats_t empty = { 0 };
    assert(stats_rules_accept(&empty, &older));       // seed (ts 0) accepts anything with ts > 0
    card_stats_t ts0 = { 5, 5, 5, 0, 0 };
    assert(!stats_rules_accept(&empty, &ts0));        // ts 0 never replaces ts 0

    char buf[16];
    assert(stats_format_followers(buf, sizeof(buf), 4313) == 4 && strcmp(buf, "4313") == 0);
    assert(stats_format_followers(buf, sizeof(buf), 0) == 1 && strcmp(buf, "0") == 0);
    assert(stats_format_followers(buf, sizeof(buf), -7) == 1 && strcmp(buf, "0") == 0);
    assert(stats_format_followers(buf, sizeof(buf), 9999) == 4 && strcmp(buf, "9999") == 0);
    stats_format_followers(buf, sizeof(buf), 10000);
    assert(strcmp(buf, "1\xE4\xB8\x87") == 0);                 // 1万
    stats_format_followers(buf, sizeof(buf), 12345);
    assert(strcmp(buf, "1.2\xE4\xB8\x87") == 0);               // 1.2万 (truncated, not 1.3)
    stats_format_followers(buf, sizeof(buf), 19999);
    assert(strcmp(buf, "1.9\xE4\xB8\x87") == 0);
    stats_format_followers(buf, sizeof(buf), 100000);
    assert(strcmp(buf, "10\xE4\xB8\x87") == 0);
    stats_format_followers(buf, sizeof(buf), 1234567);
    assert(strcmp(buf, "123.4\xE4\xB8\x87") == 0);
    char tiny[3];
    assert(stats_format_followers(tiny, sizeof(tiny), 4313) == 2 && strcmp(tiny, "43") == 0);
    puts("stats_rules tests: PASS");
    return 0;
}
