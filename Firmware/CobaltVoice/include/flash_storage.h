/**
 * @file flash_storage.h
 * @brief Stockage offline sur flash QSPI externe P25Q16H (LittleFS) pour Cobalt Voice
 *
 * Permet de sauvegarder les enregistrements quand le téléphone n'est pas
 * à portée BLE, puis de les synchroniser à la reconnexion.
 *
 * Format fichier: header CVOX (34 bytes) + données ADPCM brutes
 * Nommage: /note_XXXXX.cvox (compteur monotonique)
 *
 * Capacité estimée (~2 MB flash externe P25Q16H):
 *   - Enregistrement 5s @ 16kHz ADPCM = ~40 KB → ~50 notes
 *   - Enregistrement 15s = ~120 KB → ~16 notes
 */

#ifndef FLASH_STORAGE_H
#define FLASH_STORAGE_H

#include "config.h"
#include "audio_storage.h"

// Nommage fichiers (stockés à la racine LittleFS)
#define FLASH_FILE_PREFIX   "note_"
#define FLASH_FILE_EXT      ".cvox"

// Limites
#define FLASH_MAX_FILENAME  32
#define FLASH_MAX_FILES     50      // Max 50 notes offline (~2MB flash externe P25Q16H)

class FlashStorage {
public:
    /**
     * @brief Initialise LittleFS et crée le répertoire
     * @return true si succès
     */
    bool begin();

    /**
     * @brief Sauvegarde l'enregistrement courant (audioStorage) sur flash
     * @return true si sauvegardé avec succès
     */
    bool saveCurrentRecording();

    /**
     * @brief Charge le plus ancien fichier dans audioStorage pour transfert BLE
     * @return true si un fichier a été chargé
     */
    bool loadNextIntoAudioStorage();

    /**
     * @brief Supprime le fichier qui vient d'être transféré
     * @return true si supprimé
     */
    bool deleteCurrentSyncFile();

    /**
     * @brief Vérifie s'il y a des fichiers en attente de sync
     */
    bool hasPendingFiles();

    /**
     * @brief Compte les fichiers en attente
     */
    uint32_t getPendingCount();

    /**
     * @brief Vérifie si la flash est pleine
     * (plus d'espace ou max fichiers atteint)
     */
    bool isFull();

    /**
     * @brief Espace utilisé en bytes
     */
    uint32_t getUsedBytes() const { return _usedBytes; }

    /**
     * @brief Espace total disponible pour LittleFS
     */
    uint32_t getTotalBytes() const { return _totalBytes; }

    /**
     * @brief Nombre de fichiers stockés
     */
    uint32_t getFileCount() const { return _fileCount; }

private:
    bool _initialized = false;
    uint32_t _nextIndex = 1;        // Prochain index de fichier
    uint32_t _fileCount = 0;        // Nombre de fichiers stockés
    uint32_t _usedBytes = 0;        // Espace utilisé
    uint32_t _totalBytes = 0;       // Espace total

    // Fichier en cours de sync (pour suppression après transfert)
    char _currentSyncPath[FLASH_MAX_FILENAME];
    bool _hasSyncFile = false;

    /**
     * @brief Scanne le répertoire pour trouver le prochain index
     */
    void scanDirectory();

    /**
     * @brief Construit le chemin d'un fichier à partir de son index
     */
    void buildFilePath(uint32_t index, char* path, uint32_t maxLen);

    /**
     * @brief Trouve le fichier avec le plus petit index (le plus ancien)
     */
    bool findOldestFile(char* path, uint32_t maxLen);

    /**
     * @brief Scan complet pour recalculer les stats (init uniquement)
     */
    void fullScanStats();
};

// Instance globale
extern FlashStorage flashStorage;

#endif // FLASH_STORAGE_H
