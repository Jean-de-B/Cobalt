import 'dart:async';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:geolocator/geolocator.dart';
import 'package:volume_controller/volume_controller.dart';
import '../models/ai_action.dart';
import '../models/fiche.dart';
import '../services/ai_sorter_service.dart';
import 'ble_service.dart';
import 'local_media_service.dart';
import 'local_system_control_service.dart';
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
/// Bouton principal (D1) :
/// - Single press  → Toggle Play/Pause média
/// - Double press  → Piste suivante
/// - Triple press  → Bookmark GPS silencieux (crée une Fiche)
/// - Long press    → Push-to-talk (géré côté firmware, informatif ici)
///
/// Bouton Volume Up (D2) :
/// - Single press  → Volume Up
/// - Double press  → Next Track
/// - Triple press  → Mute/Unmute
///
/// Bouton Volume Down (D3) :
/// - Single press  → Volume Down
/// - Double press  → Previous Track
/// - Triple press  → Voice Assistant
/// =============================================================================

/// Types d'événements bouton (correspondent aux valeurs firmware)
enum HardwareButtonEvent {
  // Main button (D1)
  single,    // 0x01
  doubleTap, // 0x02
  triple,    // 0x03
  longStart, // 0x04
  longStop,  // 0x05
  // Volume Up button (D2)
  volumeUp,    // 0x11
  nextTrack,   // 0x12
  muteToggle,  // 0x13
  // Volume Down button (D3)
  volumeDown,      // 0x21
  prevTrack,       // 0x22
  voiceAssistant,  // 0x23
}

class HardwareButtonService {
  static HardwareButtonService? _instance;

  final BleService _bleService;
  final LocalMediaService _mediaService;
  final LocalSystemControlService _systemControlService;
  final DatabaseService _databaseService;

  StreamSubscription? _buttonSubscription;

  /// Stream pour l'UI (feedback visuel, debug)
  final _eventController = StreamController<HardwareButtonEvent>.broadcast();
  Stream<HardwareButtonEvent> get eventStream => _eventController.stream;

