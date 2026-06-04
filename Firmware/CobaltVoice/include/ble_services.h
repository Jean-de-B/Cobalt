/**
 * @file ble_services.h
 * @brief Services BLE pour Cobalt Voice
 *
 * Implémente:
 * - Battery Service (0x180F) standard
 * - Service custom UART-like pour transfert audio + button events
 * - Advertising multi-phase (fast → slow → stop)
 * - Intervalles de connexion adaptatifs (fast/idle)
 */

#ifndef BLE_SERVICES_H
#define BLE_SERVICES_H

#include "config.h"
#include <bluefruit.h>
#include <services/BLEDfu.h>

// Callback pour transfert terminé
typedef void (*TransferCompleteCallback)(bool success);

// Callback pour commande reçue
typedef void (*CommandReceivedCallback)(const uint8_t* data, uint16_t len);

// Callback quand l'advertising s'arrête (toutes les phases terminées)
typedef void (*AdvertisingStoppedCallback)();

class BleServices {
public:
    /**
     * @brief Initialise les services BLE (Bluefruit.begin() doit avoir été appelé avant)
     * @return true si succès
     */
    bool beginAfterBluefruit();

    /**
     * @brief Démarre l'advertising (phase rapide puis lente)
     */
    void startAdvertising();

    /**
     * @brief Arrête l'advertising
     */
    void stopAdvertising();

    /**
     * @brief Vérifie si connecté
     */
    bool isConnected();

    /**
     * @brief Vérifie si l'advertising est actif
     */
    bool isAdvertising() { return _advertising; }

    /**
     * @brief Obtient le handle de connexion
     */
    uint16_t getConnectionHandle() { return _connHandle; }

    /**
     * @brief Obtient un pointeur vers la caractéristique Debug Log
     */
    BLECharacteristic* getDebugLogChar() { return &_debugLogChar; }

    /**
     * @brief Obtient le MTU négocié
     */
    uint16_t getMtuSize() { return _mtuSize; }

    /**
     * @brief Met à jour le niveau de batterie (0-100)
     * @param level Pourcentage de batterie
     * @param charging true si USB connecté (encodé dans bit 7)
     */
    void updateBatteryLevel(uint8_t level, bool charging = false);

    /**
     * @brief Démarre le transfert d'un fichier audio (données brutes)
     * @param data Pointeur vers les données
     * @param size Taille totale
     * @return true si transfert démarré
     */
    bool startAudioTransfer(const uint8_t* data, uint32_t size);

    /**
     * @brief Démarre le transfert avec header CVOX + données ADPCM
     * @param header Pointeur vers le header (34 bytes)
     * @param headerSize Taille du header
     * @param data Pointeur vers les données ADPCM
     * @param dataSize Taille des données ADPCM
     * @return true si transfert démarré
     */
    bool startAudioTransferWithHeader(const uint8_t* header, uint32_t headerSize,
                                      const uint8_t* data, uint32_t dataSize);

    /**
     * @brief Continue le transfert (appelé depuis loop)
     * @return true si transfert en cours, false si terminé
     */
    bool continueTransfer();

    /**
     * @brief Annule le transfert en cours
     */
    void cancelTransfer();

    /**
     * @brief Vérifie si un transfert est en cours
     */
    bool isTransferring() { return _transferring; }

    /**
     * @brief Obtient la progression du transfert (0-100%)
     */
    uint8_t getTransferProgress();

    /**
     * @brief Définit le callback de fin de transfert
     */
    void setTransferCompleteCallback(TransferCompleteCallback callback);

    /**
     * @brief Définit le callback de commande reçue
     */
    void setCommandCallback(CommandReceivedCallback callback);

    /**
     * @brief Définit le callback d'arrêt advertising
     */
    void setAdvertisingStoppedCallback(AdvertisingStoppedCallback callback);

    /**
     * @brief Envoie un événement bouton au téléphone (caractéristique custom)
     * @param event Type d'événement (0x01-0x05)
     * @return true si notification envoyée
     */
    bool sendButtonEvent(uint8_t event);

