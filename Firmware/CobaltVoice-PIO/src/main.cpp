/**
 * @file main.cpp
 * @brief Cobalt Voice - Enregistreur vocal BLE basse consommation
 *
 * Mode Push-to-Wake:
 * - Repos = System OFF (~0.4µA)
 * - Bouton réveille la puce (reset GPIO)
 * - Au réveil: LED batterie 1.5s (vert/jaune/rouge)
 * - Si bouton maintenu: enregistrement push-to-talk
 * - Relâche: transfert BLE direct (si connecté) ou flash (si offline)
 * - Reconnexion BLE → sync automatique des notes en flash
 * - 10s d'inactivité sans BLE → System OFF
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
#include "button_manager.h"
#include "nfc_tag.h"

// === CONFIGURATION ===
const uint32_t MIN_RECORDING_MS = 300;

// === ÉTAT SYSTÈME ===
bool recording = false;
bool transferring = false;
bool syncing = false;
uint32_t totalSamples = 0;
uint32_t recordingStartTime = 0;
uint32_t timedRecordingDuration = 0;

// === MÉTRIQUES DE PERFORMANCE ===
uint32_t lastRecordingDuration = 0;
uint32_t transferStartTime = 0;
uint32_t lastTransferDuration = 0;
uint32_t lastTransferBytes = 0;

// Buffer ADPCM
uint8_t adpcmBuffer[PDM_BUFFER_SIZE / 4 + 4];
AdpcmState_t initialState;

// Buffer de test BLE
uint8_t testBuffer[64];

// === CALLBACK PDM ===
void onAudioData(int16_t* buffer, uint32_t samples) {
    if (!recording) return;

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

    Serial.printf("[BLE] Transfert direct: %lu + %lu bytes\n", headerSize, dataSize);

    if (bleServices.startAudioTransferWithHeader(header, headerSize, data, dataSize)) {
        transferring = true;
        syncing = false;  // Transfert direct, pas une sync flash
        transferStartTime = millis();
        lastTransferBytes = headerSize + dataSize;
        ledController.setColorImmediate(LED_COLOR_BLUE);
    } else {
        // Échec BLE → fallback flash
        Serial.println("[BLE] Échec transfert → sauvegarde flash");
        if (!flashStorage.isFull() && flashStorage.saveCurrentRecording()) {
            Serial.printf("[FLASH] Sauvegardé (fallback). En attente: %lu\n",
                           flashStorage.getPendingCount());
        }
        audioStorage.clear();
        ledController.off();
    }
}

// === SAUVEGARDE SUR FLASH (mode offline) ===
void saveToFlash() {
    if (!audioStorage.hasRecording()) return;

    if (flashStorage.isFull()) {
        Serial.println("[FLASH] Mémoire pleine, impossible de sauvegarder!");
        ledController.set(LED_COLOR_RED, LED_MODE_BLINK_FAST);
        return;
    }

    if (flashStorage.saveCurrentRecording()) {
        Serial.printf("[FLASH] Sauvegardé (offline). En attente: %lu\n",
                       flashStorage.getPendingCount());
    } else {
        Serial.println("[FLASH] Erreur de sauvegarde!");
    }
}

// === GESTION FIN D'ENREGISTREMENT (hybride BLE/Flash) ===
void handleRecordingComplete() {
    if (totalSamples == 0 || !audioStorage.hasRecording()) {
        Serial.println("[REC] Enregistrement vide, pas d'envoi");
        audioStorage.clear();
        ledController.off();
        return;
    }

    if (bleServices.isConnected()) {
        // Fast path: transfert BLE immédiat depuis RAM
        startDirectTransfer();
    } else {
        // Mode dégradé: sauvegarde flash pour sync ultérieure
        saveToFlash();
        audioStorage.clear();
        ledController.off();
    }
}

// === SYNCHRONISATION FLASH → BLE (reconnexion) ===
void checkAndSync() {
    if (!bleServices.isConnected()) return;
    if (recording || transferring) return;
    if (!flashStorage.hasPendingFiles()) return;

    Serial.printf("[SYNC] %lu fichier(s) en attente de sync\n", flashStorage.getPendingCount());

    if (!flashStorage.loadNextIntoAudioStorage()) {
        Serial.println("[SYNC] Erreur chargement fichier");
        return;
    }

    uint32_t dataSize = audioStorage.getAudioDataSize();
    const uint8_t* data = audioStorage.getDataPointer();
    const uint8_t* header = (const uint8_t*)audioStorage.getHeader();
    uint32_t headerSize = sizeof(AudioFileHeader_t);

    Serial.printf("[SYNC] Transfert: %lu + %lu bytes (header + data)\n", headerSize, dataSize);

    if (bleServices.startAudioTransferWithHeader(header, headerSize, data, dataSize)) {
        transferring = true;
        syncing = true;  // C'est une sync flash
        transferStartTime = millis();
        lastTransferBytes = headerSize + dataSize;
        ledController.setColorImmediate(LED_COLOR_BLUE);
    } else {
        Serial.println("[SYNC] Échec démarrage transfert");
    }
}

// === DÉMARRER ENREGISTREMENT ===
void startRecording() {
    Serial.println("[REC] Démarrage...");

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

    audioStorage.finalizeRecording(totalSamples, initialState.prevSample, initialState.stepIndex);

    uint32_t duration = (totalSamples * 1000) / AUDIO_SAMPLE_RATE;
    uint32_t bytes = audioStorage.getAudioDataSize();
    lastRecordingDuration = millis() - recordingStartTime;

    if (totalSamples > 0) {
        ledController.setColorImmediate(LED_COLOR_GREEN);
        Serial.printf("[REC] Terminé: %lu samples, %lu bytes, %lu ms\n", totalSamples, bytes, duration);
    } else {
        Serial.println("[REC] ERREUR: Aucun sample!");
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
    Serial.printf("[BOOT] Batterie: %.2fV (%d%%) → %s\n",
                  voltage, percent,
                  percent > 50 ? "VERT" : (percent > 20 ? "JAUNE" : "ROUGE"));

    // Affiche pendant BATTERY_LED_DURATION_MS (bloquant au boot uniquement)
    delay(BATTERY_LED_DURATION_MS);
    ledController.off();
}

// === ENTRÉE EN SYSTEM OFF ===
void enterSystemOff() {
    Serial.println("[PWR] Inactivité → System OFF");
    ledController.off();
    delay(100);
    powerManager.enterDeepSleep();
    // Ne revient jamais - le réveil = reset complet
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
    Bluefruit.configPrphConn(BLE_MTU_SIZE, 6, 16, 0);
    Bluefruit.begin();
    Bluefruit.setTxPower(BLE_TX_POWER);
    Bluefruit.setName(BLE_DEVICE_NAME);

    // === SERIAL APRÈS BLUEFRUIT ===
    delay(300);
    Serial.begin(115200);
    uint32_t start = millis();
    while (!Serial && millis() - start < 3000) delay(10);
    delay(300);

    Serial.println();
    Serial.println("=== COBALT VOICE ===");

    // === MODULES ===
    ledController.begin();
    powerManager.begin();
    adpcmCodec.begin();
    audioStorage.begin();
    pdmAudio.begin();
    pdmAudio.setBufferReadyCallback(onAudioData);
    bleServices.beginAfterBluefruit();
    // Initialise la valeur batterie BLE AVANT advertising (le téléphone la lira à la connexion)
    bleServices.updateBatteryLevel(powerManager.getLastPercent(), powerManager.isCharging());
    bleServices.startAdvertising();  // APRÈS services configurés

    // === FLASH STORAGE (offline) ===
    if (flashStorage.begin()) {
        Serial.printf("[INIT] Flash OK - %lu fichier(s) en attente\n",
                       flashStorage.getPendingCount());
    } else {
        Serial.println("[INIT] ERREUR Flash storage!");
    }

    // Bouton (machine à états multi-gestes)
    buttonManager.begin(PIN_BUTTON, BUTTON_ACTIVE_LOW);

    // === BATTERIE CRITIQUE → désactivé temporairement (debug lecture ADC) ===
    if (powerManager.isBatteryCritical()) {
        Serial.printf("[BOOT] WARNING: Batterie lue comme critique (%.2fV) - protection désactivée pour debug\n",
                      powerManager.getLastVoltage());
    }

    // === NFC TAG (test antenne) ===
    nfcTagSetup();

    // === AFFICHAGE STATUT BATTERIE AU RÉVEIL (1.5s) ===
    showBatteryStatus();

    Serial.println("[INIT] OK");

    // === CHECK: BOUTON ENCORE PRESSÉ → DÉMARRER ENREGISTREMENT ===
    if (buttonManager.isPressed()) {
        // Bloque seulement si offline ET flash pleine
        if (!bleServices.isConnected() && flashStorage.isFull()) {
            Serial.println("[BOOT] Offline + flash pleine! Enregistrement bloqué.");
            ledController.set(LED_COLOR_RED, LED_MODE_BLINK_FAST);
            delay(1000);
            ledController.off();
        } else {
            Serial.println("[BOOT] Bouton maintenu → enregistrement");
            timedRecordingDuration = 0;  // Push-to-talk
            startRecording();
        }
    }

    Serial.println("PRÊT - Bouton=enregistrer, h=aide");
    Serial.println();
}

// === LOOP ===
void loop() {
    static uint32_t lastHB = 0;
    static uint32_t lastActivityTime = millis();
    static uint32_t counter = 0;
    uint32_t now = millis();

    // === SURVEILLANCE BATTERIE ===
    powerManager.update();
    // Met à jour le BLE Battery Service (ne notifie que si la valeur change)
    if (bleServices.isConnected()) {
        bleServices.updateBatteryLevel(powerManager.getLastPercent(), powerManager.isCharging());
    }

    // Heartbeat série toutes les 10 secondes
    if (now - lastHB >= 10000) {
        lastHB = now;
        counter++;
        Serial.printf("[HB] #%lu Rec:%d BLE:%d Bat:%.2fV(%d%%) Flash:%lu\n",
                      counter, recording, bleServices.isConnected(),
                      powerManager.getLastVoltage(), powerManager.getLastPercent(),
                      flashStorage.getPendingCount());
    }

    // Commandes série
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
                Serial.printf("Bouton: %s\n", buttonManager.isPressed() ? "APPUYÉ" : "relâché");
                Serial.printf("Recording: %s\n", recording ? "OUI" : "NON");
                Serial.printf("Total samples: %lu\n", totalSamples);
                Serial.printf("Audio stocké: %lu bytes\n", audioStorage.getAudioDataSize());
                Serial.printf("Has recording: %s\n", audioStorage.hasRecording() ? "OUI" : "NON");
                Serial.printf("BLE connecté: %s\n", bleServices.isConnected() ? "OUI" : "NON");
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
        }
    }

    // === GESTION BOUTON (ButtonManager multi-gestes) ===
    ButtonEvent_t btnEvent = buttonManager.update();

    if (btnEvent != BTN_EVENT_NONE) {
        lastActivityTime = now;

        switch (btnEvent) {
            case BTN_EVENT_PRESS_DOWN:
                // Appui détecté → démarrer enregistrement IMMÉDIATEMENT (0ms latence)
                // Sera annulé si clic court (single/double/triple) détecté ensuite
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
            case BTN_EVENT_TRIPLE:
                // Clic court confirmé → ANNULER l'enregistrement anticipé + envoyer via BLE
                if (recording && timedRecordingDuration == 0) {
                    DEBUG_PRINTF("[BTN] Clic %d détecté → annulation enregistrement\n", btnEvent);
                    pdmAudio.stopCapture();
                    recording = false;
                    audioStorage.clear();
                    totalSamples = 0;
                    ledController.off();
                }
                // Envoyer l'événement au téléphone
                if (bleServices.isConnected()) {
                    bleServices.sendButtonEvent((uint8_t)btnEvent);
                    DEBUG_PRINTF("[BTN] Event %d envoyé via BLE\n", btnEvent);
                } else {
                    DEBUG_PRINTF("[BTN] Event %d (BLE déconnecté, ignoré)\n", btnEvent);
                }
                break;

            case BTN_EVENT_LONG_START:
                // Confirmation long press → enregistrement déjà en cours depuis PRESS_DOWN
                DEBUG_PRINTLN("[BTN] LONG_START confirmé (enregistrement déjà actif)");
                break;

            case BTN_EVENT_LONG_STOP:
                // Relâchement appui long → arrêter et envoyer l'enregistrement
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

    // Activité si bouton maintenu ou BLE connecté
    if (buttonManager.isPressed() || bleServices.isConnected()) {
        lastActivityTime = now;
    }

    // Traite les buffers PDM pendant l'enregistrement
    if (recording) {
        lastActivityTime = now;
        pdmAudio.processBuffers();

        // Arrêt automatique si enregistrement minuté
        if (timedRecordingDuration > 0 && millis() - recordingStartTime >= timedRecordingDuration) {
            stopRecording();
            timedRecordingDuration = 0;
            handleRecordingComplete();
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

            Serial.println("╔══════════════════════════════════════╗");
            Serial.printf( "║  TRANSFERT %s TERMINÉ\n", syncing ? "SYNC" : "DIRECT");
            Serial.println("╠══════════════════════════════════════╣");
            Serial.printf( "║ Données:    %lu bytes               \n", lastTransferBytes);
            Serial.printf( "║ Transfert:  %lu ms                  \n", lastTransferDuration);
            Serial.printf( "║ Débit:      %.1f KB/s               \n", speed / 1024.0f);
            Serial.println("╚══════════════════════════════════════╝");

            if (syncing) {
                // Sync flash → supprimer le fichier après transfert réussi
                syncing = false;

                if (bleServices.isConnected()) {
                    flashStorage.deleteCurrentSyncFile();

                    if (flashStorage.hasPendingFiles()) {
                        Serial.printf("[SYNC] Encore %lu fichier(s) en attente\n",
                                       flashStorage.getPendingCount());
                    } else {
                        Serial.println("[SYNC] Tous les fichiers synchronisés!");
                    }
                } else {
                    Serial.println("[SYNC] BLE déconnecté - fichier conservé pour retry");
                }
            } else {
                // Transfert direct → libérer la RAM
                audioStorage.clear();
            }

            ledController.off();
        }
    }

    // === SYNC FLASH → BLE (quand idle et connecté) ===
    if (!recording && !transferring) {
        checkAndSync();
    }

    // === AUTO-OFF: SYSTEM OFF APRÈS INACTIVITÉ ===
    // Conditions: pas d'enregistrement, pas de transfert, pas de BLE, pas USB
    if (!recording && !transferring && !bleServices.isConnected() && !powerManager.isCharging()) {
        if (now - lastActivityTime >= SLEEP_TIMEOUT_MS) {
            enterSystemOff();
        }
    }

    ledController.update();

    // Délai adaptatif
    if (!transferring) {
        delay(10);
    }
    yield();
}
