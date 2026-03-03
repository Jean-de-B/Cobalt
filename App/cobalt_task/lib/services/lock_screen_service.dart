import 'package:flutter/services.dart';

/// =============================================================================
/// lock_screen_service.dart
/// =============================================================================
/// Detection de l'etat de l'ecran (verrouille/deverrouille).
/// Utilise pour forcer SMS quand l'ecran est verrouille
/// (pas d'UI possible pour WhatsApp/Telegram).
/// =============================================================================

class LockScreenService {
  static const _channel = MethodChannel('com.cobalt_task/device_state');

  /// Retourne true si l'ecran est actuellement verrouille
  static Future<bool> isLocked() async {
    try {
      final result = await _channel.invokeMethod<bool>('isScreenLocked');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }
}