  HardwareButtonService._internal()
      : _bleService = BleService(),
        _mediaService = LocalMediaService(),
        _systemControlService = LocalSystemControlService(),
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
      // Main button (D1)
      0x01 => HardwareButtonEvent.single,
      0x02 => HardwareButtonEvent.doubleTap,
      0x03 => HardwareButtonEvent.triple,
      0x04 => HardwareButtonEvent.longStart,
      0x05 => HardwareButtonEvent.longStop,
      // Volume Up button (D2)
      0x11 => HardwareButtonEvent.volumeUp,
      0x12 => HardwareButtonEvent.nextTrack,
      0x13 => HardwareButtonEvent.muteToggle,
      // Volume Down button (D3)
      0x21 => HardwareButtonEvent.volumeDown,
      0x22 => HardwareButtonEvent.prevTrack,
      0x23 => HardwareButtonEvent.voiceAssistant,
      _ => null,
    };
  }

  void _dispatchAction(HardwareButtonEvent event) {
    switch (event) {
      // Main button (D1)
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
      // Volume Up button (D2)
      case HardwareButtonEvent.volumeUp:
        _handleVolumeUp();
      case HardwareButtonEvent.nextTrack:
        _handleNextTrack();
      case HardwareButtonEvent.muteToggle:
        _handleMuteToggle();
      // Volume Down button (D3)
      case HardwareButtonEvent.volumeDown:
        _handleVolumeDown();
      case HardwareButtonEvent.prevTrack:
        _handlePrevTrack();
      case HardwareButtonEvent.voiceAssistant:
        _handleVoiceAssistant();
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

  // === VOLUME UP BUTTON (D2) HANDLERS ===

  /// Volume Up : single press
  /// Si Spotify joue sur un appareil distant → volume Spotify API
  /// Sinon (local ou pas Spotify) → volume Android
  Future<void> _handleVolumeUp() async {
    // ignore: avoid_print
    print('[HWButton] Vol+ → volumeUp');
    try {
      if (_mediaService.spotifyService.isConnected && await _isSpotifyRemote()) {
        final current = await _mediaService.spotifyService.getVolume();
        if (current != null) {
          final newVol = (current + 10).clamp(0, 100);
          await _mediaService.spotifyService.setVolume(newVol);
          // ignore: avoid_print
          print('[HWButton] Spotify volume (distant): $current → $newVol');
          return;
        }
      }
      await _systemControlService.execute(controlType: SystemControlType.volumeUp);
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur volume: $e');
    }
  }

  /// Next Track : double press vol up
  Future<void> _handleNextTrack() async {
    // ignore: avoid_print
    print('[HWButton] Vol+ x2 → next track');
    try {
      await _mediaService.execute(controlType: MediaControlType.next);
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur média: $e');
    }
  }

  /// Mute Toggle : triple press vol up
  /// Alterne entre mute (0%) et le volume précédent
  final VolumeController _volumeController = VolumeController();
  double _volumeBeforeMute = 0.5;
  bool _isMuted = false;

  Future<void> _handleMuteToggle() async {
    // ignore: avoid_print
    print('[HWButton] Vol+ x3 → mute toggle (muted=$_isMuted)');
    try {
      if (_isMuted) {
        // Restaurer le volume précédent
        _volumeController.setVolume(_volumeBeforeMute);
        _isMuted = false;
        // ignore: avoid_print
        print('[HWButton] Unmute → volume ${(_volumeBeforeMute * 100).toInt()}%');
      } else {
        // Sauvegarder le volume actuel puis muter
        _volumeBeforeMute = await _volumeController.getVolume();
        _volumeController.setVolume(0);
        _isMuted = true;
        // ignore: avoid_print
        print('[HWButton] Mute (was ${(_volumeBeforeMute * 100).toInt()}%)');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur mute: $e');
    }
  }

  /// Vérifie si Spotify joue sur un appareil distant (pas ce téléphone)
  Future<bool> _isSpotifyRemote() async {
    try {
      final state = await _mediaService.spotifyService.getPlayerState();
      final device = state?['device'] as Map<String, dynamic>?;
      final type = (device?['type'] as String? ?? '').toLowerCase();
      return type != 'smartphone';
    } catch (_) {
      return false;
    }
  }

  // === VOLUME DOWN BUTTON (D3) HANDLERS ===

  /// Volume Down : single press
  /// Si Spotify joue sur un appareil distant → volume Spotify API
  /// Sinon (local ou pas Spotify) → volume Android
  Future<void> _handleVolumeDown() async {
    // ignore: avoid_print
    print('[HWButton] Vol- → volumeDown');
    try {
      if (_mediaService.spotifyService.isConnected && await _isSpotifyRemote()) {
        final current = await _mediaService.spotifyService.getVolume();
        if (current != null) {
          final newVol = (current - 10).clamp(0, 100);
          await _mediaService.spotifyService.setVolume(newVol);
          // ignore: avoid_print
          print('[HWButton] Spotify volume (distant): $current → $newVol');
          return;
        }
      }
      await _systemControlService.execute(controlType: SystemControlType.volumeDown);
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur volume: $e');
    }
  }

  /// Previous Track : double press vol down
  Future<void> _handlePrevTrack() async {
    // ignore: avoid_print
    print('[HWButton] Vol- x2 → previous track');
    try {
      await _mediaService.execute(controlType: MediaControlType.previous);
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur média: $e');
    }
  }

  /// Voice Assistant : triple press vol down
  Future<void> _handleVoiceAssistant() async {
    // ignore: avoid_print
    print('[HWButton] Vol- x3 → voice assistant');
    try {
      const intent = AndroidIntent(
        action: 'android.intent.action.VOICE_ASSIST',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
    } catch (e) {
      // ignore: avoid_print
      print('[HWButton] Erreur voice assistant: $e');
    }
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
