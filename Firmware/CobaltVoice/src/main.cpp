/**
 * @file main.cpp
 * @brief Cobalt Voice - Enregistreur vocal BLE basse consommation
 *
 * Optimisations appliquées:
 * #1  - WFE dans le loop (remplace delay(10))
 * #3  - Advertising multi-phase (fast → slow → stop → System OFF)
 * #4  - UART désactivé en production (Serial conditionné par DEBUG_SERIAL)
 * #5  - Intervalles de connexion BLE adaptatifs (fast/idle)
 * #6  - Réveil System OFF via les 3 boutons (D1, D2, D3)
 * #7  - NFC désactivé en production
 * #8  - Flash QSPI en deep power-down quand non utilisée
 * #9  - Suppression clearBonds() au boot
 * #10 - Heartbeat conditionnel (DEBUG_SERIAL seulement)
 *
 * Mode Push-to-Wake:
 * - Repos = System OFF (~0.4µA)
 * - Bouton réveille la puce (reset GPIO)
 * - Au réveil: LED batterie 1.5s (vert/jaune/rouge)
 * - Si bouton maintenu: enregistrement push-to-talk
 * - Relâche: transfert BLE direct (si connecté) ou flash (si offline)
 * - Reconnexion BLE → sync automatique des notes en flash
 * - Advertising terminé sans connexion → System OFF
 */

#include <Arduino.h>
#include <bluefruit.h>
#include "config.h"
#include "led_controller.h"
#include "power_manager.h"
#include "adpcm_codec.h"
#include "audio_storage.h"
#include "pdm_audio.h"
#include "ble_services.h"
#include "flash_storage.h"
#include "external_flash.h"
#include "button_manager.h"
#include "config_storage.h"

#if NFC_ENABLED
#include "nfc_tag.h"
#endif

// === CONFIGURATION ===
const uint32_t MIN_RECORDING_MS = 300;

// === ÉTAT SYSTÈME ===
volatile bool recording = false;  // volatile: lu dans ISR PDM (onAudioData)
bool transferring = false;
bool syncing = false;
bool lowPowerMode = loadLowPowerMode(true);  // true = System OFF après chaque action (défaut)
                           // false = reste connecté en BLE (mode normal)
uint32_t totalSamples = 0;
uint32_t recordingStartTime = 0;
uint32_t timedRecordingDuration = 0;

// === MÉTRIQUES DE PERFORMANCE ===
uint32_t lastRecordingDuration = 0;
uint32_t transferStartTime = 0;
uint32_t lastTransferDuration = 0;
uint32_t lastTransferBytes = 0;

// === MACHINE À ÉTATS RECONNEXION (non-bloquant) ===
enum ReconnectState {
    RECONNECT_IDLE = 0,
    RECONNECT_WAIT_CONNECTION,
    RECONNECT_WAIT_NOTIFY,
    RECONNECT_COMPLETE,
    RECONNECT_FAILED
};
ReconnectState reconnectState = RECONNECT_IDLE;
uint32_t reconnectStartTime = 0;
uint32_t reconnectTimeout = 0;
bool pendingRecording = false;           // Un enregistrement est terminé et en attente de transfert
bool pendingRecordingFlashFallback = false; // Fallback flash nécessaire si reconnexion échoue

// Buffer ADPCM
uint8_t adpcmBuffer[PDM_BUFFER_SIZE / 4 + 4];
AdpcmState_t initialState;

// Buffer de test BLE (debug uniquement)
#if DEBUG_SERIAL
uint8_t testBuffer[64];
#endif

// Flag pour System OFF déclenché par fin d'advertising
volatile bool advStoppedFlag = false;


// Forward declarations
void enterSystemOff();

// === CALLBACK ADVERTISING STOPPED ===
void onAdvertisingStopped() {
    // Appelé quand toutes les phases d'advertising sont terminées sans connexion
    advStoppedFlag = true;
}

// === CALLBACK PDM ===
void onAudioData(int16_t* buffer, uint32_t samples) {
    if (!recording) return;

    // Guard: limiter au buffer ADPCM disponible (PDM peut retourner un nombre variable)
    uint32_t maxSamples = (sizeof(adpcmBuffer) - 4) * 2;  // 2 samples par byte ADPCM
    if (samples > maxSamples) samples = maxSamples;

    uint32_t bytes = adpcmCodec.encode(buffer, samples, adpcmBuffer);
    audioStorage.write(adpcmBuffer, bytes);
    totalSamples += samples;
}

// === TRANSFERT BLE DIRECT DEPUIS RAM (fast path) ===
void startDirectTransfer() {
    uint32_t dataSize = audioStorage.getAudioDataSize();
    const uint8_t* data = audioStorage.getDataPointer();
    const uint8_t* header = (const uint8_t*)audioStorage.getHeader();
    uint32_t headerSize = sizeof(AudioFileHeader_t);

    DEBUG_PRINTF("[BLE] Transfert direct: %lu + %lu bytes\n", headerSize, dataSize);

    if (bleServices.startAudioTransferWithHeader(header, headerSize, data, dataSize)) {
        transferring = true;
        syncing = false;
        transferStartTime = millis();
        lastTransferBytes = headerSize + dataSize;
        ledController.setColorImmediate(LED_COLOR_BLUE);
    } else {
        // Échec BLE → fallback flash
        DEBUG_PRINTLN("[BLE] Échec transfert → sauvegarde flash");
        // Réveille la flash pour sauvegarde (optim #8)
        powerManager.flashWakeUp();
        if (!flashStorage.isFull() && flashStorage.saveCurrentRecording()) {
            DEBUG_PRINTF("[FLASH] Sauvegardé (fallback). En attente: %lu\n",
                           flashStorage.getPendingCount());
        }
        powerManager.flashDeepPowerDown();
        audioStorage.clear();
        ledController.off();
    }
}

