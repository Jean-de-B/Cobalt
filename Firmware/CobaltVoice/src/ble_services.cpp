/**
 * @file ble_services.cpp
 * @brief Implémentation des services BLE pour Cobalt Voice
 *
 * Optimisations par rapport à la version standard:
 * - Suppression clearBonds() au boot (optim #9)
 * - Advertising multi-phase: fast 30s → slow 2min → stop (optim #3)
 * - Intervalles de connexion adaptatifs fast/idle (optim #5)
 */

#include "ble_services.h"
#include <nrf_soc.h>      // sd_power_gpregret_set/clr

// Instance globale
BleServices bleServices;

// Référence pour les callbacks
static BleServices* _bleInstance = nullptr;

// UUIDs pour service audio custom (format 128-bit)
static const uint8_t AUDIO_SERVICE_UUID[] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x01, 0x00, 0x40, 0x6E
};

static const uint8_t AUDIO_TX_UUID[] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x03, 0x00, 0x40, 0x6E
};

static const uint8_t AUDIO_RX_UUID[] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x02, 0x00, 0x40, 0x6E
};

static const uint8_t BUTTON_EVENT_UUID[] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x04, 0x00, 0x40, 0x6E
};

// Firmware Version characteristic UUID: 6E400005-B5A3-F393-E0A9-E50E24DCCA9E
static const uint8_t FW_VERSION_UUID[] = {
    0x9E, 0xCA, 0xDC, 0x24, 0x0E, 0xE5, 0xA9, 0xE0,
    0x93, 0xF3, 0xA3, 0xB5, 0x05, 0x00, 0x40, 0x6E
};

// Callbacks Bluefruit
void ble_connect_callback(uint16_t connHandle) {
    if (_bleInstance) _bleInstance->_onConnect(connHandle);
}

void ble_disconnect_callback(uint16_t connHandle, uint8_t reason) {
    if (_bleInstance) _bleInstance->_onDisconnect(connHandle, reason);
}

void ble_rx_callback(uint16_t connHandle, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
    if (_bleInstance) _bleInstance->_onRxData(connHandle, data, len);
}

void ble_adv_stopped_callback() {
    if (_bleInstance) _bleInstance->_onAdvStopped();
}

// Initialise les services BLE (Bluefruit.begin() doit avoir été appelé avant)
bool BleServices::beginAfterBluefruit() {
    _bleInstance = this;
    _connected = false;
    _connHandle = BLE_CONN_HANDLE_INVALID;
    _transferring = false;
    _transferCallback = nullptr;
    _commandCallback = nullptr;
    _advStoppedCallback = nullptr;
    _mtuSize = 23;
    _postConnectState = PC_IDLE;
    _postConnectTimer = 0;
    _advertising = false;
    _fastAdvDone = false;
    _connMode = CONN_MODE_FAST;

    // Transfert avec header
    _headerData = nullptr;
    _headerSize = 0;
    _headerPos = 0;
    _headerSent = true;

    // Active Connection Event Extension
    ble_opt_t opt;
    memset(&opt, 0, sizeof(opt));
    opt.common_opt.conn_evt_ext.enable = 1;
    uint32_t err_code = sd_ble_opt_set(BLE_COMMON_OPT_CONN_EVT_EXT, &opt);
    if (err_code == NRF_SUCCESS) {
        DEBUG_PRINTLN("[BLE] Connection Event Extension enabled");
    } else {
        DEBUG_PRINTF("[BLE] Conn Event Ext error: 0x%lx\n", err_code);
    }

    // Optim #9: PAS de clearBonds() - conserver le bonding pour reconnexion rapide

    // Callbacks de connexion
    Bluefruit.Periph.setConnectCallback(ble_connect_callback);
    Bluefruit.Periph.setDisconnectCallback(ble_disconnect_callback);

    // Intervalle fixe rapide - pas de switching adaptatif (cause latence transfert)
    Bluefruit.Periph.setConnInterval(BLE_FAST_CONN_INTERVAL_MIN, BLE_FAST_CONN_INTERVAL_MAX);

    // Configure les services
    setupServices();

    // Configure l'advertising
    setupAdvertising();

    DEBUG_PRINTLN("[BLE] Services initialized");
    return true;
}

