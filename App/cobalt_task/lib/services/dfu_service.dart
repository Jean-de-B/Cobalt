import 'dart:async';
import 'dart:io';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'ble_service.dart';

/// État du processus DFU
enum DfuState {
  idle,
  preparingDevice,    // Envoi commande DFU au device
  waitingForDfu,      // Attente que le device apparaisse en mode DFU
  uploading,          // Transfert du firmware
  completed,          // Mise à jour réussie
  error,              // Erreur
}

/// Service de mise à jour firmware OTA via Nordic DFU.
///
/// Flow:
/// 1. Envoie la commande DFU au device connecté (0xFD)
/// 2. Le device redémarre en mode bootloader (apparaît comme "DfuTarg")
/// 3. Scanne BLE pour trouver le DfuTarg (nouvelle adresse MAC)
/// 4. Transfère le package DFU (.zip) via le protocole Nordic DFU
/// 5. Le device redémarre avec le nouveau firmware
class DfuService {
  static DfuService? _instance;

  final BleService _bleService;

  /// État courant du DFU
  DfuState _state = DfuState.idle;
  DfuState get state => _state;

  /// Progression du transfert (0.0 à 1.0)
  double _progress = 0.0;
  double get progress => _progress;

  /// Message de statut courant
  String _statusMessage = '';
  String get statusMessage => _statusMessage;

  /// Stream pour notifier l'UI
  final _stateController = StreamController<DfuState>.broadcast();
  Stream<DfuState> get stateStream => _stateController.stream;

  final _progressController = StreamController<double>.broadcast();
  Stream<double> get progressStream => _progressController.stream;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  /// Erreur éventuelle
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  DfuService._internal(this._bleService);

  factory DfuService(BleService bleService) {
    _instance ??= DfuService._internal(bleService);
    return _instance!;
  }

  /// Lance la mise à jour firmware.
  ///
  /// [firmwareZipPath] : chemin vers le fichier .zip DFU
  Future<bool> startDfu(String firmwareZipPath) async {
    if (_state == DfuState.uploading || _state == DfuState.preparingDevice) {
      // ignore: avoid_print
      print('DFU: Mise à jour déjà en cours');
      return false;
    }

    // Vérifier que le fichier existe
    final file = File(firmwareZipPath);
    if (!await file.exists()) {
      _setError('Fichier firmware introuvable: $firmwareZipPath');
      return false;
    }

    _errorMessage = null;
    _progress = 0.0;
    _progressController.add(0.0);

    // Étape 1: Envoyer la commande DFU au device
    _setState(DfuState.preparingDevice);
    _setStatus('Préparation de l\'appareil...');

    final success = await _bleService.triggerDfuMode();
    if (!success) {
      _setError('Impossible d\'envoyer la commande DFU');
      _bleService.enableAutoReconnect();
      return false;
    }

    // Étape 2: Attendre que le device redémarre en mode bootloader,
    // puis scanner pour trouver le DfuTarg.
    // Note: triggerDfuMode() a déjà attendu 300ms et supprimé le bond.
    _setState(DfuState.waitingForDfu);
    _setStatus('Attente du bootloader (DfuTarg)...');

    // Attendre que le bootloader démarre et commence à advertiser.
    // triggerDfuMode() a déjà attendu 300ms → total ~1s avant le scan,
    // ce qui couvre le reset firmware (~800ms) + init bootloader (~200ms).
    await Future<void>.delayed(const Duration(milliseconds: 700));

    // Scanner pour trouver le DfuTarg
    _setStatus('Recherche du bootloader DFU...');
    final dfuAddress = await _bleService.scanForDfuTarget(timeoutSeconds: 20);

    if (dfuAddress == null) {
      _setError('Bootloader DFU non trouvé.\n'
          'Le device n\'est peut-être pas entré en mode DFU.\n'
          'Réessayez ou redémarrez la montre.');
      _bleService.enableAutoReconnect();
      return false;
    }

    // Étape 3: Lancer le transfert DFU vers la nouvelle adresse
    _setState(DfuState.uploading);
    _setStatus('Transfert du firmware...');

    try {
      await NordicDfu().startDfu(
        dfuAddress,
        firmwareZipPath,
        fileInAsset: false,
        forceDfu: true,
        onProgressChanged: (
          String deviceAddress,
          int? percent,
          double? speed,
          double? avgSpeed,
          int? currentPart,
          int? partsTotal,
        ) {
          if (percent != null) {
            _progress = percent / 100.0;
            _progressController.add(_progress);
            _setStatus('Transfert: $percent% (${speed?.toStringAsFixed(1)} KB/s)');
          }
        },
        onError: (
          String deviceAddress,
          int? error,
          int? errorType,
          String? message,
        ) {
          // ignore: avoid_print
          print('DFU ERROR: $error, type: $errorType, msg: $message');
          _setError('Erreur DFU: ${message ?? "code $error"}');
        },
        onDfuCompleted: (String deviceAddress) {
          // ignore: avoid_print
          print('DFU: Terminé avec succès!');
          _setState(DfuState.completed);
          _setStatus('Mise à jour terminée!');
          _progress = 1.0;
          _progressController.add(1.0);
          _bleService.enableAutoReconnect();
        },
        onDfuAborted: (String deviceAddress) {
          // ignore: avoid_print
          print('DFU: Abandonné');
          _setError('Mise à jour annulée');
          _bleService.enableAutoReconnect();
        },
        onDeviceConnecting: (String deviceAddress) {
          _setStatus('Connexion au bootloader...');
        },
        onDeviceConnected: (String deviceAddress) {
          _setStatus('Connecté au bootloader');
        },
        onDfuProcessStarting: (String deviceAddress) {
          _setStatus('Démarrage de la mise à jour...');
        },
        onDfuProcessStarted: (String deviceAddress) {
          _setStatus('Transfert en cours...');
        },
        onEnablingDfuMode: (String deviceAddress) {
          _setStatus('Activation du mode DFU...');
        },
        onFirmwareValidating: (String deviceAddress) {
          _setStatus('Validation du firmware...');
        },
        onDeviceDisconnecting: (String deviceAddress) {
          _setStatus('Redémarrage de l\'appareil...');
        },
        onDeviceDisconnected: (String deviceAddress) {
          _setStatus('Appareil redémarré');
        },
      );

      return _state == DfuState.completed;
    } catch (e) {
      _setError('Erreur DFU: $e');
      _bleService.enableAutoReconnect();
      return false;
    }
  }

  /// Annule une mise à jour en cours
  Future<void> abort() async {
    try {
      await NordicDfu().abortDfu();
    } catch (e) {
      // ignore: avoid_print
      print('DFU: Erreur abort: $e');
    }
    _bleService.enableAutoReconnect();
  }

  /// Réinitialise l'état du DFU
  void reset() {
    _setState(DfuState.idle);
    _progress = 0.0;
    _progressController.add(0.0);
    _statusMessage = '';
    _statusController.add('');
    _errorMessage = null;
    _bleService.enableAutoReconnect();
  }

  void _setState(DfuState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  void _setStatus(String message) {
    _statusMessage = message;
    _statusController.add(message);
    // ignore: avoid_print
    print('DFU: $message');
  }

  void _setError(String message) {
    _errorMessage = message;
    _setState(DfuState.error);
    _setStatus(message);
    // ignore: avoid_print
    print('DFU ERROR: $message');
  }

  Future<void> dispose() async {
    await _stateController.close();
    await _progressController.close();
    await _statusController.close();
  }
}
