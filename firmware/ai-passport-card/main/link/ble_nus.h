// main/link/ble_nus.h — NimBLE peripheral exposing the Nordic UART Service to the
// Vision Pro. Just-Works, no bonding, no MITM, no encrypted characteristics, so
// CoreBluetooth connects silently. Name "SpatialCard-XXXX" (last two BT MAC bytes),
// 128-bit service UUID in the advertisement, name in the scan response.
// RX (write) bytes are reassembled to '\n' lines and posted to the app queue;
// TX lines are fragmented at ATT MTU-3. Advertising restarts on disconnect.
// Compiled to no-op stubs when CONFIG_CARD_ENABLE_BLE is off (browser simulator).
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"

esp_err_t ble_nus_start(void);
bool ble_nus_is_connected(void);
bool ble_nus_is_subscribed(void);            // central enabled TX notifications
bool ble_nus_send_line(const char *json, size_t len);   // appends '\n'; false if not subscribed
void ble_nus_readvertise(void);              // restart advertising when no central is connected
void ble_nus_stop(void);                     // before deep sleep
const char *ble_nus_device_name(void);
