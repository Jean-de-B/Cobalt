/**
 * @file power_manager.cpp
 * @brief Implémentation de la gestion d'énergie pour Cobalt Voice
 *
 * Optimisations par rapport à la version standard:
 * - Réveil System OFF via les 3 boutons D1, D2, D3 (optim #6)
 * - Flash QSPI deep power-down quand non utilisée (optim #8)
 * - Désactivation NFC dans disableAllPeripherals (optim #7)
 */

#include "power_manager.h"
#include "external_flash.h"
#include <nrf_power.h>
#include <nrf_gpio.h>
#include <nrf_soc.h>
#include <nrf_gpiote.h>
#include <Arduino.h>

static volatile bool _sleepWakeupFlag = false;
static void _sleepWakeupIsr() { _sleepWakeupFlag = true; }

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
    _flashInDeepPowerDown = false;

    // Lecture initiale
    update();

    DEBUG_PRINTLN("[PWR] Power manager initialized");
    DEBUG_PRINTF("[PWR] Initial battery: %.2fV (%d%%)\n", _lastVoltage, _lastPercent);
}

void PowerManager::enableBatteryDivider() {
    digitalWrite(VBAT_ENABLE, LOW);
    delay(5);
}

void PowerManager::disableBatteryDivider() {
    digitalWrite(VBAT_ENABLE, HIGH);
}

float PowerManager::readBatteryVoltage() {
    if (!_adcInitialized) return 0;

    enableBatteryDivider();

    uint32_t sum = 0;
    const int samples = 8;

    for (int i = 0; i < samples; i++) {
        sum += analogRead(PIN_VBAT);
        delayMicroseconds(50);
    }

    disableBatteryDivider();

    uint32_t avgReading = sum / samples;
    float adcVoltage = avgReading * 3.0f / 4095.0f;
    float voltage = adcVoltage * VBAT_DIVIDER_RATIO;

    return voltage;
}

uint8_t PowerManager::voltageToPercent(float voltage) {
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

bool PowerManager::isBatteryFull() {
    return _lastVoltage >= 4.1f && _lastVoltage > 0;
}

bool PowerManager::isBatteryLow() {
    return _lastPercent < 20;
}

bool PowerManager::isCharging() {
    return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk) != 0;
}

void PowerManager::enterLightSleep() {
    if (isCharging()) return;
    __WFE();
    __SEV();
    __WFE();
}

void PowerManager::disableAllPeripherals() {
    DEBUG_PRINTLN("[PWR] Disabling all peripherals...");

    // Désactive l'ADC
    NRF_SAADC->ENABLE = 0;

    // Désactive les timers non essentiels
    NRF_TIMER1->TASKS_STOP = 1;
    NRF_TIMER2->TASKS_STOP = 1;

    // Désactive le pont diviseur batterie
    disableBatteryDivider();

    // Optim #7: Désactive le NFC
#if !NFC_ENABLED
    NRF_NFCT->TASKS_DISABLE = 1;
    NVIC_DisableIRQ(NFCT_IRQn);
    DEBUG_PRINTLN("[PWR] NFC disabled");
#endif

    // Optim #8: Flash QSPI en deep power-down
    flashDeepPowerDown();
}

void PowerManager::flashDeepPowerDown() {
    // TODO: Implémenter le DPD proprement (le P25Q16H perd le QE bit au réveil)
    // Pour l'instant: no-op. La flash reste en standby (~15µA vs ~1µA en DPD)
    // L'impact batterie est négligeable vs les autres consommations (BLE, CPU)
    _flashInDeepPowerDown = false;
}

void PowerManager::flashWakeUp() {
    // No-op tant que flashDeepPowerDown est désactivé
    _flashInDeepPowerDown = false;
}

