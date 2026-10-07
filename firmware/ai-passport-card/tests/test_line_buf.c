// Host test: '\n' line reassembly shared by both transports.
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "link/line_buf.h"

static char s_lines[8][PROTO_LINE_MAX + 1];
static int s_count;

static void on_line(const char *line, size_t len, void *ctx)
{
    (void)ctx;
    assert(len == strlen(line));
    if (s_count < 8) strcpy(s_lines[s_count], line);
    s_count++;
}

static void push(line_buf_t *b, const char *s)
{
    line_buf_push(b, (const uint8_t *)s, strlen(s), on_line, NULL);
}

int main(void)
{
    line_buf_t b;
    line_buf_init(&b);

    // fragments, CRLF, and two lines in one chunk
    push(&b, "{\"t\":\"pi");
    assert(s_count == 0);
    push(&b, "ng\"}\r\n{\"t\":\"hello\"}\n");
    assert(s_count == 2);
    assert(strcmp(s_lines[0], "{\"t\":\"ping\"}") == 0);
    assert(strcmp(s_lines[1], "{\"t\":\"hello\"}") == 0);

    // non-JSON noise and blank lines are dropped; leading blanks tolerated
    push(&b, "I (123) boot: hello\n\n  {\"t\":\"x\"}\n");
    assert(s_count == 3 && strcmp(s_lines[2], "{\"t\":\"x\"}") == 0);

    // an over-long line is discarded up to its newline, the next line survives
    char big[PROTO_LINE_MAX + 40];
    memset(big, 'a', sizeof(big));
    big[0] = '{';
    big[sizeof(big) - 2] = '\n';
    big[sizeof(big) - 1] = '\0';
    push(&b, big);
    assert(s_count == 3);
    push(&b, "{\"t\":\"after\"}\n");
    assert(s_count == 4 && strcmp(s_lines[3], "{\"t\":\"after\"}") == 0);

    // exactly PROTO_LINE_MAX bytes is accepted
    char max[PROTO_LINE_MAX + 2];
    memset(max, 'b', PROTO_LINE_MAX);
    max[0] = '{';
    max[PROTO_LINE_MAX] = '\n';
    max[PROTO_LINE_MAX + 1] = '\0';
    push(&b, max);
    assert(s_count == 5 && strlen(s_lines[4]) == PROTO_LINE_MAX);

    // init clears a partial line
    push(&b, "{\"partial");
    line_buf_init(&b);
    push(&b, "{\"t\":\"n\"}\n");
    assert(s_count == 6 && strcmp(s_lines[5], "{\"t\":\"n\"}") == 0);

    puts("line_buf tests: PASS");
    return 0;
}
