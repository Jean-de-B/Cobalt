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
#include <flash_devices.h>

// Descripteur explicite du P25Q16H — la liste interne de la lib ne l'inclut pas
static const SPIFlash_Device_t _flash_devices[] = { P25Q16H };

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
    uint32_t rd = _qspiFlash.readBuffer(addr, (uint8_t*)buffer, size);
    if (rd != size) {
        DEBUG_PRINTF("[LFS-READ] FAIL block=%lu off=%lu size=%lu rd=%lu\n",
                     (uint32_t)block, (uint32_t)off, (uint32_t)size, rd);
        return LFS_ERR_IO;
    }
    return LFS_ERR_OK;
}

static int _qspi_prog(const struct lfs_config *c, lfs_block_t block,
                       lfs_off_t off, const void *buffer, lfs_size_t size) {
    (void) c;
    uint32_t addr = block * QSPI_SECTOR_SIZE + off;
    uint32_t wr = _qspiFlash.writeBuffer(addr, (const uint8_t*)buffer, size);
    if (wr != size) {
        DEBUG_PRINTF("[LFS-PROG] FAIL block=%lu off=%lu size=%lu wr=%lu\n",
                     (uint32_t)block, (uint32_t)off, (uint32_t)size, wr);
        return LFS_ERR_IO;
    }
    return LFS_ERR_OK;
}

static int _qspi_erase(const struct lfs_config *c, lfs_block_t block) {
    (void) c;
    bool ok = _qspiFlash.eraseSector(block);
    if (!ok) {
        DEBUG_PRINTF("[LFS-ERASE] FAIL block=%lu\n", (uint32_t)block);
    }
    return ok ? LFS_ERR_OK : LFS_ERR_IO;
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

// === INSTANCES GLOBALES ===
ExternalFileSystem ExternalFS;

// Accesseur pour envoyer des commandes custom à la flash via le transport Adafruit
// (évite d'écrire directement dans NRF_QSPI qui casse l'état interne du driver)
void externalFlashRunCommand(uint8_t command) {
    _qspiTransport.runCommand(command);
}

bool externalFlashIsInitialized() {
    return _qspiFlash.size() > 0;
}

// === IMPLÉMENTATION ===

ExternalFileSystem::ExternalFileSystem(void)
    : Adafruit_LittleFS(&_ExternalFSConfig)
{
}

bool ExternalFileSystem::begin(void) {
    // Étape 0: Réveiller la flash si elle était en deep power-down (0xB9)
    // Le deep power-down survit aux resets MCU — la flash P25Q16H reste endormie
    // et ne répond plus aux commandes JEDEC tant qu'on n'envoie pas 0xAB.
    //
    // Stratégie: on appelle begin() une première fois pour configurer les pins QSPI,
    // puis on envoie 0xAB via le périphérique QSPI maintenant initialisé,
    // puis on rappelle begin() pour retenter la détection JEDEC.
    // Init flash — utilise UNIQUEMENT l'API Adafruit (pas de registres directs)
    DEBUG_PRINTLN("[QSPI] Init flash...");
    if (!_qspiFlash.begin(_flash_devices, 1)) {
        // Échec: flash peut être en deep power-down ou absente
        // Le transport QSPI est maintenant configuré (pins + périphérique)
        // On envoie le wake-up via le transport Adafruit (pas de registres directs!)
        DEBUG_PRINTLN("[QSPI] Échec JEDEC → wake-up via transport Adafruit...");
        _qspiTransport.runCommand(0xAB);  // Release from Deep Power-Down
        delay(5);

        // Deuxième tentative (transport propre, état interne cohérent)
        DEBUG_PRINTLN("[QSPI] Retry...");
        if (!_qspiFlash.begin(_flash_devices, 1)) {
            DEBUG_PRINTLN("[QSPI] Erreur init flash P25Q16H");
            return false;
        }
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

bool ExternalFileSystem::testRawWrite() {
    // Test sur le dernier secteur (n'interfère pas avec LittleFS)
    uint32_t testSector = (_qspiFlash.size() / QSPI_SECTOR_SIZE) - 1;
    uint32_t testAddr = testSector * QSPI_SECTOR_SIZE;

    DEBUG_PRINTF("[QSPI-TEST] Erase sector %lu (addr 0x%lX)...\n", testSector, testAddr);
    bool eraseOk = _qspiFlash.eraseSector(testSector);
    DEBUG_PRINTF("[QSPI-TEST] Erase: %s\n", eraseOk ? "OK" : "FAIL");
    if (!eraseOk) return false;

    uint8_t writeData[256];
    for (int i = 0; i < 256; i++) writeData[i] = (uint8_t)i;

    DEBUG_PRINTLN("[QSPI-TEST] Write 256 bytes...");
    uint32_t written = _qspiFlash.writeBuffer(testAddr, writeData, 256);
    DEBUG_PRINTF("[QSPI-TEST] Write: %lu/256\n", written);
    if (written != 256) return false;

    uint8_t readData[256];
    memset(readData, 0, 256);
    uint32_t rd = _qspiFlash.readBuffer(testAddr, readData, 256);
    DEBUG_PRINTF("[QSPI-TEST] Read: %lu/256\n", rd);

    bool match = (memcmp(writeData, readData, 256) == 0);
    DEBUG_PRINTF("[QSPI-TEST] Verify: %s\n", match ? "MATCH" : "MISMATCH");
    if (!match) {
        DEBUG_PRINTF("[QSPI-TEST] First bytes: W=%02X%02X%02X%02X R=%02X%02X%02X%02X\n",
            writeData[0], writeData[1], writeData[2], writeData[3],
            readData[0], readData[1], readData[2], readData[3]);
    }

    // Cleanup: erase the test sector
    _qspiFlash.eraseSector(testSector);
    return match;
}