// === SAUVEGARDE SUR FLASH (mode offline) ===
void saveToFlash() {
    if (!audioStorage.hasRecording()) return;

    // Réveille la flash (optim #8)
    powerManager.flashWakeUp();

    if (flashStorage.isFull()) {
        DEBUG_PRINTLN("[FLASH] Mémoire pleine, impossible de sauvegarder!");
        ledController.set(LED_COLOR_RED, LED_MODE_BLINK_FAST);
        powerManager.flashDeepPowerDown();
        return;
    }

    if (flashStorage.saveCurrentRecording()) {
        DEBUG_PRINTF("[FLASH] Sauvegardé (offline). En attente: %lu\n",
                       flashStorage.getPendingCount());
    } else {
        DEBUG_PRINTLN("[FLASH] Erreur de sauvegarde!");
    }

    powerManager.flashDeepPowerDown();
}

// === DÉMARRER LA RECONNEXION BLE (non-bloquant) ===
void startReconnection(uint32_t timeoutMs) {
    reconnectState = RECONNECT_WAIT_CONNECTION;
    reconnectStartTime = millis();
    reconnectTimeout = timeoutMs;
    DEBUG_PRINTF("[TIMING] Démarrage reconnexion BLE (timeout %lums)...\n", timeoutMs);
}

// === MISE À JOUR DE LA RECONNEXION BLE (appelée depuis loop) ===
void updateReconnection() {
    if (reconnectState == RECONNECT_IDLE) return;

    uint32_t now = millis();
    uint32_t elapsed = now - reconnectStartTime;

    // Timeout global
    if (elapsed >= reconnectTimeout) {
        DEBUG_PRINTF("[TIMING] Timeout reconnexion après %lums\n", elapsed);
        reconnectState = RECONNECT_FAILED;
        return;
    }

    switch (reconnectState) {
        case RECONNECT_WAIT_CONNECTION:
            // Attente de la connexion BLE
            if (bleServices.isConnected()) {
                DEBUG_PRINTF("[TIMING] BLE connecté à t=%lums (%lums d'attente)\n", now, elapsed);
                reconnectState = RECONNECT_WAIT_NOTIFY;
            }
            break;

        case RECONNECT_WAIT_NOTIFY:
            // Attente que le post-connect setup soit terminé + notify enabled
            if (bleServices.isConnected() && bleServices.isNotifyEnabled()) {
                DEBUG_PRINTF("[TIMING] BLE prêt (notify enabled) à t=%lums (%lums total)\n", now, elapsed);
                reconnectState = RECONNECT_COMPLETE;
            }
            // Vérifier si déconnecté pendant l'attente
            else if (!bleServices.isConnected()) {
                DEBUG_PRINTLN("[TIMING] Déconnecté pendant attente notify");
                reconnectState = RECONNECT_WAIT_CONNECTION;
            }
            break;

        case RECONNECT_COMPLETE:
        case RECONNECT_FAILED:
            // États terminaux, rien à faire ici
            break;

        default:
            break;
    }
}

// === ATTENTE BLE PRÊT (connecté + notify souscrit) - version originale bloquante (conservée pour référence) ===
/*
bool waitForBleReady(uint32_t timeoutMs) {
    uint32_t start = millis();
    DEBUG_PRINTF("[TIMING] Attente BLE prêt (timeout %lums)...\n", timeoutMs);

    // Phase 1: attendre la connexion
    while (!bleServices.isConnected() && (millis() - start < timeoutMs)) {
        bleServices.update();  // Traiter la machine à états post-connect
        delay(10);
    }
    if (!bleServices.isConnected()) {
        DEBUG_PRINTF("[TIMING] Timeout connexion après %lums\n", millis() - start);
        return false;
    }
    DEBUG_PRINTF("[TIMING] BLE connecté à t=%lums (%lums d'attente)\n", millis(), millis() - start);

    // Phase 2: attendre que le post-connect setup soit terminé + notify enabled
    // Le phone doit souscrire aux notifications TX après discovery des services
    while (millis() - start < timeoutMs) {
        bleServices.update();  // Traiter PHY/DLE/MTU
        debugBle.flush();
        if (bleServices.isConnected() && bleServices.isNotifyEnabled()) {
            DEBUG_PRINTF("[TIMING] BLE prêt (notify enabled) à t=%lums (%lums total)\n",
                millis(), millis() - start);
            return true;
        }
        delay(10);
    }
    DEBUG_PRINTF("[TIMING] Timeout notify après %lums\n", millis() - start);
    return false;
}
*/

// === GESTION FIN D'ENREGISTREMENT (hybride BLE/Flash) ===
void handleRecordingComplete() {
    if (totalSamples == 0 || !audioStorage.hasRecording()) {
        DEBUG_PRINTLN("[REC] Enregistrement vide, pas d'envoi");
        audioStorage.clear();
        ledController.off();
        return;
    }

    DEBUG_PRINTF("[TIMING] Enregistrement terminé à t=%lums. Données: %lu bytes\n",
        millis(), audioStorage.getAudioDataSize());

    // Démarrer la reconnexion BLE non-bloquante
    // Timeout 5s — laisse le temps au phone de se connecter + discovery + subscribe
    ledController.set(LED_COLOR_BLUE, LED_MODE_BLINK_FAST);
    pendingRecording = true;
    pendingRecordingFlashFallback = false;
    startReconnection(5000);
}

