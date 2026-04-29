/**
 * @file config.h
 * @brief Configuration globale pour Cobalt Voice
 *
 * Enregistreur vocal minimaliste pour XIAO nRF52840 Sense
 */

#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// =============================================================================
// HARDWARE PINS (XIAO nRF52840 Sense)
// NOTE: Utilise les définitions existantes du variant.h Seeed quand possible
// =============================================================================

// Bouton Push-to-Talk
#define PIN_BUTTON          D1          // Bouton externe principal (PTT)
#define PIN_BUTTON_VOL_UP   D3          // Bouton Volume Up (anciennement D2)
#define PIN_BUTTON_VOL_DOWN D2          // Bouton Volume Down (anciennement D3)
#define BUTTON_ACTIVE_LOW   true        // true si le bouton tire vers GND

// LED RGB intégrée (active low sur XIAO)
// LED_RED, LED_GREEN, LED_BLUE sont déjà définis dans variant.h
#define PIN_LED_RED         LED_RED
#define PIN_LED_GREEN       LED_GREEN
#define PIN_LED_BLUE        LED_BLUE
#define LED_ACTIVE_LOW      true

// Batterie - défini dans variant.h:
// PIN_VBAT (32) = P0.31, entrée ADC pont diviseur
// VBAT_ENABLE (14) = P0.14, LOW pour activer le pont diviseur

// PDM Microphone - définis dans variant.h
// PIN_PDM_CLK et PIN_PDM_DATA existent déjà

// =============================================================================
// AUDIO CONFIGURATION
// =============================================================================

#define AUDIO_SAMPLE_RATE       16000   // 16 kHz
#define AUDIO_BITS_PER_SAMPLE   16      // 16-bit PCM
#define AUDIO_CHANNELS          1       // Mono

// Taille des buffers PDM (en samples)
// Double buffering pour éviter les pertes
#define PDM_BUFFER_SIZE         512     // 512 samples = 32ms @ 16kHz
#define PDM_BUFFER_COUNT        2       // Double buffer

// =============================================================================
// ADPCM COMPRESSION
// =============================================================================

// Ratio de compression: 16-bit -> 4-bit = 4:1
#define ADPCM_BITS_PER_SAMPLE   4
#define ADPCM_BLOCK_SIZE        256     // Samples par bloc ADPCM

// =============================================================================
// STORAGE CONFIGURATION
// =============================================================================

// Buffer ADPCM en RAM - maximisé pour enregistrements longs
// nRF52840: 256KB RAM - ~64KB SoftDevice - ~35-50KB (BLE/PDM/stack) = ~120KB dispo
// Débit ADPCM: 16kHz × 4 bits / 8 = 8000 bytes/sec → 120KB ≈ 15 secondes
#define AUDIO_BUFFER_SIZE       (120 * 1024)  // 120KB buffer audio (~15s @ 16kHz ADPCM)
#define MAX_RECORDING_SECONDS   15            // Cohérent avec 120KB / 8000 bytes/s

// =============================================================================
// BATTERY CONFIGURATION
// =============================================================================

// Tension batterie LiPo - XIAO nRF52840 Sense
// Pont diviseur : R1 = 1MΩ, R2 = 510kΩ → ratio = (R1+R2)/R2 = 1510/510 ≈ 2.96
#define VBAT_DIVIDER_RATIO      (1510.0f / 510.0f)  // ~2.961 (schéma Seeed)
#define VBAT_REFERENCE          3.0f    // Référence ADC AR_INTERNAL_3_0

// Seuils de tension (mapping linéaire)
#define VBAT_FULL               4.2f    // Batterie pleine = 100%
#define VBAT_EMPTY              3.5f    // Batterie vide = 0%
#define VBAT_LOW                3.6f    // Batterie faible (~15%)
#define VBAT_CRITICAL           3.5f    // Seuil critique - SHUTDOWN

// Intervalle de lecture batterie
#define BATTERY_CHECK_INTERVAL  30000   // 30 secondes

// =============================================================================
// FIRMWARE VERSION (pour OTA DFU)
// =============================================================================

#define FIRMWARE_VERSION_MAJOR  1
#define FIRMWARE_VERSION_MINOR  0
#define FIRMWARE_VERSION_PATCH  0
#define FIRMWARE_VERSION_STRING "1.0.0"

// =============================================================================
// BLE CONFIGURATION
// =============================================================================

// Le nom BLE est généré dynamiquement depuis l'adresse MAC hardware
// Format: "Cobalt XXXX" où XXXX = 4 derniers hex de FICR->DEVICEADDR
// Voir main.cpp setup() pour la génération
#define BLE_DEVICE_NAME_PREFIX  "Cobalt "
#define BLE_TX_POWER            8       // dBm (max nRF52840, portée maximale)

// MTU optimisé pour transfert rapide
#define BLE_MTU_SIZE            247     // Maximum MTU
#define BLE_DATA_LENGTH         251     // DLE extension

// UUIDs pour service audio custom
#define UUID_AUDIO_SERVICE      "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define UUID_AUDIO_TX           "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // Notify
#define UUID_AUDIO_RX           "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // Write

// Intervalles de connexion BLE (unités de 1.25ms)
// Mode rapide pour transfert audio
#define BLE_CONN_INTERVAL_MIN   16      // 20ms (16 * 1.25ms)
#define BLE_CONN_INTERVAL_MAX   80      // 100ms (80 * 1.25ms)

