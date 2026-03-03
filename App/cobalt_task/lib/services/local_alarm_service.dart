import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

/// =============================================================================
/// local_alarm_service.dart
/// =============================================================================
/// Service pour créer des alarmes et timers via Android Intents.
/// Utilise android_intent_plus pour communiquer avec l'app Horloge système.
///
/// PERMISSIONS REQUISES (AndroidManifest.xml):
/// <uses-permission android:name="com.android.alarm.permission.SET_ALARM"/>
///
/// Note: Ces intents ouvrent l'app Horloge système, pas de permission spéciale
/// requise pour l'utilisateur.
/// =============================================================================

/// Résultat d'une opération alarme/timer
class AlarmResult {
  final bool success;
  final String? error;

  const AlarmResult({required this.success, this.error});

  factory AlarmResult.success() => const AlarmResult(success: true);
  factory AlarmResult.failure(String error) =>
      AlarmResult(success: false, error: error);
}

class LocalAlarmService {
  bool _initialized = false;

  /// Initialise le service
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    // ignore: avoid_print
    print('[Alarm] Service initialisé');
  }

  /// Définit une alarme à une heure précise
  ///
  /// Utilise l'intent ACTION_SET_ALARM pour ouvrir l'app Horloge
  Future<AlarmResult> setAlarm({
    required DateTime time,
    String? label,
  }) async {
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.HOUR': time.hour,
          'android.intent.extra.alarm.MINUTES': time.minute,
          'android.intent.extra.alarm.MESSAGE': label ?? 'Alarme Cobalt',
          'android.intent.extra.alarm.SKIP_UI': false, // Montrer la confirmation
        },
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );

      await intent.launch();

      // ignore: avoid_print
      print(
          '[Alarm] Intent lancé: ${time.hour}:${time.minute.toString().padLeft(2, '0')}');
      return AlarmResult.success();
    } catch (e) {
      // ignore: avoid_print
      print('[Alarm] Erreur: $e');
      return AlarmResult.failure(e.toString());
    }
  }

  /// Lance un minuteur (timer)
  ///
  /// Utilise l'intent ACTION_SET_TIMER pour ouvrir l'app Horloge
  Future<AlarmResult> setTimer({
    required int durationSeconds,
    String? label,
  }) async {
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_TIMER',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.LENGTH': durationSeconds,
          'android.intent.extra.alarm.MESSAGE': label ?? 'Minuteur Cobalt',
          'android.intent.extra.alarm.SKIP_UI': false, // Montrer la confirmation
        },
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );

      await intent.launch();

      // ignore: avoid_print
      print('[Alarm] Timer lancé: ${durationSeconds}s');
      return AlarmResult.success();
    } catch (e) {
      // ignore: avoid_print
      print('[Alarm] Erreur timer: $e');
      return AlarmResult.failure(e.toString());
    }
  }

  /// Ouvre l'application Horloge
  Future<void> openClockApp() async {
    final intent = AndroidIntent(
      action: 'android.intent.action.SHOW_ALARMS',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );
    await intent.launch();
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
