/**
 * @file nfc_tag.h
 * @brief Tag NFC Type 2 hardcoded pour test antenne
 *
 * Emule un tag NFC-A Type 2 (T2T) avec un message NDEF
 * contenant le texte "Cobalt Voice".
 * Utilise le peripherique NFCT du nRF52840 (pins P0.09/P0.10).
 */

#ifndef NFC_TAG_H
#define NFC_TAG_H

#include <Arduino.h>

/**
 * @brief Initialise le tag NFC Type 2
 * @return true si NFC disponible et configure
 */
bool nfcTagSetup();

/**
 * @brief Verifie si un champ NFC est detecte
 */
bool nfcTagIsFieldPresent();

#endif // NFC_TAG_H
