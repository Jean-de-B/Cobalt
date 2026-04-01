/**
 * @file external_flash.h
 * @brief Système de fichiers LittleFS sur flash QSPI externe (P25Q16H)
 *
 * Utilise Adafruit_SPIFlash pour accéder au P25Q16H (2MB) via QSPI,
 * et Adafruit_LittleFS pour monter un filesystem dessus.
 * Pattern identique à InternalFileSystem du BSP Adafruit.
 */

#ifndef EXTERNAL_FLASH_H
#define EXTERNAL_FLASH_H

#include <Adafruit_LittleFS.h>

class ExternalFileSystem : public Adafruit_LittleFS
{
  public:
    ExternalFileSystem(void);

    /**
     * @brief Initialise le QSPI flash + monte LittleFS
     * @return true si succès
     */
    bool begin(void);

    /**
     * @brief Taille totale de la flash externe en bytes
     */
    uint32_t totalSize(void);

    /**
     * @brief Test d'écriture/lecture raw flash (diagnostic)
     * @return true si lecture = écriture
     */
    bool testRawWrite();
};

extern ExternalFileSystem ExternalFS;

// Envoie une commande custom à la flash via le transport Adafruit (safe)
void externalFlashRunCommand(uint8_t command);
bool externalFlashIsInitialized();

#endif /* EXTERNAL_FLASH_H */
