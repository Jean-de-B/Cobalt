/**
 * @file flash_storage.cpp
 * @brief Implémentation du stockage offline sur flash QSPI externe (LittleFS)
 *
 * Utilise ExternalFileSystem (LittleFS sur P25Q16H via QSPI)
 * Fichiers stockés à la racine LittleFS: /note_00001.cvox, /note_00002.cvox...
 */

#include "flash_storage.h"
#include <Adafruit_LittleFS.h>
#include "external_flash.h"

using namespace Adafruit_LittleFS_Namespace;

// Espace flash externe P25Q16H via QSPI (~2 MB)
#define FLASH_EXTERNAL_SIZE     (2 * 1024 * 1024)

// Instance globale
FlashStorage flashStorage;

bool FlashStorage::begin() {
    if (_initialized) return true;

    // Initialise LittleFS sur la flash QSPI externe
    if (!ExternalFS.begin()) {
        DEBUG_PRINTLN("[FLASH] Erreur init LittleFS (QSPI externe)");
        return false;
    }

    _totalBytes = FLASH_EXTERNAL_SIZE;

    // Scanne les fichiers existants pour reprendre le compteur
    scanDirectory();
    updateStats();

    _initialized = true;

    DEBUG_PRINTF("[FLASH] Init OK - %lu fichiers, %lu/%lu bytes utilisés\n",
                 _fileCount, _usedBytes, _totalBytes);

    return true;
}

void FlashStorage::scanDirectory() {
    // Parcourt la racine pour trouver le plus grand index
    // et compter les fichiers
    _nextIndex = 1;
    _fileCount = 0;

    File dir = ExternalFS.open("/");
    if (!dir) {
        DEBUG_PRINTLN("[FLASH] Impossible d'ouvrir la racine");
        return;
    }

    File entry = dir.openNextFile();
    while (entry) {
        const char* name = entry.name();

        // Vérifie si c'est un fichier note_XXXXX.cvox
        if (strncmp(name, FLASH_FILE_PREFIX, strlen(FLASH_FILE_PREFIX)) == 0) {
            // Extrait l'index du nom de fichier
            uint32_t idx = atoi(name + strlen(FLASH_FILE_PREFIX));
            if (idx >= _nextIndex) {
                _nextIndex = idx + 1;
            }
            _fileCount++;
        }
        entry.close();
        entry = dir.openNextFile();
    }
    dir.close();

    DEBUG_PRINTF("[FLASH] Scan: %lu fichiers, prochain index: %lu\n",
                 _fileCount, _nextIndex);
}

void FlashStorage::buildFilePath(uint32_t index, char* path, uint32_t maxLen) {
    snprintf(path, maxLen, "/%s%05lu%s",
             FLASH_FILE_PREFIX, index, FLASH_FILE_EXT);
}

bool FlashStorage::saveCurrentRecording() {
    if (!_initialized) {
        DEBUG_PRINTLN("[FLASH] Non initialisé");
        return false;
    }

    if (!audioStorage.hasRecording()) {
        DEBUG_PRINTLN("[FLASH] Pas d'enregistrement à sauvegarder");
        return false;
    }

    if (isFull()) {
        DEBUG_PRINTLN("[FLASH] Flash pleine!");
        return false;
    }

    // Construit le chemin du fichier
    char filepath[FLASH_MAX_FILENAME];
    buildFilePath(_nextIndex, filepath, sizeof(filepath));

    DEBUG_PRINTF("[FLASH] Sauvegarde: %s (utilisé: %lu/%lu, fichiers: %lu)\n",
                 filepath, _usedBytes, _totalBytes, _fileCount);

    // Ouvre le fichier en écriture
    File file(ExternalFS);
    if (!file.open(filepath, FILE_O_WRITE)) {
        DEBUG_PRINTF("[FLASH] Erreur ouverture: %s\n", filepath);
        return false;
    }

    // Écrit le header CVOX (34 bytes)
    const AudioFileHeader_t* header = audioStorage.getHeader();
    uint32_t written = file.write((const uint8_t*)header, sizeof(AudioFileHeader_t));
    if (written != sizeof(AudioFileHeader_t)) {
        DEBUG_PRINTLN("[FLASH] Erreur écriture header");
        file.close();
        ExternalFS.remove(filepath);
        return false;
    }

    // Écrit les données ADPCM par blocs (évite dépassement buffer interne LittleFS)
    const uint8_t* data = audioStorage.getDataPointer();
    uint32_t dataSize = audioStorage.getAudioDataSize();
    uint32_t totalWritten = 0;
    const uint32_t WRITE_BLOCK = 512;

    while (totalWritten < dataSize) {
        uint32_t toWrite = min(WRITE_BLOCK, dataSize - totalWritten);
        written = file.write(data + totalWritten, toWrite);
        if (written != toWrite) {
            DEBUG_PRINTF("[FLASH] Erreur écriture données @ %lu (%lu/%lu)\n",
                         totalWritten, written, toWrite);
            file.close();
            ExternalFS.remove(filepath);
            return false;
        }
        totalWritten += written;
    }

    file.close();

    _nextIndex++;
    _fileCount++;
    updateStats();

    DEBUG_PRINTF("[FLASH] Sauvegardé: %lu bytes (header:%lu + data:%lu)\n",
                 (uint32_t)sizeof(AudioFileHeader_t) + dataSize,
                 (uint32_t)sizeof(AudioFileHeader_t), dataSize);

    return true;
}