// Mode économique pour idle connecté (optim #5)
#define BLE_IDLE_CONN_INTERVAL_MIN  400   // 500ms (400 * 1.25ms)
#define BLE_IDLE_CONN_INTERVAL_MAX  800   // 1000ms (800 * 1.25ms)

// Mode rapide pour transfert — Samsung refuse les intervalles < 12 (15ms)
#define BLE_FAST_CONN_INTERVAL_MIN  24    // 30ms (24 * 1.25ms) - stable sur Samsung
#define BLE_FAST_CONN_INTERVAL_MAX  40    // 50ms (40 * 1.25ms)

// Supervision timeout & slave latency
#define BLE_SUPERVISION_TIMEOUT     1200  // 1200 * 10ms = 12s (marge pour slave_latency=4)
#define BLE_SLAVE_LATENCY           4     // Skip jusqu'à 4 events en mode idle (économie d'énergie)
#define BLE_CONN_SETUP_DELAY_MS     500   // Délai avant PHY/DLE après connexion

// =============================================================================
// ADVERTISING CONFIGURATION (mode agressif : wake → record → send → sleep)
// =============================================================================

// Phase unique: fast advertising court pendant l'enregistrement/transfert
#define ADV_FAST_INTERVAL_MIN   32      // 20ms (en unités de 0.625ms)
#define ADV_FAST_INTERVAL_MAX   48      // 30ms
#define ADV_FAST_TIMEOUT_S      15      // 15 secondes — assez pour que l'app se connecte

// Phase 2: slow advertising bref si le phone n'a pas accroché en fast
#define ADV_SLOW_INTERVAL_MIN   1600    // 1000ms (en unités de 0.625ms)
#define ADV_SLOW_INTERVAL_MAX   2400    // 1500ms
#define ADV_SLOW_TIMEOUT_S      15      // 15 secondes en lent, puis System OFF

// Total: 30 secondes d'advertising max avant System OFF

// Mode pairing (triple-tap PTT) : advertising long pour première connexion
#define ADV_PAIRING_INTERVAL_MIN  160   // 100ms (en unités de 0.625ms)
#define ADV_PAIRING_INTERVAL_MAX  240   // 150ms
#define ADV_PAIRING_TIMEOUT_S     180   // 3 minutes en mode pairing

// =============================================================================
// POWER MANAGEMENT (mode agressif)
// =============================================================================

// Timeout avant System OFF après inactivité
// Condition: pas de BLE connecté, pas de bouton, pas de transfert
#define SLEEP_TIMEOUT_MS        5000    // 5 secondes → System OFF

// Durée d'affichage du statut batterie (utilisé si showBatteryStatus() appelé)
#define BATTERY_LED_DURATION_MS 300

// =============================================================================
// FEATURE FLAGS (low power)
// =============================================================================

// NFC: désactivé en production pour économiser ~0.5mA (optim #7)
#define NFC_ENABLED             0       // 1 = activer NFC, 0 = désactiver

// =============================================================================
// LED TIMING
// =============================================================================

#define LED_BLINK_FAST_MS       100     // Clignotement rapide
#define LED_BLINK_SLOW_MS       500     // Clignotement lent
#define LED_BRIEF_FLASH_MS      500     // Flash bref (0.5s)

// =============================================================================
// DEBUG
// =============================================================================

#define DEBUG_SERIAL            1       // 1 = UART Serial en plus du BLE
#define DEBUG_BAUD_RATE         115200

// Les logs debug passent TOUJOURS par le buffer BLE (debug_ble)
// Si DEBUG_SERIAL=1, ils passent aussi par le Serial USB (dev câblé)
#include "debug_ble.h"

#if DEBUG_SERIAL
  #define DEBUG_PRINT(x)        do { Serial.print(x); debugBle.log(String(x).c_str()); } while(0)
  #define DEBUG_PRINTLN(x)      do { Serial.println(x); debugBle.log(String(x).c_str()); debugBle.log("\n"); } while(0)
  #define DEBUG_PRINTF(...)     do { Serial.printf(__VA_ARGS__); debugBle.logf(__VA_ARGS__); } while(0)
#else
  #define DEBUG_PRINT(x)        debugBle.log(String(x).c_str())
  #define DEBUG_PRINTLN(x)      do { debugBle.log(String(x).c_str()); debugBle.log("\n"); } while(0)
  #define DEBUG_PRINTF(...)     debugBle.logf(__VA_ARGS__)
#endif

// =============================================================================
// BLE COMMANDS (téléphone → firmware via RX)
// =============================================================================

#define CMD_ENTER_DFU           0xFD    // Entrer en mode DFU OTA (bootloader)
#define CMD_GET_VERSION         0xFE    // Demander la version firmware

// =============================================================================
// BUTTON EVENT CODES (envoyés via BLE caractéristique custom)
// =============================================================================

// L'app Android intercepte ces codes et appelle AudioManager
// Convention: 0x1x = bouton D2, 0x2x = bouton D3
#define BTN_EVT_VOLUME_UP       0x11    // D2 single press → Volume +
#define BTN_EVT_VOLUME_DOWN     0x21    // D3 single press → Volume -

#endif // CONFIG_H
