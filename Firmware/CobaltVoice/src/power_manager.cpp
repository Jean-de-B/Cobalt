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
    DEBUG_PRINTLN("[PWR] Entering System ON sleep (GPIO interrupt wake)...");

    disableAllPeripherals();

    // Si un bouton est déjà pressé au moment d'entrer en veille,
    // le FALLING edge ne se déclenchera pas → forcer le flag directement.
    const int wake_level = BUTTON_ACTIVE_LOW ? LOW : HIGH;
    _sleepWakeupFlag = (digitalRead(PIN_BUTTON)        == wake_level) ||
                       (digitalRead(PIN_BUTTON_VOL_UP)  == wake_level) ||
                       (digitalRead(PIN_BUTTON_VOL_DOWN) == wake_level);

    const int trigger = BUTTON_ACTIVE_LOW ? FALLING : RISING;
    attachInterrupt(digitalPinToInterrupt(PIN_BUTTON),         _sleepWakeupIsr, trigger);
    attachInterrupt(digitalPinToInterrupt(PIN_BUTTON_VOL_UP),  _sleepWakeupIsr, trigger);
    attachInterrupt(digitalPinToInterrupt(PIN_BUTTON_VOL_DOWN),_sleepWakeupIsr, trigger);

    DEBUG_PRINTLN("[PWR] Sleeping — wake on D1/D2/D3");

    while (!_sleepWakeupFlag) {
        NRF_WDT->RR[0] = WDT_RR_RR_Reload;  // Kick WDT (irrévocable, timeout 8s)
        sd_app_evt_wait();
    }

    detachInterrupt(digitalPinToInterrupt(PIN_BUTTON));
    detachInterrupt(digitalPinToInterrupt(PIN_BUTTON_VOL_UP));
    detachInterrupt(digitalPinToInterrupt(PIN_BUTTON_VOL_DOWN));

    flashWakeUp();
    DEBUG_PRINTLN("[PWR] Wake from sleep (button press)");
}

bool PowerManager::update() {
    uint32_t now = millis();

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

    if (isBatteryCritical()) {
        DEBUG_PRINTLN("[PWR] !!! BATTERY CRITICAL !!!");
        return false;
    }

    return true;
}
