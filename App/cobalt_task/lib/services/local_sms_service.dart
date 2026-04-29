import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/services.dart';
import 'contact_lookup_service.dart';
import 'contact_history_service.dart';

/// =============================================================================
/// local_sms_service.dart
/// =============================================================================
/// Service pour envoyer des SMS sur Android.
///
/// Deux modes de fonctionnement:
/// 1. Mode DIRECT: Envoi automatique sans UI (arrière-plan, écran verrouillé)
///    Utilise SmsManager natif via MethodChannel
/// 2. Mode UI: Ouvre l'app SMS avec message pré-rempli (fallback)
///
/// Le mode direct nécessite la permission SEND_SMS.
/// =============================================================================

/// Résultat d'une opération SMS
class SmsResult {
  final bool success;
  final String? error;
  final String? resolvedContact; // Nom du contact trouvé
  final String? phoneNumber; // Numéro utilisé
  final bool sentDirectly; // true si envoyé en arrière-plan

  const SmsResult({
    required this.success,
    this.error,
    this.resolvedContact,
    this.phoneNumber,
    this.sentDirectly = false,
  });

  factory SmsResult.success({
    String? contact,
    String? phone,
    bool direct = false,
  }) =>
      SmsResult(
        success: true,
        resolvedContact: contact,
        phoneNumber: phone,
        sentDirectly: direct,
      );

  factory SmsResult.failure(String error) =>
      SmsResult(success: false, error: error);
}

class LocalSmsService {
  bool _initialized = false;
  final ContactLookupService _contactLookup = ContactLookupService();
  final ContactHistoryService _contactHistory = ContactHistoryService();

  /// Canal natif pour l'envoi SMS direct
  static const MethodChannel _smsChannel = MethodChannel('com.cobalt_task/sms');

  /// Mode d'envoi: true = direct (arrière-plan), false = via app SMS
  bool _directMode = true;

  /// Anti-doublon : hash du dernier SMS envoyé + timestamp
  String? _lastSmsHash;
  DateTime? _lastSmsTime;

  /// Active/désactive le mode direct
  bool get directMode => _directMode;
  set directMode(bool value) => _directMode = value;

  /// Initialise le service
  Future<void> initialize() async {
    if (_initialized) return;
    await _contactLookup.initialize();
    await _contactHistory.initialize();
    _initialized = true;
    // ignore: avoid_print
    print('[SMS] Service initialisé - Mode direct: $_directMode');
  }

  /// Envoie un SMS
  /// En mode direct: envoi automatique en arrière-plan
  /// En mode UI: ouvre l'app SMS avec message pré-rempli
  Future<SmsResult> sendSms({
    required String recipient,
    required String message,
    bool? forceDirect, // Override le mode par défaut
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // Anti-doublon : ignorer si même destinataire+message dans les 10 dernières secondes
      final hash = '$recipient|$message';
      if (_lastSmsHash == hash && _lastSmsTime != null &&
          DateTime.now().difference(_lastSmsTime!).inSeconds < 10) {
        // ignore: avoid_print
        print('[SMS] Doublon détecté (${DateTime.now().difference(_lastSmsTime!).inSeconds}s) → ignoré');
        return SmsResult.success(contact: recipient, phone: '', direct: true);
      }
      _lastSmsHash = hash;
      _lastSmsTime = DateTime.now();

      // Résoudre le numéro de téléphone
      final (phoneNumber, resolvedName) = await _resolvePhoneNumber(recipient);

      if (phoneNumber == null) {
        return SmsResult.failure(
          'Contact "$recipient" non trouvé dans le répertoire',
        );
      }

      // Décider du mode d'envoi
      final useDirectMode = forceDirect ?? _directMode;

      if (useDirectMode) {
        // Mode direct: envoi via SmsManager natif
        final result = await _sendSmsDirect(phoneNumber, message);

        // Le timeout Android (10s) retourne true si le broadcast ne revient pas
        // → le SMS est considéré envoyé. Pas de retry pour éviter les doublons.
        if (result) {
          await _contactHistory.recordContact(
            contactName: resolvedName ?? recipient,
            phoneNumber: phoneNumber,
            app: 'sms',
          );
          // ignore: avoid_print
          print('[SMS] Envoyé directement à: ${resolvedName ?? phoneNumber}');
          return SmsResult.success(
            contact: resolvedName,
            phone: phoneNumber,
            direct: true,
          );
        } else {
          // Échec confirmé par l'OS (pas un timeout) — ne pas retenter
          // ignore: avoid_print
          print('[SMS] Échec confirmé par l\'OS (pas de retry)');
          return SmsResult.failure('Échec envoi SMS à ${resolvedName ?? phoneNumber}');
        }
      } else {
        // Mode UI: ouvrir l'app SMS
        return await _sendSmsViaApp(phoneNumber, message, resolvedName, recipient);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[SMS] Erreur: $e');
      return SmsResult.failure(e.toString());
    }
  }

  /// Résout un nom de contact en numéro de téléphone
  Future<(String?, String?)> _resolvePhoneNumber(String recipient) async {
    // Vérifier si c'est déjà un numéro
    final cleanNumber = recipient.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleanNumber.length >= 10) {
      // ignore: avoid_print
      print('[SMS] Numéro direct: $cleanNumber');
      return (cleanNumber, null);
    }

    // Rechercher dans les contacts
    // ignore: avoid_print
    print('[SMS] Recherche du contact: "$recipient"');
    final lookupResult = await _contactLookup.findContact(recipient);

    if (lookupResult.found && lookupResult.phoneNumber != null) {
      final phoneNumber = lookupResult.phoneNumber!.replaceAll(RegExp(r'[^\d+]'), '');
      // ignore: avoid_print
      print('[SMS] Contact trouvé: "${lookupResult.displayName}" -> $phoneNumber');
      return (phoneNumber, lookupResult.displayName);
    }

    // ignore: avoid_print
    print('[SMS] Contact non trouvé');
    return (null, null);
  }

  /// Envoie un SMS directement via SmsManager natif (arrière-plan)
  Future<bool> _sendSmsDirect(String phoneNumber, String message) async {
    try {
      final result = await _smsChannel.invokeMethod<bool>('sendSms', {
        'phoneNumber': phoneNumber,
        'message': message,
      });

      return result ?? false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[SMS] Erreur PlatformException: ${e.message}');
      return false;
    } catch (e) {
      // ignore: avoid_print
      print('[SMS] Erreur envoi direct: $e');
      return false;
    }
  }

  /// Ouvre l'app SMS avec message pré-rempli (mode UI)
  Future<SmsResult> _sendSmsViaApp(
    String phoneNumber,
    String message,
    String? resolvedName,
    String recipient,
  ) async {
    final intent = AndroidIntent(
      action: 'android.intent.action.SENDTO',
      data: 'smsto:$phoneNumber',
      arguments: <String, dynamic>{
        'sms_body': message,
      },
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();

    // Enregistrer dans l'historique
    await _contactHistory.recordContact(
      contactName: resolvedName ?? recipient,
      phoneNumber: phoneNumber,
      app: 'sms',
    );

    // ignore: avoid_print
    print('[SMS] App SMS ouverte pour: ${resolvedName ?? phoneNumber}');
    return SmsResult.success(
      contact: resolvedName,
      phone: phoneNumber,
      direct: false,
    );
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
