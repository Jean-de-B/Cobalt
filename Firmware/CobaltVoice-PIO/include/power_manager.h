/**
 * @file power_manager.h
 * @brief Gestion d'énergie et surveillance batterie pour Cobalt Voice
 */

#ifndef POWER_MANAGER_H
#define POWER_MANAGER_H

#include "config.h"

class PowerManager {
public:
    /**
     * @brief Initialise le gestionnaire d'énergie
     */
    void begin();

    /**
     * @brief Lit la tension batterie
     * @return Tension en volts (0 si erreur)
     */
    float readBatteryVoltage();

    /**
     * @brief Calcule le pourcentage de charge
     * @return Pourcentage 0-100
     */
    uint8_t getBatteryPercent();

    /**
     * @brief Vérifie si la batterie est critique
     * @return true si tension < VBAT_CRITICAL
     */
    bool isBatteryCritical();

    /**
     * @brief Vérifie si la batterie est faible
     * @return true si < 20%
     */
    bool isBatteryLow();

    /**
     * @brief Détecte si USB est connecté (charge)
     * @return true si VBUS présent
     */
    bool isCharging();

    /**
     * @brief Met le système en System ON Sleep
     * Le CPU dort jusqu'à interruption GPIO ou timer
     */
    void enterLightSleep();

    /**
     * @brief Met le système en System OFF (deep sleep)
     * Seul un reset ou GPIO peut réveiller
     * UTILISÉ EN CAS DE BATTERIE CRITIQUE
     */
    void enterDeepSleep();

    /**
     * @brief Configure le réveil par GPIO
     * @param pin Pin de réveil (bouton)
     * @param activeLevel Niveau actif (LOW ou HIGH)
     */
    void configureWakeupPin(uint32_t pin, uint32_t activeLevel);

    /**
     * @brief Désactive tous les périphériques pour économiser l'énergie
     */
    void disableAllPeripherals();

    /**
     * @brief Met à jour la surveillance (appelé périodiquement)
     * @return true si batterie OK, false si critique
     */
    bool update();

    /**
     * @brief Obtient la dernière tension lue
     */
    float getLastVoltage() { return _lastVoltage; }

    /**
     * @brief Obtient le dernier pourcentage lu
     */
    uint8_t getLastPercent() { return _lastPercent; }

private:
    float _lastVoltage = 0;
    uint8_t _lastPercent = 100;
    uint32_t _lastCheckTime = 0;
    bool _adcInitialized = false;

    /**
     * @brief Convertit la tension en pourcentage
     * Utilise une courbe de décharge LiPo approximative
     */
    uint8_t voltageToPercent(float voltage);

    /**
     * @brief Active le pont diviseur de batterie
     */
    void enableBatteryDivider();

    /**
     * @brief Désactive le pont diviseur (économie)
     */
    void disableBatteryDivider();
};

// Instance globale
extern PowerManager powerManager;

#endif // POWER_MANAGER_H
