/**
 * @file ble_services.cpp
 * @brief Implémentation des services BLE pour Cobalt Voice
 */

#include "ble_services.h"

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

// Constructeur implicite - initialisation des membres
bool BleServices::begin() {
    _bleInstance = this;
    _connected = false;
    _connHandle = BLE_CONN_HANDLE_INVALID;
    _transferring = false;
    _transferCallback = nullptr;
    _commandCallback = nullptr;
    _mtuSize = 23;  // MTU par défaut

    // Transfert avec header
    _headerData = nullptr;
    _headerSize = 0;
    _headerPos = 0;
    _headerSent = true;

    // Configure pour débit max AVANT begin()
    // MTU=247, event_len=6 (7.5ms), HVN queue=16, write queue=0
    Bluefruit.configPrphConn(BLE_MTU_SIZE, 6, 16, 0);

    // Initialise Bluefruit
    Bluefruit.begin();

    // Active Connection Event Extension (utilise tout le temps radio disponible)
    ble_opt_t opt;
    memset(&opt, 0, sizeof(opt));
    opt.common_opt.conn_evt_ext.enable = 1;
    uint32_t err_code = sd_ble_opt_set(BLE_COMMON_OPT_CONN_EVT_EXT, &opt);
    if (err_code == NRF_SUCCESS) {
        DEBUG_PRINTLN("[BLE] Connection Event Extension enabled");
    } else {
        DEBUG_PRINTF("[BLE] Conn Event Ext error: 0x%lx\n", err_code);
    }

    // Efface les anciennes données de bonding pour repartir propre
    // (utile après changement de firmware)
    Bluefruit.Periph.clearBonds();
    DEBUG_PRINTLN("[BLE] Bonds cleared");

    // Configure la puissance TX
    Bluefruit.setTxPower(BLE_TX_POWER);

    // Nom du device
    Bluefruit.setName(BLE_DEVICE_NAME);

    // Callbacks de connexion
    Bluefruit.Periph.setConnectCallback(ble_connect_callback);
    Bluefruit.Periph.setDisconnectCallback(ble_disconnect_callback);

    // Configure les paramètres de connexion préférés
    Bluefruit.Periph.setConnInterval(BLE_CONN_INTERVAL_MIN, BLE_CONN_INTERVAL_MAX);

    // Configure les services
    setupServices();

    // Configure l'advertising
    setupAdvertising();

    DEBUG_PRINTLN("[BLE] Services initialized");
    return true;
}

// Version sans Bluefruit.begin() - pour quand il a déjà été appelé
bool BleServices::beginAfterBluefruit() {
    _bleInstance = this;
    _connected = false;
    _connHandle = BLE_CONN_HANDLE_INVALID;
    _transferring = false;
    _transferCallback = nullptr;
    _commandCallback = nullptr;
    _mtuSize = 23;

    // Transfert avec header
    _headerData = nullptr;
    _headerSize = 0;
    _headerPos = 0;
    _headerSent = true;

    // Bluefruit.begin() a DÉJÀ été appelé dans main.cpp
    // On fait juste la config restante

    // Active Connection Event Extension (utilise tout le temps radio disponible)
    ble_opt_t opt;
    memset(&opt, 0, sizeof(opt));
    opt.common_opt.conn_evt_ext.enable = 1;
    uint32_t err_code = sd_ble_opt_set(BLE_COMMON_OPT_CONN_EVT_EXT, &opt);
    if (err_code == NRF_SUCCESS) {
        DEBUG_PRINTLN("[BLE] Connection Event Extension enabled");
    } else {
        DEBUG_PRINTF("[BLE] Conn Event Ext error: 0x%lx\n", err_code);
    }

    Bluefruit.Periph.clearBonds();
    DEBUG_PRINTLN("[BLE] Bonds cleared");

    // Callbacks de connexion
    Bluefruit.Periph.setConnectCallback(ble_connect_callback);
    Bluefruit.Periph.setDisconnectCallback(ble_disconnect_callback);

    // Configure les paramètres de connexion préférés
    Bluefruit.Periph.setConnInterval(BLE_CONN_INTERVAL_MIN, BLE_CONN_INTERVAL_MAX);

    // Configure les services
    setupServices();

    // Configure l'advertising
    setupAdvertising();

    DEBUG_PRINTLN("[BLE] Services initialized");
    return true;
}

