/**
 * @file external_flash.cpp
 * @brief Implémentation du filesystem LittleFS sur flash QSPI externe
 *
 * P25Q16H: 2MB, secteurs 4KB, pages 256 bytes
 * Connecté via QSPI sur les pins définis dans variant.h:
 *   SCK=24, CS=25, IO0=26, IO1=27, IO2=28, IO3=29
 *
 * Pattern identique à InternalFileSystem.cpp du BSP Adafruit.
 */

#include "external_flash.h"
#include "config.h"

// Adafruit_SPIFlashBase : driver flash sans dépendance SdFat
// Adafruit_FlashTransport : sélectionne automatiquement QSPI sur nRF52840
#include <Adafruit_SPIFlashBase.h>
#include <Adafruit_FlashTransport.h>

// === CONFIGURATION QSPI ===
// Le constructeur par défaut utilise les pins de variant.h:
//   EXTERNAL_FLASH_DEVICES = P25Q16H (détection automatique JEDEC)
//   EXTERNAL_FLASH_USE_QSPI = défini
static Adafruit_FlashTransport_QSPI _qspiTransport;
static Adafruit_SPIFlashBase        _qspiFlash(&_qspiTransport);

// === PARAMÈTRES P25Q16H ===
#define QSPI_SECTOR_SIZE    4096                // Taille secteur (unité d'effacement)
#define QSPI_PAGE_SIZE      256                 // Taille page (unité d'écriture)
#define QSPI_TOTAL_SIZE     (2 * 1024 * 1024)   // 2 MB
#define QSPI_BLOCK_COUNT    (QSPI_TOTAL_SIZE / QSPI_SECTOR_SIZE)  // 512 blocs

// === CALLBACKS LittleFS ===

static int _qspi_read(const struct lfs_config *c, lfs_block_t block,
                       lfs_off_t off, void *buffer, lfs_size_t size) {
    (void) c;
    uint32_t addr = block * QSPI_SECTOR_SIZE + off;
    return (_qspiFlash.readBuffer(addr, (uint8_t*)buffer, size) == size)
           ? LFS_ERR_OK : LFS_ERR_IO;
}

static int _qspi_prog(const struct lfs_config *c, lfs_block_t block,
                       lfs_off_t off, const void *buffer, lfs_size_t size) {
    (void) c;
    uint32_t addr = block * QSPI_SECTOR_SIZE + off;
    return (_qspiFlash.writeBuffer(addr, (const uint8_t*)buffer, size) == size)
           ? LFS_ERR_OK : LFS_ERR_IO;
}

static int _qspi_erase(const struct lfs_config *c, lfs_block_t block) {
    (void) c;
    // eraseSector() attend un numéro de secteur (pas une adresse)
    return _qspiFlash.eraseSector(block) ? LFS_ERR_OK : LFS_ERR_IO;
}

static int _qspi_sync(const struct lfs_config *c) {
    (void) c;
    _qspiFlash.waitUntilReady();
    return LFS_ERR_OK;
}

// === CONFIGURATION LFS STATIQUE ===
static struct lfs_config _ExternalFSConfig = {
    .context = NULL,

    .read  = _qspi_read,
    .prog  = _qspi_prog,
    .erase = _qspi_erase,
    .sync  = _qspi_sync,

    .read_size      = QSPI_PAGE_SIZE,      // 256 bytes
    .prog_size      = QSPI_PAGE_SIZE,      // 256 bytes
    .block_size     = QSPI_SECTOR_SIZE,    // 4096 bytes (= granularité d'effacement)
    .block_count    = QSPI_BLOCK_COUNT,    // 512 blocs (= 2MB / 4KB)
    .lookahead      = 128,

    .read_buffer      = NULL,
    .prog_buffer      = NULL,
    .lookahead_buffer = NULL,
    .file_buffer      = NULL
};

// === INSTANCE GLOBALE ===
ExternalFileSystem ExternalFS;

// === IMPLÉMENTATION ===

ExternalFileSystem::ExternalFileSystem(void)
    : Adafruit_LittleFS(&_ExternalFSConfig)
{
}

bool ExternalFileSystem::begin(void) {
    // Étape 1: Initialise le driver QSPI (détection auto P25Q16H via JEDEC)
    if (!_qspiFlash.begin()) {
        DEBUG_PRINTLN("[QSPI] Erreur init flash P25Q16H");
        return false;
    }

    DEBUG_PRINTF("[QSPI] Flash détectée: %lu KB (JEDEC: 0x%06lX)\n",
                 _qspiFlash.size() / 1024, _qspiFlash.getJEDECID());

    // Étape 2: Monte LittleFS sur la flash QSPI
    if (!Adafruit_LittleFS::begin()) {
        // Premier démarrage ou flash corrompue → formatage
        DEBUG_PRINTLN("[QSPI] LittleFS mount échoué, formatage...");
        this->format();

        if (!Adafruit_LittleFS::begin()) {
            DEBUG_PRINTLN("[QSPI] ERREUR: formatage + montage échoué");
            return false;
        }
        DEBUG_PRINTLN("[QSPI] Formaté et monté avec succès");
    }

    DEBUG_PRINTLN("[QSPI] LittleFS monté sur flash externe (2 MB)");
    return true;
}

uint32_t ExternalFileSystem::totalSize(void) {
    return _qspiFlash.size();
}
