import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../constants/app_constants.dart';

/// =============================================================================
/// ble_service.dart
/// =============================================================================
/// Service de communication Bluetooth Low Energy avec l'appareil Cobalt Voice.
///
/// Responsabilités:
/// - Scanner et détecter l'appareil "Cobalt Voice"
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

  /// Subscriptions aux streams (pour cleanup)
  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _notificationSubscription;

  /// Compteur de tentatives de reconnexion (pour backoff progressif)
  int _reconnectAttempts = 0;

  /// Flag pour désactiver la reconnexion auto (déconnexion manuelle)
  bool _autoReconnectEnabled = true;

  // ---------------------------------------------------------------------------
  // STREAM CONTROLLERS (Communication réactive avec l'UI)
  // ---------------------------------------------------------------------------

  /// Stream de l'état de connexion
  final _connectionStateController =
      StreamController<BleConnectionState>.broadcast();
  Stream<BleConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Stream des données audio complètes reçues
  final _audioDataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  /// Stream de progression du transfert (0.0 à 1.0)
  final _transferProgressController = StreamController<double>.broadcast();
  Stream<double> get transferProgressStream =>
      _transferProgressController.stream;

  /// Stream du niveau de batterie (0-100)
  final _batteryLevelController = StreamController<int>.broadcast();
  Stream<int> get batteryLevelStream => _batteryLevelController.stream;

  /// Stream des appareils découverts pendant le scan
  final _discoveredDevicesController =
      StreamController<List<ScanResult>>.broadcast();
  Stream<List<ScanResult>> get discoveredDevicesStream =>
      _discoveredDevicesController.stream;

  /// Liste des appareils Cobalt Voice découverts
  final List<ScanResult> _discoveredDevices = [];
  List<ScanResult> get discoveredDevices => List.unmodifiable(_discoveredDevices);

  /// Niveau de batterie actuel
  int _batteryLevel = -1;
  int get batteryLevel => _batteryLevel;

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

  /// Lance le scan pour trouver les appareils Cobalt Voice.
  ///
  /// Si [autoConnect] est true (par défaut), se connecte automatiquement
  /// au premier appareil trouvé. Si false, collecte les appareils et les
  /// expose via [discoveredDevicesStream] pour sélection manuelle.
  Future<void> startScan({int timeout = 10, bool autoConnect = true}) async {
    // Toute action de scan réactive la reconnexion auto
    _autoReconnectEnabled = true;
    _reconnectAttempts = 0;

    // Vérifier le Bluetooth
    if (!await isBluetoothAvailable()) {
      _updateState(BleConnectionState.disabled);
      return;
    }

    // Arrêter tout scan en cours
    await FlutterBluePlus.stopScan();

    // Réinitialiser la liste des appareils découverts
    _discoveredDevices.clear();
    _discoveredDevicesController.add(_discoveredDevices);

    _updateState(BleConnectionState.scanning);

    // Écouter les résultats du scan
    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        // Récupérer le nom depuis plusieurs sources possibles
        final advName = result.advertisementData.advName;
        final platformName = result.device.platformName;
        final deviceName = advName.isNotEmpty ? advName : platformName;

        // Debug: afficher tous les appareils trouvés
        // ignore: avoid_print
        print('BLE Scan: trouvé "$deviceName" (adv: "$advName", platform: "$platformName")');

        // Match par préfixe "Cobalt Voice" (accepte Cobalt Voice, Cobalt Voice 2, etc.)
        if (deviceName.toLowerCase().startsWith(BleConstants.deviceNamePrefix.toLowerCase())) {
          // Vérifier si l'appareil n'est pas déjà dans la liste
          final alreadyFound = _discoveredDevices.any(
            (d) => d.device.remoteId == result.device.remoteId,
          );

          if (!alreadyFound) {
            // ignore: avoid_print
            print('BLE: Montre trouvée: "$deviceName" (${result.device.remoteId})');
            _discoveredDevices.add(result);
            _discoveredDevicesController.add(List.from(_discoveredDevices));

            // Auto-connect au premier appareil trouvé
            if (autoConnect) {
              // ignore: avoid_print
              print('BLE: Auto-connexion à "$deviceName"');
              FlutterBluePlus.stopScan();
              _connectToDevice(result.device);
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

    // Vérifier si le scan s'est terminé sans trouver d'appareil
    await Future.delayed(Duration(seconds: timeout + 1));
    if (_connectionState == BleConnectionState.scanning) {
      // ignore: avoid_print
      print('BLE: Scan terminé, ${_discoveredDevices.length} appareil(s) trouvé(s)');
      _updateState(BleConnectionState.disconnected);
    }
  }

  /// Se connecte à un appareil spécifique (appelé depuis l'UI)
  Future<void> connectToDevice(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
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

      // Découvrir les services et caractéristiques
      await _discoverServices(device);

      // Souscrire aux notifications
      await _subscribeToNotifications();

      // Lire le niveau de batterie si disponible
      await readBatteryLevel();

      // Connexion réussie: reset le backoff et active la reconnexion auto
      _reconnectAttempts = 0;
      _autoReconnectEnabled = true;

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

  /// Négocie le MTU et configure la priorité de connexion
  Future<void> _negotiateMtu(BluetoothDevice device) async {
    try {
      // Demander le MTU maximum - le firmware répondra avec ce qu'il supporte
      final mtu = await device.requestMtu(BleConstants.preferredMtu);
      // ignore: avoid_print
      print('BLE: MTU négocié: $mtu bytes');

      // Priorité BALANCED par défaut pour stabilité à distance (20-100ms)
      // HIGH sera demandé dynamiquement pendant les transferts
      await device.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.balanced,
      );
      // ignore: avoid_print
      print('BLE: Priorité connexion BALANCED (stabilité portée)');
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur négociation MTU/priorité: $e');
    }
  }

  /// Bascule en priorité haute pour un transfert rapide
  Future<void> _requestHighPriority() async {
    try {
      await _connectedDevice?.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      // ignore: avoid_print
      print('BLE: Priorité → HIGH (transfert actif)');
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur priorité HIGH: $e');
    }
  }

  /// Revient en priorité balanced après le transfert
  Future<void> _requestBalancedPriority() async {
    try {
      await _connectedDevice?.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.balanced,
      );
      // ignore: avoid_print
      print('BLE: Priorité → BALANCED (idle)');
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur priorité BALANCED: $e');
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
        print('BLE: Service audio Cobalt Voice trouvé!');

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
  }

  /// Lit le niveau de batterie
  Future<void> readBatteryLevel() async {
    if (_batteryCharacteristic == null) {
      _batteryLevel = -1;
      return;
    }

    try {
      final value = await _batteryCharacteristic!.read();
      if (value.isNotEmpty) {
        _batteryLevel = value[0];
        _batteryLevelController.add(_batteryLevel);
        // ignore: avoid_print
        print('BLE: Niveau batterie = $_batteryLevel%');
      }
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
      print('BLE DATA: Magic number = "$magic"');

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

  /// Réinitialise le buffer de réception
  void _resetBuffer() {
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
    _connectedDevice = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _batteryCharacteristic = null;
    _batteryLevel = -1;

    if (_connectionState != BleConnectionState.disabled) {
      _updateState(BleConnectionState.disconnected);
      // Tenter une reconnexion automatique après un délai
      if (_autoReconnectEnabled) {
        _scheduleReconnect();
      }
    }
  }

  /// Planifie une tentative de reconnexion automatique avec backoff progressif
  ///
  /// Délais: 1s, 3s, 5s, 10s, puis 30s en boucle
  void _scheduleReconnect() {
    final delays = [1, 3, 5, 10, 30];
    final delaySeconds = _reconnectAttempts < delays.length
        ? delays[_reconnectAttempts]
        : delays.last;

    // ignore: avoid_print
    print('BLE: Reconnexion dans ${delaySeconds}s (tentative ${_reconnectAttempts + 1})');

    Future.delayed(Duration(seconds: delaySeconds), () {
      if (_connectionState == BleConnectionState.disconnected && _autoReconnectEnabled) {
        _reconnectAttempts++;
        // ignore: avoid_print
        print('BLE: Reconnexion automatique (tentative $_reconnectAttempts)...');
        _startReconnectScan();
      }
    });
  }

  /// Lance un scan de reconnexion avec retry automatique en cas d'échec
  /// Scan rapide (5s) pour reconnecter vite quand la montre est à portée
  Future<void> _startReconnectScan() async {
    if (!await isBluetoothAvailable()) {
      _updateState(BleConnectionState.disabled);
      return;
    }

    await FlutterBluePlus.stopScan();
    _updateState(BleConnectionState.scanning);

    const reconnectScanTimeout = 5; // Plus rapide que le scan manuel (10s)

    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final advName = result.advertisementData.advName;
        final platformName = result.device.platformName;
        final deviceName = advName.isNotEmpty ? advName : platformName;

        if (deviceName.toLowerCase().startsWith(BleConstants.deviceNamePrefix.toLowerCase())) {
          // ignore: avoid_print
          print('BLE: Montre retrouvée: "$deviceName"');
          FlutterBluePlus.stopScan();
          _reconnectAttempts = 0;
          _connectToDevice(result.device);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: reconnectScanTimeout),
      androidUsesFineLocation: true,
    );

    // Attendre la fin du scan
    await Future.delayed(const Duration(seconds: reconnectScanTimeout + 1));

    // Si toujours pas connecté, retenter
    if (_connectionState == BleConnectionState.scanning ||
        _connectionState == BleConnectionState.disconnected) {
      _updateState(BleConnectionState.disconnected);
      if (_autoReconnectEnabled) {
        // ignore: avoid_print
        print('BLE: Scan échoué, replanification...');
        _scheduleReconnect();
      }
    }
  }

  /// Déconnecte l'appareil (déconnexion manuelle = pas de reconnexion auto)
  Future<void> disconnect() async {
    _autoReconnectEnabled = false;
    _reconnectAttempts = 0;

    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _notificationSubscription?.cancel();

    await _connectedDevice?.disconnect();
    _handleDisconnection();
  }

  /// Met à jour l'état de connexion et notifie les listeners
  void _updateState(BleConnectionState newState) {
    if (_connectionState != newState) {
      final previousState = _connectionState;
      _connectionState = newState;
      _connectionStateController.add(newState);

      // Gérer la priorité de connexion dynamiquement
      if (newState == BleConnectionState.syncing && previousState == BleConnectionState.connected) {
        // Transfert démarre → priorité haute pour vitesse
        _requestHighPriority();
      } else if (newState == BleConnectionState.connected && previousState == BleConnectionState.syncing) {
        // Transfert terminé → priorité balanced pour portée
        _requestBalancedPriority();
      }

      // Gérer le wake lock selon l'état de connexion
      if (newState == BleConnectionState.connected ||
          newState == BleConnectionState.syncing) {
        WakelockPlus.enable();
        // ignore: avoid_print
        print('BLE: Wake lock activé (écran verrouillé OK)');
      } else if (newState == BleConnectionState.disconnected ||
                 newState == BleConnectionState.disabled) {
        WakelockPlus.disable();
        // ignore: avoid_print
        print('BLE: Wake lock désactivé');
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
    await disconnect();
    await _connectionStateController.close();
    await _audioDataController.close();
    await _transferProgressController.close();
    await _batteryLevelController.close();
    await _discoveredDevicesController.close();
  }
}