void BleServices::setupServices() {
    // === Battery Service (standard 0x180F) ===
    _batteryService.begin();

    // === Service Audio Custom ===
    _audioService = BLEService(AUDIO_SERVICE_UUID);
    _audioService.begin();

    // Caractéristique TX (Notify) - pour envoyer l'audio
    _audioTxChar = BLECharacteristic(AUDIO_TX_UUID);
    _audioTxChar.setProperties(CHR_PROPS_NOTIFY);
    _audioTxChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    _audioTxChar.setMaxLen(BLE_MTU_SIZE - 3);  // ATT header = 3 octets
    _audioTxChar.begin();

    // Caractéristique RX (Write) - pour recevoir des commandes
    _audioRxChar = BLECharacteristic(AUDIO_RX_UUID);
    _audioRxChar.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
    _audioRxChar.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
    _audioRxChar.setMaxLen(BLE_MTU_SIZE - 3);
    _audioRxChar.setWriteCallback(ble_rx_callback);
    _audioRxChar.begin();

    // Caractéristique Button Event (Notify) - événements bouton vers téléphone
    _buttonEventChar = BLECharacteristic(BUTTON_EVENT_UUID);
    _buttonEventChar.setProperties(CHR_PROPS_NOTIFY);
    _buttonEventChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    _buttonEventChar.setMaxLen(1);
    _buttonEventChar.begin();

    DEBUG_PRINTLN("[BLE] Services configured");
}

void BleServices::setupAdvertising() {
    // === Paquet Advertising (31 bytes max) ===
    // Flags (3) + TxPower (3) + Name (2 + 14 = 16) = 22 bytes OK
    Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
    Bluefruit.Advertising.addTxPower();
    Bluefruit.Advertising.addName();

    // === Paquet Scan Response (31 bytes max, envoyé sur demande) ===
    // Les UUIDs de service vont ici car ils prennent trop de place (18 bytes pour 128-bit)
    Bluefruit.ScanResponse.addService(_batteryService);
    Bluefruit.ScanResponse.addService(_audioService);

    // Paramètres d'advertising
    Bluefruit.Advertising.restartOnDisconnect(true);
    Bluefruit.Advertising.setInterval(32, 244);    // en unités de 0.625ms
    Bluefruit.Advertising.setFastTimeout(30);      // 30 secondes en mode rapide
}

void BleServices::startAdvertising() {
    Bluefruit.Advertising.start(0);  // 0 = advertising permanent
    DEBUG_PRINTLN("[BLE] Advertising started");
}

void BleServices::stopAdvertising() {
    Bluefruit.Advertising.stop();
    DEBUG_PRINTLN("[BLE] Advertising stopped");
}

bool BleServices::isConnected() {
    return _connected && Bluefruit.connected();
}

void BleServices::updateBatteryLevel(uint8_t level, bool charging) {
    if (level > 100) level = 100;
    // Encode: bit 7 = charging flag, bits 0-6 = percentage
    uint8_t encoded = level | (charging ? 0x80 : 0x00);

    // Ne notifier que si la valeur a changé (évite de spammer le BLE)
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

    DEBUG_PRINTLN("[BLE] Connected!");

    // === FIX CRITIQUE: NE PAS initier MTU Exchange ===
    // Laisser le téléphone (central) initier pour éviter la race condition
    // qui bloquait le MTU à 23 bytes (20 payload = 0.65 KB/s)
    // Le SoftDevice répondra automatiquement avec notre max (247)

    // Demande 2M PHY pour doubler le débit brut
    ble_gap_phys_t phys;
    memset(&phys, 0, sizeof(phys));
    phys.tx_phys = BLE_GAP_PHY_2MBPS;
    phys.rx_phys = BLE_GAP_PHY_2MBPS;
    uint32_t err = sd_ble_gap_phy_update(connHandle, &phys);
    if (err == NRF_SUCCESS) {
        DEBUG_PRINTLN("[BLE] 2M PHY requested");
    } else {
        DEBUG_PRINTF("[BLE] 2M PHY request error: 0x%lx\n", err);
    }

    // Active DLE (Data Length Extension)
    Bluefruit.Connection(connHandle)->requestDataLengthUpdate();

    // Attend que le téléphone négocie le MTU (avec timeout)
    uint32_t start = millis();
    while (millis() - start < 3000) {
        uint16_t mtu = Bluefruit.Connection(_connHandle)->getMtu();
        if (mtu > 23) {
            _mtuSize = mtu;
            _transferChunkSize = _mtuSize - 3;
            break;
        }
        delay(50);
    }

    // Log des paramètres de connexion
    if (_mtuSize > 23) {
        DEBUG_PRINTF("[BLE] MTU OK: %d bytes (chunk: %d, %.1fx vs default)\n",
                     _mtuSize, _transferChunkSize, (float)_transferChunkSize / 20.0f);
    } else {
        DEBUG_PRINTLN("[BLE] MTU WARNING: still 23 bytes - phone may negotiate later");
    }
    DEBUG_PRINTLN("[BLE] Connection configured (7.5ms interval, 2M PHY, DLE)");
}

void BleServices::_onDisconnect(uint16_t connHandle, uint8_t reason) {
    _connected = false;
    _connHandle = BLE_CONN_HANDLE_INVALID;
    _mtuSize = 23;

    DEBUG_PRINTF("[BLE] Disconnected, reason: 0x%02X\n", reason);

    // Annule tout transfert en cours
    if (_transferring) {
        cancelTransfer();
        if (_transferCallback) {
            _transferCallback(false);
        }
    }
}

void BleServices::_onRxData(uint16_t connHandle, uint8_t* data, uint16_t len) {
    DEBUG_PRINTF("[BLE] RX data: %d bytes\n", len);

    if (_commandCallback && len > 0) {
        _commandCallback(data, len);
    }
}

