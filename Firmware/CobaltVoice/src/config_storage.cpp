/**
 * @file config_storage.cpp
 * @brief Implémentation de la persistance de configuration
 */

#include "config_storage.h"
#include "config.h"
#include "external_flash.h"
#include <Adafruit_LittleFS.h>

using namespace Adafruit_LittleFS_Namespace;

#define CONFIG_FILENAME "/cobalt_config.bin"

// Structure simple: magic + version + lowPowerMode
typedef struct __attribute__((packed)) {
    uint8_t magic[4];      // "COCF"
    uint8_t version;       // 1
    bool lowPowerMode;
} ConfigData_t;

bool loadLowPowerMode(bool defaultVal) {
    if (!externalFlashIsInitialized()) {
        DEBUG_PRINTLN("[CONFIG] Flash non initialisée, valeur par défaut");
        return defaultVal;
    }

    File file(ExternalFS);
    if (!file.open(CONFIG_FILENAME, FILE_O_READ)) {
        DEBUG_PRINTLN("[CONFIG] Fichier non trouvé, valeur par défaut");
        return defaultVal;
    }

    ConfigData_t config;
    uint32_t bytesRead = file.read((uint8_t*)&config, sizeof(ConfigData_t));
    file.close();

    if (bytesRead != sizeof(ConfigData_t)) {
        DEBUG_PRINTLN("[CONFIG] Fichier corrompu (taille incorrecte)");
        return defaultVal;
    }

    // Vérifie magic number
    if (config.magic[0] != 'C' || config.magic[1] != 'O' ||
        config.magic[2] != 'C' || config.magic[3] != 'F') {
        DEBUG_PRINTLN("[CONFIG] Magic number invalide");
        return defaultVal;
    }

    if (config.version != 1) {
        DEBUG_PRINTLN("[CONFIG] Version non supportée");
        return defaultVal;
    }

    DEBUG_PRINTF("[CONFIG] lowPowerMode chargé: %s\n",
                 config.lowPowerMode ? "true (LOW POWER)" : "false (NORMAL)");
    return config.lowPowerMode;
}

bool saveLowPowerMode(bool value) {
    if (!externalFlashIsInitialized()) {
        DEBUG_PRINTLN("[CONFIG] Flash non initialisée, impossible de sauvegarder");
        return false;
    }

    ConfigData_t config;
    config.magic[0] = 'C';
    config.magic[1] = 'O';
    config.magic[2] = 'C';
    config.magic[3] = 'F';
    config.version = 1;
    config.lowPowerMode = value;

    File file(ExternalFS);
    if (!file.open(CONFIG_FILENAME, FILE_O_WRITE)) {
        DEBUG_PRINTLN("[CONFIG] Erreur ouverture fichier");
        return false;
    }

    uint32_t bytesWritten = file.write((const uint8_t*)&config, sizeof(ConfigData_t));
    file.close();

    if (bytesWritten != sizeof(ConfigData_t)) {
        DEBUG_PRINTLN("[CONFIG] Erreur écriture fichier");
        ExternalFS.remove(CONFIG_FILENAME);
        return false;
    }

    DEBUG_PRINTF("[CONFIG] lowPowerMode sauvegardé: %s\n",
                 value ? "true (LOW POWER)" : "false (NORMAL)");
    return true;
}