// main/link/line_buf.c — see line_buf.h.
#include "link/line_buf.h"

#include <string.h>

void line_buf_init(line_buf_t *b)
{
    b->len = 0;
    b->discarding = false;
    b->data[0] = '\0';
}

static void deliver(line_buf_t *b, line_buf_cb_t cb, void *ctx)
{
    size_t start = 0;
    while (start < b->len && (b->data[start] == ' ' || b->data[start] == '\t')) start++;
    if (start < b->len && b->data[start] == '{' && cb) {
        b->data[b->len] = '\0';
        cb(b->data + start, b->len - start, ctx);
    }
    b->len = 0;
}

void line_buf_push(line_buf_t *b, const uint8_t *bytes, size_t n, line_buf_cb_t cb, void *ctx)
{
    for (size_t i = 0; i < n; i++) {
        char c = (char)bytes[i];
        if (c == '\n') {
            if (b->discarding) {
                b->discarding = false;
                b->len = 0;
            } else {
                deliver(b, cb, ctx);
            }
            continue;
        }
        if (b->discarding || c == '\r') continue;
        if (b->len >= PROTO_LINE_MAX) {
            b->discarding = true;   // over-long line: drop it entirely
            b->len = 0;
            continue;
        }
        b->data[b->len++] = c;
    }
}