    /**
     * @brief Entre en mode DFU OTA (bootloader Adafruit)
     * Le device redémarre en mode DFU, accessible sous le nom "DfuTarg"
     */
    void enterDfuMode();

    /**
     * @brief Envoie la version firmware au téléphone via notification
     * Format: 3 bytes [major, minor, patch]
     */
    bool sendFirmwareVersion();

    /**
     * @brief Déconnecte proprement
     */
    void disconnect();

    /**
     * @brief Désactive le BLE (pour économie d'énergie)
     */
    void disable();

    /**
     * @brief Réactive le BLE
     */
    void enable();

    /**
     * @brief Efface tous les bonds et relance un advertising général (mode appairage).
     * À appeler sur triple press hors connexion pour permettre un ré-appairage.
     */
    void clearBondsAndRestartPairing();

    /**
     * @brief Passe en mode connexion rapide (pour transfert)
     * Intervalle 15-30ms - consomme plus mais transfert rapide
     */
    void setFastConnectionMode();

    /**
     * @brief Passe en mode connexion économique (pour idle)
     * Intervalle 500ms-1s - très basse consommation
     */
    void setIdleConnectionMode();

    /**
     * @brief Appelé depuis loop() pour gérer le setup post-connexion non-bloquant
     */
    void update();

    // Callbacks internes (ne pas appeler directement)
    void _onConnect(uint16_t connHandle);
    void _onDisconnect(uint16_t connHandle, uint8_t reason);
    void _onRxData(uint16_t connHandle, uint8_t* data, uint16_t len);
    void _onAdvStopped();

private:
    // Mode de connexion (idle vs fast)
    enum ConnMode {
        CONN_MODE_FAST = 0,
        CONN_MODE_IDLE
    };
    ConnMode _connMode;

    // Machine à états post-connexion (non-bloquante)
    enum PostConnectState {
        PC_IDLE = 0,
        PC_WAIT_STABLE,    // Attente stabilisation connexion
        PC_CONN_PARAMS,    // Mise à jour paramètres connexion
        PC_PHY_UPDATE,     // Demande 2M PHY
        PC_DLE_UPDATE,     // Demande DLE
        PC_WAIT_MTU,       // Attente négociation MTU
        PC_DONE            // Setup terminé
    };
    PostConnectState _postConnectState;
    uint32_t _postConnectTimer;
    // Services
    BLEDfu _dfuService;                    // DFU OTA Service (Adafruit bootloader)
    BLEBas _batteryService;                // Battery Service standard
    BLEService _audioService;              // Service custom audio
    BLECharacteristic _audioTxChar;        // TX (Notify) - envoi audio
    BLECharacteristic _audioRxChar;        // RX (Write) - commandes
    BLECharacteristic _buttonEventChar;    // Button Event (Notify)
    BLECharacteristic _fwVersionChar;      // Firmware Version (Read + Notify)
    BLECharacteristic _debugLogChar;       // Debug Log (Notify) — 6E400006

    // État connexion
    uint16_t _connHandle;
    bool _connected;
    uint16_t _mtuSize;
    bool _advertising;

    // État transfert
    bool _transferring;
    const uint8_t* _transferData;
    uint32_t _transferSize;
    uint32_t _transferPos;
    uint32_t _transferChunkSize;

    // Transfert avec header séparé
    const uint8_t* _headerData;
    uint32_t _headerSize;
    uint32_t _headerPos;
    bool _headerSent;

    // Backoff après BLOCKED (évite spam CPU quand queue SoftDevice pleine)
    uint32_t _transferRetryMs = 0;

    // Batterie (anti-spam BLE)
    uint8_t _lastBatteryEncoded = 0xFF;  // Valeur impossible → force premier envoi

    // Callbacks
    TransferCompleteCallback _transferCallback;
    CommandReceivedCallback _commandCallback;
    AdvertisingStoppedCallback _advStoppedCallback;

    /**
     * @brief Configure les services BLE
     */
    void setupServices();

    /**
     * @brief Configure l'advertising
     */
    void setupAdvertising();

    /**
     * @brief Négocie le MTU optimal
     */
    void negotiateMtu();
};

// Instance globale
extern BleServices bleServices;

#endif // BLE_SERVICES_H