// === SYNCHRONISATION FLASH → BLE (reconnexion) ===
void checkAndSync() {
    if (!bleServices.isConnected()) return;
    if (recording || transferring) return;
    if (!flashStorage.hasPendingFiles()) return;

    DEBUG_PRINTF("[SYNC] %lu fichier(s) en attente de sync\n", flashStorage.getPendingCount());

    // Réveille la flash pour la sync (optim #8)
    powerManager.flashWakeUp();

    if (!flashStorage.loadNextIntoAudioStorage()) {
        DEBUG_PRINTLN("[SYNC] Erreur chargement fichier");
        powerManager.flashDeepPowerDown();
        return;
    }

    uint32_t dataSize = audioStorage.getAudioDataSize();
    const uint8_t* data = audioStorage.getDataPointer();
    const uint8_t* header = (const uint8_t*)audioStorage.getHeader();
    uint32_t headerSize = sizeof(AudioFileHeader_t);

    DEBUG_PRINTF("[SYNC] Transfert: %lu + %lu bytes (header + data)\n", headerSize, dataSize);

    if (bleServices.startAudioTransferWithHeader(header, headerSize, data, dataSize)) {
        transferring = true;
        syncing = true;
        transferStartTime = millis();
        lastTransferBytes = headerSize + dataSize;
        ledController.setColorImmediate(LED_COLOR_BLUE);
    } else {
        DEBUG_PRINTLN("[SYNC] Échec démarrage transfert");
        powerManager.flashDeepPowerDown();
    }
}

// === DÉMARRER ENREGISTREMENT ===
void startRecording() {
    DEBUG_PRINTLN("[REC] Démarrage...");

    totalSamples = 0;
    audioStorage.clear();
    adpcmCodec.reset();
    initialState = adpcmCodec.getState();

    audioStorage.startRecording();
    pdmAudio.startCapture();
    recording = true;
    recordingStartTime = millis();

    ledController.setColorImmediate(LED_COLOR_RED);
}

// === ARRÊTER ENREGISTREMENT ===
void stopRecording() {
    pdmAudio.stopCapture();
    recording = false;
    delayMicroseconds(100);  // Laisse une éventuelle ISR PDM en cours se terminer

    audioStorage.finalizeRecording(totalSamples, initialState.prevSample, initialState.stepIndex);

    uint32_t duration = (totalSamples * 1000) / AUDIO_SAMPLE_RATE;
    uint32_t bytes = audioStorage.getAudioDataSize();
    lastRecordingDuration = millis() - recordingStartTime;

    if (totalSamples > 0) {
        ledController.setColorImmediate(LED_COLOR_GREEN);
        DEBUG_PRINTF("[REC] Terminé: %lu samples, %lu bytes, %lu ms\n", totalSamples, bytes, duration);
    } else {
        DEBUG_PRINTLN("[REC] ERREUR: Aucun sample!");
    }
}

// === AFFICHE LE STATUT BATTERIE VIA LED (1.5s) ===
void showBatteryStatus() {
    uint8_t percent = powerManager.getBatteryPercent();
    float voltage = powerManager.getLastVoltage();

    LedColor_t color;
    if (percent > 50) {
        color = LED_COLOR_GREEN;
    } else if (percent > 20) {
        color = LED_COLOR_YELLOW;
    } else {
        color = LED_COLOR_RED;
    }

    ledController.setColorImmediate(color);
    DEBUG_PRINTF("[BOOT] Batterie: %.2fV (%d%%) → %s\n",
                  voltage, percent,
                  percent > 50 ? "VERT" : (percent > 20 ? "JAUNE" : "ROUGE"));

    delay(BATTERY_LED_DURATION_MS);
    ledController.off();
}

// === ENTRÉE EN SYSTEM OFF ===
void enterSystemOff() {
    DEBUG_PRINTLN("[PWR] → System OFF demandé");

    // Flush les logs debug vers le téléphone AVANT de couper le BLE
    if (bleServices.isConnected()) {
        for (int i = 0; i < 10; i++) {
            debugBle.flush();
            delay(20);
        }
        bleServices.waitForTxFlush();
    }

    ledController.off();

    // Nettoyage BLE
    Bluefruit.Advertising.restartOnDisconnect(false);
    bleServices.stopAdvertising();
    if (bleServices.isConnected()) {
        Bluefruit.disconnect(bleServices.getConnectionHandle());
        delay(300);
    }

    if (powerManager.isCharging()) {
        // USB branché : simuler le System OFF (pas de vrai sleep sinon boucle VBUS)
        // On coupe tout et on attend un appui bouton pour "réveiller"
        DEBUG_PRINTLN("[PWR] USB détecté → simulation sleep (attente bouton)");
        ledController.off();

        // Attendre qu'un bouton soit pressé (simule le GPIO wake)
        while (!btnMain.readRawPressed()) {
            delay(10);
        }

        // Simuler un reboot : relancer l'advertising + check PTT
        DEBUG_PRINTLN("[PWR] Bouton pressé → réveil simulé");
        Bluefruit.Advertising.restartOnDisconnect(true);
        bleServices.startAdvertising();

        // L'enregistrement démarrera dans loop() via BTN_EVENT_PRESS_DOWN
        return;
    }

    // Vrai System OFF (batterie uniquement)
    DEBUG_PRINTLN("[PWR] → System OFF réel");
    powerManager.enterDeepSleep();
}