void BleServices::setupServices() {
    // === DFU OTA Service (Adafruit bootloader) ===
    // DOIT être ajouté EN PREMIER pour être visible dans le scan
    _dfuService.begin();
    DEBUG_PRINTLN("[BLE] DFU OTA service added");

    // === Battery Service (standard 0x180F) ===
    _batteryService.begin();

    // === Service Audio Custom ===
    _audioService = BLEService(AUDIO_SERVICE_UUID);
    _audioService.begin();

    // Caractéristique TX (Notify) - pour envoyer l'audio
    _audioTxChar = BLECharacteristic(AUDIO_TX_UUID);
    _audioTxChar.setProperties(CHR_PROPS_NOTIFY);
    _audioTxChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    _audioTxChar.setMaxLen(BLE_MTU_SIZE - 3);
    _audioTxChar.begin();

    // Caractéristique RX (Write) - pour recevoir des commandes
    _audioRxChar = BLECharacteristic(AUDIO_RX_UUID);
    _audioRxChar.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
    _audioRxChar.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
    _audioRxChar.setMaxLen(BLE_MTU_SIZE - 3);
    _audioRxChar.setWriteCallback(ble_rx_callback);
    _audioRxChar.begin();

    // Caractéristique Button Event (Notify)
    _buttonEventChar = BLECharacteristic(BUTTON_EVENT_UUID);
    _buttonEventChar.setProperties(CHR_PROPS_NOTIFY);
    _buttonEventChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    _buttonEventChar.setMaxLen(1);
    _buttonEventChar.begin();

    // Caractéristique Firmware Version (Read + Notify)
    _fwVersionChar = BLECharacteristic(FW_VERSION_UUID);
    _fwVersionChar.setProperties(CHR_PROPS_READ | CHR_PROPS_NOTIFY);
    _fwVersionChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    _fwVersionChar.setMaxLen(3);
    uint8_t version[3] = { FIRMWARE_VERSION_MAJOR, FIRMWARE_VERSION_MINOR, FIRMWARE_VERSION_PATCH };
    _fwVersionChar.write(version, 3);
    _fwVersionChar.begin();

    DEBUG_PRINTLN("[BLE] Services configured");
}

void BleServices::setupAdvertising() {
    // === Paquet Advertising (31 bytes max) ===
    Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
    Bluefruit.Advertising.addTxPower();
    Bluefruit.Advertising.addName();

    // === Paquet Scan Response (31 bytes max) ===
    Bluefruit.ScanResponse.addService(_audioService);
    Bluefruit.ScanResponse.addService(_batteryService);

    // Optim #3: Multi-phase advertising
    // restartOnDisconnect=true pour relancer automatiquement
    Bluefruit.Advertising.restartOnDisconnect(true);

    // Phase rapide: intervalle 20-30ms pendant 30s
    Bluefruit.Advertising.setInterval(ADV_FAST_INTERVAL_MIN, ADV_FAST_INTERVAL_MAX);
    Bluefruit.Advertising.setFastTimeout(ADV_FAST_TIMEOUT_S);

    // Callback quand l'advertising s'arrête (fin de phase)
    Bluefruit.Advertising.setStopCallback(ble_adv_stopped_callback);
}

void BleServices::startAdvertising() {
    _fastAdvDone = false;

    // Phase rapide: intervalle 20-30ms
    Bluefruit.Advertising.setInterval(ADV_FAST_INTERVAL_MIN, ADV_FAST_INTERVAL_MAX);
    Bluefruit.Advertising.setFastTimeout(ADV_FAST_TIMEOUT_S);

    // Démarre avec timeout = fast + slow phases (total en secondes)
    // 0 = permanent, mais on veut stopper après les phases
    // On utilise le callback pour gérer la transition
    Bluefruit.Advertising.start(ADV_FAST_TIMEOUT_S);
    _advertising = true;

    DEBUG_PRINTLN("[BLE] Advertising started (fast phase)");
}

void BleServices::startSlowAdvertising() {
    // Phase lente: intervalle 1000-1500ms pendant 2 minutes
    Bluefruit.Advertising.setInterval(ADV_SLOW_INTERVAL_MIN, ADV_SLOW_INTERVAL_MAX);
    Bluefruit.Advertising.setFastTimeout(0);  // Pas de phase rapide

    Bluefruit.Advertising.start(ADV_SLOW_TIMEOUT_S);
    _advertising = true;

    DEBUG_PRINTLN("[BLE] Advertising switched to slow phase");
}

