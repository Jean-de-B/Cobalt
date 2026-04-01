/**
 * @file audio_storage.cpp
 * @brief Implémentation du stockage audio en RAM
 */

#include "audio_storage.h"

// Instance globale
AudioStorage audioStorage;

bool AudioStorage::begin() {
    clear();
    DEBUG_PRINTLN("[STORAGE] Audio storage initialized");
    // Débit ADPCM = SAMPLE_RATE * 4 bits / 8 = SAMPLE_RATE / 2 bytes/sec
    DEBUG_PRINTF("[STORAGE] Buffer size: %lu bytes (max ~%d sec @ 16kHz ADPCM)\n",
                 (uint32_t)AUDIO_BUFFER_SIZE,
                 (int)(AUDIO_BUFFER_SIZE / (AUDIO_SAMPLE_RATE / 2)));
    return true;
}

void AudioStorage::initHeader() {
    memset(&_header, 0, sizeof(_header));

    // Magic number
    _header.magic[0] = 'C';
    _header.magic[1] = 'V';
    _header.magic[2] = 'O';
    _header.magic[3] = 'X';

    // Version
    _header.version = 1;

    // Format audio
    _header.sampleRate = AUDIO_SAMPLE_RATE;
    _header.channels = AUDIO_CHANNELS;
    _header.bitsPerSample = ADPCM_BITS_PER_SAMPLE;
    _header.blockSize = ADPCM_BLOCK_SIZE;

    // Valeurs à remplir lors de la finalisation
    _header.totalSamples = 0;
    _header.dataSize = 0;
    _header.initialSample = 0;
    _header.initialIndex = 0;
}

bool AudioStorage::startRecording() {
    if (_recording) {
        DEBUG_PRINTLN("[STORAGE] Already recording!");
        return false;
    }

    clear();
    initHeader();
    _recording = true;

    DEBUG_PRINTLN("[STORAGE] Recording started");
    return true;
}

uint32_t AudioStorage::write(const uint8_t* data, uint32_t size) {
    if (!_recording) {
        DEBUG_PRINTLN("[STORAGE] Not recording!");
        return 0;
    }

    // Vérifie l'espace disponible
    uint32_t available = getAvailableSpace();
    if (available == 0) {
        DEBUG_PRINTLN("[STORAGE] Buffer full!");
        return 0;
    }

    // Limite la taille à l'espace disponible
    uint32_t toWrite = min(size, available);

    // Copie les données
    memcpy(&_audioBuffer[_writePos], data, toWrite);
    _writePos += toWrite;

    return toWrite;
}

bool AudioStorage::finalizeRecording(uint32_t totalPcmSamples, int16_t initialSample, int8_t initialIndex) {
    if (!_recording) {
        DEBUG_PRINTLN("[STORAGE] Not recording!");
        return false;
    }

    _recording = false;

    // Met à jour le header
    _header.totalSamples = totalPcmSamples;
    _header.dataSize = _writePos;
    _header.initialSample = initialSample;
    _header.initialIndex = initialIndex;

    _hasValidRecording = (_writePos > 0);

    DEBUG_PRINTF("[STORAGE] Recording finalized: %lu PCM samples, %lu bytes ADPCM\n",
                 totalPcmSamples, _writePos);

    return _hasValidRecording;
}

uint32_t AudioStorage::getTotalSize() {
    if (!_hasValidRecording) return 0;
    return AUDIO_HEADER_SIZE + _header.dataSize;
}

uint32_t AudioStorage::read(uint32_t offset, uint8_t* buffer, uint32_t size) {
    if (!_hasValidRecording) return 0;

    uint32_t totalSize = getTotalSize();
    if (offset >= totalSize) return 0;

    uint32_t available = totalSize - offset;
    uint32_t toRead = min(size, available);

    if (offset < AUDIO_HEADER_SIZE) {
        // Lecture du header
        uint32_t headerBytes = min(toRead, AUDIO_HEADER_SIZE - offset);
        memcpy(buffer, ((uint8_t*)&_header) + offset, headerBytes);

        if (toRead > headerBytes) {
            // Continuation dans les données audio
            uint32_t audioBytes = toRead - headerBytes;
            memcpy(buffer + headerBytes, _audioBuffer, audioBytes);
        }
    } else {
        // Lecture des données audio uniquement
        uint32_t audioOffset = offset - AUDIO_HEADER_SIZE;
        memcpy(buffer, &_audioBuffer[audioOffset], toRead);
    }

    return toRead;
}

void AudioStorage::clear() {
    _writePos = 0;
    _hasValidRecording = false;
    _recording = false;
    memset(&_header, 0, sizeof(_header));
    // On ne clear pas le buffer entier pour économiser du temps
    // Les nouvelles données écraseront les anciennes

    DEBUG_PRINTLN("[STORAGE] Buffer cleared");
}