void BleServices::negotiateMtu() {
    // Lecture passive du MTU (le téléphone initie la négociation)
    // Ne PAS appeler requestMtuExchange() pour éviter la race condition
    if (!_connected || _connHandle == BLE_CONN_HANDLE_INVALID) return;

    uint16_t mtu = Bluefruit.Connection(_connHandle)->getMtu();
    if (mtu > 23) {
        _mtuSize = mtu;
    }
    _transferChunkSize = _mtuSize - 3;  // 3 octets pour ATT header

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

    // Vérifie/met à jour le MTU avant transfert
    negotiateMtu();

    // Pas de header séparé
    _headerData = nullptr;
    _headerSize = 0;
    _headerPos = 0;
    _headerSent = true;

    _transferData = data;
    _transferSize = size;
    _transferPos = 0;
    _transferring = true;

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

    // Vérifie/met à jour le MTU avant transfert
    negotiateMtu();

    // Header à envoyer en premier
    _headerData = header;
    _headerSize = headerSize;
    _headerPos = 0;
    _headerSent = false;

    // Données ADPCM à envoyer après le header
    _transferData = data;
    _transferSize = dataSize;
    _transferPos = 0;
    _transferring = true;

    DEBUG_PRINTF("[BLE] Starting transfer with header: %lu + %lu bytes (MTU:%d chunk:%d)\n",
                 headerSize, dataSize, _mtuSize, _transferChunkSize);
    return true;
}

bool BleServices::continueTransfer() {
    if (!_transferring || !isConnected()) {
        return false;
    }

    // Vérifie si le buffer de notification est disponible
    if (!_audioTxChar.notifyEnabled()) {
        // Le client n'a pas activé les notifications - attendre silencieusement
        return true;
    }

    // Envoie autant de chunks que possible jusqu'à ce que la queue HVN soit pleine
    // PAS de limite artificielle - on envoie tant que notify() accepte

    // Phase 1 : Envoyer le header si présent
    while (!_headerSent && _headerPos < _headerSize) {
        uint32_t remaining = _headerSize - _headerPos;
        uint32_t chunkSize = min(remaining, (uint32_t)_transferChunkSize);

        if (_audioTxChar.notify(&_headerData[_headerPos], chunkSize)) {
            _headerPos += chunkSize;
        } else {
            break;  // Queue HVN pleine, on réessaye au prochain appel
        }
    }

    // Marque le header comme envoyé
    if (!_headerSent && _headerPos >= _headerSize) {
        _headerSent = true;
    }

    // Phase 2 : Envoyer les données ADPCM
    if (_headerSent && _transferData != nullptr) {
        while (_transferPos < _transferSize) {
            uint32_t remaining = _transferSize - _transferPos;
            uint32_t chunkSize = min(remaining, (uint32_t)_transferChunkSize);

            if (_audioTxChar.notify(&_transferData[_transferPos], chunkSize)) {
                _transferPos += chunkSize;
            } else {
                break;  // Queue HVN pleine, on réessaye au prochain appel
            }
        }
    }

    // Vérifie si terminé (header + données)
    bool headerDone = _headerSent || (_headerData == nullptr);
    bool dataDone = (_transferData == nullptr) || (_transferPos >= _transferSize);

    if (headerDone && dataDone) {
        uint32_t totalSent = _headerSize + _transferSize;
        DEBUG_PRINTF("[BLE] Transfer complete: %lu bytes sent\n", totalSent);
        _transferring = false;

        if (_transferCallback) {
            _transferCallback(true);
        }
        return false;
    }

    return true;  // Transfert en cours
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

void BleServices::disconnect() {
    if (_connected) {
        Bluefruit.disconnect(_connHandle);
    }
}

void BleServices::disable() {
    stopAdvertising();
    disconnect();
    // Note: On ne peut pas vraiment désactiver la SoftDevice sans reset
    DEBUG_PRINTLN("[BLE] Disabled (advertising stopped)");
}

void BleServices::enable() {
    startAdvertising();
    DEBUG_PRINTLN("[BLE] Enabled (advertising started)");
}

void BleServices::setFastConnectionMode() {
    // Mode connexion stable (15-30ms) - pas de changement dynamique
    // Cette fonction est conservée pour compatibilité mais n'a plus d'effet
    if (!_connected) return;
    DEBUG_PRINTLN("[BLE] Connection mode: stable (15-30ms)");
}

void BleServices::setIdleConnectionMode() {
    // Mode connexion stable (15-30ms) - pas de changement dynamique
    // Cette fonction est conservée pour compatibilité mais n'a plus d'effet
    if (!_connected) return;
    DEBUG_PRINTLN("[BLE] Connection mode: stable (15-30ms)");
}

bool BleServices::sendButtonEvent(uint8_t event) {
    if (!isConnected()) return false;
    if (!_buttonEventChar.notifyEnabled()) return false;

    return _buttonEventChar.notify(&event, 1);
}
