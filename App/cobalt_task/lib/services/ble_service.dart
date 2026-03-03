import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../constants/app_constants.dart';

/// =============================================================================
/// ble_service.dart
/// =============================================================================
/// Service de communication Bluetooth Low Energy avec l'appareil Cobalt Task.
///
/// Responsabilités:
/// - Scanner et détecter l'appareil "Cobalt Task"
/// - Établir et maintenir la connexion BLE
/// - Négocier le MTU optimal (247 bytes)
/// - Recevoir les données audio via notifications
/// - Gérer la reconnexion automatique
///
/// Architecture:
/// - Pattern Singleton pour instance unique
/// - Streams pour communication réactive avec l'UI
/// - Buffer accumulateur pour reconstituer les données audio complètes
/// =============================================================================

class BleService {
  /// Instance singleton
  static BleService? _instance;

  /// Appareil connecté
  BluetoothDevice? _connectedDevice;

  /// Caractéristique TX pour recevoir les données audio
  BluetoothCharacteristic? _txCharacteristic;

  /// Caractéristique RX pour envoyer des commandes (optionnel)
  BluetoothCharacteristic? _rxCharacteristic;

  /// Caractéristique Button Event pour recevoir les événements bouton
  BluetoothCharacteristic? _buttonCharacteristic;

  /// Subscription aux notifications bouton
  StreamSubscription? _buttonSubscription;

  /// Caractéristique du niveau de batterie
  BluetoothCharacteristic? _batteryCharacteristic;

  /// État actuel de la connexion
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  /// Buffer pour accumuler les paquets de données reçus
  final List<int> _dataBuffer = [];

  /// Taille attendue des données (depuis le header CVOX)
  int? _expectedDataSize;

  /// Flag pour indiquer si on a reçu le header
  bool _headerReceived = false;

  /// Timer pour détecter les transferts bloqués
  Timer? _staleTransferTimer;

  /// Délai max sans nouvelles données avant reset (en secondes)
  static const int _staleTimeoutSeconds = 5;

  /// Subscriptions aux streams (pour cleanup)
  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _notificationSubscription;

  /// Compteur de tentatives de reconnexion
  int _reconnectAttempts = 0;

  /// Flag pour activer/désactiver la reconnexion automatique
  bool _autoReconnectEnabled = true;

  /// Timer de reconnexion
  Timer? _reconnectTimer;

  /// Délais de reconnexion progressifs (backoff en secondes)
  static const List<int> _reconnectDelays = [1, 3, 5, 10, 30];

  /// Liste des appareils découverts pendant le scan
  final List<ScanResult> _discoveredDevices = [];

  // ---------------------------------------------------------------------------
  // STREAM CONTROLLERS (Communication réactive avec l'UI)
  // ---------------------------------------------------------------------------

  /// Stream de l'état de connexion
  final _connectionStateController =
      StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Stream des appareils découverts (pour le device picker)
  final _discoveredDevicesController =
      StreamController<List<ScanResult>>.broadcast();
  Stream<List<ScanResult>> get discoveredDevicesStream =>
      _discoveredDevicesController.stream;

