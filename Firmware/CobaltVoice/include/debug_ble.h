/**
 * @file debug_ble.h
 * @brief Debug logs via BLE — buffer circulaire + flush vers caractéristique BLE
 *
 * Remplace le Serial debug. Les messages sont accumulés dans un ring buffer
 * et envoyés au téléphone via BLE notify quand connecté.
 * Quand pas connecté, les messages sont silencieusement perdus (overflow).
 */

#ifndef DEBUG_BLE_H
#define DEBUG_BLE_H

#include <Arduino.h>
#include <bluefruit.h>

// Taille du ring buffer debug (1KB)
#define DEBUG_BLE_BUFFER_SIZE  1024

class DebugBle {
public:
    void begin(BLECharacteristic* characteristic);

    /**
     * @brief Écrit un message dans le buffer debug
     * Thread-safe (appelable depuis ISR ou loop)
     */
    void log(const char* msg);

    /**
     * @brief Printf dans le buffer debug
     */
    void logf(const char* fmt, ...) __attribute__((format(printf, 2, 3)));

    /**
     * @brief Envoie les messages en attente via BLE notify
     * Non-bloquant. Appelé depuis loop().
     */
    void flush();

private:
    BLECharacteristic* _char = nullptr;
    char _buffer[DEBUG_BLE_BUFFER_SIZE];
    volatile uint16_t _head = 0;  // Position d'écriture
    volatile uint16_t _tail = 0;  // Position de lecture
    uint16_t _available();
};

extern DebugBle debugBle;

#endif // DEBUG_BLE_H
