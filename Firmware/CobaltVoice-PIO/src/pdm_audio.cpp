/**
 * @file pdm_audio.cpp
 * @brief Capture PDM simplifiée - callback direct sans double buffering
 */

#include "pdm_audio.h"

// Instance globale
PdmAudio pdmAudio;

// Buffer pour la bibliothèque PDM
static int16_t _pdmBuffer[PDM_BUFFER_SIZE];

/**
 * @brief Callback PDM - appelé directement par la bibliothèque
 */
void onPDMdata() {
    int bytesAvailable = PDM.available();
    if (bytesAvailable > 0) {
        int bytesRead = PDM.read(_pdmBuffer, bytesAvailable);
        int samplesRead = bytesRead / 2;

        // Appelle directement le callback utilisateur si capture active
        if (pdmAudio.isCapturing() && pdmAudio._userCallback != nullptr) {
            pdmAudio._userCallback(_pdmBuffer, samplesRead);
            pdmAudio._totalSamples += samplesRead;
        }
    }
}

bool PdmAudio::begin() {
    _capturing = false;
    _userCallback = nullptr;
    _totalSamples = 0;

    // Enregistre le callback PDM
    PDM.onReceive(onPDMdata);

    DEBUG_PRINTLN("[PDM] Audio module initialized");
    return true;
}

void PdmAudio::setGain(uint8_t gain) {
    PDM.setGain(gain);
    DEBUG_PRINTF("[PDM] Gain set to %d\n", gain);
}

bool PdmAudio::startCapture() {
    if (_capturing) {
        DEBUG_PRINTLN("[PDM] Already capturing");
        return true;
    }

    _totalSamples = 0;

    // Configure le gain
    PDM.setGain(40);

    DEBUG_PRINTF("[PDM] Starting with %d channels, %d Hz\n", AUDIO_CHANNELS, AUDIO_SAMPLE_RATE);

    // Démarre la capture PDM
    if (!PDM.begin(AUDIO_CHANNELS, AUDIO_SAMPLE_RATE)) {
        DEBUG_PRINTLN("[PDM] Failed to start!");
        return false;
    }

    _capturing = true;
    DEBUG_PRINTLN("[PDM] Capture started");
    return true;
}

void PdmAudio::stopCapture() {
    if (!_capturing) return;

    _capturing = false;
    PDM.end();

    DEBUG_PRINTF("[PDM] Capture stopped. Total samples: %lu\n", _totalSamples);
}

void PdmAudio::setBufferReadyCallback(PdmBufferReadyCallback callback) {
    _userCallback = callback;
}

// Méthodes de compatibilité (ne font rien dans cette version simplifiée)
bool PdmAudio::processBuffers() {
    return false;  // Pas de buffers à traiter - callback direct
}

void PdmAudio::resetCounters() {
    _totalSamples = 0;
}

void PdmAudio::printDebugCounters() {
    Serial.printf("[PDM-DBG] TotalSamples=%lu, Capturing=%d\n",
                  _totalSamples, _capturing ? 1 : 0);
}

void PdmAudio::resetDebugCounters() {
    // Rien à faire
}
