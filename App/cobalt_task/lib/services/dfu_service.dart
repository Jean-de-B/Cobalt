import 'dart:async';
import 'dart:io';
import 'package:nordic_dfu/nordic_dfu.dart';
import 'ble_service.dart';

// ignore: avoid_print
void _dfuLog(String msg) => print('[DFU] $msg');

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
    await Future<void>.delayed(const Duration(milliseconds: 2500));

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

    // Timer de diagnostic : log toutes les 5s une fois le transfert à 100%
    // pour mesurer combien de temps le bootloader met à répondre.
    Timer? diagTimer;
    final sw = Stopwatch();

    void cancelDiag() {
      diagTimer?.cancel();
      diagTimer = null;
    }

    void startDiag() {
      sw.start();
      diagTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _dfuLog('DIAG post-100%: ${sw.elapsed.inSeconds}s écoulés'
            ' | état=${_state.name}'
            ' | progress=${(_progress * 100).toInt()}%'
            ' | aucun callback (onFirmwareValidating/onDeviceDisconnected/'
            'onDfuCompleted) reçu depuis 100%');
      });
    }

    try {
      _dfuLog('startDfu → adresse=$dfuAddress  forceDfu=true');
      await NordicDfu().startDfu(
        dfuAddress,
        firmwareZipPath,
        fileInAsset: false,
        // PRN activé : le bootloader Adafruit nRF52 sature sa file HCI quand
        // les paquets arrivent plus vite qu'il n'écrit en flash → gel à 100%.
        // dataDelay=400 : délai inter-objets recommandé pour SDK 15/16, donne
        // le temps au bootloader de préparer la flash entre chaque objet (4 KB).
        // rebootTime=1000 : laisse 1 s au bootloader pour rebooter.
        // Note : numberOfPackets (PRN=8) n'est pas exposé par nordic_dfu 6.2 ;
        // la lib Android sous-jacente choisit la valeur par défaut (12).
        androidSpecialParameter: const AndroidSpecialParameter(
          packetReceiptNotificationsEnabled: true,
          dataDelay: 400,
          rebootTime: 1000,
        ),
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
            if (percent == 100) {
              _dfuLog('▶ 100% atteint — démarrage timer diagnostic.'
                  ' En attente de: onFirmwareValidating → onDeviceDisconnecting'
                  ' → onDeviceDisconnected → onDfuCompleted');
              startDiag();
            }
          }
        },
        onError: (
          String deviceAddress,
          int? error,
          int? errorType,
          String? message,
        ) {
          cancelDiag();
          _dfuLog('✗ onError: code=$error  type=$errorType  msg="$message"'
              '  (après ${sw.elapsed.inSeconds}s post-100%)');
          _setError('Erreur DFU: ${message ?? "code $error"}');
        },
        onDfuCompleted: (String deviceAddress) {
          cancelDiag();
          _dfuLog('✓ onDfuCompleted (après ${sw.elapsed.inSeconds}s post-100%)');
          _setState(DfuState.completed);
          _setStatus('Mise à jour terminée!');
          _progress = 1.0;
          _progressController.add(1.0);
          _bleService.enableAutoReconnect();
        },
        onDfuAborted: (String deviceAddress) {
          cancelDiag();
          _dfuLog('✗ onDfuAborted (après ${sw.elapsed.inSeconds}s post-100%)');
          _setError('Mise à jour annulée');
          _bleService.enableAutoReconnect();
        },
        onDeviceConnecting: (String deviceAddress) {
          _dfuLog('→ onDeviceConnecting: $deviceAddress');
          _setStatus('Connexion au bootloader...');
        },
        onDeviceConnected: (String deviceAddress) {
          _dfuLog('→ onDeviceConnected: $deviceAddress');
          _setStatus('Connecté au bootloader');
        },
        onDfuProcessStarting: (String deviceAddress) {
          _dfuLog('→ onDfuProcessStarting');
          _setStatus('Démarrage de la mise à jour...');
        },
        onDfuProcessStarted: (String deviceAddress) {
          _dfuLog('→ onDfuProcessStarted');
          _setStatus('Transfert en cours...');
        },
        onEnablingDfuMode: (String deviceAddress) {
          _dfuLog('→ onEnablingDfuMode');
          _setStatus('Activation du mode DFU...');
        },
        onFirmwareValidating: (String deviceAddress) {
          _dfuLog('→ onFirmwareValidating (après ${sw.elapsed.inSeconds}s post-100%)');
          _setStatus('Validation du firmware...');
        },
        onDeviceDisconnecting: (String deviceAddress) {
          _dfuLog('→ onDeviceDisconnecting (après ${sw.elapsed.inSeconds}s post-100%)');
          _setStatus('Redémarrage de l\'appareil...');
        },
        onDeviceDisconnected: (String deviceAddress) {
          _dfuLog('→ onDeviceDisconnected (après ${sw.elapsed.inSeconds}s post-100%)');
          _setStatus('Appareil redémarré');
          // Fallback: le bootloader Adafruit (0x1530) ne déclenche pas toujours
          // onDfuCompleted. Disconnect à 100% = DFU réussi.
          if (_progress >= 1.0 && _state == DfuState.uploading) {
            cancelDiag();
            _dfuLog('✓ Complété via fallback onDeviceDisconnected');
            _setState(DfuState.completed);
            _setStatus('Mise à jour terminée!');
            _bleService.enableAutoReconnect();
          }
        },
      ).timeout(
        const Duration(minutes: 3),
        onTimeout: () {
          cancelDiag();
          if (_progress >= 1.0 && _state == DfuState.uploading) {
            _dfuLog('✓ Timeout 3 min après 100% → traité comme succès'
                ' (${sw.elapsed.inSeconds}s post-100%)');
            _setState(DfuState.completed);
            _setStatus('Mise à jour terminée!');
            _bleService.enableAutoReconnect();
          } else if (_state == DfuState.uploading) {
            _dfuLog('✗ Timeout 3 min à ${(_progress * 100).toInt()}%');
            _setError('Timeout DFU (${(_progress * 100).toInt()}% transféré)');
            _bleService.enableAutoReconnect();
          }
          return null;
        },
      );

      cancelDiag();
      _dfuLog('startDfu Future terminé | état final=${_state.name}'
          '  progress=${(_progress * 100).toInt()}%'
          '  post-100%=${sw.elapsed.inSeconds}s');

      // Fallback final: Future terminée normalement sans onDfuCompleted.
      if (_state == DfuState.uploading) {
        if (_progress >= 1.0) {
          _dfuLog('✓ Fallback final: Future à 100% sans onDfuCompleted → succès');
          _setState(DfuState.completed);
          _setStatus('Mise à jour terminée!');
          _bleService.enableAutoReconnect();
        } else {
          _dfuLog('✗ Fallback final: Future terminée à ${(_progress * 100).toInt()}% sans completion');
          _setError('DFU interrompu à ${(_progress * 100).toInt()}%');
          _bleService.enableAutoReconnect();
        }
      }

      return _state == DfuState.completed;
    } catch (e) {
      cancelDiag();
      _dfuLog('✗ Exception: $e');
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