void BleServices::_onAdvStopped() {
    if (_connected) {
        // Connecté, advertising s'est arrêté normalement
        _advertising = false;
        return;
    }

    if (!_fastAdvDone) {
        // Phase rapide terminée → passer en phase lente
        _fastAdvDone = true;
        startSlowAdvertising();
    } else {
        // Phase lente terminée → advertising terminé
        _advertising = false;
        DEBUG_PRINTLN("[BLE] Advertising stopped (all phases done)");

        // Notifie main.cpp pour déclencher le System OFF
        if (_advStoppedCallback) {
            _advStoppedCallback();
        }
    }
}

void BleServices::stopAdvertising() {
    Bluefruit.Advertising.stop();
    _advertising = false;
    DEBUG_PRINTLN("[BLE] Advertising stopped");
}

bool BleServices::isConnected() {
    return _connected && Bluefruit.connected();
}

void BleServices::updateBatteryLevel(uint8_t level, bool charging) {
    if (level > 100) level = 100;
    uint8_t encoded = level | (charging ? 0x80 : 0x00);

    if (encoded == _lastBatteryEncoded) return;
    _lastBatteryEncoded = encoded;

    _batteryService.write(encoded);

    if (_connected) {
        _batteryService.notify(encoded);
        DEBUG_PRINTF("[BLE] Battery: %d%% %s\n", level, charging ? "[CHG]" : "");
    }
}

void BleServices::_onConnect(uint16_t connHandle) {
    _connHandle = connHandle;
    _connected = true;
    _advertising = false;

    // Lancer la machine à états post-connexion (traitée dans update())
    // NE PAS bloquer ici — le callback doit retourner immédiatement
    // pour laisser le SoftDevice traiter les événements BLE
    _postConnectState = PC_WAIT_STABLE;
    _postConnectTimer = millis();

    DEBUG_PRINTF("[BLE] Connected! handle=0x%04X → post-connect setup démarré\n", connHandle);
}

void BleServices::update() {
    if (_postConnectState == PC_IDLE || _postConnectState == PC_DONE) return;
    if (!_connected) {
        _postConnectState = PC_IDLE;
        return;
    }

    uint32_t elapsed = millis() - _postConnectTimer;

    switch (_postConnectState) {

    case PC_WAIT_STABLE:
        // Laisser 200ms au stack BLE pour stabiliser la connexion
        if (elapsed >= 200) {
            _postConnectState = PC_CONN_PARAMS;
            _postConnectTimer = millis();
        }
        break;

    case PC_CONN_PARAMS: {
        // Supervision timeout explicite (évite status=8)
        ble_gap_conn_params_t gap_params;
        memset(&gap_params, 0, sizeof(gap_params));
        gap_params.min_conn_interval = BLE_FAST_CONN_INTERVAL_MIN;
        gap_params.max_conn_interval = BLE_FAST_CONN_INTERVAL_MAX;
        gap_params.slave_latency     = BLE_SLAVE_LATENCY;
        gap_params.conn_sup_timeout  = BLE_SUPERVISION_TIMEOUT;
        uint32_t err = sd_ble_gap_conn_param_update(_connHandle, &gap_params);
        DEBUG_PRINTF("[BLE] Conn params: 0x%lx (sup_timeout=%dms)\n", err, BLE_SUPERVISION_TIMEOUT * 10);
        _postConnectState = PC_PHY_UPDATE;
        _postConnectTimer = millis();
        break;
    }

    case PC_PHY_UPDATE:
        // Attendre 150ms après conn params avant PHY
        if (elapsed >= 150) {
            ble_gap_phys_t phys;
            memset(&phys, 0, sizeof(phys));
            phys.tx_phys = BLE_GAP_PHY_2MBPS;
            phys.rx_phys = BLE_GAP_PHY_2MBPS;
            uint32_t err = sd_ble_gap_phy_update(_connHandle, &phys);
            DEBUG_PRINTF("[BLE] PHY 2M: 0x%lx\n", err);
            _postConnectState = PC_DLE_UPDATE;
            _postConnectTimer = millis();
        }
        break;

    case PC_DLE_UPDATE:
        // Attendre 100ms après PHY avant DLE
        if (elapsed >= 100) {
            Bluefruit.Connection(_connHandle)->requestDataLengthUpdate();
            DEBUG_PRINTLN("[BLE] DLE requested");
            _postConnectState = PC_WAIT_MTU;
            _postConnectTimer = millis();
        }
        break;

    case PC_WAIT_MTU: {
        // Vérifier si le MTU a été négocié (le phone envoie requestMtu)
        uint16_t mtu = Bluefruit.Connection(_connHandle)->getMtu();
        if (mtu > 23) {
            _mtuSize = mtu;
            _transferChunkSize = _mtuSize - 3;
            DEBUG_PRINTF("[BLE] MTU: %d bytes (chunk=%d) after %lums\n",
                         _mtuSize, _transferChunkSize, elapsed);
            _postConnectState = PC_DONE;
        } else if (elapsed >= 3000) {
            // Timeout 3s — utiliser MTU par défaut
            DEBUG_PRINTLN("[BLE] MTU timeout, using default chunk=20");
            _transferChunkSize = 20;
            _postConnectState = PC_DONE;
        }
        // Sinon : on revient au prochain loop(), pas de blocage
        break;
    }

    case PC_DONE:
        DEBUG_PRINTF("[BLE] Post-connect DONE. mtu=%d chunk=%d\n", _mtuSize, _transferChunkSize);
        _postConnectState = PC_IDLE;
        // Switch to idle connection interval to save battery
        setIdleConnectionMode();
        break;

    default:
        break;
    }
}

