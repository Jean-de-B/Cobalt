import 'dart:async';
import 'package:geolocator/geolocator.dart';
import '../models/ai_action.dart';
import '../models/fiche.dart';
import '../services/ai_sorter_service.dart';
import 'ble_service.dart';
import 'local_media_service.dart';
import 'database_service.dart';

/// =============================================================================
/// hardware_button_service.dart
/// =============================================================================
/// Service de gestion des événements bouton hardware du bracelet Cobalt.
///
/// Le firmware détecte les gestes (single/double/triple/long press) via une
/// machine à états et envoie un byte d'événement via BLE. Ce service reçoit
/// ces événements et les route vers les actions appropriées.
///
/// Actions configurables :
/// - Single press  → Toggle Play/Pause média
/// - Double press  → Piste suivante
/// - Triple press  → Bookmark GPS silencieux (crée une Fiche)
/// - Long press    → Push-to-talk (géré côté firmware, informatif ici)
/// =============================================================================

/// Types d'événements bouton (correspondent aux valeurs firmware)
enum HardwareButtonEvent {
  single,    // 0x01
  doubleTap, // 0x02
  triple,    // 0x03
  longStart, // 0x04
  longStop,  // 0x05
}

class HardwareButtonService {
  static HardwareButtonService? _instance;

  final BleService _bleService;
  final LocalMediaService _mediaService;
  final DatabaseService _databaseService;

  StreamSubscription? _buttonSubscription;

  /// Stream pour l'UI (feedback visuel, debug)
  final _eventController = StreamController<HardwareButtonEvent>.broadcast();
  Stream<HardwareButtonEvent> get eventStream => _eventController.stream;

  HardwareButtonService._internal()
      : _bleService = BleService(),
        _mediaService = LocalMediaService(),
        _databaseService = DatabaseService();

  factory HardwareButtonService() {
    _instance ??= HardwareButtonService._internal();
    return _instance!;
  }

  /// Initialise et s'abonne aux événements bouton BLE
  Future<void> initialize() async {
    _buttonSubscription?.cancel();
    _buttonSubscription = _bleService.buttonEventStream.listen(_handleEvent);
    // ignore: avoid_print
    print('[HWButton] Service initialisé');
  }

  /// Traite un événement bouton brut reçu via BLE
  void _handleEvent(int rawEvent) {
    final event = _parseEvent(rawEvent);
    if (event == null) {
      // ignore: avoid_print
      print('[HWButton] Événement inconnu: 0x${rawEvent.toRadixString(16)}');
      return;
    }

    // ignore: avoid_print
    print('[HWButton] Événement: $event');
    _eventController.add(event);
    _dispatchAction(event);
  }

  HardwareButtonEvent? _parseEvent(int raw) {
    return switch (raw) {
      0x01 => HardwareButtonEvent.single,
      0x02 => HardwareButtonEvent.doubleTap,
      0x03 => HardwareButtonEvent.triple,
      0x04 => HardwareButtonEvent.longStart,
      0x05 => HardwareButtonEvent.longStop,
      _ => null,
    };
  }

  void _dispatchAction(HardwareButtonEvent event) {
    switch (event) {
      case HardwareButtonEvent.single:
        _handleSinglePress();
      case HardwareButtonEvent.doubleTap:
        _handleDoublePress();
      case HardwareButtonEvent.triple:
        _handleTriplePress();
      case HardwareButtonEvent.longStart:
        _handleLongStart();
      case HardwareButtonEvent.longStop:
        _handleLongStop();
    }
  }

  // === HANDLERS D'ACTIONS ===

  /// Single press : toggle play/pause média
  Future<void> _handleSinglePress() async {
    // ignore: avoid_print
    print('[HWButton] Single → togglePlayPause');
    try {
      await _mediaService.execute(controlType: MediaControlType.playPause);
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur média: $e');
    }
  }

  /// Double press : piste suivante
  Future<void> _handleDoublePress() async {
    // ignore: avoid_print
    print('[HWButton] Double → next track');
    try {
      await _mediaService.execute(controlType: MediaControlType.next);
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur média: $e');
    }
  }

  /// Triple press : bookmark GPS silencieux
  Future<void> _handleTriplePress() async {
    // ignore: avoid_print
    print('[HWButton] Triple → GPS bookmark');
    await _createGpsBookmark();
  }

  /// Long press start : enregistrement géré par le firmware
  void _handleLongStart() {
    // ignore: avoid_print
    print('[HWButton] LongStart → enregistrement géré par firmware');
  }

  /// Long press stop : fin d'enregistrement, audio arrive via TX
  void _handleLongStop() {
    // ignore: avoid_print
    print('[HWButton] LongStop → fin enregistrement firmware');
  }

  // === GPS SILENT BOOKMARK ===

  Future<void> _createGpsBookmark() async {
    try {
      // Récupérer la position GPS
      Position? position;
      try {
        position = await Geolocator.getLastKnownPosition();
        position ??= await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 5),
          ),
        );
      } catch (e) {
        // ignore: avoid_print
        print('[HWButton] GPS indisponible: $e');
      }

      // Construire le contenu
      final now = DateTime.now();
      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

      String content;
      if (position != null) {
        final lat = position.latitude.toStringAsFixed(5);
        final lon = position.longitude.toStringAsFixed(5);
        content =
            '\u{1F4CD} Point d\'intérêt marqué ($lat, $lon) à $timeStr';
      } else {
        content =
            '\u{1F4CD} Point d\'intérêt marqué à $timeStr (GPS indisponible)';
      }

      // Créer la Fiche
      final fiche = Fiche.fromAnalysis(
        title: 'Repère GPS - $timeStr',
        category: NoteCategory.memo,
        content: content,
      );

      final id = await _databaseService.insertFiche(fiche);
      // ignore: avoid_print
      print('[HWButton] GPS bookmark créé (fiche id: $id)');
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur GPS bookmark: $e');
    }
  }

  // === DEBUG : SIMULATION D'ÉVÉNEMENTS ===

  /// Simule un événement bouton (pour debug sans bracelet)
  void simulateEvent(HardwareButtonEvent event) {
    // ignore: avoid_print
    print('[HWButton] Simulation: $event');
    _eventController.add(event);
    _dispatchAction(event);
  }

  Future<void> dispose() async {
    await _buttonSubscription?.cancel();
    await _eventController.close();
  }
}
