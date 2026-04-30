#include "debug_ble.h"
#include <bluefruit.h>
#include <stdarg.h>

DebugBle debugBle;

void DebugBle::begin(BLECharacteristic* characteristic) {
    _char = characteristic;
    _head = 0;
    _tail = 0;
}

void DebugBle::log(const char* msg) {
    if (!msg) return;
    while (*msg) {
        uint16_t next = (_head + 1) % DEBUG_BLE_BUFFER_SIZE;
        if (next == _tail) {
            // Buffer full: overwrite oldest data so recent messages are preserved
            _tail = (_tail + 1) % DEBUG_BLE_BUFFER_SIZE;
        }
        _buffer[_head] = *msg++;
        _head = next;
    }
}

void DebugBle::logf(const char* fmt, ...) {
    char tmp[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, args);
    va_end(args);
    log(tmp);
}

void DebugBle::flush() {
    if (!_char || _head == _tail) return;
    if (!_char->notifyEnabled()) return;

    uint8_t buf[DEBUG_BLE_CHUNK_SIZE];
    uint16_t len = 0;

    while (_tail != _head && len < DEBUG_BLE_CHUNK_SIZE) {
        buf[len++] = (uint8_t)_buffer[_tail];
        _tail = (_tail + 1) % DEBUG_BLE_BUFFER_SIZE;
    }

    if (len > 0) {
        _char->notify(buf, len);
    }
}