void BleServices::_onDisconnect(uint16_t connHandle, uint8_t reason) {
    _connected = false;
    _connHandle = BLE_CONN_HANDLE_INVALID;
    _mtuSize = 23;
    _postConnectState = PC_IDLE;
    _connMode = CONN_MODE_FAST;

    DEBUG_PRINTF("[BLE] Disconnected, reason: 0x%02X\n", reason);

    if (_transferring) {
        cancelTransfer();
        if (_transferCallback) {
            _transferCallback(false);
        }
    }

    // L'advertising redémarrera automatiquement (restartOnDisconnect=true)
    // Il repartira en phase rapide grâce au callback
    _fastAdvDone = false;
    _advertising = true;
}

void BleServices::_onRxData(uint16_t connHandle, uint8_t* data, uint16_t len) {
    DEBUG_PRINTF("[BLE] RX data: %d bytes → ", len);
#if DEBUG_SERIAL
    for (uint16_t i = 0; i < len && i < 16; i++) {
        Serial.printf("0x%02X ", data[i]);
    }
    Serial.println();
#endif

    if (len > 0) {
        switch (data[0]) {
            case CMD_ENTER_DFU:
                DEBUG_PRINTLN("[BLE] *** Commande 0xFD (DFU) reçue! ***");
                enterDfuMode();
                return;  // Ne revient jamais (reset)

            case CMD_GET_VERSION:
                DEBUG_PRINTLN("[BLE] Commande 0xFE (GET_VERSION) reçue");
                sendFirmwareVersion();
                return;

            default:
                break;
        }

        if (_commandCallback) {
            _commandCallback(data, len);
        }
    }
}

void BleServices::enterDfuMode() {
    DEBUG_PRINTLN("[DFU] === ENTRÉE EN MODE DFU OTA ===");

    if (_connected) {
        DEBUG_PRINTLN("[DFU] Déconnexion BLE...");
        Bluefruit.Advertising.restartOnDisconnect(false);
        Bluefruit.disconnect(_connHandle);
        delay(600);
    }

    Bluefruit.Advertising.stop();
    delay(100);

    DEBUG_PRINTLN("[DFU] Écriture GPREGRET = 0xB1...");
    sd_power_gpregret_clr(0, 0xFF);
    sd_power_gpregret_set(0, 0xB1);
    DEBUG_PRINTF("[DFU]   Bootloader addr: 0x%08lX\n", (uint32_t)NRF_UICR->NRFFW[0]);

#if DEBUG_SERIAL
    Serial.flush();
#endif
    delay(100);
    NVIC_SystemReset();
    // Ne revient jamais
}