  /// Liste actuelle des appareils découverts
  List<ScanResult> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);

  /// Stream des données audio complètes reçues
  final _audioDataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  /// Stream de progression du transfert (0.0 à 1.0)
  final _transferProgressController = StreamController<double>.broadcast();
  Stream<double> get transferProgressStream =>
      _transferProgressController.stream;

  /// Stream du niveau de batterie (0-100, -1 si non disponible)
  final _batteryLevelController = StreamController<int>.broadcast();
  Stream<int> get batteryLevelStream => _batteryLevelController.stream;

  /// Stream de l'état de charge (true = USB branché)
  final _chargingController = StreamController<bool>.broadcast();
  Stream<bool> get chargingStream => _chargingController.stream;

  /// Stream des événements bouton hardware (1 byte: 0x01-0x05)
  final _buttonEventController = StreamController<int>.broadcast();
  Stream<int> get buttonEventStream => _buttonEventController.stream;

  /// Niveau de batterie actuel (0-100, -1 si non disponible)
  int _batteryLevel = -1;
  int get batteryLevel => _batteryLevel;

  /// État de charge actuel
  bool _isCharging = false;
  bool get isCharging => _isCharging;

  // ---------------------------------------------------------------------------
  // CONSTRUCTEUR ET SINGLETON
  // ---------------------------------------------------------------------------

  /// Constructeur privé
  BleService._internal();

  /// Factory Singleton
  factory BleService() {
    _instance ??= BleService._internal();
    return _instance!;
  }

  /// Getter pour l'état actuel
  BleConnectionState get connectionState => _connectionState;

  /// Getter pour vérifier si connecté
  bool get isConnected => _connectionState == BleConnectionState.connected ||
      _connectionState == BleConnectionState.syncing;

  // ---------------------------------------------------------------------------
  // INITIALISATION ET VÉRIFICATION BLUETOOTH
  // ---------------------------------------------------------------------------

  /// Vérifie si le Bluetooth est disponible et activé
  Future<bool> isBluetoothAvailable() async {
    // Vérifier le support matériel
    if (!await FlutterBluePlus.isSupported) {
      _updateState(BleConnectionState.disabled);
      return false;
    }

    // Vérifier si le Bluetooth est activé
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _updateState(BleConnectionState.disabled);
      return false;
    }

    return true;
  }

  /// Demande l'activation du Bluetooth (Android uniquement)
  Future<void> requestBluetoothEnable() async {
    await FlutterBluePlus.turnOn();
  }

  // ---------------------------------------------------------------------------
  // SCAN ET CONNEXION
  // ---------------------------------------------------------------------------

  /// Lance le scan pour trouver les appareils Cobalt Voice
  ///
  /// Si [autoConnect] est true, se connecte automatiquement au premier
  /// appareil trouvé (mode démarrage). Sinon, collecte les appareils
  /// pour le device picker (mode manuel).
  Future<void> startScan({int timeout = 10, bool autoConnect = false}) async {
    // Réactiver la reconnexion automatique quand l'utilisateur lance un scan
    _autoReconnectEnabled = true;
    _reconnectAttempts = 0;

    // Vérifier le Bluetooth
    if (!await isBluetoothAvailable()) {
      _updateState(BleConnectionState.disabled);
      return;
    }

    // Arrêter tout scan en cours
    await FlutterBluePlus.stopScan();

    // Réinitialiser les appareils découverts
    _discoveredDevices.clear();
    _discoveredDevicesController.add([]);

    _updateState(BleConnectionState.scanning);

    // Écouter les résultats du scan
    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        // Récupérer le nom depuis plusieurs sources possibles
        final advName = result.advertisementData.advName;
        final platformName = result.device.platformName;
        final deviceName = advName.isNotEmpty ? advName : platformName;

        // Filtrer par préfixe "Cobalt Voice" (insensible à la casse)
        if (deviceName.toLowerCase().startsWith(
            BleConstants.deviceNamePrefix.toLowerCase())) {
          // Ajouter si pas déjà dans la liste
          final alreadyFound = _discoveredDevices.any(
              (d) => d.device.remoteId == result.device.remoteId);
          if (!alreadyFound) {
            _discoveredDevices.add(result);
            _discoveredDevicesController.add(List.from(_discoveredDevices));
            // ignore: avoid_print
            print('BLE Scan: trouvé "$deviceName"');

            // Auto-connect: se connecter au premier appareil trouvé
            if (autoConnect) {
              // ignore: avoid_print
              print('BLE: Auto-connect au premier appareil trouvé');
              connectToDevice(result.device);
              return;
            }
          }
        }
      }
    });

    // Lancer le scan avec timeout
    await FlutterBluePlus.startScan(
      timeout: Duration(seconds: timeout),
      androidUsesFineLocation: true,
    );

    // Après le timeout, repasser en disconnected si toujours en scan
    await Future.delayed(Duration(seconds: timeout + 1));
    if (_connectionState == BleConnectionState.scanning) {
      // ignore: avoid_print
      print('BLE: Scan terminé, ${_discoveredDevices.length} appareil(s) trouvé(s)');
      _updateState(BleConnectionState.disconnected);

      // Si auto-connect et aucun appareil trouvé, planifier une reconnexion
      if (autoConnect && _autoReconnectEnabled) {
        _scheduleReconnect();
      }
    }
  }

  /// Connecte un appareil spécifique choisi par l'utilisateur
  Future<void> connectToDevice(BluetoothDevice device) async {
    // Arrêter le scan en cours
    await FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();
    // Lancer la connexion
    await _connectToDevice(device);
  }

  /// Se connecte à un appareil BLE
  Future<void> _connectToDevice(BluetoothDevice device) async {
    _updateState(BleConnectionState.connecting);

    try {
      // Écouter les changements d'état de connexion
      _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        // ignore: avoid_print
        print('BLE: État connexion changé -> $state');
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      // Établir la connexion
      // ignore: avoid_print
      print('BLE: Connexion à ${device.remoteId}...');
      await device.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );
      // ignore: avoid_print
      print('BLE: Connecté!');

      _connectedDevice = device;

      // Négocier le MTU optimal
      await _negotiateMtu(device);
      // Yield : laisser le main thread Android traiter les events en attente
      // (chaque opération BLE utilise le main thread via MethodChannel)
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Découvrir les services et caractéristiques
      await _discoverServices(device);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Souscrire aux notifications
      await _subscribeToNotifications();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Lire le niveau de batterie si disponible
      await readBatteryLevel();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // ignore: avoid_print
      print('BLE: Configuration terminée, état -> connected');
      _updateState(BleConnectionState.connected);
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur de connexion -> $e');
      _updateState(BleConnectionState.error);
      _handleDisconnection();
    }
  }

  /// Négocie le MTU et la priorité de connexion
  Future<void> _negotiateMtu(BluetoothDevice device) async {
    try {
      // Demander le MTU maximum - le firmware répondra avec ce qu'il supporte
      final mtu = await device.requestMtu(BleConstants.preferredMtu);
      // ignore: avoid_print
      print('BLE: MTU négocié: $mtu bytes');

      // Priorité BALANCED par défaut (meilleure portée, économie batterie)
      // On passe en HIGH uniquement pendant les transferts de données
      await device.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.balanced,
      );
      // ignore: avoid_print
      print('BLE: Priorité connexion BALANCED (intervalles 20-100ms)');
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur négociation MTU/priorité: $e');
    }
  }

  /// Demande une priorité haute (pour les transferts de données)
  Future<void> _requestHighPriority() async {
    if (_connectedDevice == null) return;
    try {
      await _connectedDevice!.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      // ignore: avoid_print
      print('BLE: Priorité → HIGH (transfert en cours)');
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur changement priorité HIGH: $e');
    }
  }

  /// Revient en priorité balanced (après transfert)
  Future<void> _requestBalancedPriority() async {
    if (_connectedDevice == null) return;
    try {
      await _connectedDevice!.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.balanced,
      );
      // ignore: avoid_print
      print('BLE: Priorité → BALANCED (idle)');
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur changement priorité BALANCED: $e');
    }
  }

  /// Découvre les services et caractéristiques BLE
  Future<void> _discoverServices(BluetoothDevice device) async {
    // ignore: avoid_print
    print('BLE: Découverte des services...');
    final services = await device.discoverServices();

    // ignore: avoid_print
    print('BLE: ${services.length} services trouvés');

    for (final service in services) {
      final serviceUuid = service.uuid.toString().toLowerCase();
      // ignore: avoid_print
      print('BLE: Service -> $serviceUuid');

      // Chercher notre service audio personnalisé
      if (serviceUuid == BleConstants.serviceUuid.toLowerCase()) {
        // ignore: avoid_print
        print('BLE: Service audio Cobalt Task trouvé!');

        for (final characteristic in service.characteristics) {
          final charUuid = characteristic.uuid.toString().toLowerCase();
          // ignore: avoid_print
          print('BLE:   Caractéristique -> $charUuid');

          // Caractéristique TX (notifications)
          if (charUuid == BleConstants.txCharacteristicUuid.toLowerCase()) {
            _txCharacteristic = characteristic;
            // ignore: avoid_print
            print('BLE:   -> TX trouvée!');
          }

          // Caractéristique RX (écriture)
          if (charUuid == BleConstants.rxCharacteristicUuid.toLowerCase()) {
            _rxCharacteristic = characteristic;
            // ignore: avoid_print
            print('BLE:   -> RX trouvée!');
          }

          // Caractéristique Button Event (notifications)
          if (charUuid == BleConstants.buttonCharacteristicUuid.toLowerCase()) {
            _buttonCharacteristic = characteristic;
            // ignore: avoid_print
            print('BLE:   -> Button Event trouvée!');
          }
        }
      }

      // Service de batterie standard (UUID 0x180F)
      if (serviceUuid == '180f' || serviceUuid == '0000180f-0000-1000-8000-00805f9b34fb') {
        // ignore: avoid_print
        print('BLE: Service batterie trouvé!');
        for (final characteristic in service.characteristics) {
          final charUuid = characteristic.uuid.toString().toLowerCase();
          // Caractéristique niveau de batterie (UUID 0x2A19)
          if (charUuid == '2a19' || charUuid == '00002a19-0000-1000-8000-00805f9b34fb') {
            _batteryCharacteristic = characteristic;
            // ignore: avoid_print
            print('BLE:   -> Batterie trouvée!');
          }
        }
      }
    }

    if (_txCharacteristic == null) {
      // ignore: avoid_print
      print('BLE: ERREUR - Caractéristique TX non trouvée!');
      print('BLE: UUID recherché: ${BleConstants.txCharacteristicUuid}');
      throw Exception('Caractéristique TX non trouvée');
    }
  }

  /// Souscrit aux notifications de la caractéristique TX
  Future<void> _subscribeToNotifications() async {
    if (_txCharacteristic == null) return;

    // Activer les notifications
    // ignore: avoid_print
    print('BLE: Activation des notifications sur TX...');
    await _txCharacteristic!.setNotifyValue(true);
    // ignore: avoid_print
    print('BLE: Notifications activées!');

    // Écouter les données entrantes
    _notificationSubscription?.cancel();
    _notificationSubscription =
        _txCharacteristic!.onValueReceived.listen(_handleReceivedData);
    // ignore: avoid_print
    print('BLE: En écoute des données audio...');

    // Souscrire aux notifications Button Event
    if (_buttonCharacteristic != null) {
      await _buttonCharacteristic!.setNotifyValue(true);
      _buttonSubscription?.cancel();
      _buttonSubscription =
          _buttonCharacteristic!.onValueReceived.listen((data) {
        if (data.isNotEmpty) {
          _buttonEventController.add(data[0]);
          // ignore: avoid_print
          print('BLE: Button event reçu: 0x${data[0].toRadixString(16)}');
        }
      });
      // ignore: avoid_print
      print('BLE: Abonné aux notifications Button Event');
    }
  }

  /// Subscription aux notifications batterie
  StreamSubscription? _batterySubscription;

  /// Décode la valeur brute batterie (bit 7 = charging, bits 0-6 = percent)
  void _decodeBatteryValue(int raw) {
    _isCharging = (raw & 0x80) != 0;
    _batteryLevel = (raw & 0x7F).clamp(0, 100);
    _batteryLevelController.add(_batteryLevel);
    _chargingController.add(_isCharging);
  }

  /// Lit le niveau de batterie et s'abonne aux notifications
  Future<void> readBatteryLevel() async {
    if (_batteryCharacteristic == null) {
      _batteryLevel = -1;
      return;
    }

    try {
      // Lecture initiale
      final value = await _batteryCharacteristic!.read();
      if (value.isNotEmpty) {
        _decodeBatteryValue(value[0]);
        // ignore: avoid_print
        print('BLE: Batterie initiale = $_batteryLevel% ${_isCharging ? "[CHARGE]" : ""}');
      }

      // S'abonner aux notifications pour mises à jour en temps réel
      await _batteryCharacteristic!.setNotifyValue(true);
      _batterySubscription?.cancel();
      _batterySubscription = _batteryCharacteristic!.onValueReceived.listen((data) {
        if (data.isNotEmpty) {
          _decodeBatteryValue(data[0]);
        }
      });
      // ignore: avoid_print
      print('BLE: Abonné aux notifications batterie');
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur lecture batterie: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // RÉCEPTION ET TRAITEMENT DES DONNÉES
  // ---------------------------------------------------------------------------

  /// Traite les données reçues via notifications BLE
  ///
  /// Les données arrivent en chunks (max 244 bytes par notification).
  /// Le header CVOX (34 bytes) peut être fragmenté sur plusieurs paquets.
  /// On accumule d'abord, puis on analyse le header une fois complet.
  void _handleReceivedData(List<int> data) {
    if (data.isEmpty) {
      // ignore: avoid_print
      print('BLE DATA: Paquet vide reçu, ignoré');
      return;
    }

    // Redémarrer le timer de timeout à chaque réception de données
    _restartStaleTimer();

    // IMPORTANT: Ajouter les données au buffer EN PREMIER
    _dataBuffer.addAll(data);

    // ignore: avoid_print
    print('BLE DATA: Reçu ${data.length} bytes (buffer total: ${_dataBuffer.length})');

    // Analyser le header depuis le BUFFER une fois qu'on a assez de données
    if (!_headerReceived && _dataBuffer.length >= AudioConstants.cvoxHeaderSize) {
      // ignore: avoid_print
      print('BLE DATA: Buffer complet, analyse du header CVOX...');

      // Vérifier le magic number "CVOX" depuis le buffer
      final magic = String.fromCharCodes(_dataBuffer.sublist(0, 4));
      // ignore: avoid_print
      print('BLE DATA: Magic number = "$magic" (bytes: ${_dataBuffer.sublist(0, 4)})');

      if (magic == 'CVOX') {
        // Extraire la taille des données depuis le header (offset 16, 4 bytes LE)
        final byteData = ByteData.sublistView(Uint8List.fromList(_dataBuffer));
        _expectedDataSize = byteData.getUint32(16, Endian.little);
        _headerReceived = true;

        // ignore: avoid_print
        print('BLE DATA: Header CVOX valide! Taille ADPCM: $_expectedDataSize bytes');
        print('BLE DATA: Taille totale attendue: ${AudioConstants.cvoxHeaderSize + _expectedDataSize!} bytes');

        _updateState(BleConnectionState.syncing);
      } else {
        // ignore: avoid_print
        print('BLE DATA: ERREUR - Magic invalide "$magic", reset buffer');
        _resetBuffer();
        return;
      }
    }

    // Calculer et émettre la progression
    if (_expectedDataSize != null && _expectedDataSize! > 0) {
      final totalExpected = AudioConstants.cvoxHeaderSize + _expectedDataSize!;
      final progress = _dataBuffer.length / totalExpected;
      _transferProgressController.add(progress.clamp(0.0, 1.0));

      // Log progression toutes les 10%
      final percent = (progress * 100).toInt();
      if (percent % 10 == 0 && percent > 0) {
        // ignore: avoid_print
        print('BLE DATA: Progression ${percent}% (${_dataBuffer.length}/$totalExpected bytes)');
      }
    }

    // Vérifier si le transfert est complet
    if (_headerReceived && _expectedDataSize != null) {
      final totalExpected = AudioConstants.cvoxHeaderSize + _expectedDataSize!;

      if (_dataBuffer.length >= totalExpected) {
        // ignore: avoid_print
        print('BLE DATA: Transfert COMPLET! ${_dataBuffer.length} bytes reçus');

        // Transfert complet, émettre les données
        final completeData = Uint8List.fromList(_dataBuffer);
        _audioDataController.add(completeData);
        // ignore: avoid_print
        print('BLE DATA: Données envoyées au stream audio');

        // Réinitialiser le buffer pour la prochaine note
        _resetBuffer();

        _updateState(BleConnectionState.connected);
      }
    }
  }

  /// Redémarre le timer de détection de transfert bloqué
  void _restartStaleTimer() {
    _staleTransferTimer?.cancel();
    _staleTransferTimer = Timer(Duration(seconds: _staleTimeoutSeconds), () {
      if (_dataBuffer.isNotEmpty) {
        // ignore: avoid_print
        print('BLE DATA: TIMEOUT - Aucune donnée reçue depuis $_staleTimeoutSeconds secondes, reset buffer');
        _resetBuffer();
        _updateState(BleConnectionState.connected);
      }
    });
  }

  /// Annule le timer de timeout
  void _cancelStaleTimer() {
    _staleTransferTimer?.cancel();
    _staleTransferTimer = null;
  }

  /// Réinitialise le buffer de réception
  void _resetBuffer() {
    _cancelStaleTimer();
    _dataBuffer.clear();
    _expectedDataSize = null;
    _headerReceived = false;
    _transferProgressController.add(0.0);
  }

  // ---------------------------------------------------------------------------
  // DÉCONNEXION ET NETTOYAGE
  // ---------------------------------------------------------------------------

  /// Gère une déconnexion (volontaire ou non)
  void _handleDisconnection() {
    _resetBuffer();
    _batterySubscription?.cancel();
    _batterySubscription = null;
    _buttonSubscription?.cancel();
    _buttonSubscription = null;
    _connectedDevice = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _buttonCharacteristic = null;
    _batteryCharacteristic = null;
    _batteryLevel = -1;
    _isCharging = false;
    _batteryLevelController.add(-1);
    _chargingController.add(false);

    if (_connectionState != BleConnectionState.disabled) {
      _updateState(BleConnectionState.disconnected);
    }

    // Tenter une reconnexion automatique si activée
    if (_autoReconnectEnabled) {
      _scheduleReconnect();
    }
  }

  /// Planifie une tentative de reconnexion avec backoff progressif
  void _scheduleReconnect() {
    if (!_autoReconnectEnabled) return;

    // Déterminer le délai selon le nombre de tentatives
    final delayIndex = _reconnectAttempts.clamp(0, _reconnectDelays.length - 1);
    final delaySec = _reconnectDelays[delayIndex];

    _reconnectAttempts++;
    // ignore: avoid_print
    print('BLE: Reconnexion dans ${delaySec}s (tentative #$_reconnectAttempts)');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (_autoReconnectEnabled &&
          _connectionState == BleConnectionState.disconnected) {
        _startReconnectScan();
      }
    });
  }

  /// Lance un scan rapide pour la reconnexion automatique
  Future<void> _startReconnectScan() async {
    if (!_autoReconnectEnabled) return;
    if (_connectionState != BleConnectionState.disconnected) return;

    // ignore: avoid_print
    print('BLE: Scan de reconnexion automatique...');
    // Scan court (5s) en mode auto-connect
    await startScan(timeout: 5, autoConnect: true);
  }

  /// Déconnecte l'appareil (déconnexion volontaire)
  Future<void> disconnect() async {
    // Désactiver la reconnexion automatique (déconnexion volontaire)
    _autoReconnectEnabled = false;
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;

    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _batterySubscription?.cancel();
    _notificationSubscription?.cancel();

    await _connectedDevice?.disconnect();

    // Nettoyage sans reconnexion (on a désactivé _autoReconnectEnabled)
    _resetBuffer();
    _batterySubscription?.cancel();
    _batterySubscription = null;
    _connectedDevice = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _batteryCharacteristic = null;
    _batteryLevel = -1;
    _isCharging = false;
    _batteryLevelController.add(-1);
    _chargingController.add(false);

    if (_connectionState != BleConnectionState.disabled) {
      _updateState(BleConnectionState.disconnected);
    }
  }

  /// Met à jour l'état de connexion et notifie les listeners
  /// Gère aussi le wake lock et la priorité de connexion dynamique
  void _updateState(BleConnectionState newState) {
    if (_connectionState != newState) {
      final oldState = _connectionState;
      _connectionState = newState;
      _connectionStateController.add(newState);

      // NOTE: Wake lock géré par le foreground service (allowWakeLock: true)
      // Ne PAS appeler WakelockPlus ici pour éviter les appels plateforme
      // redondants qui saturent le main thread Android

      // Priorité dynamique: HIGH pendant syncing, BALANCED sinon
      if (newState == BleConnectionState.syncing) {
        _requestHighPriority();
      } else if (oldState == BleConnectionState.syncing &&
                 newState == BleConnectionState.connected) {
        _requestBalancedPriority();
      }

      // Reset du compteur de reconnexion quand connecté
      if (newState == BleConnectionState.connected) {
        _reconnectAttempts = 0;
        _reconnectTimer?.cancel();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // ENVOI DE COMMANDES (Optionnel)
  // ---------------------------------------------------------------------------

  /// Envoie une commande à l'appareil via la caractéristique RX
  ///
  /// Peut être utilisé pour déclencher un enregistrement,
  /// demander le statut, etc.
  Future<void> sendCommand(List<int> command) async {
    if (_rxCharacteristic == null || !isConnected) {
      throw StateError('Non connecté ou caractéristique RX non disponible');
    }

    await _rxCharacteristic!.write(command, withoutResponse: true);
  }

  // ---------------------------------------------------------------------------
  // NETTOYAGE
  // ---------------------------------------------------------------------------

  /// Libère toutes les ressources
  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    await disconnect();
    await _connectionStateController.close();
    await _audioDataController.close();
    await _transferProgressController.close();
    await _batteryLevelController.close();
    await _chargingController.close();
    await _buttonEventController.close();
    await _discoveredDevicesController.close();
  }
}
