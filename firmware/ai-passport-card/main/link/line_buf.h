// main/link/line_buf.h — '\n'-delimited line reassembly shared by the serial and
// BLE receivers. Pure (no ESP-IDF), host-tested.
//
// Rules: '\r' is ignored; lines not starting with '{' (after leading blanks) are
// dropped (plain-text noise); a line longer than PROTO_LINE_MAX is discarded up to
// the next '\n'. Complete lines are delivered NUL-terminated without the '\n'.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "link/proto.h"

typedef struct {
    char data[PROTO_LINE_MAX + 1];
    size_t len;
    bool discarding;
} line_buf_t;

typedef void (*line_buf_cb_t)(const char *line, size_t len, void *ctx);

void line_buf_init(line_buf_t *b);
void line_buf_push(line_buf_t *b, const uint8_t *bytes, size_t n, line_buf_cb_t cb, void *ctx);
