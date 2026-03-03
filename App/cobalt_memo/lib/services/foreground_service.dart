import 'dart:async';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// =============================================================================
/// foreground_service.dart
/// =============================================================================
/// Service de premier plan pour maintenir l'application active en arrière-plan.
///
/// Fonctionnalités:
/// - Notification persistante "Cobalt Memo - En écoute"
/// - Maintien du CPU actif pendant les opérations critiques
///
/// Utilisé pour:
/// - Réception BLE depuis le bracelet (écran verrouillé)
/// - Transcription API Groq
/// - Traitement de mémos consécutifs sans déverrouiller l'écran
/// =============================================================================

/// Callback pour les tâches en arrière-plan
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(CobaltTaskHandler());
}

/// Handler pour les tâches de premier plan
class CobaltTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // ignore: avoid_print
    print('[ForegroundService] Démarré à $timestamp (starter: $starter)');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Appelé périodiquement (intervalle configurable)
    // Utilisé pour garder le service actif
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // ignore: avoid_print
    print('[ForegroundService] Arrêté à $timestamp');
  }

  @override
  void onNotificationButtonPressed(String id) {
    // ignore: avoid_print
    print('[ForegroundService] Bouton notification: $id');
  }

  @override
  void onNotificationPressed() {
    // Ouvrir l'app quand on clique sur la notification
    FlutterForegroundTask.launchApp();
  }
}

/// Service de gestion du premier plan
class CobaltForegroundService {
  static CobaltForegroundService? _instance;

  bool _isRunning = false;

  /// Singleton
  factory CobaltForegroundService() {
    _instance ??= CobaltForegroundService._internal();
    return _instance!;
  }

  CobaltForegroundService._internal();

  /// Vérifie si le service est en cours d'exécution
  bool get isRunning => _isRunning;

  /// Initialise le service de premier plan
  Future<void> initialize() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cobalt_foreground_service',
        channelName: 'Cobalt Memo Service',
        channelDescription: 'Service d\'écoute Cobalt Memo',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    // ignore: avoid_print
    print('[ForegroundService] Initialisé');
  }

  /// Démarre le service de premier plan
  Future<bool> start() async {
    if (_isRunning) {
      // ignore: avoid_print
      print('[ForegroundService] Déjà en cours');
      return true;
    }

    // Demander les permissions nécessaires
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // Vérifier si on peut ignorer les optimisations de batterie
    final batteryOptimization =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!batteryOptimization) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    // Démarrer le service
    final result = await FlutterForegroundTask.startService(
      notificationTitle: 'Cobalt Memo',
      notificationText: 'En écoute...',
      callback: startCallback,
    );

    if (result is ServiceRequestSuccess) {
      _isRunning = true;
      // ignore: avoid_print
      print('[ForegroundService] Service démarré');
      return true;
    } else {
      // ignore: avoid_print
      print('[ForegroundService] Échec du démarrage');
      return false;
    }
  }

  /// Met à jour la notification
  Future<void> updateNotification({
    required String title,
    required String text,
  }) async {
    if (!_isRunning) return;

    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Affiche une notification temporaire pour une action
  Future<void> showActionNotification(String action) async {
    await updateNotification(
      title: 'Cobalt Memo',
      text: action,
    );

    // Revenir à l'état normal après 3 secondes
    Future.delayed(const Duration(seconds: 3), () {
      updateNotification(
        title: 'Cobalt Memo',
        text: 'En écoute...',
      );
    });
  }

  /// Arrête le service de premier plan
  Future<void> stop() async {
    if (!_isRunning) return;

    await FlutterForegroundTask.stopService();
    _isRunning = false;

    // ignore: avoid_print
    print('[ForegroundService] Service arrêté');
  }

  /// Acquiert un wake lock pour maintenir le CPU actif
  Future<void> acquireWakeLock() async {
    await WakelockPlus.enable();
    // ignore: avoid_print
    print('[ForegroundService] Wake lock acquis');
  }

  /// Libère le wake lock
  Future<void> releaseWakeLock() async {
    await WakelockPlus.disable();
    // ignore: avoid_print
    print('[ForegroundService] Wake lock libéré');
  }

  /// Exécute une opération critique avec wake lock
  Future<T> runWithWakeLock<T>(Future<T> Function() operation) async {
    await acquireWakeLock();
    try {
      return await operation();
    } finally {
      await releaseWakeLock();
    }
  }
}
