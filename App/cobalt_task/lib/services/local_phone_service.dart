import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:url_launcher/url_launcher.dart';
import 'contact_lookup_service.dart';
import 'contact_history_service.dart';

/// =============================================================================
/// local_phone_service.dart
/// =============================================================================
/// Service pour passer des appels téléphoniques sur Android.
/// Recherche d'abord le contact dans le répertoire pour obtenir le numéro.
/// =============================================================================

/// Résultat d'une opération d'appel
class PhoneResult {
  final bool success;
  final String? error;
  final String? resolvedContact;
  final String? phoneNumber;

  const PhoneResult({
    required this.success,
    this.error,
    this.resolvedContact,
    this.phoneNumber,
  });

  factory PhoneResult.success({String? contact, String? phone}) =>
      PhoneResult(success: true, resolvedContact: contact, phoneNumber: phone);

  factory PhoneResult.failure(String error) =>
      PhoneResult(success: false, error: error);
}

class LocalPhoneService {
  bool _initialized = false;
  final ContactLookupService _contactLookup = ContactLookupService();
  final ContactHistoryService _contactHistory = ContactHistoryService();

  /// Initialise le service
  Future<void> initialize() async {
    if (_initialized) return;

    await _contactLookup.initialize();
    await _contactHistory.initialize();
    _initialized = true;
    // ignore: avoid_print
    print('[Phone] Service initialisé');
  }

  /// Passe un appel téléphonique
  /// Recherche d'abord le contact dans le répertoire
  Future<PhoneResult> call({
    required String contact,
    String? phoneNumber,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // Si un numéro est déjà fourni, l'utiliser directement
      if (phoneNumber != null && phoneNumber.isNotEmpty) {
        return await _callNumber(phoneNumber, contact);
      }

      // Vérifier si le contact est un numéro
      final cleanNumber = contact.replaceAll(RegExp(r'[^\d+]'), '');
      if (cleanNumber.length >= 8) {
        return await _callNumber(cleanNumber, null);
      }

      // Rechercher le contact dans le répertoire
      // ignore: avoid_print
      print('[Phone] Recherche du contact: "$contact"');
      final lookupResult = await _contactLookup.findContact(contact);

      if (lookupResult.found && lookupResult.phoneNumber != null) {
        // ignore: avoid_print
        print('[Phone] Contact trouvé: "${lookupResult.displayName}" -> ${lookupResult.phoneNumber}');
        return await _callNumber(lookupResult.phoneNumber!, lookupResult.displayName);
      } else {
        // ignore: avoid_print
        print('[Phone] Contact non trouvé: "$contact"');
        return PhoneResult.failure('Contact "$contact" non trouvé dans le répertoire');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Phone] Erreur: $e');
      return PhoneResult.failure(e.toString());
    }
  }

  /// Appelle directement un numéro avec ACTION_CALL (appel direct)
  Future<PhoneResult> _callNumber(String number, String? contactName) async {
    // Nettoyer le numéro
    final cleanNumber = number.replaceAll(RegExp(r'[^\d+]'), '');

    try {
      // Utiliser ACTION_CALL pour lancer l'appel directement
      final intent = AndroidIntent(
        action: 'android.intent.action.CALL',
        data: Uri.encodeFull('tel:$cleanNumber'),
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );

      await intent.launch();

      // Enregistrer dans l'historique des contacts
      if (contactName != null) {
        await _contactHistory.recordContact(
          contactName: contactName,
          phoneNumber: cleanNumber,
          app: 'call',
        );
      }

      // ignore: avoid_print
      print('[Phone] Appel direct lancé: ${contactName ?? cleanNumber}');
      return PhoneResult.success(contact: contactName, phone: cleanNumber);
    } catch (e) {
      // ignore: avoid_print
      print('[Phone] Erreur appel direct: $e');
      return PhoneResult.failure('Impossible de lancer l\'appel: $e');
    }
  }

  /// Appelle via WhatsApp
  /// Note: WhatsApp n'a pas de deep link officiel pour les appels directs.
  /// On ouvre le chat WhatsApp du contact avec le bouton appel visible.
  Future<PhoneResult> callWhatsApp({
    required String phoneNumber,
    String? contactName,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      // Nettoyer et formater le numéro (format international sans +)
      final cleanNumber = phoneNumber.replaceAll(RegExp(r'[^\d+]'), '');
      // Retirer le + et le 0 initial pour format WhatsApp
      String waNumber = cleanNumber;
      if (waNumber.startsWith('+')) {
        waNumber = waNumber.substring(1);
      } else if (waNumber.startsWith('0')) {
        waNumber = '33${waNumber.substring(1)}'; // France par défaut
      }

      // ignore: avoid_print
      print('[Phone] Appel WhatsApp pour: $waNumber');

      // Méthode 1: Intent Android pour ouvrir WhatsApp avec le contact
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: 'https://wa.me/$waNumber',
        package: 'com.whatsapp',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );

      try {
        await intent.launch();

        // Enregistrer dans l'historique
        if (contactName != null) {
          await _contactHistory.recordContact(
            contactName: contactName,
            phoneNumber: cleanNumber,
            app: 'whatsapp',
          );
        }

        // ignore: avoid_print
        print('[Phone] WhatsApp ouvert pour: ${contactName ?? waNumber}');
        return PhoneResult.success(contact: contactName, phone: cleanNumber);
      } catch (e) {
        // ignore: avoid_print
        print('[Phone] Intent WhatsApp échoué: $e, essai avec URL...');
      }

      // Méthode 2: Fallback avec URL launcher
      final uri = Uri.parse('https://wa.me/$waNumber');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);

        if (contactName != null) {
          await _contactHistory.recordContact(
            contactName: contactName,
            phoneNumber: cleanNumber,
            app: 'whatsapp',
          );
        }

        // ignore: avoid_print
        print('[Phone] WhatsApp ouvert via URL: ${contactName ?? waNumber}');
        return PhoneResult.success(contact: contactName, phone: cleanNumber);
      }

      // ignore: avoid_print
      print('[Phone] WhatsApp non disponible');
      return PhoneResult.failure('WhatsApp non disponible');
    } catch (e) {
      // ignore: avoid_print
      print('[Phone] Erreur appel WhatsApp: $e');
      return PhoneResult.failure(e.toString());
    }
  }

  /// Ouvre directement l'app téléphone
  Future<PhoneResult> openDialer() async {
    final intent = AndroidIntent(
      action: 'android.intent.action.DIAL',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();
    return PhoneResult.success();
  }

  /// Getter pour accéder à l'historique (utilisé par le dispatcher)
  ContactHistoryService get contactHistory => _contactHistory;

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
