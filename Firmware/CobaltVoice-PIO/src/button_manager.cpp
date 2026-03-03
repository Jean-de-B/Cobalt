/**
 * @file button_manager.cpp
 * @brief Machine a etats pour detection multi-gestes bouton
 *
 * Strategie "Record-then-cancel" :
 * - Emet BTN_EVENT_PRESS_DOWN des le premier appui depuis IDLE
 * - Emet BTN_EVENT_PRESS_DOWN aussi en STATE_COUNTING (nouvel appui multi-press)
 *   pour que main.cpp redemarre l'enregistrement si besoin
 * - Si relache < 500ms → comptage multi-press, puis SINGLE/DOUBLE/TRIPLE
 * - Si maintenu >= 500ms → LONG_START (enregistrement deja en cours)
 */

#include "button_manager.h"

// Instance globale
ButtonManager buttonManager;

void ButtonManager::begin(uint8_t pin, bool activeLow) {
    _pin = pin;
    _activeLow = activeLow;
    _state = STATE_IDLE;
    _pressCount = 0;
    _debouncedState = false;
    _lastRawState = false;
    _lastRawChangeTime = 0;
    _pressStartTime = 0;
    _lastReleaseTime = 0;

    pinMode(_pin, INPUT_PULLUP);
}

bool ButtonManager::isPressed() {
    return _debouncedState;
}

bool ButtonManager::_readDebounced() {
    bool rawState = _activeLow ? (digitalRead(_pin) == LOW) : (digitalRead(_pin) == HIGH);

    if (rawState != _lastRawState) {
        _lastRawState = rawState;
        _lastRawChangeTime = millis();
    }

    if ((millis() - _lastRawChangeTime) > DEBOUNCE_MS) {
        _debouncedState = rawState;
    }

    return _debouncedState;
}

ButtonEvent_t ButtonManager::update() {
    bool pressed = _readDebounced();
    uint32_t now = millis();

    switch (_state) {

        case STATE_IDLE:
            if (pressed) {
                _pressStartTime = now;
                _pressCount = 0;
                _state = STATE_PRESSED;
                return BTN_EVENT_PRESS_DOWN;  // Démarrage immédiat enregistrement
            }
            break;

        case STATE_PRESSED:
            if (!pressed) {
                // Relache avant le seuil long press → appui court
                _pressCount++;
                _lastReleaseTime = now;
                _state = STATE_COUNTING;
            } else if ((now - _pressStartTime) >= LONG_PRESS_MS) {
                // Maintenu assez longtemps → confirmer long press
                _state = STATE_WAIT_RELEASE;
                return BTN_EVENT_LONG_START;
            }
            break;

        case STATE_WAIT_RELEASE:
            if (!pressed) {
                _state = STATE_IDLE;
                return BTN_EVENT_LONG_STOP;
            }
            break;

        case STATE_COUNTING:
            if (pressed) {
                // Nouvel appui dans la fenetre multi-press
                _pressStartTime = now;
                _state = STATE_PRESSED;
                return BTN_EVENT_PRESS_DOWN;  // Relancer l'enregistrement
            } else if ((now - _lastReleaseTime) >= MULTI_PRESS_WINDOW_MS) {
                // Fenetre expiree, emettre l'evenement
                _state = STATE_IDLE;
                switch (_pressCount) {
                    case 1:  return BTN_EVENT_SINGLE;
                    case 2:  return BTN_EVENT_DOUBLE;
                    default: return BTN_EVENT_TRIPLE; // 3+
                }
            }
            break;
    }

    return BTN_EVENT_NONE;
}
