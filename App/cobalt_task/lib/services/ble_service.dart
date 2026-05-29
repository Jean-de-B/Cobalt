import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_constants.dart';
import 'settings_service.dart';

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

  /// ID (MAC) de l'appareil sélectionné par l'utilisateur (persisté)
  String? _selectedDeviceId;

  /// Nom de l'appareil connecté (pour affichage UI)
  String? _connectedDeviceName;

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

  /// Caractéristique de la version firmware
  BluetoothCharacteristic? _fwVersionCharacteristic;

  /// Caractéristique Debug Log (logs firmware via BLE)
  BluetoothCharacteristic? _debugLogCharacteristic;
  StreamSubscription? _debugLogSubscription;
  final _debugLogController = StreamController<String>.broadcast();
  Stream<String> get debugLogStream => _debugLogController.stream;

  /// Version firmware de l'appareil connecté (ex: "1.0.0")
  String? _firmwareVersion;
  String? get firmwareVersion => _firmwareVersion;
  final _firmwareVersionController = StreamController<String?>.broadcast();
  Stream<String?> get firmwareVersionStream => _firmwareVersionController.stream;

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

  /// Timer heartbeat : vérifie que la connexion est vivante toutes les 20s
  Timer? _heartbeatTimer;
  static const int _heartbeatIntervalSec = 20;

  /// Subscription à l'état de l'adaptateur BT (pour react au BT on/off)
  StreamSubscription? _btStateSubscription;

  // Reconnexion : scan continu de 15s en boucle jusqu'à retrouver le device

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
  BleService._internal() {
    _loadSelectedDeviceId();
  }

  /// Factory Singleton
  factory BleService() {
    _instance ??= BleService._internal();
    return _instance!;
  }

  /// Charge le device ID sélectionné depuis SharedPreferences
  Future<void> _loadSelectedDeviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedDeviceId = prefs.getString(_prefKeySelectedDeviceId);
      if (_selectedDeviceId != null) {
        // ignore: avoid_print
        print('BLE: Device ID restauré: $_selectedDeviceId');
      }
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur chargement device ID: $e');
    }
  }

  /// Persiste le device ID sélectionné
  Future<void> _saveSelectedDeviceId(String? deviceId) async {
    _selectedDeviceId = deviceId;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (deviceId != null) {
        await prefs.setString(_prefKeySelectedDeviceId, deviceId);
      } else {
        await prefs.remove(_prefKeySelectedDeviceId);
      }
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur sauvegarde device ID: $e');
    }
  }

  /// Getter pour l'état actuel
  BleConnectionState get connectionState => _connectionState;

  /// Getter pour vérifier si connecté
  /// ID du device appairé persisté (null si aucun device sélectionné)
  String? get selectedDeviceId => _selectedDeviceId;

  bool get isConnected => _connectionState == BleConnectionState.connected ||
      _connectionState == BleConnectionState.syncing;

  /// Nom de l'appareil connecté (ex: "Cobalt A3F2")
  String? get connectedDeviceName => _connectedDeviceName;

  /// Clé SharedPreferences pour persister le device ID sélectionné
  static const String _prefKeySelectedDeviceId = 'ble_selected_device_id';

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
    final adapterState = FlutterBluePlus.adapterStateNow;
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
  Future<void> startScan({int timeout = 10, bool autoConnect = false, bool isReconnectScan = false}) async {
    // Réactiver la reconnexion automatique quand l'utilisateur lance un scan
    _autoReconnectEnabled = true;
    if (!isReconnectScan) {
      _reconnectAttempts = 0;
    }

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

            // Auto-connect: se connecter au bon appareil
            if (autoConnect) {
              // Si on a un device ID mémorisé, ne reconnecter qu'à celui-ci
              if (_selectedDeviceId != null &&
                  result.device.remoteId.str != _selectedDeviceId) {
                // ignore: avoid_print
                print('BLE: Auto-connect ignoré "$deviceName" (attendu: $_selectedDeviceId)');
                continue;
              }
              // ignore: avoid_print
              print('BLE: Auto-connect à "$deviceName" (${result.device.remoteId})');
              connectToDevice(result.device, deviceName: deviceName);
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
      withRemoteIds: (autoConnect && _selectedDeviceId != null)
          ? [_selectedDeviceId!]
          : const [],
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

  /// Scan de navigation rapide pour le device picker.
  /// Affiche TOUS les devices BLE nommés, pas seulement Cobalt Voice.
  /// Pas d'auto-connect, rafraîchit les RSSI, tourne jusqu'à stopBrowseScan().
  Future<void> startBrowseScan() async {
    if (!await isBluetoothAvailable()) {
      // ignore: avoid_print
      print('BLE Browse: Bluetooth non disponible');
      return;
    }

    await FlutterBluePlus.stopScan();
    _discoveredDevices.clear();
    _discoveredDevicesController.add([]);

    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      bool changed = false;
      for (final result in results) {
        final advName = result.advertisementData.advName;
        final platformName = result.device.platformName;
        final deviceName = advName.isNotEmpty ? advName : platformName;

        // Accepter tout device avec un nom (pas de filtre "Cobalt Voice")
        if (deviceName.isNotEmpty) {
          final idx = _discoveredDevices.indexWhere(
              (d) => d.device.remoteId == result.device.remoteId);
          if (idx >= 0) {
            _discoveredDevices[idx] = result; // rafraîchit RSSI
          } else {
            _discoveredDevices.add(result);
          }
          changed = true;
        }
      }
      if (changed) {
        // Trier : Cobalt Voice en premier, puis par RSSI
        _discoveredDevices.sort((a, b) {
          final aName = (a.advertisementData.advName.isNotEmpty
              ? a.advertisementData.advName : a.device.platformName).toLowerCase();
          final bName = (b.advertisementData.advName.isNotEmpty
              ? b.advertisementData.advName : b.device.platformName).toLowerCase();
          final aIsCobalt = aName.startsWith(BleConstants.deviceNamePrefix.toLowerCase());
          final bIsCobalt = bName.startsWith(BleConstants.deviceNamePrefix.toLowerCase());
          if (aIsCobalt && !bIsCobalt) return -1;
          if (!aIsCobalt && bIsCobalt) return 1;
          return b.rssi.compareTo(a.rssi); // plus fort signal en premier
        });
        _discoveredDevicesController.add(List.from(_discoveredDevices));
      }
    });

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 30),
      androidUsesFineLocation: true,
      continuousUpdates: true,
    );
  }

  /// Arrête le scan de navigation.
  Future<void> stopBrowseScan() async {
    await FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();
  }

  /// Connecte un appareil spécifique choisi par l'utilisateur.
  /// Déconnecte proprement l'ancien appareil si différent.
  Future<void> connectToDevice(BluetoothDevice device, {String? deviceName}) async {
    // Arrêter le scan en cours
    await FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();

    // Déconnecter l'ancien appareil si on change de device
    if (_connectedDevice != null &&
        _connectedDevice!.remoteId != device.remoteId) {
      // ignore: avoid_print
      print('BLE: Déconnexion de l\'ancien appareil ${_connectedDevice!.remoteId}');
      try {
        _connectionSubscription?.cancel();
        _notificationSubscription?.cancel();
        _batterySubscription?.cancel();
        _buttonSubscription?.cancel();
        await _connectedDevice!.disconnect();
      } catch (e) {
        // ignore: avoid_print
        print('BLE: Erreur déconnexion ancien appareil: $e');
      }
      _connectedDevice = null;
      _txCharacteristic = null;
      _rxCharacteristic = null;
      _buttonCharacteristic = null;
      _batteryCharacteristic = null;
    }

    // Mémoriser le device ID sélectionné (persisté pour auto-reconnect)
    await _saveSelectedDeviceId(device.remoteId.str);
    _connectedDeviceName = deviceName ?? device.platformName;

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
      _connectedDeviceName ??= device.platformName;

      // Icône verte immédiatement (feedback utilisateur instantané)
      _updateState(BleConnectionState.connected);

      // Laisser le firmware terminer son post-connect setup
      // (conn params, PHY, DLE) avant de faire quoi que ce soit.
      // Le firmware met ~500ms (wait_stable 200ms + conn_params + PHY 150ms + DLE 100ms).
      // ignore: avoid_print
      print('BLE: Attente setup firmware (800ms)...');
      await Future.delayed(const Duration(milliseconds: 800));

      // Vérifier qu'on est toujours connecté après l'attente
      if (!device.isConnected) {
        // ignore: avoid_print
        print('BLE: Déconnecté pendant le setup firmware → retry');
        throw Exception('Déconnexion pendant setup');
      }

      // Négocier le MTU (le firmware attend notre requestMtu dans PC_WAIT_MTU)
      await _negotiateMtu(device);

      // Découvrir les services
      await _discoverServices(device);

      // Souscrire aux notifications
      await _subscribeToNotifications();

      // Lire batterie et firmware version (non-bloquant)
      try { await readBatteryLevel(); } catch (e) {
        // ignore: avoid_print
        print('BLE: Erreur lecture batterie (retry dans 5s): $e');
        // Retry après 5s si la connexion est toujours active
        Future.delayed(const Duration(seconds: 5), () {
          if (isConnected) readBatteryLevel();
        });
      }
      try { await readFirmwareVersion(); } catch (e) {
        // ignore: avoid_print
        print('BLE: Erreur lecture firmware version: $e');
      }

      // ignore: avoid_print
      print('BLE: Configuration terminée');
      _startHeartbeat();
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
      // Le stack BLE négocie souvent le MTU automatiquement à la connexion.
      // On vérifie d'abord si c'est déjà fait pour éviter une double négociation.
      final currentMtu = device.mtuNow;
      if (currentMtu >= BleConstants.preferredMtu) {
        // ignore: avoid_print
        print('BLE: MTU déjà négocié: $currentMtu bytes (skip requestMtu)');
      } else {
        final mtu = await device.requestMtu(BleConstants.preferredMtu);
        // ignore: avoid_print
        print('BLE: MTU négocié: $mtu bytes');
      }

      await device.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.balanced,
      );
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur négociation MTU/priorité: $e (on continue)');
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

          // Caractéristique Firmware Version (lecture)
          if (charUuid == BleConstants.fwVersionCharacteristicUuid.toLowerCase()) {
            _fwVersionCharacteristic = characteristic;
            // ignore: avoid_print
            print('BLE:   -> Firmware Version trouvée!');
          }

          // Caractéristique Debug Log (notifications firmware → téléphone)
          if (charUuid == BleConstants.debugLogCharacteristicUuid.toLowerCase()) {
            _debugLogCharacteristic = characteristic;
            // ignore: avoid_print
            print('BLE:   -> Debug Log trouvée!');
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

  /// Lit la version firmware de l'appareil connecté
  Future<void> readFirmwareVersion() async {
    if (_fwVersionCharacteristic == null) {
      _firmwareVersion = null;
      return;
    }

    try {
      final value = await _fwVersionCharacteristic!.read();
      if (value.length >= 3) {
        _firmwareVersion = '${value[0]}.${value[1]}.${value[2]}';
        _firmwareVersionController.add(_firmwareVersion);
        // ignore: avoid_print
        print('BLE: Firmware version = $_firmwareVersion');
      }
    } catch (e) {
      // ignore: avoid_print
      print('BLE: Erreur lecture firmware version: $e');
    }
  }

  /// Envoie la commande DFU pour faire entrer l'appareil en mode bootloader
  /// Retourne true si la commande a été envoyée
  Future<bool> triggerDfuMode() async {
    if (_rxCharacteristic == null || !isConnected) {
      // ignore: avoid_print
      print('BLE DFU: Non connecté ou RX non disponible');
      return false;
    }

    final deviceAddress = _connectedDevice!.remoteId.str;
    // ignore: avoid_print
    print('BLE DFU: Envoi commande DFU (0xFD) à $deviceAddress');

    // Désactiver la reconnexion automatique pendant le DFU
    _autoReconnectEnabled = false;
    _reconnectTimer?.cancel();

    try {
      await _rxCharacteristic!.write(
        [BleConstants.cmdEnterDfu],
        withoutResponse: true,
      );
      // ignore: avoid_print
      print('BLE DFU: Commande envoyée, device va redémarrer en mode DFU');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('BLE DFU: Erreur envoi commande: $e');
      _autoReconnectEnabled = true;
      return false;
    }
  }

  /// Scanne pour trouver le device en mode DFU (bootloader Adafruit = "DfuTarg")
  /// Retourne l'adresse MAC du DFU target, ou null si non trouvé
  ///
  /// Détection par nom ("DfuTarg", "Dfu") OU par service UUID Nordic DFU (0xFE59)
  Future<String?> scanForDfuTarget({int timeoutSeconds = 20}) async {
    // ignore: avoid_print
    print('BLE DFU: Scan pour DfuTarg (timeout: ${timeoutSeconds}s)...');

    await FlutterBluePlus.stopScan();

    // UUID du service Nordic Secure DFU
    const nordicDfuServiceUuid = 'fe59';

    final completer = Completer<String?>();
    StreamSubscription? sub;
    Timer? timeout;
    final Set<String> loggedDevices = {};

    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final addr = result.device.remoteId.str;
        final advName = result.advertisementData.advName;
        final platformName = result.device.platformName;
        final name = advName.isNotEmpty ? advName : platformName;
        final serviceUuids = result.advertisementData.serviceUuids
            .map((e) => e.toString().toLowerCase())
            .toList();

        // Log TOUS les devices trouvés (une seule fois par adresse)
        if (!loggedDevices.contains(addr)) {
          loggedDevices.add(addr);
          // ignore: avoid_print
          print('BLE DFU SCAN: "$name" @ $addr  services=$serviceUuids  rssi=${result.rssi}');
        }

        // Critère 1: Nom contient "dfu" (DfuTarg, etc.)
        final nameMatch = name.isNotEmpty &&
            (name.toLowerCase().contains('dfutarg') ||
             name.toLowerCase().contains('dfu'));

        // Critère 2: Advertise le service Nordic DFU (0xFE59)
        final serviceMatch = serviceUuids.any((uuid) =>
            uuid.contains(nordicDfuServiceUuid));

        if (nameMatch || serviceMatch) {
          // ignore: avoid_print
          print('BLE DFU: *** DFU TARGET TROUVÉ! ***  "$name" @ $addr  '
              '(name=${nameMatch ? "OUI" : "non"}, service=${serviceMatch ? "OUI" : "non"})');
          if (!completer.isCompleted) {
            completer.complete(addr);
          }
        }
      }
    });

    timeout = Timer(Duration(seconds: timeoutSeconds), () {
      if (!completer.isCompleted) {
        // ignore: avoid_print
        print('BLE DFU: Timeout - DfuTarg non trouvé après ${timeoutSeconds}s');
        print('BLE DFU: ${loggedDevices.length} device(s) BLE détecté(s) au total');
        completer.complete(null);
      }
    });

    await FlutterBluePlus.startScan(
      timeout: Duration(seconds: timeoutSeconds),
      androidUsesFineLocation: true,
    );

    final address = await completer.future;
    timeout.cancel();
    await sub.cancel();
    await FlutterBluePlus.stopScan();
    return address;
  }

  /// Réactive la reconnexion automatique (après DFU terminé/annulé)
  void enableAutoReconnect() {
    _autoReconnectEnabled = true;
    _reconnectAttempts = 0;
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
    _stopHeartbeat();
    _resetBuffer();
    _batterySubscription?.cancel();
    _batterySubscription = null;
    _buttonSubscription?.cancel();
    _buttonSubscription = null;
    _debugLogSubscription?.cancel();
    _debugLogSubscription = null;
    _connectedDevice = null;
    // Garder _connectedDeviceName pour l'affichage pendant la reconnexion
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _buttonCharacteristic = null;
    _batteryCharacteristic = null;
    _fwVersionCharacteristic = null;
    _debugLogCharacteristic = null;
    _firmwareVersion = null;
    _firmwareVersionController.add(null);
    _batteryLevel = -1;
    _isCharging = false;
    _batteryLevelController.add(-1);
    _chargingController.add(false);

    if (_connectionState != BleConnectionState.disabled) {
      // Si reconnexion automatique active, rester en "scanning" (orange)
      // au lieu de passer en "disconnected" (gris)
      if (_autoReconnectEnabled && _selectedDeviceId != null) {
        _updateState(BleConnectionState.scanning);
      } else {
        _updateState(BleConnectionState.disconnected);
      }
    }

    // Tenter une reconnexion automatique si activée
    if (_autoReconnectEnabled) {
      _scheduleReconnect();
    }
  }

  /// Lance un scan continu de reconnexion pour le device connu.
  /// Le scan tourne en boucle jusqu'à ce que le device soit retrouvé.
  /// Phase 1 : scan continu agressif (couvre la fenêtre d'advertising firmware)
  static const int _fastScanDurationSec = 30;
  /// Phase 2 : scan périodique en veille
  static const int _slowScanDurationSec = 15;
  static const int _slowRetryIntervalSec = 30;
  /// Nombre de cycles rapides avant de passer en veille
  static const int _maxFastCycles = 6; // 6 × 30s = 3 minutes

  void _scheduleReconnect() {
    if (!_autoReconnectEnabled) return;
    if (_selectedDeviceId == null) return;

    _reconnectAttempts++;

    final bool isFast = _reconnectAttempts <= _maxFastCycles;
    final int delaySec = isFast ? 1 : _slowRetryIntervalSec;

    // ignore: avoid_print
    print('BLE: Reconnexion dans ${delaySec}s (cycle #$_reconnectAttempts, mode ${isFast ? "rapide" : "veille"})');

    // En mode veille, icône grise
    if (!isFast) {
      _updateState(BleConnectionState.disconnected);
    }


    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (_autoReconnectEnabled &&
          (_connectionState == BleConnectionState.disconnected ||
           _connectionState == BleConnectionState.scanning)) {
        _startContinuousScan();
      }
    });
  }

  /// Scan avec durée adaptée au cycle (long en rapide, court en veille).
  /// Pas de pause inter-scan en mode rapide : on enchaîne immédiatement.
  Future<void> _startContinuousScan() async {
    if (!_autoReconnectEnabled) { return; }
    if (_selectedDeviceId == null) { return; }
    if (_connectionState == BleConnectionState.connected ||
        _connectionState == BleConnectionState.connecting) { return; }

    final bool isFast = _reconnectAttempts <= _maxFastCycles;
    final int scanDuration = isFast ? _fastScanDurationSec : _slowScanDurationSec;

    if (isFast) {
      _updateState(BleConnectionState.scanning);
    }

    // ignore: avoid_print
    print('BLE: Scan ${scanDuration}s pour $_selectedDeviceId (cycle #$_reconnectAttempts)...');

    await FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();

    bool found = false;
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (found) return;
      for (final result in results) {
        if (result.device.remoteId.str == _selectedDeviceId) {
          found = true;
          final advName = result.advertisementData.advName;
          final platformName = result.device.platformName;
          final deviceName = advName.isNotEmpty ? advName : platformName;
          // ignore: avoid_print
          print('BLE: Device retrouvé! "$deviceName" → connexion');
          _reconnectAttempts = 0;
          connectToDevice(result.device, deviceName: deviceName);
          return;
        }
      }
    });

    await FlutterBluePlus.startScan(
      timeout: Duration(seconds: scanDuration),
      androidUsesFineLocation: true,
      withRemoteIds: [_selectedDeviceId!],
    );

    // Attendre la fin du scan
    await Future.delayed(Duration(seconds: scanDuration + 1));

    if (!found && _autoReconnectEnabled &&
        _connectionState != BleConnectionState.connected &&
        _connectionState != BleConnectionState.connecting) {
      _scheduleReconnect();
    }
  }

  /// Initialise le service: charge le device persisté, écoute l'état BT,
  /// et démarre la reconnexion automatique si un device est connu.
  Future<void> initialize() async {
    // S'assurer que le device ID persisté est chargé avant de continuer
    await _loadSelectedDeviceId();

    // Écouter les changements d'état de l'adaptateur BT
    _btStateSubscription?.cancel();
    _btStateSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        // BT vient d'être activé → relancer la reconnexion si device connu
        // Note: après une coupure BT, l'état est 'disabled' (pas 'disconnected')
        if (_selectedDeviceId != null &&
            (_connectionState == BleConnectionState.disconnected ||
             _connectionState == BleConnectionState.disabled)) {
          // ignore: avoid_print
          print('BLE: Adaptateur BT activé → relance reconnexion');
          _reconnectAttempts = 0;
          _autoReconnectEnabled = true;
          _scheduleReconnect();
        }
      } else if (state == BluetoothAdapterState.off) {
        // BT désactivé → mettre en état disabled
        _reconnectTimer?.cancel();
        _updateState(BleConnectionState.disabled);
      }
    });

    // Auto-reconnexion au démarrage si un device est mémorisé ET setting activé
    if (_selectedDeviceId != null && SettingsService().autoConnectBracelet) {
      // ignore: avoid_print
      print('BLE: Device connu au démarrage → reconnexion automatique');
      _autoReconnectEnabled = true;
      _scheduleReconnect();
    }
  }

  /// Déclenche immédiatement un scan de reconnexion (depuis foreground resume)
  void triggerReconnect() {
    if (_selectedDeviceId == null) { return; }

    if (_connectionState == BleConnectionState.disabled) {
      // BT potentiellement réactivé — vérifier l'état réel avant de scanner
      FlutterBluePlus.adapterState.first.then((btState) {
        if (btState == BluetoothAdapterState.on) {
          // ignore: avoid_print
          print('BLE: triggerReconnect() depuis disabled, BT on → scan immédiat');
          _reconnectAttempts = 0;
          _autoReconnectEnabled = true;
          _updateState(BleConnectionState.scanning);
          _startContinuousScan();
        }
      });
      return;
    }

    if (_connectionState == BleConnectionState.disconnected ||
        _connectionState == BleConnectionState.scanning) {
      // ignore: avoid_print
      print('BLE: triggerReconnect() → scan immédiat');
      _reconnectTimer?.cancel();
      _reconnectAttempts = 0;
      _startContinuousScan();
    }
  }

  /// Déconnecte l'appareil (déconnexion volontaire)
  Future<void> disconnect() async {
    // Désactiver la reconnexion automatique (déconnexion volontaire)
    _stopHeartbeat();
    _autoReconnectEnabled = false;
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;

    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _batterySubscription?.cancel();
    _notificationSubscription?.cancel();
    _buttonSubscription?.cancel();

    await _connectedDevice?.disconnect();

    // Oublier le device sélectionné (déconnexion volontaire)
    await _saveSelectedDeviceId(null);

    // Nettoyage sans reconnexion (on a désactivé _autoReconnectEnabled)
    _resetBuffer();
    _batterySubscription = null;
    _buttonSubscription = null;
    _connectedDevice = null;
    _connectedDeviceName = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _buttonCharacteristic = null;
    _batteryCharacteristic = null;
    _fwVersionCharacteristic = null;
    _firmwareVersion = null;
    _firmwareVersionController.add(null);
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
  // DEBUG LOG FIRMWARE
  // ---------------------------------------------------------------------------

  /// Active les notifications Debug Log (appelé par DebugScreen à l'ouverture)
  Future<void> enableDebugLog() async {
    if (_debugLogCharacteristic == null) return;
    await _debugLogCharacteristic!.setNotifyValue(true);
    _debugLogSubscription?.cancel();
    _debugLogSubscription =
        _debugLogCharacteristic!.onValueReceived.listen((data) {
      if (data.isNotEmpty) {
        final logMessage = utf8.decode(data, allowMalformed: true);
        _debugLogController.add(logMessage);
      }
    });
    // ignore: avoid_print
    print('BLE: Debug Log activé');
  }

  /// Désactive les notifications Debug Log (appelé par DebugScreen à la fermeture)
  Future<void> disableDebugLog() async {
    _debugLogSubscription?.cancel();
    _debugLogSubscription = null;
    if (_debugLogCharacteristic != null) {
      try {
        await _debugLogCharacteristic!.setNotifyValue(false);
      } catch (_) {}
    }
    // ignore: avoid_print
    print('BLE: Debug Log désactivé');
  }

  // ---------------------------------------------------------------------------
  // HEARTBEAT
  // ---------------------------------------------------------------------------

  /// Démarre un timer périodique qui lit la batterie pour vérifier que le lien
  /// BLE est toujours vivant. Un échec déclenche une reconnexion immédiate.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: _heartbeatIntervalSec),
      (_) async {
        if (_connectionState != BleConnectionState.connected) return;
        final char = _batteryCharacteristic;
        if (char == null) return;
        try {
          final value = await char.read().timeout(const Duration(seconds: 5));
          if (value.isNotEmpty) _decodeBatteryValue(value[0]);
        } catch (e) {
          if (_connectionState == BleConnectionState.connected) {
            // ignore: avoid_print
            print('BLE: Heartbeat échoué → reconnexion forcée ($e)');
            _handleDisconnection();
          }
        }
      },
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ---------------------------------------------------------------------------
  // NETTOYAGE
  // ---------------------------------------------------------------------------

  /// Libère toutes les ressources
  Future<void> dispose() async {
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    _btStateSubscription?.cancel();
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