// === SETUP ===
void setup() {
    // LEDs manuelles (rouge = démarrage)
    pinMode(PIN_LED_RED, OUTPUT);
    pinMode(PIN_LED_GREEN, OUTPUT);
    pinMode(PIN_LED_BLUE, OUTPUT);
    digitalWrite(PIN_LED_RED, LOW);
    digitalWrite(PIN_LED_GREEN, HIGH);
    digitalWrite(PIN_LED_BLUE, HIGH);

    // === BLUEFRUIT EN PREMIER (obligatoire avant Serial) ===
    // event_length=40 (50ms) : permet au SoftDevice de pack plusieurs paquets par event
    // hvn_qsize=30 : queue HVN plus large pour buffering notifications
    Bluefruit.configPrphConn(BLE_MTU_SIZE, 40, 30, 0);
    Bluefruit.begin();
    Bluefruit.autoConnLed(false);  // Désactive le clignotement bleu automatique pendant l'advertising
    Bluefruit.setTxPower(BLE_TX_POWER);

    // Génère un nom unique basé sur l'adresse MAC hardware (FICR->DEVICEADDR)
    // Format: "Cobalt XXXX" — unique par puce, survit à tous les flashs
    char bleDeviceName[20];
    uint32_t devAddr = NRF_FICR->DEVICEADDR[0];
    uint16_t suffix = (uint16_t)(devAddr & 0xFFFF);
    snprintf(bleDeviceName, sizeof(bleDeviceName), "%s%04X", BLE_DEVICE_NAME_PREFIX, suffix);
    Bluefruit.setName(bleDeviceName);

    // === SERIAL (conditionnel - optim #4) ===
#if DEBUG_SERIAL
    delay(300);
    Serial.begin(DEBUG_BAUD_RATE);
    // Pas de while(!Serial) — peut bloquer si USB CDC pas prêt
    delay(2000);
    Serial.println();
    Serial.println("=== COBALT VOICE DEBUG ===");
    Serial.printf("[BLE] Device name: %s\n", bleDeviceName);

    // Raison du réveil (API SoftDevice safe)
    uint32_t resetReas = 0;
    sd_power_reset_reason_get(&resetReas);
    Serial.printf("[BOOT] Reset reason: 0x%04lX →", resetReas);
    if (resetReas & 0x01)    Serial.print(" RESET_PIN");
    if (resetReas & 0x02)    Serial.print(" WATCHDOG");
    if (resetReas & 0x04)    Serial.print(" SOFT_RESET");
    if (resetReas & 0x10000) Serial.print(" GPIO(bouton)");
    if (resetReas & 0x80000) Serial.print(" NFC");
    if (resetReas == 0)      Serial.print(" POWER_ON");
    Serial.println();

    // NE PAS clear ici — bootResetReas le relira plus bas pour le PTT check
#endif

    // === MODULES (init rapide, pas de LED progress) ===
    ledController.begin();
    powerManager.begin();
    adpcmCodec.begin();
    audioStorage.begin();
    pdmAudio.begin();
    pdmAudio.setBufferReadyCallback(onAudioData);
    bleServices.beginAfterBluefruit();

    // Init debug BLE (connecte le buffer au caractéristique)
    debugBle.begin(bleServices.getDebugLogChar());

    // Lire la raison du réveil (utilisée ici ET pour le PTT check plus bas)
    uint32_t bootResetReas = 0;
    sd_power_reset_reason_get(&bootResetReas);
    sd_power_reset_reason_clr(bootResetReas);  // Clear une seule fois
    if (bootResetReas & 0x10000) {
        DEBUG_PRINTLN("[BOOT] Réveil par GPIO (bouton)");
    } else if (bootResetReas & 0x02) {
        DEBUG_PRINTLN("[BOOT] Réveil par WATCHDOG");
    } else if (bootResetReas & 0x04) {
        DEBUG_PRINTLN("[BOOT] Réveil par SOFT RESET");
    } else if (bootResetReas & 0x01) {
        DEBUG_PRINTLN("[BOOT] Réveil par RESET PIN");
    } else {
        DEBUG_PRINTF("[BOOT] Réveil: reason=0x%04lX (POWER_ON ou inconnu)\n", bootResetReas);
    }
    DEBUG_PRINTF("[BOOT] WDT actif=%lu timeout=%lums\n",
        NRF_WDT->RUNSTATUS, (NRF_WDT->CRV + 1) / 33);  // CRV en ticks 32kHz

    // Callback quand l'advertising est terminé sans connexion
    bleServices.setAdvertisingStoppedCallback(onAdvertisingStopped);

    // Démarre l'advertising immédiatement (le phone peut commencer à se connecter)
    bleServices.updateBatteryLevel(powerManager.getLastPercent(), powerManager.isCharging());
    bleServices.startAdvertising();

    // Boutons AVANT le check PTT (pour que le manager détecte le relâchement)
    btnMain.begin(PIN_BUTTON, BUTTON_ACTIVE_LOW);
    btnVolUp.begin(PIN_BUTTON_VOL_UP, BUTTON_ACTIVE_LOW, true);
    btnVolDown.begin(PIN_BUTTON_VOL_DOWN, BUTTON_ACTIVE_LOW, true);

    // === PTT CHECK — lire le reset reason stocké (pas re-lire le registre effacé) ===
    // bootResetReas a été lu plus haut, avant le clear
    bool pttCheck1 = (digitalRead(PIN_BUTTON) == (BUTTON_ACTIVE_LOW ? LOW : HIGH));
    delay(50);
    bool pttCheck2 = (digitalRead(PIN_BUTTON) == (BUTTON_ACTIVE_LOW ? LOW : HIGH));
    bool pttHeld = pttCheck1 && pttCheck2;

    if (pttHeld) {
        bool isGpioWake = (bootResetReas & 0x10000) != 0;
        if (isGpioWake) {
            DEBUG_PRINTLN("[BOOT] PTT confirmé (GPIO wake) → enregistrement");
            timedRecordingDuration = 0;
            startRecording();
        } else {
            DEBUG_PRINTF("[BOOT] PTT ignoré (reason=0x%04lX, pas GPIO)\n", bootResetReas);
            pttHeld = false;
        }
    }

    // === INIT DIFFÉRÉE (s'exécute pendant l'enregistrement) ===

    // Flash storage (offline)
    if (flashStorage.begin()) {
        DEBUG_PRINTF("[INIT] Flash OK - %lu fichier(s) en attente\n",
                       flashStorage.getPendingCount());
    } else {
        DEBUG_PRINTLN("[INIT] ERREUR Flash storage!");
        NRF_QSPI->ENABLE = 0;
    }

    // Batterie critique → shutdown (sauf USB)
    if (powerManager.isBatteryCritical() && !powerManager.isCharging()) {
        DEBUG_PRINTF("[BOOT] BATTERIE CRITIQUE (%.2fV) → shutdown!\n",
                      powerManager.getLastVoltage());
        if (recording) {
            pdmAudio.stopCapture();
            recording = false;
        }
        enterSystemOff();
    }

#if NFC_ENABLED
    nfcTagSetup();
#endif

    DEBUG_PRINTLN("[INIT] OK");

    if (!pttHeld) {
        // Réveil par bouton volume ou appui court → LED bleue pendant advertising
        ledController.set(LED_COLOR_BLUE, LED_MODE_BLINK_SLOW);
        DEBUG_PRINTLN("[BOOT] Réveil sans PTT → advertising seul");
    }

    DEBUG_PRINTLN("PRÊT");
}

