/**
 * @file debug_ble.cpp
 * @brief Implémentation du debug via BLE
 */

#include "debug_ble.h"
#include <stdarg.h>

DebugBle debugBle;

void DebugBle::begin(BLECharacteristic* characteristic) {
    _char = characteristic;
    _head = 0;
    _tail = 0;
}

uint16_t DebugBle::_available() {
    if (_head >= _tail) {
        return _head - _tail;
    }
    return DEBUG_BLE_BUFFER_SIZE - _tail + _head;
}

void DebugBle::log(const char* msg) {
    if (msg == nullptr) return;

    // Écrire dans le ring buffer (écrase les anciens messages si plein)
    while (*msg) {
        _buffer[_head] = *msg++;
        _head = (_head + 1) % DEBUG_BLE_BUFFER_SIZE;
        // Si on rattrape le tail, avancer le tail (perte des vieux messages)
        if (_head == _tail) {
            _tail = (_tail + 1) % DEBUG_BLE_BUFFER_SIZE;
        }
    }
}

void DebugBle::logf(const char* fmt, ...) {
    char tmp[200];
    va_list args;
    va_start(args, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, args);
    va_end(args);
    log(tmp);
}

void DebugBle::flush() {
    if (_char == nullptr) return;
    if (_head == _tail) return;  // Rien à envoyer
    if (!_char->notifyEnabled()) return;  // Personne n'écoute

    // Envoyer par chunks (max MTU-3 bytes par notification)
    uint16_t chunkSize = _char->getMaxLen();
    if (chunkSize == 0) chunkSize = 20;

    uint8_t chunk[244];
    uint16_t sent = 0;

    while (_tail != _head && sent < 2) {  // Max 2 notifications par flush (non-bloquant)
        uint16_t len = 0;

        // Copier depuis le ring buffer dans le chunk
        while (_tail != _head && len < chunkSize) {
            chunk[len++] = (uint8_t)_buffer[_tail];
            _tail = (_tail + 1) % DEBUG_BLE_BUFFER_SIZE;
        }

        if (len > 0) {
            if (!_char->notify(chunk, len)) {
                // Queue BLE pleine, on réessaiera au prochain flush
                // Reculer le tail (on n'a pas réussi à envoyer)
                // Simplification: on perd ces bytes plutôt que de compliquer le rollback
                break;
            }
            sent++;
        }
    }
}
