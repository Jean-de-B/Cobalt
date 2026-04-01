/**
 * @file adpcm_codec.cpp
 * @brief Implémentation du codec IMA ADPCM optimisé pour ARM Cortex-M4
 */

#include "adpcm_codec.h"

// Instance globale
AdpcmCodec adpcmCodec;

// Table d'ajustement d'index IMA ADPCM standard
// Indexée par le nibble ADPCM (0-15)
const int8_t AdpcmCodec::_indexTable[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

// Table des pas de quantification IMA ADPCM standard
// 89 entrées, indexées par stepIndex (0-88)
const uint16_t AdpcmCodec::_stepTable[89] = {
    7, 8, 9, 10, 11, 12, 13, 14,
    16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66,
    73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658,
    724, 796, 876, 963, 1060, 1166, 1282, 1411,
    1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
    3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484,
    7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
    32767
};

void AdpcmCodec::begin() {
    reset();
    DEBUG_PRINTLN("[ADPCM] Codec initialized");
}

void AdpcmCodec::reset() {
    _state.prevSample = 0;
    _state.stepIndex = 0;
}

uint8_t AdpcmCodec::encodeSample(int16_t sample) {
    // Récupère le pas courant
    uint16_t step = _stepTable[_state.stepIndex];

    // Calcule la différence avec la prédiction
    int32_t diff = sample - _state.prevSample;

    // Détermine le signe
    uint8_t sign = 0;
    if (diff < 0) {
        sign = 8;  // Bit de signe (bit 3)
        diff = -diff;
    }

    // Quantifie la différence
    // delta = (diff * 4) / step
    // Mais on utilise une méthode plus efficace
    uint8_t delta = 0;
    uint16_t tempStep = step;

    if (diff >= tempStep) {
        delta = 4;
        diff -= tempStep;
    }
    tempStep >>= 1;

    if (diff >= tempStep) {
        delta |= 2;
        diff -= tempStep;
    }
    tempStep >>= 1;

    if (diff >= tempStep) {
        delta |= 1;
    }

    // Combine signe et magnitude
    uint8_t nibble = sign | delta;

    // Décode pour mettre à jour le prédicteur (même calcul que le décodeur)
    // Cela assure que encodeur et décodeur restent synchronisés
    int32_t diffq = step >> 3;
    if (delta & 4) diffq += step;
    if (delta & 2) diffq += step >> 1;
    if (delta & 1) diffq += step >> 2;

    if (sign) {
        _state.prevSample -= diffq;
    } else {
        _state.prevSample += diffq;
    }

    // Clamp le prédicteur
    if (_state.prevSample > 32767) _state.prevSample = 32767;
    if (_state.prevSample < -32768) _state.prevSample = -32768;

    // Met à jour l'index
    _state.stepIndex += _indexTable[nibble];

    // Clamp l'index
    if (_state.stepIndex < 0) _state.stepIndex = 0;
    if (_state.stepIndex > 88) _state.stepIndex = 88;

    return nibble;
}

uint32_t AdpcmCodec::encode(const int16_t* pcmInput, uint32_t pcmSamples, uint8_t* adpcmOutput) {
    uint32_t outputBytes = 0;

    // Traite les samples par paires
    for (uint32_t i = 0; i < pcmSamples; i += 2) {
        // Premier sample -> nibble bas
        uint8_t nibble1 = encodeSample(pcmInput[i]);

        // Deuxième sample -> nibble haut (ou 0 si impair)
        uint8_t nibble2 = 0;
        if (i + 1 < pcmSamples) {
            nibble2 = encodeSample(pcmInput[i + 1]);
        }

        // Pack les deux nibbles dans un octet
        // Format: nibble1 dans les bits bas, nibble2 dans les bits hauts
        adpcmOutput[outputBytes++] = (nibble2 << 4) | nibble1;
    }

    return outputBytes;
}
