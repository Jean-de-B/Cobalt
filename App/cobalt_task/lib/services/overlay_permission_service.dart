import 'package:flutter/services.dart';

/// =============================================================================
/// overlay_permission_service.dart
/// =============================================================================
/// Gere la permission SYSTEM_ALERT_WINDOW (superposition d'apps).
///
/// Cette permission est necessaire pour que les actions locales (alarmes,
/// appels, navigation, etc.) fonctionnent quand l'app est en arriere-plan.
/// Sans elle, Android 10+ bloque les startActivity() depuis le background.
/// =============================================================================

class OverlayPermissionService {
  static const _channel = MethodChannel('com.cobalt_task/overlay_permission');

  /// Verifie si la permission de superposition est accordee
  static Future<bool> canDrawOverlays() async {
    try {
      final result = await _channel.invokeMethod<bool>('canDrawOverlays');
      return result ?? false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[Overlay] Erreur vérification: ${e.message}');
      return false;
    }
  }

  /// Ouvre les parametres systeme pour accorder la permission
  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestOverlayPermission');
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[Overlay] Erreur demande: ${e.message}');
    }
  }
}