// === LOOP ===
void loop() {
    static uint32_t lastActivityTime = millis();
    uint32_t now = millis();

#if DEBUG_SERIAL
    static uint32_t lastHB = 0;
    static uint32_t counter = 0;
#endif

    // === SURVEILLANCE BATTERIE ===
    powerManager.update();

    // === BLE POST-CONNECT SETUP (machine à états non-bloquante) ===
    bleServices.update();

    // === DÉTECTION CONNEXION/DÉCONNEXION ===
    static bool wasConnected = false;
    bool isNowConnected = bleServices.isConnected();
    if (isNowConnected && !wasConnected && !recording && !transferring) {
        ledController.off();
    } else if (!isNowConnected && wasConnected && !recording && !transferring) {
        ledController.set(LED_COLOR_BLUE, LED_MODE_BLINK_SLOW);
        // En mode normal, relancer l'advertising si pas déjà actif
        if (!lowPowerMode && !bleServices.isAdvertising()) {
            DEBUG_PRINTLN("[BLE] Déconnexion en mode normal → restart advertising");
            bleServices.startAdvertising();
        }
    }
    wasConnected = isNowConnected;

    static uint32_t lastBatteryBleUpdate = 0;
    if (isNowConnected && (now - lastBatteryBleUpdate >= BATTERY_CHECK_INTERVAL)) {
        lastBatteryBleUpdate = now;
        bleServices.updateBatteryLevel(powerManager.getLastPercent(), powerManager.isCharging());
    }

    // === BATTERIE CRITIQUE → SHUTDOWN PROTECTION LIPO ===
    if (powerManager.isBatteryCritical() && !powerManager.isCharging()) {
        DEBUG_PRINTF("[PWR] BATTERIE CRITIQUE (%.2fV) → arrêt d'urgence!\n",
                      powerManager.getLastVoltage());
        // Arrête proprement l'enregistrement en cours
        if (recording) {
            pdmAudio.stopCapture();
            recording = false;
            delayMicroseconds(100);
            // Tente de sauvegarder sur flash si possible
            if (totalSamples > 0) {
                audioStorage.finalizeRecording(totalSamples, initialState.prevSample, initialState.stepIndex);
                powerManager.flashWakeUp();
                if (!flashStorage.isFull()) {
                    flashStorage.saveCurrentRecording();
                }
                powerManager.flashDeepPowerDown();
            }
        }
        // Feedback visuel: 3 clignotements rouges rapides
        for (int i = 0; i < 3; i++) {
            ledController.setColorImmediate(LED_COLOR_RED);
            delay(150);
            ledController.off();
            delay(150);
        }
        enterSystemOff();
    }

    // Optim #10: Heartbeat conditionnel (DEBUG_SERIAL seulement)
#if DEBUG_SERIAL
    if (now - lastHB >= 2000) {
        lastHB = now;
        counter++;
        Serial.printf("[HB] #%lu t=%lums Rec:%d Xfer:%d BLE:%d Adv:%d Bat:%.2fV(%d%%)\n",
                      counter, now, recording, transferring,
                      bleServices.isConnected(), bleServices.isAdvertising(),
                      powerManager.getLastVoltage(), powerManager.getLastPercent());
    }
#endif

    // Optim #4: Commandes série uniquement en debug
#if DEBUG_SERIAL
    if (Serial.available()) {
        lastActivityTime = now;
        char c = Serial.read();
        switch (c) {
            case 'h':
            case 'H':
                Serial.println("\n=== AIDE ===");
                Serial.println("h - Aide");
                Serial.println("s - Status (+ info flash)");
                Serial.println("b - Batterie");
                Serial.println("l - Test LEDs");
                Serial.println("r - Enregistrement 3s (test)");
                Serial.println("t - Sync flash vers BLE");
                Serial.println("x - Test BLE (envoie 0x00-0x3F)");
                Serial.println("d - Effacer enregistrement RAM");
                Serial.println();
                break;

            case 's':
            case 'S':
                Serial.printf("\nUptime: %lu ms\n", millis());
                Serial.printf("Bouton: %s\n", btnMain.isPressed() ? "APPUYÉ" : "relâché");
                Serial.printf("Recording: %s\n", recording ? "OUI" : "NON");
                Serial.printf("Total samples: %lu\n", totalSamples);
                Serial.printf("Audio stocké: %lu bytes\n", audioStorage.getAudioDataSize());
                Serial.printf("Has recording: %s\n", audioStorage.hasRecording() ? "OUI" : "NON");
                Serial.printf("BLE connecté: %s\n", bleServices.isConnected() ? "OUI" : "NON");
                Serial.printf("Advertising: %s\n", bleServices.isAdvertising() ? "OUI" : "NON");
                Serial.printf("Transfert en cours: %s\n", transferring ? "OUI" : "NON");
                Serial.printf("Flash: %lu/%lu bytes, %lu fichier(s) en attente\n",
                    flashStorage.getUsedBytes(), flashStorage.getTotalBytes(),
                    flashStorage.getPendingCount());
                Serial.printf("Flash pleine: %s\n\n", flashStorage.isFull() ? "OUI" : "NON");
                break;

            case 'b':
            case 'B':
                Serial.printf("\nBatterie: %.2fV (%d%%)\n",
                    powerManager.getLastVoltage(),
                    powerManager.getLastPercent());
                Serial.printf("Charge USB: %s\n\n", powerManager.isCharging() ? "OUI" : "NON");
                break;

            case 'l':
            case 'L':
                Serial.println("\nTest LEDs...");
                ledController.setColorImmediate(LED_COLOR_RED); delay(300);
                ledController.setColorImmediate(LED_COLOR_GREEN); delay(300);
                ledController.setColorImmediate(LED_COLOR_BLUE); delay(300);
                ledController.off();
                Serial.println("Terminé\n");
                break;

            case 'r':
            case 'R':
                if (!recording && !transferring) {
                    if (!bleServices.isConnected() && flashStorage.isFull()) {
                        Serial.println("[REC] Offline + flash pleine!");
                    } else {
                        timedRecordingDuration = 3000;
                        startRecording();
                    }
                } else {
                    Serial.println("[REC] Occupé");
                }
                break;

            case 't':
            case 'T':
                if (!bleServices.isConnected()) {
                    Serial.println("[BLE] Non connecté");
                } else if (recording) {
                    Serial.println("[BLE] Enregistrement en cours");
                } else if (transferring) {
                    Serial.println("[BLE] Transfert en cours");
                } else if (flashStorage.hasPendingFiles()) {
                    Serial.printf("[SYNC] Lancement sync manuelle (%lu fichiers)\n",
                                   flashStorage.getPendingCount());
                    checkAndSync();
                } else {
                    Serial.println("[BLE] Aucun fichier en attente de sync");
                }
                break;

            case 'x':
            case 'X':
                if (!bleServices.isConnected()) {
                    Serial.println("[TEST] Non connecté");
                } else if (transferring) {
                    Serial.println("[TEST] Transfert en cours");
                } else {
                    Serial.println("[TEST] Envoi 64 bytes");
                    for (int i = 0; i < 64; i++) {
                        testBuffer[i] = (uint8_t)i;
                    }
                    if (bleServices.startAudioTransfer(testBuffer, 64)) {
                        transferring = true;
                        transferStartTime = millis();
                        lastTransferBytes = 64;
                        lastRecordingDuration = 0;
                        ledController.setColorImmediate(LED_COLOR_BLUE);
                    } else {
                        Serial.println("[TEST] Échec!");
                    }
                }
                break;

            case 'd':
            case 'D':
                if (!recording) {
                    audioStorage.clear();
                    totalSamples = 0;
                    Serial.println("\nEnregistrement effacé\n");
                } else {
                    Serial.println("\nImpossible pendant l'enregistrement\n");
                }
                break;

            case 'f':
            case 'F':
                Serial.println("\n=== TEST FLASH RAW ===");
                powerManager.flashWakeUp();
                if (ExternalFS.testRawWrite()) {
                    Serial.println("=== FLASH RAW: OK ===\n");
                } else {
                    Serial.println("=== FLASH RAW: ECHEC ===\n");
                }
                powerManager.flashDeepPowerDown();
                break;
        }
    }
#endif

    // === GESTION BOUTON (ButtonManager multi-gestes) ===
    ButtonEvent_t btnEvent = btnMain.update();

    if (btnEvent != BTN_EVENT_NONE) {
        lastActivityTime = now;

        switch (btnEvent) {
            case BTN_EVENT_PRESS_DOWN:
                if (!recording && !transferring) {
                    if (!bleServices.isConnected() && flashStorage.isFull()) {
                        DEBUG_PRINTLN("[BTN] Offline + flash pleine! Enregistrement bloqué.");
                        ledController.set(LED_COLOR_RED, LED_MODE_BLINK_FAST);
                    } else {
                        timedRecordingDuration = 0;
                        startRecording();
                        DEBUG_PRINTLN("[BTN] PRESS_DOWN → enregistrement anticipé");
                    }
                }
                break;

            case BTN_EVENT_SINGLE:
            case BTN_EVENT_DOUBLE:
                if (recording && timedRecordingDuration == 0) {
                    DEBUG_PRINTF("[BTN] Clic %d détecté → annulation enregistrement\n", btnEvent);
                    pdmAudio.stopCapture();
                    recording = false;
                    delayMicroseconds(100);
                    audioStorage.clear();
                    totalSamples = 0;
                    ledController.off();
                }
                if (bleServices.isConnected()) {
                    bleServices.sendButtonEvent((uint8_t)btnEvent);
                    DEBUG_PRINTF("[BTN] Event %d envoyé via BLE\n", btnEvent);
                }
                break;

            case BTN_EVENT_TRIPLE:
                // Triple-tap = basculer low power ↔ normal
                if (recording) {
                    pdmAudio.stopCapture();
                    recording = false;
                    delayMicroseconds(100);
                    audioStorage.clear();
                    totalSamples = 0;
                }

                lowPowerMode = !lowPowerMode;
                if (lowPowerMode) {
                    DEBUG_PRINTLN("[MODE] Triple-tap → LOW POWER (sleep après chaque action)");
                    // Feedback: 2 flashs rouges
                    for (int i = 0; i < 2; i++) {
                        ledController.setColorImmediate(LED_COLOR_RED);
                        delay(150);
                        ledController.off();
                        delay(150);
                    }
                } else {
                    DEBUG_PRINTLN("[MODE] Triple-tap → NORMAL (reste connecté)");
                    // Feedback: 2 flashs verts
                    for (int i = 0; i < 2; i++) {
                        ledController.setColorImmediate(LED_COLOR_GREEN);
                        delay(150);
                        ledController.off();
                        delay(150);
                    }
                    // En mode normal, relancer l'advertising si pas connecté
                    if (!bleServices.isConnected()) {
                        bleServices.startAdvertising();
                        ledController.set(LED_COLOR_BLUE, LED_MODE_BLINK_SLOW);
                    }
                }
                // Sauvegarde le nouveau mode
                if (!saveLowPowerMode(lowPowerMode)) {
                    DEBUG_PRINTLN("[CONFIG] Erreur sauvegarde lowPowerMode!");
                }
                break;

            case BTN_EVENT_LONG_START:
                DEBUG_PRINTLN("[BTN] LONG_START confirmé (enregistrement déjà actif)");
                break;

            case BTN_EVENT_LONG_STOP:
                if (recording && timedRecordingDuration == 0) {
                    uint32_t recordingDuration = millis() - recordingStartTime;
                    if (recordingDuration < MIN_RECORDING_MS) {
                        DEBUG_PRINTF("[REC] Ignoré (trop court: %lu ms)\n", recordingDuration);
                        pdmAudio.stopCapture();
                        recording = false;
                        audioStorage.clear();
                        totalSamples = 0;
                        ledController.off();
                    } else {
                        stopRecording();
                        handleRecordingComplete();
                    }
                }
                break;

            default:
                break;
        }
    }

    // === GESTION BOUTONS VOLUME (media only) ===
    // Feedback LED immédiat à l'appui (pas au relâchement)
    static bool volUpWasPressed = false;
    static bool volDownWasPressed = false;

    bool volUpPressed = btnVolUp.isPressed();
    if (volUpPressed && !volUpWasPressed) {
        if (bleServices.isConnected()) {
            ledController.set(LED_COLOR_GREEN, LED_MODE_BRIEF_FLASH);
        }
        DEBUG_PRINTLN("[VOL+] Appui détecté");
    }
    volUpWasPressed = volUpPressed;

    bool volDownPressed = btnVolDown.isPressed();
    if (volDownPressed && !volDownWasPressed) {
        if (bleServices.isConnected()) {
            ledController.set(LED_COLOR_GREEN, LED_MODE_BRIEF_FLASH);
        }
        DEBUG_PRINTLN("[VOL-] Appui détecté");
    }
    volDownWasPressed = volDownPressed;

    // Envoi événement bouton via caractéristique custom (l'app Android gère le volume)
    ButtonEvent_t volUpEvent = btnVolUp.update();
    if (volUpEvent == BTN_EVENT_SINGLE) {
        if (bleServices.isConnected()) {
            bleServices.sendButtonEvent(BTN_EVT_VOLUME_UP);
            bleServices.waitForTxFlush();
            if (lowPowerMode) {
                DEBUG_PRINTLN("[VOL+] Event sent → System OFF (low power)");
                enterSystemOff();
            } else {
                DEBUG_PRINTLN("[VOL+] Event sent (mode normal)");
            }
        }
    }

    ButtonEvent_t volDownEvent = btnVolDown.update();
    if (volDownEvent == BTN_EVENT_SINGLE) {
        if (bleServices.isConnected()) {
            bleServices.sendButtonEvent(BTN_EVT_VOLUME_DOWN);
            bleServices.waitForTxFlush();
            if (lowPowerMode) {
                DEBUG_PRINTLN("[VOL-] Event sent → System OFF (low power)");
                enterSystemOff();
            } else {
                DEBUG_PRINTLN("[VOL-] Event sent (mode normal)");
            }
        }
    }

    // Activité si bouton principal maintenu (enregistrement)
    if (btnMain.isPressed()) {
        lastActivityTime = now;
    }

    // Traite les buffers PDM pendant l'enregistrement
    if (recording) {
        lastActivityTime = now;
        pdmAudio.processBuffers();

        // Auto-stop si buffer RAM plein (~15s max)
        if (audioStorage.isFull()) {
            DEBUG_PRINTLN("[REC] Buffer RAM plein → arrêt auto + envoi");
            stopRecording();
            handleRecordingComplete();
        } else if (timedRecordingDuration > 0 && millis() - recordingStartTime >= timedRecordingDuration) {
            stopRecording();
            timedRecordingDuration = 0;
            handleRecordingComplete();
        }
    }

    // === GESTION RECONNEXION ET ENREGISTREMENT EN ATTENTE ===
    updateReconnection();

    if (pendingRecording) {
        if (reconnectState == RECONNECT_COMPLETE) {
            DEBUG_PRINTF("[TIMING] → Transfert BLE direct à t=%lums\n", millis());
            startDirectTransfer();
            pendingRecording = false;
            reconnectState = RECONNECT_IDLE;
        } else if (reconnectState == RECONNECT_FAILED) {
            DEBUG_PRINTLN("[TIMING] BLE pas prêt → sauvegarde flash");
            saveToFlash();
            audioStorage.clear();
            ledController.off();
            pendingRecording = false;
            pendingRecordingFlashFallback = false;
            reconnectState = RECONNECT_IDLE;
            if (lowPowerMode) {
                DEBUG_PRINTLN("[PWR] Enregistrement sauvé offline → System OFF (low power)");
                enterSystemOff();
            } else {
                DEBUG_PRINTLN("[PWR] Enregistrement sauvé offline (mode normal, reste actif)");
            }
        }
    }

    // === TRANSFERT BLE ===
    if (transferring) {
        lastActivityTime = now;
        if (!bleServices.continueTransfer()) {
            transferring = false;
            lastTransferDuration = millis() - transferStartTime;

            float speed = (lastTransferDuration > 0) ?
                          (float)lastTransferBytes * 1000.0f / (float)lastTransferDuration : 0;

            DEBUG_PRINTF("[XFER] %s terminé: %lu bytes, %lu ms, %.1f KB/s\n",
                         syncing ? "SYNC" : "DIRECT",
                         lastTransferBytes, lastTransferDuration, speed / 1024.0f);

            if (syncing) {
                syncing = false;

                if (bleServices.isConnected()) {
                    // Flash déjà réveillée depuis checkAndSync()
                    flashStorage.deleteCurrentSyncFile();

                    if (flashStorage.hasPendingFiles()) {
                        DEBUG_PRINTF("[SYNC] Encore %lu fichier(s) en attente\n",
                                       flashStorage.getPendingCount());
                    } else {
                        DEBUG_PRINTLN("[SYNC] Tous les fichiers synchronisés!");
                        // Optim #8: Remet la flash en deep power-down
                        powerManager.flashDeepPowerDown();
                    }
                } else {
                    DEBUG_PRINTLN("[SYNC] BLE déconnecté - fichier conservé pour retry");
                    powerManager.flashDeepPowerDown();
                }
            } else {
                // Transfert direct terminé
                audioStorage.clear();
                ledController.off();
                if (lowPowerMode) {
                    DEBUG_PRINTLN("[PWR] Transfert terminé → System OFF (low power)");
                    enterSystemOff();
                } else {
                    DEBUG_PRINTLN("[PWR] Transfert terminé → reste connecté (mode normal)");
                }
            }

            ledController.off();

            // Sync terminée, plus rien en attente
            if (!syncing && !flashStorage.hasPendingFiles()) {
                if (lowPowerMode) {
                    DEBUG_PRINTLN("[PWR] Sync complète → System OFF (low power)");
                    enterSystemOff();
                } else {
                    DEBUG_PRINTLN("[PWR] Sync complète → reste connecté (mode normal)");
                }
            }
        }
    }

    // === SYNC FLASH → BLE (quand idle et connecté, throttled) ===
    // Sync les fichiers en attente puis System OFF après le dernier
    static uint32_t lastSyncAttempt = 0;
    if (!recording && !transferring && (now - lastSyncAttempt >= 500)) {
        lastSyncAttempt = now;
        checkAndSync();
    }

    // === ADVERTISING TERMINÉ SANS CONNEXION ===
    if (advStoppedFlag) {
        advStoppedFlag = false;
        if (!bleServices.isConnected() && !recording && !transferring) {
            if (lowPowerMode && !powerManager.isCharging()) {
                DEBUG_PRINTLN("[PWR] Advertising terminé → System OFF (low power)");
                enterSystemOff();
            } else {
                // Mode normal ou USB: relancer l'advertising
                DEBUG_PRINTLN("[PWR] Advertising terminé → restart (mode normal ou USB)");
                bleServices.startAdvertising();
            }
        }
    }

    // === AUTO-OFF: SYSTEM OFF APRÈS INACTIVITÉ (low power uniquement) ===
    if (lowPowerMode && !recording && !transferring && !bleServices.isConnected() && !powerManager.isCharging()) {
        if (now - lastActivityTime >= SLEEP_TIMEOUT_MS) {
            enterSystemOff();
        }
    }

    // Flush les logs debug vers BLE (non-bloquant)
    debugBle.flush();

    ledController.update();

    // Optim #1: WFE au lieu de delay(10)
    // Pendant un transfert BLE, pas de sleep (débit max)
    // Pendant un enregistrement, le PDM génère des interruptions régulières
    // Sinon, le CPU dort jusqu'à la prochaine interruption (BLE, GPIO, timer)
    if (!transferring) {
        // sd_app_evt_wait() est la version SoftDevice-safe de WFE
        // Elle gère correctement les événements SoftDevice pending
        sd_app_evt_wait();
    }
}