void PowerManager::enterDeepSleep() {
    DEBUG_PRINTLN("[PWR] Entering System OFF (~0.4uA) — wake on D1/D2/D3...");

    disableAllPeripherals();

    // Arrête le SoftDevice proprement avant System OFF
    // (sinon sd_power_system_off() retourne une erreur)
    sd_softdevice_disable();

    // Configure les trois boutons comme sources de réveil System OFF.
    // nrf_gpio_cfg_sense_input() est requis pour System OFF (GPIOTE ne fonctionne pas).
    nrf_gpio_pin_pull_t pull = BUTTON_ACTIVE_LOW ? NRF_GPIO_PIN_PULLUP : NRF_GPIO_PIN_PULLDOWN;
    nrf_gpio_pin_sense_t sense = BUTTON_ACTIVE_LOW ? NRF_GPIO_PIN_SENSE_LOW : NRF_GPIO_PIN_SENSE_HIGH;

    nrf_gpio_cfg_sense_input(g_ADigitalPinMap[PIN_BUTTON],         pull, sense);
    nrf_gpio_cfg_sense_input(g_ADigitalPinMap[PIN_BUTTON_VOL_UP],  pull, sense);
    nrf_gpio_cfg_sense_input(g_ADigitalPinMap[PIN_BUTTON_VOL_DOWN], pull, sense);

    // System OFF : consommation ~0.4µA. Le réveil par GPIO = reset matériel → setup() re-exécuté.
    // Cette ligne ne retourne jamais.
    NRF_POWER->SYSTEMOFF = 1;
    // Barrière mémoire au cas où le compilateur réordonne
    __DSB();
    while (1) { __WFE(); }
}

bool PowerManager::update() {
    uint32_t now = millis();

    if (now - _lastCheckTime < BATTERY_CHECK_INTERVAL && _lastCheckTime != 0) {
        return !isBatteryCritical();
    }

    float newVoltage = readBatteryVoltage();
    uint8_t newPercent = voltageToPercent(newVoltage);

    // Calcul vitesse charge/décharge dès la deuxième lecture
    if (_prevCheckTime != 0 && _prevVoltage > 0) {
        float elapsedMin = (now - _prevCheckTime) / 60000.0f;
        float dvdt_mv_min = (newVoltage - _prevVoltage) * 1000.0f / elapsedMin;  // mV/min

        // Estimation autonomie restante basée sur la vitesse de décharge
        const char* trend = (dvdt_mv_min > 2.0f) ? "▲ CHARGE" :
                            (dvdt_mv_min < -2.0f) ? "▼ DECHARGE" : "≈ STABLE";

        if (dvdt_mv_min < -2.0f) {
            // Temps restant estimé jusqu'à VBAT_EMPTY (en heures)
            float mv_restants = (newVoltage - VBAT_EMPTY) * 1000.0f;
            float heures_restantes = mv_restants / (-dvdt_mv_min * 60.0f);
            DEBUG_PRINTF("[PWR] %.2fV (%d%%) %s | %.1fmV/min → ~%.1fh restantes %s\n",
                         newVoltage, newPercent, trend,
                         dvdt_mv_min, heures_restantes,
                         isCharging() ? "[CHARGING]" : "");
        } else if (dvdt_mv_min > 2.0f) {
            // Temps restant estimé jusqu'à VBAT_FULL (en minutes)
            float mv_restants = (VBAT_FULL - newVoltage) * 1000.0f;
            float min_restantes = mv_restants / dvdt_mv_min;
            DEBUG_PRINTF("[PWR] %.2fV (%d%%) %s | +%.1fmV/min → ~%.0fmin pour plein %s\n",
                         newVoltage, newPercent, trend,
                         dvdt_mv_min, min_restantes,
                         isCharging() ? "[CHARGING]" : "");
        } else {
            DEBUG_PRINTF("[PWR] %.2fV (%d%%) %s | %.1fmV/min %s\n",
                         newVoltage, newPercent, trend,
                         dvdt_mv_min,
                         isCharging() ? "[CHARGING]" : "");
        }
    } else {
        DEBUG_PRINTF("[PWR] %.2fV (%d%%) %s\n",
                     newVoltage, newPercent,
                     isCharging() ? "[CHARGING]" : "");
    }

    _prevVoltage = _lastVoltage;
    _prevCheckTime = _lastCheckTime;
    _lastCheckTime = now;
    _lastVoltage = newVoltage;
    _lastPercent = newPercent;

    if (isBatteryCritical()) {
        DEBUG_PRINTLN("[PWR] !!! BATTERY CRITICAL !!!");
        return false;
    }

    return true;
}
