import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// =============================================================================
/// foreground_service.dart
/// =============================================================================
/// Service de premier plan pour maintenir l'application active en arrière-plan.
///
/// Fonctionnalités:
/// - Notification persistante "Cobalt Task" avec bouton micro
/// - Maintien du CPU actif pendant les opérations critiques
/// - Communication avec l'UI via SendPort/ReceivePort + MethodChannel natif
///
/// Le bouton micro de la notification est géré côté natif Android
/// (via com.cobalt_task/custom_notification MethodChannel) pour garantir
/// l'affichage sur Samsung One UI. Le plugin flutter_foreground_task
/// ne rend pas les boutons correctement sur Samsung (icône null).
/// =============================================================================

/// Callback pour les tâches en arrière-plan
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(CobaltTaskHandler());
}

/// Handler pour les tâches de premier plan
class CobaltTaskHandler extends TaskHandler {
  @override
  void onStart(DateTime timestamp, SendPort? sendPort) async {
    // ignore: avoid_print
    print('[ForegroundService] Handler démarré à $timestamp');
  }

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    // Garde le service actif
  }

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) async {
    // ignore: avoid_print
    print('[ForegroundService] Handler arrêté à $timestamp');
  }

  @override
  void onNotificationButtonPressed(String id) {
    // ignore: avoid_print
    print('[ForegroundService] Plugin button pressed: $id (unused - native handles this)');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}

/// Service de gestion du premier plan
class CobaltForegroundService {
  static CobaltForegroundService? _instance;

  /// MethodChannel natif pour la notification custom avec bouton micro
  static const _nativeNotifChannel = MethodChannel('com.cobalt_task/custom_notification');

  bool _isRunning = false;
  ReceivePort? _receivePort;
  final _micButtonController = StreamController<bool>.broadcast();
  final _assistRecordController = StreamController<bool>.broadcast();

  /// Stream qui emet true quand le bouton micro de la notification est presse.
  Stream<bool> get micButtonStream => _micButtonController.stream;

  /// Stream qui emet true quand un ASSIST broadcast est recu (Power long-press).
  Stream<bool> get assistRecordStream => _assistRecordController.stream;

  /// Singleton
  factory CobaltForegroundService() {
    _instance ??= CobaltForegroundService._internal();
    return _instance!;
  }

  CobaltForegroundService._internal() {
    // Écouter les appuis sur le bouton micro depuis le natif Android
    _nativeNotifChannel.setMethodCallHandler(_handleNativeCall);
    // ignore: avoid_print
    print('[ForegroundService] MethodChannel custom_notification configuré');
  }

  /// Handler pour les appels depuis le natif (bouton micro notification)
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    // ignore: avoid_print
    print('[ForegroundService] Native call: ${call.method}');
    switch (call.method) {
      case 'onMicButtonPressed':
        // ignore: avoid_print
        print('[ForegroundService] Bouton micro natif presse!');
        _micButtonController.add(true);
        break;
      case 'onAssistRecordPressed':
        // ignore: avoid_print
        print('[ForegroundService] ASSIST record broadcast recu!');
        _assistRecordController.add(true);
        break;
    }
  }

  /// Vérifie si le service est en cours d'exécution
  bool get isRunning => _isRunning;

  /// Initialise le service de premier plan
  Future<void> initialize() async {
    // ignore: avoid_print
    print('[ForegroundService] Initialisation...');

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cobalt_foreground_v2',
        channelName: 'Cobalt Task Service',
        channelDescription: 'Service d\'écoute Cobalt Task',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
        iconData: const NotificationIconData(
          resType: ResourceType.drawable,
          resPrefix: ResourcePrefix.ic,
          name: 'notification',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 300000,
        isOnceEvent: true,
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    // Vérifier les permissions UNE SEULE FOIS au démarrage
    try {
      final notificationPermission =
          await FlutterForegroundTask.checkNotificationPermission();
      // ignore: avoid_print
      print('[ForegroundService] Permission notification: $notificationPermission');
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      final batteryOptimization =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      // ignore: avoid_print
      print('[ForegroundService] Battery optimization ignorée: $batteryOptimization');
      if (!batteryOptimization) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[ForegroundService] Erreur permissions: $e');
    }

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

    // ignore: avoid_print
    print('[ForegroundService] Démarrage du service...');

    _receivePort = FlutterForegroundTask.receivePort;
    _receivePort?.listen((message) {
      // ignore: avoid_print
      print('[ForegroundService] ReceivePort message: $message');
    });

    final success = await FlutterForegroundTask.startService(
      notificationTitle: 'Cobalt Task',
      notificationText: '',
      callback: startCallback,
    );

    if (success) {
      _isRunning = true;
      // ignore: avoid_print
      print('[ForegroundService] Service démarré OK');

      // Remplacer la notification du plugin par notre version native
      // avec le bouton micro garanti visible sur Samsung
      await _showNativeMicNotification('Cobalt Task', '', false);
    } else {
      // ignore: avoid_print
      print('[ForegroundService] ÉCHEC du démarrage du service');
    }

    return success;
  }

  /// Affiche/met a jour la notification native avec bouton micro
  Future<void> _showNativeMicNotification(String title, String text, bool isRecording) async {
    try {
      await _nativeNotifChannel.invokeMethod('showMicNotification', {
        'title': title,
        'text': text,
        'isRecording': isRecording,
      });
      // ignore: avoid_print
      print('[ForegroundService] Notification native mise à jour: $title - $text (rec=$isRecording)');
    } catch (e) {
      // ignore: avoid_print
      print('[ForegroundService] Erreur notification native: $e');
    }
  }

  /// Met à jour la notification
  Future<void> updateNotification({
    required String title,
    required String text,
    bool isRecording = false,
  }) async {
    if (!_isRunning) return;

    // Mettre à jour via le natif (avec bouton micro)
    await _showNativeMicNotification(title, text, isRecording);
  }

  /// Affiche une notification temporaire pour une action
  Future<void> showActionNotification(String action) async {
    await updateNotification(
      title: 'Cobalt Task',
      text: action,
    );

    // Revenir à l'état normal après 3 secondes
    Future.delayed(const Duration(seconds: 3), () {
      updateNotification(
        title: 'Cobalt Task',
        text: '',
      );
    });
  }

  /// Arrête le service de premier plan
  Future<void> stop() async {
    if (!_isRunning) return;

    await FlutterForegroundTask.stopService();
    _receivePort?.close();
    _receivePort = null;
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