bool FlashStorage::findOldestFile(char* path, uint32_t maxLen) {
    // Trouve le fichier avec le plus petit index
    File dir = ExternalFS.open("/");
    if (!dir) return false;

    uint32_t minIndex = UINT32_MAX;
    bool found = false;

    File entry = dir.openNextFile();
    while (entry) {
        const char* name = entry.name();

        if (strncmp(name, FLASH_FILE_PREFIX, strlen(FLASH_FILE_PREFIX)) == 0) {
            uint32_t idx = atoi(name + strlen(FLASH_FILE_PREFIX));
            if (idx < minIndex) {
                minIndex = idx;
                found = true;
            }
        }
        entry.close();
        entry = dir.openNextFile();
    }
    dir.close();

    if (found) {
        buildFilePath(minIndex, path, maxLen);
    }

    return found;
}

bool FlashStorage::loadNextIntoAudioStorage() {
    if (!_initialized) return false;
    if (_fileCount == 0) return false;

    // Trouve le fichier le plus ancien
    char filepath[FLASH_MAX_FILENAME];
    if (!findOldestFile(filepath, sizeof(filepath))) {
        DEBUG_PRINTLN("[FLASH] Aucun fichier trouvé");
        return false;
    }

    DEBUG_PRINTF("[FLASH] Chargement: %s\n", filepath);

    // Ouvre le fichier
    File file(ExternalFS);
    if (!file.open(filepath, FILE_O_READ)) {
        DEBUG_PRINTF("[FLASH] Erreur ouverture: %s\n", filepath);
        return false;
    }

    uint32_t fileSize = file.size();
    if (fileSize <= sizeof(AudioFileHeader_t)) {
        DEBUG_PRINTLN("[FLASH] Fichier trop petit");
        file.close();
        return false;
    }

    // Lit le header
    AudioFileHeader_t header;
    uint32_t bytesRead = file.read((uint8_t*)&header, sizeof(AudioFileHeader_t));
    if (bytesRead != sizeof(AudioFileHeader_t)) {
        DEBUG_PRINTLN("[FLASH] Erreur lecture header");
        file.close();
        return false;
    }

    // Vérifie le magic number
    if (header.magic[0] != 'C' || header.magic[1] != 'V' ||
        header.magic[2] != 'O' || header.magic[3] != 'X') {
        DEBUG_PRINTLN("[FLASH] Magic number invalide");
        file.close();
        return false;
    }

    // Taille des données ADPCM
    uint32_t dataSize = fileSize - sizeof(AudioFileHeader_t);

    // Vérifie que ça tient dans le buffer RAM
    if (dataSize > AUDIO_BUFFER_SIZE) {
        DEBUG_PRINTF("[FLASH] Fichier trop gros: %lu > %lu\n", dataSize, (uint32_t)AUDIO_BUFFER_SIZE);
        file.close();
        return false;
    }

    // Charge dans audioStorage
    audioStorage.clear();
    audioStorage.startRecording();

    // Lit les données ADPCM par blocs
    uint8_t readBuf[256];
    uint32_t remaining = dataSize;
    while (remaining > 0) {
        uint32_t toRead = min(remaining, (uint32_t)sizeof(readBuf));
        bytesRead = file.read(readBuf, toRead);
        if (bytesRead == 0) break;
        audioStorage.write(readBuf, bytesRead);
        remaining -= bytesRead;
    }

    file.close();

    // Finalise avec les infos du header
    audioStorage.finalizeRecording(header.totalSamples, header.initialSample, header.initialIndex);

    // Mémorise le fichier pour suppression après transfert
    strncpy(_currentSyncPath, filepath, FLASH_MAX_FILENAME - 1);
    _currentSyncPath[FLASH_MAX_FILENAME - 1] = '\0';
    _hasSyncFile = true;

    DEBUG_PRINTF("[FLASH] Chargé: %lu samples, %lu bytes ADPCM\n",
                 header.totalSamples, dataSize);

    return true;
}

bool FlashStorage::deleteCurrentSyncFile() {
    if (!_hasSyncFile) {
        DEBUG_PRINTLN("[FLASH] Pas de fichier sync à supprimer");
        return false;
    }

    DEBUG_PRINTF("[FLASH] Suppression: %s\n", _currentSyncPath);

    if (ExternalFS.remove(_currentSyncPath)) {
        _hasSyncFile = false;
        _fileCount = (_fileCount > 0) ? _fileCount - 1 : 0;
        updateStats();
        DEBUG_PRINTF("[FLASH] Supprimé. Restant: %lu fichiers\n", _fileCount);
        return true;
    }

    DEBUG_PRINTLN("[FLASH] Erreur suppression");
    return false;
}

bool FlashStorage::hasPendingFiles() {
    if (!_initialized) return false;
    return _fileCount > 0;
}

uint32_t FlashStorage::getPendingCount() {
    return _fileCount;
}

bool FlashStorage::isFull() {
    if (!_initialized) return true;

    // Vérifie le nombre max de fichiers
    if (_fileCount >= FLASH_MAX_FILES) return true;

    // Vérifie l'espace disponible (garde 4KB de marge)
    if (_totalBytes > 0 && _usedBytes + 4096 >= _totalBytes) return true;

    return false;
}

void FlashStorage::updateStats() {
    _usedBytes = 0;
    _fileCount = 0;

    File dir = ExternalFS.open("/");
    if (!dir) return;

    File entry = dir.openNextFile();
    while (entry) {
        const char* name = entry.name();
        if (strncmp(name, FLASH_FILE_PREFIX, strlen(FLASH_FILE_PREFIX)) == 0) {
            _usedBytes += entry.size();
            _fileCount++;
        }
        entry.close();
        entry = dir.openNextFile();
    }
    dir.close();
}