bool BleServices::sendFirmwareVersion() {
    if (!isConnected()) return false;
    uint8_t version[3] = { FIRMWARE_VERSION_MAJOR, FIRMWARE_VERSION_MINOR, FIRMWARE_VERSION_PATCH };
    DEBUG_PRINTF("[BLE] Firmware version: %d.%d.%d\n", version[0], version[1], version[2]);
    return _fwVersionChar.notify(version, 3);
}

void BleServices::negotiateMtu() {
    if (!_connected || _connHandle == BLE_CONN_HANDLE_INVALID) return;

    uint16_t mtu = Bluefruit.Connection(_connHandle)->getMtu();
    if (mtu > 23) {
        _mtuSize = mtu;
    }
    _transferChunkSize = _mtuSize - 3;

    DEBUG_PRINTF("[BLE] MTU check: %d bytes (chunk: %d)\n", _mtuSize, _transferChunkSize);
}

bool BleServices::startAudioTransfer(const uint8_t* data, uint32_t size) {
    if (!isConnected()) {
        DEBUG_PRINTLN("[BLE] Cannot transfer: not connected");
        return false;
    }

    if (_transferring) {
        DEBUG_PRINTLN("[BLE] Transfer already in progress");
        return false;
    }

    if (data == nullptr || size == 0) {
        DEBUG_PRINTLN("[BLE] Invalid transfer data");
        return false;
    }

    negotiateMtu();

    _headerData = nullptr;
    _headerSize = 0;
    _headerPos = 0;
    _headerSent = true;

    _transferData = data;
    _transferSize = size;
    _transferPos = 0;
    _transferring = true;

    setFastConnectionMode();

    DEBUG_PRINTF("[BLE] Starting transfer: %lu bytes (MTU:%d chunk:%d)\n",
                 size, _mtuSize, _transferChunkSize);
    return true;
}

bool BleServices::startAudioTransferWithHeader(const uint8_t* header, uint32_t headerSize,
                                               const uint8_t* data, uint32_t dataSize) {
    if (!isConnected()) {
        DEBUG_PRINTLN("[BLE] Cannot transfer: not connected");
        return false;
    }

    if (_transferring) {
        DEBUG_PRINTLN("[BLE] Transfer already in progress");
        return false;
    }

    if (header == nullptr || headerSize == 0) {
        DEBUG_PRINTLN("[BLE] Invalid header data");
        return false;
    }

    negotiateMtu();

    _headerData = header;
    _headerSize = headerSize;
    _headerPos = 0;
    _headerSent = false;

    _transferData = data;
    _transferSize = dataSize;
    _transferPos = 0;
    _transferring = true;

    setFastConnectionMode();

    DEBUG_PRINTF("[BLE] Starting transfer with header: %lu + %lu bytes (MTU:%d chunk:%d)\n",
                 headerSize, dataSize, _mtuSize, _transferChunkSize);
    return true;
}

bool BleServices::continueTransfer() {
    if (!_transferring || !isConnected()) {
        return false;
    }

    if (!_audioTxChar.notifyEnabled()) {
        DEBUG_PRINTLN("[BLE] continueTransfer: notify NOT enabled, waiting...");
        return true;
    }

    uint32_t sentThisCall = 0;

    // Phase 1 : Envoyer le header
    while (!_headerSent && _headerPos < _headerSize) {
        uint32_t remaining = _headerSize - _headerPos;
        uint32_t chunkSize = min(remaining, (uint32_t)_transferChunkSize);

        if (_audioTxChar.notify(&_headerData[_headerPos], chunkSize)) {
            _headerPos += chunkSize;
            sentThisCall += chunkSize;
        } else {
            DEBUG_PRINTF("[BLE] Header notify BLOCKED at %lu/%lu\n", _headerPos, _headerSize);
            break;
        }
    }

    if (!_headerSent && _headerPos >= _headerSize) {
        _headerSent = true;
        DEBUG_PRINTLN("[BLE] Header sent OK");
    }

    // Phase 2 : Envoyer les données ADPCM
    if (_headerSent && _transferData != nullptr) {
        while (_transferPos < _transferSize) {
            uint32_t remaining = _transferSize - _transferPos;
            uint32_t chunkSize = min(remaining, (uint32_t)_transferChunkSize);

            if (_audioTxChar.notify(&_transferData[_transferPos], chunkSize)) {
                _transferPos += chunkSize;
                sentThisCall += chunkSize;
            } else {
                DEBUG_PRINTF("[BLE] Data notify BLOCKED at %lu/%lu (sent this call: %lu)\n",
                             _transferPos, _transferSize, sentThisCall);
                break;
            }
        }
    }

    bool headerDone = _headerSent || (_headerData == nullptr);
    bool dataDone = (_transferData == nullptr) || (_transferPos >= _transferSize);

    if (headerDone && dataDone) {
        uint32_t totalSent = _headerSize + _transferSize;
        DEBUG_PRINTF("[BLE] Transfer complete: %lu bytes sent\n", totalSent);
        _transferring = false;

        setIdleConnectionMode();

        if (_transferCallback) {
            _transferCallback(true);
        }
        return false;
    }

    return true;
}

