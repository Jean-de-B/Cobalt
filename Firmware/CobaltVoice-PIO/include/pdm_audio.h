/**
 * @file pdm_audio.h
 * @brief Capture audio PDM simplifiée pour XIAO nRF52840 Sense
 */

#ifndef PDM_AUDIO_H
#define PDM_AUDIO_H

#include "config.h"
#include <PDM.h>

// Callback appelé quand des données audio sont prêtes
typedef void (*PdmBufferReadyCallback)(int16_t* buffer, uint32_t samples);

class PdmAudio {
public:
    /**
     * @brief Initialise le module PDM
     * @return true si succès
     */
    bool begin();

    /**
     * @brief Démarre la capture audio
     * @return true si succès
     */
    bool startCapture();

    /**
     * @brief Arrête la capture audio
     */
    void stopCapture();

    /**
     * @brief Vérifie si la capture est en cours
     */
    bool isCapturing() { return _capturing; }

    /**
     * @brief Définit le callback pour données audio prêtes
     * @param callback Fonction appelée avec les samples audio
     */
    void setBufferReadyCallback(PdmBufferReadyCallback callback);

    /**
     * @brief Obtient le nombre de samples capturés
     */
    uint32_t getTotalSamples() { return _totalSamples; }

    /**
     * @brief Reset les compteurs
     */
    void resetCounters();

    /**
     * @brief Ajuste le gain du microphone
     * @param gain Gain (0-255, défaut ~40)
     */
    void setGain(uint8_t gain);

    /**
     * @brief Affiche les compteurs de debug
     */
    void printDebugCounters();

    /**
     * @brief Reset les compteurs debug
     */
    void resetDebugCounters();

    /**
     * @brief Compatibilité - ne fait rien dans cette version
     */
    bool processBuffers();

    // Accessibles par le callback PDM
    PdmBufferReadyCallback _userCallback;
    volatile uint32_t _totalSamples;

private:
    volatile bool _capturing;
};

// Instance globale
extern PdmAudio pdmAudio;

#endif // PDM_AUDIO_H
