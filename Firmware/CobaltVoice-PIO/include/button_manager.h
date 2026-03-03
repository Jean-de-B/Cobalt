/**
 * @file button_manager.h
 * @brief Gestionnaire de bouton multi-gestes pour Cobalt Voice
 *
 * Detecte : single press, double press, triple press, long press
 * via une machine a etats avec debounce et fenetres temporelles.
 *
 * Strategie "Record-then-cancel" :
 * - BTN_EVENT_PRESS_DOWN emis des le premier appui (0ms latence)
 * - main.cpp demarre l'enregistrement immediatement
 * - Si clic court detecte (SINGLE/DOUBLE/TRIPLE) → main.cpp annule l'enregistrement
 * - Si maintenu >500ms (LONG_START) → enregistrement continue normalement
 */

#ifndef BUTTON_MANAGER_H
#define BUTTON_MANAGER_H

#include <Arduino.h>

// Types d'evenements bouton
typedef enum {
    BTN_EVENT_NONE       = 0x00,
    BTN_EVENT_SINGLE     = 0x01,  // Envoyé via BLE
    BTN_EVENT_DOUBLE     = 0x02,  // Envoyé via BLE
    BTN_EVENT_TRIPLE     = 0x03,  // Envoyé via BLE
    BTN_EVENT_LONG_START = 0x04,  // Informatif (enregistrement déjà en cours)
    BTN_EVENT_LONG_STOP  = 0x05,  // Arrêt enregistrement
    BTN_EVENT_PRESS_DOWN = 0x10   // Interne uniquement - appui detecte (pas envoyé via BLE)
} ButtonEvent_t;

class ButtonManager {
public:
    /**
     * @brief Initialise le bouton
     * @param pin GPIO du bouton
     * @param activeLow true si le bouton est actif a l'etat bas (pull-up)
     */
    void begin(uint8_t pin, bool activeLow = true);

    /**
     * @brief Met a jour la machine a etats (appeler dans loop())
     * @return Evenement detecte, ou BTN_EVENT_NONE
     */
    ButtonEvent_t update();

    /**
     * @brief Etat debounce actuel du bouton
     */
    bool isPressed();

private:
    // Configuration
    uint8_t _pin;
    bool _activeLow;

    // Temporisation
    static const uint32_t DEBOUNCE_MS           = 50;
    static const uint32_t MULTI_PRESS_WINDOW_MS = 300;
    static const uint32_t LONG_PRESS_MS         = 500;

    // Machine a etats
    enum State {
        STATE_IDLE,          // Attente d'appui
        STATE_PRESSED,       // Bouton enfonce, attente long press ou relachement
        STATE_WAIT_RELEASE,  // Long press actif, attente relachement
        STATE_COUNTING       // Relache apres appui court, comptage multi-press
    };

    State    _state;
    uint8_t  _pressCount;
    bool     _debouncedState;
    bool     _lastRawState;
    uint32_t _lastRawChangeTime;
    uint32_t _pressStartTime;
    uint32_t _lastReleaseTime;

    bool _readDebounced();
};

extern ButtonManager buttonManager;

#endif // BUTTON_MANAGER_H
