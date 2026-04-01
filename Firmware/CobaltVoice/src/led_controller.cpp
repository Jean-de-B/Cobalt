/**
 * @file led_controller.cpp
 * @brief Implémentation du contrôleur LED RGB
 */

#include "led_controller.h"

// Instance globale
LedController ledController;

void LedController::begin() {
    // Configure les pins en sortie
    pinMode(PIN_LED_RED, OUTPUT);
    pinMode(PIN_LED_GREEN, OUTPUT);
    pinMode(PIN_LED_BLUE, OUTPUT);

    // Éteint toutes les LEDs au démarrage
    off();

    _currentColor = LED_COLOR_OFF;
    _currentMode = LED_MODE_OFF;
    _ledState = false;
    _lastToggleTime = 0;
    _blinkInterval = LED_BLINK_SLOW_MS;
    _flashComplete = false;

    DEBUG_PRINTLN("[LED] Controller initialized");
}

void LedController::applyColor(LedColor_t color) {
    // Pour LEDs active LOW, HIGH = éteint, LOW = allumé
    bool r = false, g = false, b = false;

    switch (color) {
        case LED_COLOR_RED:
            r = true;
            break;
        case LED_COLOR_GREEN:
            g = true;
            break;
        case LED_COLOR_BLUE:
            b = true;
            break;
        case LED_COLOR_YELLOW:
            r = true; g = true;
            break;
        case LED_COLOR_CYAN:
            g = true; b = true;
            break;
        case LED_COLOR_MAGENTA:
            r = true; b = true;
            break;
        case LED_COLOR_WHITE:
            r = true; g = true; b = true;
            break;
        case LED_COLOR_OFF:
        default:
            break;
    }

    // Applique aux pins (inverse si active low)
    if (LED_ACTIVE_LOW) {
        digitalWrite(PIN_LED_RED, r ? LOW : HIGH);
        digitalWrite(PIN_LED_GREEN, g ? LOW : HIGH);
        digitalWrite(PIN_LED_BLUE, b ? LOW : HIGH);
    } else {
        digitalWrite(PIN_LED_RED, r ? HIGH : LOW);
        digitalWrite(PIN_LED_GREEN, g ? HIGH : LOW);
        digitalWrite(PIN_LED_BLUE, b ? HIGH : LOW);
    }
}

void LedController::setLedState(bool state) {
    _ledState = state;
    if (state) {
        applyColor(_currentColor);
    } else {
        applyColor(LED_COLOR_OFF);
    }
}

void LedController::set(LedColor_t color, LedMode_t mode) {
    _currentColor = color;
    _currentMode = mode;
    _flashComplete = false;
    _lastToggleTime = millis();

    switch (mode) {
        case LED_MODE_BLINK_FAST:
            _blinkInterval = LED_BLINK_FAST_MS;
            _ledState = true;
            break;
        case LED_MODE_BLINK_SLOW:
            _blinkInterval = LED_BLINK_SLOW_MS;
            _ledState = true;
            break;
        case LED_MODE_BRIEF_FLASH:
            _blinkInterval = LED_BRIEF_FLASH_MS;
            _ledState = true;
            break;
        case LED_MODE_SOLID:
            _ledState = true;
            break;
        case LED_MODE_OFF:
        default:
            _ledState = false;
            break;
    }

    setLedState(_ledState);
}

void LedController::update() {
    if (_currentMode == LED_MODE_OFF || _currentMode == LED_MODE_SOLID) {
        return;  // Pas besoin de mise à jour
    }

    uint32_t now = millis();

    if (_currentMode == LED_MODE_BRIEF_FLASH) {
        // Flash unique puis éteint
        if (!_flashComplete && (now - _lastToggleTime >= _blinkInterval)) {
            setLedState(false);
            _flashComplete = true;
            _currentMode = LED_MODE_OFF;
        }
        return;
    }

    // Mode clignotement
    if (now - _lastToggleTime >= _blinkInterval) {
        _lastToggleTime = now;
        _ledState = !_ledState;
        setLedState(_ledState);
    }
}

void LedController::off() {
    set(LED_COLOR_OFF, LED_MODE_OFF);
}

void LedController::setColorImmediate(LedColor_t color) {
    _currentColor = color;
    _currentMode = LED_MODE_SOLID;
    _ledState = true;
    applyColor(color);
}

// === Méthodes de raccourci ===

void LedController::setIdle() {
    off();
}

void LedController::setRecording() {
    set(LED_COLOR_RED, LED_MODE_SOLID);
}

void LedController::setTransferring() {
    set(LED_COLOR_BLUE, LED_MODE_BLINK_FAST);
}

void LedController::setLowBattery() {
    set(LED_COLOR_YELLOW, LED_MODE_BRIEF_FLASH);
}

void LedController::setCharging() {
    set(LED_COLOR_GREEN, LED_MODE_SOLID);
}

void LedController::setError() {
    set(LED_COLOR_WHITE, LED_MODE_BLINK_FAST);
}
