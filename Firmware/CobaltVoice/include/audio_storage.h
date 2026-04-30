/**
 * @file audio_storage.h
 * @brief Stockage audio en mémoire RAM interne pour Cobalt Voice
 *
 * Utilise un buffer circulaire en RAM comme tampon d'enregistrement
 * Les données sont au format ADPCM compressé
 */

#ifndef AUDIO_STORAGE_H
#define AUDIO_STORAGE_H

#include "config.h"

// En-tête de fichier audio (pour reconstruction côté application)
// Format CVOX v1 - 34 bytes (compatible avec cobalt_memo app)
typedef struct __attribute__((packed)) {
    char     magic[4];          // "CVOX" - offset 0-3
    uint16_t version;           // Version du format (1) - offset 4-5
    uint16_t sampleRate;        // Fréquence d'échantillonnage - offset 6-7
    uint8_t  channels;          // Nombre de canaux (1 = mono) - offset 8
    uint8_t  bitsPerSample;     // Bits par sample ADPCM (4) - offset 9
    uint16_t blockSize;         // Taille bloc ADPCM - offset 10-11
    uint32_t totalSamples;      // Nombre total de samples PCM - offset 12-15
    uint32_t dataSize;          // Taille des données ADPCM - offset 16-19
    int16_t  initialSample;     // Sample initial pour décodage - offset 20-21
    int8_t   initialIndex;      // Index initial pour décodage - offset 22
    uint8_t  reserved1;         // 0x00 = live (direct BLE), 0x01 = différé (depuis flash offline) - offset 23
    uint8_t  reserved2[10];     // Padding supplémentaire - offset 24-33
} AudioFileHeader_t;

// Vérifie la taille du header à la compilation
static_assert(sizeof(AudioFileHeader_t) == 34, "AudioFileHeader_t must be 34 bytes");

#define AUDIO_HEADER_SIZE sizeof(AudioFileHeader_t)

class AudioStorage {
public:
    /**
     * @brief Initialise le stockage
     * @return true si succès
     */
    bool begin();

    /**
     * @brief Démarre un nouvel enregistrement
     * @return true si succès
     */
    bool startRecording();

    /**
     * @brief Écrit des données ADPCM dans le buffer
     * @param data Données ADPCM
     * @param size Taille en octets
     * @return Nombre d'octets écrits
     */
    uint32_t write(const uint8_t* data, uint32_t size);

    /**
     * @brief Finalise l'enregistrement
     * @param totalPcmSamples Nombre total de samples PCM encodés
     * @param initialSample Sample initial ADPCM
     * @param initialIndex Index initial ADPCM
     * @return true si succès
     */
    bool finalizeRecording(uint32_t totalPcmSamples, int16_t initialSample, int8_t initialIndex);

    /**
     * @brief Obtient la taille totale des données (header + audio)
     */
    uint32_t getTotalSize();

    /**
     * @brief Obtient la taille des données audio seules
     */
    uint32_t getAudioDataSize() { return _writePos; }

    /**
     * @brief Lit des données depuis le buffer
     * @param offset Position de lecture
     * @param buffer Buffer de destination
     * @param size Taille à lire
     * @return Nombre d'octets lus
     */
    uint32_t read(uint32_t offset, uint8_t* buffer, uint32_t size);

    /**
     * @brief Vérifie si le buffer est plein
     */
    bool isFull() { return _writePos >= AUDIO_BUFFER_SIZE; }

    /**
     * @brief Obtient l'espace disponible
     */
    uint32_t getAvailableSpace() {
        return (_writePos < AUDIO_BUFFER_SIZE) ? (AUDIO_BUFFER_SIZE - _writePos) : 0;
    }

    /**
     * @brief Obtient le pourcentage d'utilisation
     */
    uint8_t getUsagePercent() {
        return (uint8_t)((_writePos * 100UL) / AUDIO_BUFFER_SIZE);
    }

    /**
     * @brief Efface le buffer
     */
    void clear();

    /**
     * @brief Vérifie si un enregistrement est disponible
     */
    bool hasRecording() { return _hasValidRecording; }

    /**
     * @brief Marque l'enregistrement comme différé (chargé depuis flash offline)
     * Positionne reserved1 = 0x01 dans le header avant le transfert BLE.
     */
    void markAsDeferred() { _header.reserved1 = 0x01; }

    /**
     * @brief Obtient le pointeur vers le header
     */
    const AudioFileHeader_t* getHeader() { return &_header; }

    /**
     * @brief Obtient le pointeur direct vers les données (pour transfert rapide)
     */
    const uint8_t* getDataPointer() { return _audioBuffer; }

private:
    // Buffer audio en RAM
    uint8_t _audioBuffer[AUDIO_BUFFER_SIZE];

    // Header du fichier
    AudioFileHeader_t _header;

    // Position d'écriture
    uint32_t _writePos;

    // Flag d'enregistrement valide
    bool _hasValidRecording;

    // Flag d'enregistrement en cours
    bool _recording;

    /**
     * @brief Initialise le header
     */
    void initHeader();
};

// Instance globale
extern AudioStorage audioStorage;

#endif // AUDIO_STORAGE_H
