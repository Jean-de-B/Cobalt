#pragma once
#include <Arduino.h>

class BLECharacteristic;  // forward declaration — full def in debug_ble.cpp

#define DEBUG_BLE_BUFFER_SIZE   1024   // ring buffer capacity (bytes)
#define DEBUG_BLE_CHUNK_SIZE    244    // BLE_MTU_SIZE(247) - 3

class DebugBle {
public:
    void begin(BLECharacteristic* characteristic);
    void log(const char* msg);
    void logf(const char* fmt, ...) __attribute__((format(printf, 2, 3)));
    // Call from loop() to drain the ring buffer via BLE notify
    void flush();

private:
    BLECharacteristic* _char = nullptr;
    char _buffer[DEBUG_BLE_BUFFER_SIZE];
    volatile uint16_t _head = 0;
    volatile uint16_t _tail = 0;
};

extern DebugBle debugBle;
