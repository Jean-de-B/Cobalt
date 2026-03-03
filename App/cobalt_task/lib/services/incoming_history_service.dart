import 'dart:convert';
import 'package:flutter/services.dart';

/// =============================================================================
/// incoming_history_service.dart
/// =============================================================================
/// Bridge Flutter vers CobaltNotificationListener.
/// Permet de savoir sur quelle app un contact nous a ecrit recemment
/// pour repondre sur la meme app.
/// =============================================================================

class IncomingHistoryService {
  static const _channel = MethodChannel('com.cobalt_task/notification_listener');

  /// Verifie si le NotificationListener est active dans les parametres systeme
  static Future<bool> isEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isEnabled');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Ouvre les parametres systeme pour activer le NotificationListener
  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } on PlatformException {
      // ignore
    }
  }

  /// Retourne l'app la plus recente par laquelle un contact nous a ecrit.
  /// Cherche par nom (insensible a la casse, correspondance partielle).
  /// Retourne "whatsapp", "telegram", "signal", "messenger", "sms" ou null.
  static Future<String?> getLastIncomingApp(String contactName) async {
    try {
      final rawHistory = await _channel.invokeMethod<String>('getIncomingHistory');
      if (rawHistory == null || rawHistory == '[]') return null;

      final history = jsonDecode(rawHistory) as List<dynamic>;
      if (history.isEmpty) return null;

      final normalized = contactName.trim().toLowerCase();

      // Chercher la notification la plus recente de ce contact
      String? bestApp;
      int bestTimestamp = 0;

      for (final entry in history) {
        final sender = (entry['sender'] as String?)?.toLowerCase() ?? '';
        final app = entry['app'] as String?;
        final timestamp = entry['timestamp'] as int? ?? 0;

        // Match: le nom du contact est contenu dans le sender ou inversement
        if (sender.contains(normalized) || normalized.contains(sender)) {
          if (timestamp > bestTimestamp) {
            bestTimestamp = timestamp;
            bestApp = app;
          }
        }
      }

      return bestApp;
    } on PlatformException {
      return null;
    }
  }
}
