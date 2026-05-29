/// =============================================================================
/// app_constants.dart
/// =============================================================================
/// Constantes globales de l'application Cobalt Task.
/// Contient les UUIDs BLE, la configuration audio et les styles du thème.
/// =============================================================================

import 'package:flutter/material.dart';

/// -----------------------------------------------------------------------------
/// CONFIGURATION BLUETOOTH LOW ENERGY (BLE)
/// -----------------------------------------------------------------------------
/// Ces UUIDs correspondent au firmware nRF52840 de Cobalt Task.
/// Basé sur le Nordic UART Service (NUS) personnalisé.

class BleConstants {
  /// Préfixe du nom des montres à rechercher lors du scan BLE
  /// Le firmware génère "Cobalt XXXX" (XXXX = ID hardware unique)
  static const String deviceNamePrefix = 'Cobalt ';

  /// UUID du service audio personnalisé (Nordic UART Service modifié)
  static const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

  /// UUID de la caractéristique TX (notifications: appareil → téléphone)
  /// L'appareil envoie les données audio ADPCM via cette caractéristique
  static const String txCharacteristicUuid =
      '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  /// UUID de la caractéristique RX (écriture: téléphone → appareil)
  /// Utilisé pour envoyer des commandes à l'appareil (optionnel)
  static const String rxCharacteristicUuid =
      '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

  /// UUID de la caractéristique Button Event (notifications: appareil → téléphone)
  /// L'appareil envoie les événements bouton (single/double/triple/long) via cette caractéristique
  static const String buttonCharacteristicUuid =
      '6e400004-b5a3-f393-e0a9-e50e24dcca9e';

  /// UUID de la caractéristique Firmware Version (Read + Notify)
  /// Format: 3 bytes [major, minor, patch]
  static const String fwVersionCharacteristicUuid =
      '6e400005-b5a3-f393-e0a9-e50e24dcca9e';

  /// UUID de la caractéristique Debug Log (Notify: firmware → téléphone)
  /// Envoie les logs Serial du firmware en UTF-8 via BLE
  static const String debugLogCharacteristicUuid =
      '6e400006-b5a3-f393-e0a9-e50e24dcca9e';

  /// Commande pour entrer en mode DFU OTA
  static const int cmdEnterDfu = 0xFD;

  /// Commande pour demander la version firmware
  static const int cmdGetVersion = 0xFE;

  /// MTU demandé à l'appareil (Maximum Transmission Unit)
  /// On demande 512, le firmware négocie à 247 (payload effectif: 244 bytes)
  static const int preferredMtu = 512;

  /// Timeout pour le scan BLE (en secondes)
  static const int scanTimeout = 10;

  /// Délai avant tentative de reconnexion (en secondes)
  static const int reconnectDelay = 3;
}

/// -----------------------------------------------------------------------------
/// CONFIGURATION AUDIO ADPCM
/// -----------------------------------------------------------------------------
/// Paramètres correspondant au format audio du firmware nRF52840.
/// Format: IMA ADPCM 4-bit, 16 kHz, Mono

class AudioConstants {
  /// Fréquence d'échantillonnage (Hz)
  static const int sampleRate = 16000;

  /// Nombre de canaux (1 = Mono)
  static const int channels = 1;

  /// Bits par échantillon PCM décodé
  static const int bitsPerSample = 16;

  /// Bits par échantillon ADPCM compressé
  static const int adpcmBitsPerSample = 4;

  /// Taille d'un bloc ADPCM (en échantillons)
  static const int blockSize = 256;

  /// Durée maximale d'enregistrement (en secondes)
  static const int maxRecordingDuration = 15;

  /// Magic number du header CVOX
  static const String cvoxMagic = 'CVOX';

  /// Taille du header CVOX (en bytes)
  static const int cvoxHeaderSize = 36;
}

/// -----------------------------------------------------------------------------
/// THEME DE L'APPLICATION (Warm Cream Theme)
/// -----------------------------------------------------------------------------
/// Palette creme douce avec ombres et typographie sans-serif.

class AppColors {
  // --- Surfaces ---
  static const Color background = Color(0xFFF5F0EB);
  static const Color surface = Color(0xFFFFFFFF);

  // --- Bordure (legacy, utilisee dans les dialogs/dividers) ---
  static const Color border = Color(0xFFE8E3DE);

  // --- Texte ---
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF8A8380);
  static const Color textTertiary = Color(0xFFB0AAA5);

  // --- Accent ---
  static const Color accent = Color(0xFF00C471);

  // --- Categories ---
  static const Color categoryTodo = Color(0xFF4A90D9);
  static const Color categoryEvent = Color(0xFF34A853);
  static const Color categoryContact = Color(0xFF7B61FF);
  static const Color categoryMemo = Color(0xFFE8913A);
  static const Color categoryShopping = Color(0xFF00ACC1);

  // --- Actions locales (backward compat emoji-prefixed summaries) ---
  static const Color actionCalendar = Color(0xFF4285F4);
  static const Color actionSms = Color(0xFF34A853);
  static const Color actionWhatsapp = Color(0xFF25D366);
  static const Color actionCall = Color(0xFF4CAF50);
  static const Color actionNav = Color(0xFFEA4335);
  static const Color actionMedia = Color(0xFF1DB954);
  static const Color actionApp = Color(0xFFE1306C);
  static const Color actionAlarm = Color(0xFFFF9500);
  static const Color actionTimer = Color(0xFFFF6B00);
  static const Color actionSystem = Color(0xFF9C27B0);

  // --- Ombres ---
  static const Color shadowLight = Color(0x1A000000);
  static const Color shadowMedium = Color(0x29000000);

  // --- BLE (fonctionnel) ---
  static const Color bleDisconnected = Color(0xFFB0AAA5);
  static const Color bleConnecting = Color(0xFFFF9500);
  static const Color bleConnected = Color(0xFF34A853);
  static const Color bleSyncing = Color(0xFF4A90D9);
}

/// Typographie : sans-serif par defaut, monospace pour donnees techniques
class AppTextStyles {
  static const TextStyle cardTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.3,
  );

  static const TextStyle cardBody = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.5,
  );

  static const TextStyle noteText = TextStyle(
    fontSize: 14,
    color: AppColors.textPrimary,
    height: 1.5,
  );

  static const TextStyle metadata = TextStyle(
    fontSize: 12,
    color: AppColors.textSecondary,
  );

  static const TextStyle heading = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle technicalData = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  static const TextStyle cardTime = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );
}

/// -----------------------------------------------------------------------------
/// ÉTATS DE CONNEXION BLE
/// -----------------------------------------------------------------------------
/// Énumération des différents états possibles de la connexion Bluetooth.

enum BleConnectionState {
  /// Bluetooth désactivé ou non disponible
  disabled,

  /// Déconnecté, en attente de scan
  disconnected,

  /// Scan en cours
  scanning,

  /// Connexion en cours
  connecting,

  /// Connecté à l'appareil
  connected,

  /// Réception de données en cours
  syncing,

  /// Erreur de connexion
  error,
}
