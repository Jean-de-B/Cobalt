/**
 * @file led_controller.h
 * @brief Contrôleur LED RGB pour Cobalt Voice
 *
 * Code couleur intelligent:
 * - Veille: Éteinte
 * - Enregistrement: Rouge fixe
 * - Transfert: Bleu clignotant
 * - Batterie faible: Jaune bref
 * - Charge: Vert
 * - Erreur: Blanc clignotant
 */

#ifndef LED_CONTROLLER_H
#define LED_CONTROLLER_H

#include "config.h"

// Couleurs prédéfinies (valeurs pour LEDs active LOW)
typedef enum {
    LED_COLOR_OFF = 0,
    LED_COLOR_RED,
    LED_COLOR_GREEN,
    LED_COLOR_BLUE,
    LED_COLOR_YELLOW,    // Rouge + Vert
    LED_COLOR_CYAN,      // Vert + Bleu
    LED_COLOR_MAGENTA,   // Rouge + Bleu
    LED_COLOR_WHITE      // Rouge + Vert + Bleu
} LedColor_t;

// Modes d'affichage
typedef enum {
    LED_MODE_OFF,
    LED_MODE_SOLID,
    LED_MODE_BLINK_FAST,
    LED_MODE_BLINK_SLOW,
    LED_MODE_BRIEF_FLASH,  // Un seul flash puis éteint
    LED_MODE_PULSE         // Effet de pulsation (si supporté)
} LedMode_t;

class LedController {
public:
    /**
     * @brief Initialise les LEDs
     */
    void begin();

    /**
     * @brief Met à jour l'état des LEDs (appeler depuis loop)
     */
    void update();

    /**
     * @brief Définit la couleur et le mode
     * @param color Couleur
     * @param mode Mode d'affichage
     */
    void set(LedColor_t color, LedMode_t mode);

    /**
     * @brief Éteint toutes les LEDs
     */
    void off();

    // Méthodes de raccourci pour les états système
    void setIdle();           // Veille - éteint
    void setRecording();      // Rouge fixe
    void setTransferring();   // Bleu clignotant
    void setLowBattery();     // Jaune bref
    void setCharging();       // Vert fixe
    void setError();          // Blanc clignotant

    /**
     * @brief Force une couleur immédiate (sans mode)
     */
    void setColorImmediate(LedColor_t color);

    /**
     * @brief Obtient la couleur actuelle
     */
    LedColor_t getCurrentColor() { return _currentColor; }

    /**
     * @brief Obtient le mode actuel
     */
    LedMode_t getCurrentMode() { return _currentMode; }

private:
    LedColor_t _currentColor;
    LedMode_t _currentMode;

    bool _ledState;           // État actuel ON/OFF
    uint32_t _lastToggleTime; // Pour le clignotement
    uint32_t _blinkInterval;  // Intervalle de clignotement
    bool _flashComplete;      // Pour le mode flash unique

    /**
     * @brief Applique une couleur aux pins LED
     */
    void applyColor(LedColor_t color);

    /**
     * @brief Active/désactive les LEDs
     */
    void setLedState(bool state);
};

// Instance globale
extern LedController ledController;

#endif // LED_CONTROLLER_H
