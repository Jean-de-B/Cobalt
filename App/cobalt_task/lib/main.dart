import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'app.dart';
import 'services/audio_service.dart';
import 'services/database_service.dart';
import 'services/foreground_service.dart';
import 'services/audio_feedback_service.dart';
import 'services/sherpa_transcription_service.dart';
import 'services/hardware_button_service.dart';
import 'services/settings_service.dart';

/// =============================================================================
/// main.dart
/// =============================================================================
/// Point d'entree de l'application Cobalt Task.
///
/// Strategie d'initialisation:
/// 1. Flutter bindings + config legere (orientation, .env)
/// 2. runApp() IMMEDIATEMENT pour afficher l'UI
/// 3. Services lourds initialises en arriere-plan apres le premier frame
///    (permissions, BLE, Sherpa, foreground service)
///
/// Cela evite le blocage sur l'ecran de demarrage natif Android
/// si un service met du temps a repondre (ex: Sherpa sur certains appareils).
/// =============================================================================

Future<void> main() async {
  // Assurer l'initialisation des bindings Flutter
  WidgetsFlutterBinding.ensureInitialized();

  // Configurer l'orientation (portrait uniquement)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Configurer la barre de statut (transparente)
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Charger les variables d'environnement (rapide, fichier local)
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    // ignore: avoid_print
    print('Avertissement: Fichier .env non trouve. '
        'La transcription Whisper ne fonctionnera pas sans cle API Groq.');
  }

  // LANCER L'UI IMMEDIATEMENT
  // Les services lourds s'initialisent en arriere-plan apres le premier frame
  runApp(const CobaltTaskApp());

  // Initialiser les services apres le premier frame
  // (l'utilisateur voit l'ecran d'accueil pendant ce temps)
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _initializeServices();
  });
}

/// Initialise tous les services lourds avec timeouts de securite.
/// Chaque etape est dans un try-catch pour ne jamais bloquer l'app.
Future<void> _initializeServices() async {
  // ignore: avoid_print
  print('INIT: Demarrage initialisation des services...');

  // 1. Permissions (peut afficher des dialogues systeme)
  try {
    await _requestPermissions().timeout(const Duration(seconds: 20));
  } catch (e) {
    // ignore: avoid_print
    print('INIT: Permissions timeout/erreur: $e');
  }

  // 2. Base de donnees SQLite (rapide normalement)
  try {
    final databaseService = DatabaseService();
    await databaseService.database.timeout(const Duration(seconds: 10));
    // ignore: avoid_print
    print('INIT: Base de donnees initialisee');
  } catch (e) {
    // ignore: avoid_print
    print('INIT: Erreur base de donnees: $e');
  }

  // 2b. Service de paramètres
  await SettingsService().initialize();
  // ignore: avoid_print
  print('INIT: SettingsService initialisé');

  // 3. Service de feedback audio (TTS)
  try {
    final audioFeedback = AudioFeedbackService();
    await audioFeedback.initialize().timeout(const Duration(seconds: 5));
    // ignore: avoid_print
    print('INIT: AudioFeedback initialise');
  } catch (e) {
    // ignore: avoid_print
    print('INIT: Erreur AudioFeedback: $e');
  }

  // 4. Sherpa STT offline (charge une librairie native - peut echouer sur certains appareils)
  try {
    final sherpaService = SherpaTranscriptionService();
    await sherpaService.initialize().timeout(const Duration(seconds: 10));
    // ignore: avoid_print
    print('INIT: Sherpa initialise (isReady: ${sherpaService.isReady})');
  } catch (e) {
    // ignore: avoid_print
    print('INIT: Sherpa timeout/erreur (fallback cloud): $e');
  }

  // 5. Service audio principal (BLE, foreground service, media, etc.)
  try {
    final audioService = AudioService();
    await audioService.initialize().timeout(const Duration(seconds: 20));
    // ignore: avoid_print
    print('INIT: AudioService initialise');
  } catch (e) {
    // ignore: avoid_print
    print('INIT: Erreur AudioService: $e');
  }

  // 6. Service bouton hardware (événements bracelet → actions)
  try {
    final hwButtonService = HardwareButtonService();
    await hwButtonService.initialize().timeout(const Duration(seconds: 5));
    // ignore: avoid_print
    print('INIT: HardwareButtonService initialisé');
  } catch (e) {
    // ignore: avoid_print
    print('INIT: Erreur HardwareButtonService: $e');
  }

  // ignore: avoid_print
  print('INIT: Tous les services initialises');
}

/// Demande les permissions necessaires au demarrage
Future<void> _requestPermissions() async {
  // Permissions Bluetooth (Android 12+)
  final bluetoothScan = await Permission.bluetoothScan.request();
  final bluetoothConnect = await Permission.bluetoothConnect.request();

  // Permission de localisation (requise pour le scan BLE sur Android)
  final location = await Permission.locationWhenInUse.request();

  // Permission microphone (pour l'enregistrement vocal)
  final microphone = await Permission.microphone.request();

  // Permission contacts (pour la recherche de contacts SMS/Messagerie)
  final contacts = await Permission.contacts.request();

  // Permission appels telephoniques (pour ACTION_CALL direct)
  final phone = await Permission.phone.request();

  // Permission SMS (pour envoi direct en arriere-plan)
  final sms = await Permission.sms.request();

  // Permission notifications (Android 13+, pour foreground service)
  final notification = await Permission.notification.request();

  // Log des resultats (pour debug)
  // ignore: avoid_print
  print('Permissions - '
      'BT Scan: $bluetoothScan, '
      'BT Connect: $bluetoothConnect, '
      'Location: $location, '
      'Micro: $microphone, '
      'Contacts: $contacts, '
      'Phone: $phone, '
      'SMS: $sms, '
      'Notification: $notification');
}