void BleServices::cancelTransfer() {
    if (_transferring) {
        DEBUG_PRINTLN("[BLE] Transfer cancelled");
        _transferring = false;
        _transferPos = 0;
    }
}

uint8_t BleServices::getTransferProgress() {
    if (!_transferring || _transferSize == 0) return 0;
    return (uint8_t)((_transferPos * 100ULL) / _transferSize);
}

void BleServices::setTransferCompleteCallback(TransferCompleteCallback callback) {
    _transferCallback = callback;
}

void BleServices::setCommandCallback(CommandReceivedCallback callback) {
    _commandCallback = callback;
}

void BleServices::setAdvertisingStoppedCallback(AdvertisingStoppedCallback callback) {
    _advStoppedCallback = callback;
}

void BleServices::disconnect() {
    if (_connected) {
        Bluefruit.disconnect(_connHandle);
    }
}

void BleServices::disable() {
    stopAdvertising();
    disconnect();
    DEBUG_PRINTLN("[BLE] Disabled (advertising stopped)");
}

void BleServices::enable() {
    startAdvertising();
    DEBUG_PRINTLN("[BLE] Enabled (advertising started)");
}

void BleServices::setFastConnectionMode() {
    if (!_connected || _connHandle == BLE_CONN_HANDLE_INVALID) return;
    if (_connMode == CONN_MODE_FAST) return;

    ble_gap_conn_params_t params;
    memset(&params, 0, sizeof(params));
    params.min_conn_interval = BLE_FAST_CONN_INTERVAL_MIN;
    params.max_conn_interval = BLE_FAST_CONN_INTERVAL_MAX;
    params.slave_latency     = BLE_SLAVE_LATENCY;
    params.conn_sup_timeout  = BLE_SUPERVISION_TIMEOUT;

    uint32_t err = sd_ble_gap_conn_param_update(_connHandle, &params);
    _connMode = CONN_MODE_FAST;
    DEBUG_PRINTF("[BLE] → Fast mode (7.5-15ms): 0x%lx\n", err);
}

void BleServices::setIdleConnectionMode() {
    if (!_connected || _connHandle == BLE_CONN_HANDLE_INVALID) return;
    if (_connMode == CONN_MODE_IDLE) return;

    ble_gap_conn_params_t params;
    memset(&params, 0, sizeof(params));
    params.min_conn_interval = BLE_IDLE_CONN_INTERVAL_MIN;
    params.max_conn_interval = BLE_IDLE_CONN_INTERVAL_MAX;
    params.slave_latency     = 4;  // Skip up to 4 events (~2-4s effective interval)
    params.conn_sup_timeout  = BLE_SUPERVISION_TIMEOUT;

    uint32_t err = sd_ble_gap_conn_param_update(_connHandle, &params);
    _connMode = CONN_MODE_IDLE;
    DEBUG_PRINTF("[BLE] → Idle mode (500-1000ms, latency=4): 0x%lx\n", err);
}

bool BleServices::sendButtonEvent(uint8_t event) {
    if (!isConnected()) return false;
    if (!_buttonEventChar.notifyEnabled()) return false;

    return _buttonEventChar.notify(&event, 1);
}

