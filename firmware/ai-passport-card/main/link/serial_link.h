// main/link/serial_link.h — USB Serial/JTAG line link to the Mac Hub.
// Reader task: '\n'-delimited JSON lines -> app event queue (non-JSON lines dropped).
// Writer: one line per call (<= PROTO_LINE_MAX + '\n'), serialized by a recursive
// mutex, bounded write timeouts so an absent host never blocks a caller.
// serial_link_start() also takes over the ESP_LOG vprintf for good and writes through
// the same mutex, so log lines and protocol lines can never interleave on the wire
// (before muteLogs the boot `hello` used to be cut in half by "Returned from app_main()").
// After the Hub's hello{muteLogs:true}, ESP_LOG output is wrapped into
// {"t":"log","lvl":..,"msg":..} lines (rate-limited to 20/s) so only JSON is on the port.
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"

esp_err_t serial_link_start(void);
bool serial_link_write_line(const char *json, size_t len);
void serial_link_set_json_logs(bool on);
bool serial_link_json_logs(void);
// USB host present (SOF seen on the USB Serial/JTAG peripheral): used as "USB present".
bool serial_link_usb_present(void);
