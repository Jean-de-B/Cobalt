/// =============================================================================
/// app_constants.dart
/// =============================================================================
/// Constantes globales de l'application Cobalt Voice.
/// Contient les UUIDs BLE, la configuration audio et les styles du thème.
/// =============================================================================

import 'package:flutter/material.dart';

/// -----------------------------------------------------------------------------
/// CONFIGURATION BLUETOOTH LOW ENERGY (BLE)
/// -----------------------------------------------------------------------------
/// Ces UUIDs correspondent au firmware nRF52840 de Cobalt Voice.
/// Basé sur le Nordic UART Service (NUS) personnalisé.

class BleConstants {
  /// Préfixe du nom des montres à rechercher lors du scan BLE
  static const String deviceNamePrefix = 'Cobalt Voice';

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
  static const int cvoxHeaderSize = 34;
}

/// -----------------------------------------------------------------------------
/// THÈME DE L'APPLICATION (Retro-Minimalist Dark Theme)
/// -----------------------------------------------------------------------------
/// Palette de couleurs sombre avec typographie monospace.

class AppColors {
  /// Couleur de fond principale (noir pur)
  static const Color background = Color(0xFF000000);

  /// Couleur de surface pour les cartes
  static const Color surface = Color(0xFF121212);

  /// Couleur de bordure subtile
  static const Color border = Color(0xFF2A2A2A);

  /// Couleur du texte principal (blanc cassé)
  static const Color textPrimary = Color(0xFFE0E0E0);

  /// Couleur du texte secondaire (gris)
  static const Color textSecondary = Color(0xFF888888);

  /// Couleur d'accent (vert rétro)
  static const Color accent = Color(0xFF00FF88);

  /// Indicateur BLE - déconnecté (gris)
  static const Color bleDisconnected = Color(0xFF666666);

  /// Indicateur BLE - en connexion (orange)
  static const Color bleConnecting = Color(0xFFFF9500);

  /// Indicateur BLE - connecté (vert)
  static const Color bleConnected = Color(0xFF00FF88);

  /// Indicateur BLE - synchronisation (bleu)
  static const Color bleSyncing = Color(0xFF00AAFF);
}

/// Style de texte monospace pour l'interface
class AppTextStyles {
  /// Style pour le texte principal des notes
  static const TextStyle noteText = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    color: AppColors.textPrimary,
    height: 1.5,
  );

  /// Style pour les métadonnées (date, durée)
  static const TextStyle metadata = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    color: AppColors.textSecondary,
  );

  /// Style pour les titres
  static const TextStyle heading = TextStyle(
    fontFamily: 'monospace',
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: AppColors.textPrimary,
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
