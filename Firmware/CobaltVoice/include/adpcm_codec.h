/**
 * @file adpcm_codec.h
 * @brief Codec IMA ADPCM pour compression audio 4:1
 *
 * Implémente l'encodage IMA ADPCM standard:
 * - Entrée: PCM 16-bit signé
 * - Sortie: ADPCM 4-bit (2 samples par octet)
 * - Ratio compression: 4:1
 */

#ifndef ADPCM_CODEC_H
#define ADPCM_CODEC_H

#include "config.h"

// Structure d'état de l'encodeur ADPCM
typedef struct {
    int16_t prevSample;    // Échantillon précédent (prédicteur)
    int8_t  stepIndex;     // Index dans la table de pas
} AdpcmState_t;

class AdpcmCodec {
public:
    /**
     * @brief Initialise le codec (reset état)
     */
    void begin();

    /**
     * @brief Reset l'état de l'encodeur (nouveau fichier)
     */
    void reset();

    /**
     * @brief Encode un bloc de samples PCM en ADPCM
     *
     * @param pcmInput    Buffer d'entrée PCM 16-bit signé
     * @param pcmSamples  Nombre de samples à encoder
     * @param adpcmOutput Buffer de sortie ADPCM (doit être pcmSamples/2 octets)
     * @return            Nombre d'octets ADPCM générés
     *
     * Note: pcmSamples doit être pair (2 samples -> 1 octet ADPCM)
     */
    uint32_t encode(const int16_t* pcmInput, uint32_t pcmSamples, uint8_t* adpcmOutput);

    /**
     * @brief Encode un seul sample PCM en nibble ADPCM 4-bit
     *
     * @param sample Sample PCM 16-bit signé
     * @return       Nibble ADPCM 4-bit (0-15)
     */
    uint8_t encodeSample(int16_t sample);

    /**
     * @brief Obtient l'état actuel (pour header de fichier)
     */
    AdpcmState_t getState() { return _state; }

    /**
     * @brief Définit l'état (pour reprise)
     */
    void setState(AdpcmState_t state) { _state = state; }

    /**
     * @brief Calcule la taille ADPCM pour un nombre de samples PCM
     */
    static uint32_t getEncodedSize(uint32_t pcmSamples) {
        return (pcmSamples + 1) / 2;  // 2 samples -> 1 octet
    }

private:
    AdpcmState_t _state;

    // Tables IMA ADPCM standard
    static const int8_t _indexTable[16];
    static const uint16_t _stepTable[89];
};

// Instance globale
extern AdpcmCodec adpcmCodec;

#endif // ADPCM_CODEC_H
