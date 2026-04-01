import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/services.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:torch_light/torch_light.dart';
import '../models/ai_action.dart';

/// =============================================================================
/// local_system_control_service.dart
/// =============================================================================
/// Service pour contrôler les paramètres système Android.
///
/// Fonctionnalités:
/// - Volume (volume_controller)
/// - Ne pas déranger (ouvre les paramètres)
/// - WiFi/Bluetooth/Mode avion (ouvre les paramètres)
/// - Luminosité (ouvre les paramètres)
/// - Lampe torche (via intent caméra)
///
/// PERMISSIONS REQUISES (AndroidManifest.xml):
/// - ACCESS_NOTIFICATION_POLICY pour le mode Ne pas déranger
/// =============================================================================

/// Résultat d'une opération de contrôle système
class SystemControlResult {
  final bool success;
  final String? error;
  final double? currentVolume;

  const SystemControlResult({
    required this.success,
    this.error,
    this.currentVolume,
  });

  factory SystemControlResult.success([double? volume]) =>
      SystemControlResult(success: true, currentVolume: volume);

  factory SystemControlResult.failure(String error) =>
      SystemControlResult(success: false, error: error);
}

class LocalSystemControlService {
  bool _initialized = false;
  final VolumeController _volumeController = VolumeController();
  static const _mediaChannel = MethodChannel('com.cobalt_task/media_keys');

  /// Initialise le service
  Future<void> initialize() async {
    if (_initialized) return;

    // Désactiver l'UI système lors du changement de volume
    _volumeController.showSystemUI = false;

    _initialized = true;
    // ignore: avoid_print
    print('[SystemControl] Service initialisé');
  }

  /// Exécute une commande de contrôle système
  Future<SystemControlResult> execute({
    required SystemControlType controlType,
    int? value,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      switch (controlType) {
        // === VOLUME ===
        case SystemControlType.volumeUp:
          return await _volumeUp();

        case SystemControlType.volumeDown:
          return await _volumeDown();

        case SystemControlType.volumeSet:
          return await _setVolume(value ?? 50);

        case SystemControlType.volumeMute:
          return await _setVolume(0);

        // === MODES SONORES ===
        case SystemControlType.vibrate:
          return await _setVolume(0);

        case SystemControlType.silent:
          return await _setVolume(0);

        case SystemControlType.normal:
          return await _setVolume(50);

        // === NE PAS DÉRANGER ===
        case SystemControlType.dndOn:
          return await _openDndSettings(enable: true);

        case SystemControlType.dndOff:
          return await _openDndSettings(enable: false);

        // === CONNECTIVITÉ ===
        case SystemControlType.wifiToggle:
          return await _openSettings('android.settings.WIFI_SETTINGS', 'Wi-Fi');

        case SystemControlType.bluetoothToggle:
          return await _openSettings('android.settings.BLUETOOTH_SETTINGS', 'Bluetooth');

        case SystemControlType.airplaneToggle:
          return await _openSettings('android.settings.AIRPLANE_MODE_SETTINGS', 'Mode avion');

        // === ÉCRAN ===
        case SystemControlType.brightnessUp:
        case SystemControlType.brightnessDown:
          return await _openSettings('android.settings.DISPLAY_SETTINGS', 'Luminosité');

        case SystemControlType.flashlightOn:
          return await _toggleFlashlight(on: true);

        case SystemControlType.flashlightOff:
          return await _toggleFlashlight(on: false);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[SystemControl] Erreur: $e');
      return SystemControlResult.failure(e.toString());
    }
  }

  /// Augmente le volume (1 palier Android natif via AudioManager)
  Future<SystemControlResult> _volumeUp() async {
    final result = await _mediaChannel.invokeMethod('volumeUp');
    final map = Map<String, dynamic>.from(result);
    final percent = (map['current'] * 100.0 / map['max']).round();
    // ignore: avoid_print
    print('[SystemControl] Volume: $percent% (${map['current']}/${map['max']})');
    return SystemControlResult.success(percent / 100.0);
  }

  /// Diminue le volume (1 palier Android natif via AudioManager)
  Future<SystemControlResult> _volumeDown() async {
    final result = await _mediaChannel.invokeMethod('volumeDown');
    final map = Map<String, dynamic>.from(result);
    final percent = (map['current'] * 100.0 / map['max']).round();
    // ignore: avoid_print
    print('[SystemControl] Volume: $percent% (${map['current']}/${map['max']})');
    return SystemControlResult.success(percent / 100.0);
  }

  /// Définit le volume à une valeur précise (0-100)
  Future<SystemControlResult> _setVolume(int percent) async {
    final volume = (percent / 100.0).clamp(0.0, 1.0);
    _volumeController.setVolume(volume);
    // ignore: avoid_print
    print('[SystemControl] Volume défini: $percent%');
    return SystemControlResult.success(volume);
  }

  /// Ouvre les paramètres Ne pas déranger
  Future<SystemControlResult> _openDndSettings({required bool enable}) async {
    // ignore: avoid_print
    print('[SystemControl] Ouverture paramètres Ne pas déranger...');

    final intent = AndroidIntent(
      action: 'android.settings.ZEN_MODE_SETTINGS',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();

    // ignore: avoid_print
    print('[SystemControl] Paramètres DND ouverts - ${enable ? "activer" : "désactiver"} manuellement');
    return SystemControlResult.success();
  }

  /// Ouvre une page de paramètres Android
  Future<SystemControlResult> _openSettings(String action, String name) async {
    // ignore: avoid_print
    print('[SystemControl] Ouverture paramètres $name...');

    final intent = AndroidIntent(
      action: action,
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();

    // ignore: avoid_print
    print('[SystemControl] Paramètres $name ouverts');
    return SystemControlResult.success();
  }

  /// Active/désactive la lampe torche
  Future<SystemControlResult> _toggleFlashlight({required bool on}) async {
    // ignore: avoid_print
    print('[SystemControl] Lampe torche: ${on ? "ON" : "OFF"}');

    try {
      // Vérifier si la lampe torche est disponible
      final isTorchAvailable = await TorchLight.isTorchAvailable();

      if (!isTorchAvailable) {
        // ignore: avoid_print
        print('[SystemControl] Lampe torche non disponible sur cet appareil');
        return SystemControlResult.failure('Lampe torche non disponible');
      }

      if (on) {
        await TorchLight.enableTorch();
        // ignore: avoid_print
        print('[SystemControl] Lampe torche activée');
      } else {
        await TorchLight.disableTorch();
        // ignore: avoid_print
        print('[SystemControl] Lampe torche désactivée');
      }

      return SystemControlResult.success();
    } catch (e) {
      // ignore: avoid_print
      print('[SystemControl] Erreur lampe torche: $e');
      return SystemControlResult.failure('Erreur lampe torche: $e');
    }
  }

  /// Récupère le volume actuel (0.0 - 1.0)
  Future<double> getVolume() async {
    return await _volumeController.getVolume();
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;

  /// Libère les ressources
  void dispose() {
    _volumeController.removeListener();
  }
}
