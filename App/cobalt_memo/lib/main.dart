import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'app.dart';
import 'services/audio_service.dart';
import 'services/database_service.dart';

/// =============================================================================
/// main.dart
/// =============================================================================
/// Point d'entrée de l'application Cobalt Voice.
///
/// Initialise dans l'ordre:
/// 1. Flutter bindings
/// 2. Variables d'environnement (.env)
/// 3. Permissions Bluetooth
/// 4. Base de données SQLite
/// 5. Service audio (pipeline BLE → Transcription)
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

  // Charger les variables d'environnement
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    // Le fichier .env peut ne pas exister en développement
    // ignore: avoid_print
    print('Avertissement: Fichier .env non trouvé. '
        'La transcription ne fonctionnera pas sans clé API Groq.');
  }

  // Demander les permissions Bluetooth
  await _requestPermissions();

  // Initialiser la base de données
  final databaseService = DatabaseService();
  await databaseService.database; // Déclenche l'initialisation

  // Initialiser le service audio
  final audioService = AudioService();
  await audioService.initialize();

  // Lancer l'application
  runApp(const CobaltVoiceApp());
}

/// Demande les permissions nécessaires pour le Bluetooth
Future<void> _requestPermissions() async {
  // Permissions Bluetooth (Android 12+)
  final bluetoothScan = await Permission.bluetoothScan.request();
  final bluetoothConnect = await Permission.bluetoothConnect.request();

  // Permission de localisation (requise pour le scan BLE sur Android)
  final location = await Permission.locationWhenInUse.request();

  // Log des résultats (pour debug)
  // ignore: avoid_print
  print('Permissions - '
      'Bluetooth Scan: $bluetoothScan, '
      'Bluetooth Connect: $bluetoothConnect, '
      'Location: $location');
}
