/**
 * @file power_manager.cpp
 * @brief Implémentation de la gestion d'énergie pour Cobalt Voice
 */

#include "power_manager.h"
#include <nrf_power.h>
#include <nrf_gpio.h>
#include <nrf_soc.h>

// Instance globale
PowerManager powerManager;

void PowerManager::begin() {
    // Configure le pin VBAT_ENABLE (P0.14) pour contrôler le pont diviseur
    // LOW = pont diviseur activé (lecture possible), HIGH = désactivé (économie)
    pinMode(VBAT_ENABLE, OUTPUT);
    digitalWrite(VBAT_ENABLE, HIGH);  // Désactivé par défaut

    // Configure l'ADC pour la lecture batterie
    analogReference(AR_INTERNAL_3_0);  // Référence 3.0V
    analogReadResolution(12);          // 12 bits

    _adcInitialized = true;

    // Lecture initiale
    update();

    DEBUG_PRINTLN("[PWR] Power manager initialized");
    DEBUG_PRINTF("[PWR] Initial battery: %.2fV (%d%%)\n", _lastVoltage, _lastPercent);
}

void PowerManager::enableBatteryDivider() {
    // Active le pont diviseur via VBAT_ENABLE (P0.14) - LOW = activé
    digitalWrite(VBAT_ENABLE, LOW);
    delay(5);  // Temps de stabilisation du pont diviseur (MOSFET + RC)
}

void PowerManager::disableBatteryDivider() {
    // Désactive le pont diviseur pour économiser l'énergie - HIGH = désactivé
    digitalWrite(VBAT_ENABLE, HIGH);
}

float PowerManager::readBatteryVoltage() {
    if (!_adcInitialized) return 0;

    enableBatteryDivider();

    // Moyenne de plusieurs lectures pour stabilité
    uint32_t sum = 0;
    const int samples = 8;

    for (int i = 0; i < samples; i++) {
        sum += analogRead(PIN_VBAT);  // PIN_VBAT défini dans variant.h
        delayMicroseconds(50);
    }

    disableBatteryDivider();

    uint32_t avgReading = sum / samples;

    // Conversion ADC -> Tension
    // ADC 12-bit (0-4095), Référence 3.0V (AR_INTERNAL_3_0)
    // Pont diviseur XIAO: R1=1MΩ, R2=510kΩ → ratio ~2.96
    float adcVoltage = avgReading * 3.0f / 4095.0f;  // Tension vue par l'ADC
    float voltage = adcVoltage * VBAT_DIVIDER_RATIO;  // Tension batterie réelle

    return voltage;
}

uint8_t PowerManager::voltageToPercent(float voltage) {
    // Mapping linéaire: 4.2V = 100%, 3.5V = 0%
    if (voltage >= VBAT_FULL) return 100;
    if (voltage <= VBAT_EMPTY) return 0;

    float percent = (voltage - VBAT_EMPTY) / (VBAT_FULL - VBAT_EMPTY) * 100.0f;
    return (uint8_t)percent;
}

uint8_t PowerManager::getBatteryPercent() {
    float voltage = readBatteryVoltage();
    return voltageToPercent(voltage);
}

bool PowerManager::isBatteryCritical() {
    return _lastVoltage < VBAT_CRITICAL && _lastVoltage > 0;
}

bool PowerManager::isBatteryLow() {
    return _lastPercent < 20;
}

bool PowerManager::isCharging() {
    // Sur XIAO nRF52840 Sense, on détecte la charge via la tension
    // Si la tension est > 4.1V, on est probablement en charge
    // Alternative: utiliser NRF_POWER->USBREGSTATUS si USB est connecté
    return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
}

void PowerManager::configureWakeupPin(uint32_t pin, uint32_t activeLevel) {
    // Configure le GPIO pour réveiller du System OFF
    nrf_gpio_cfg_sense_input(
        pin,
        (activeLevel == LOW) ? NRF_GPIO_PIN_PULLUP : NRF_GPIO_PIN_PULLDOWN,
        (activeLevel == LOW) ? NRF_GPIO_PIN_SENSE_LOW : NRF_GPIO_PIN_SENSE_HIGH
    );
}

void PowerManager::enterLightSleep() {
    // Ne pas dormir si USB est connecté (casse le CDC Serial)
    if (isCharging()) {
        DEBUG_PRINTLN("[PWR] USB connected - skipping sleep");
        return;
    }

    // System ON Sleep - le CPU dort mais peut être réveillé par interruption
    // La SoftDevice gère automatiquement le sleep entre les événements

    DEBUG_PRINTLN("[PWR] Entering light sleep...");

    // Force le CPU à dormir jusqu'à la prochaine interruption
    __WFE();  // Wait For Event
    __SEV();  // Set Event (pour éviter race condition)
    __WFE();  // Wait For Event
}

void PowerManager::disableAllPeripherals() {
    DEBUG_PRINTLN("[PWR] Disabling all peripherals...");

    // Note: Le Bluetooth sera désactivé séparément via Bluefruit
    // Ici on désactive les autres périphériques

    // Désactive l'ADC
    NRF_SAADC->ENABLE = 0;

    // Désactive les timers non essentiels (sauf ceux de la SoftDevice)
    // NRF_TIMER0 est utilisé par SoftDevice - ne pas toucher
    NRF_TIMER1->TASKS_STOP = 1;
    NRF_TIMER2->TASKS_STOP = 1;

    // Désactive le pont diviseur batterie
    disableBatteryDivider();
}

void PowerManager::enterDeepSleep() {
    DEBUG_PRINTLN("[PWR] Entering System OFF...");

    // Désactive les périphériques non essentiels
    disableAllPeripherals();

    // Configure le réveil par le bouton (GPIO sense)
    configureWakeupPin(PIN_BUTTON, BUTTON_ACTIVE_LOW ? LOW : HIGH);

    delay(100);  // Laisse le temps aux messages Serial de sortir

    // System OFF via SoftDevice (obligatoire quand SoftDevice est actif)
    // Consommation ~0.4µA - seul un GPIO SENSE ou Reset peut réveiller
    // Au réveil = RESET complet (setup() re-exécuté)
    sd_power_system_off();

    // Fallback si SoftDevice n'est pas actif
    NRF_POWER->SYSTEMOFF = 1;

    // Ne devrait jamais arriver ici
    while(1) { __WFI(); }
}

bool PowerManager::update() {
    uint32_t now = millis();

    // Vérifie seulement périodiquement pour économiser l'énergie
    if (now - _lastCheckTime < BATTERY_CHECK_INTERVAL && _lastCheckTime != 0) {
        return !isBatteryCritical();
    }

    _lastCheckTime = now;
    _lastVoltage = readBatteryVoltage();
    _lastPercent = voltageToPercent(_lastVoltage);

    DEBUG_PRINTF("[PWR] Battery: %.2fV (%d%%) %s\n",
                 _lastVoltage,
                 _lastPercent,
                 isCharging() ? "[CHARGING]" : "");

    // Vérifie si critique
    if (isBatteryCritical()) {
        DEBUG_PRINTLN("[PWR] !!! BATTERY CRITICAL !!!");
        return false;
    }

    return true;
}
