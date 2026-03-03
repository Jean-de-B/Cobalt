import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/ai_action.dart';
import 'contact_lookup_service.dart';
import 'contact_history_service.dart';

/// =============================================================================
/// local_messaging_service.dart
/// =============================================================================
/// Service pour envoyer des messages via WhatsApp, Telegram, Signal, Messenger.
/// Recherche d'abord le contact dans le répertoire pour obtenir le numéro.
/// =============================================================================

/// Résultat d'une opération de messagerie
class MessagingResult {
  final bool success;
  final String? error;
  final String? resolvedContact;
  final String? phoneNumber;

  const MessagingResult({
    required this.success,
    this.error,
    this.resolvedContact,
    this.phoneNumber,
  });

  factory MessagingResult.success({String? contact, String? phone}) =>
      MessagingResult(success: true, resolvedContact: contact, phoneNumber: phone);

  factory MessagingResult.failure(String error) =>
      MessagingResult(success: false, error: error);
}

class LocalMessagingService {
  bool _initialized = false;
  final ContactLookupService _contactLookup = ContactLookupService();
  final ContactHistoryService _contactHistory = ContactHistoryService();

  /// Package names des apps de messagerie
  static const Map<MessagingApp, String> _packageNames = {
    MessagingApp.whatsapp: 'com.whatsapp',
    MessagingApp.telegram: 'org.telegram.messenger',
    MessagingApp.signal: 'org.thoughtcrime.securesms',
    MessagingApp.messenger: 'com.facebook.orca',
  };

  /// Initialise le service
  Future<void> initialize() async {
    if (_initialized) return;

    await _contactLookup.initialize();
    await _contactHistory.initialize();
    _initialized = true;
    // ignore: avoid_print
    print('[Messaging] Service initialisé');
  }

  /// Envoie un message via une app de messagerie
  Future<MessagingResult> sendMessage({
    required MessagingApp app,
    required String recipient,
    required String message,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    try {
      switch (app) {
        case MessagingApp.whatsapp:
          return await _sendWhatsApp(recipient, message);
        case MessagingApp.telegram:
          return await _sendTelegram(recipient, message);
        case MessagingApp.signal:
          return await _sendSignal(recipient, message);
        case MessagingApp.messenger:
          return await _sendMessenger(recipient, message);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Messaging] Erreur: $e');
      return MessagingResult.failure(e.toString());
    }
  }

  /// Envoie un message WhatsApp
  Future<MessagingResult> _sendWhatsApp(String recipient, String message) async {
    // ignore: avoid_print
    print('[Messaging] WhatsApp -> $recipient: $message');

    // Étape 1: Résoudre le numéro de téléphone
    String? phoneNumber;
    String? resolvedName;

    // Vérifier si c'est déjà un numéro
    final cleanNumber = recipient.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleanNumber.length >= 8) {
      phoneNumber = cleanNumber;
    } else {
      // Rechercher dans les contacts
      final lookupResult = await _contactLookup.findContact(recipient);
      if (lookupResult.found && lookupResult.phoneNumber != null) {
        phoneNumber = lookupResult.phoneNumber!.replaceAll(RegExp(r'[^\d+]'), '');
        resolvedName = lookupResult.displayName;
        // ignore: avoid_print
        print('[Messaging] Contact trouvé: "$resolvedName" -> $phoneNumber');
      }
    }

    // Étape 2: Construire le deep link WhatsApp
    final encodedMessage = Uri.encodeComponent(message);
    Uri uri;

    if (phoneNumber != null && phoneNumber.isNotEmpty) {
      // Avec numéro - ajouter le préfixe pays si nécessaire
      final formattedNumber = phoneNumber.startsWith('+') ? phoneNumber : '+33${phoneNumber.substring(1)}';
      uri = Uri.parse('whatsapp://send?phone=$formattedNumber&text=$encodedMessage');
      // ignore: avoid_print
      print('[Messaging] WhatsApp avec numéro: $formattedNumber');
    } else {
      // ignore: avoid_print
      print('[Messaging] Contact non trouvé, ouverture WhatsApp sans numéro');
      return MessagingResult.failure('Contact "$recipient" non trouvé dans le répertoire');
    }

    // Étape 3: Lancer WhatsApp
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);

      // Enregistrer dans l'historique des contacts
      await _contactHistory.recordContact(
        contactName: resolvedName ?? recipient,
        phoneNumber: phoneNumber,
        app: 'whatsapp',
      );

      // ignore: avoid_print
      print('[Messaging] WhatsApp ouvert pour: ${resolvedName ?? phoneNumber}');
      return MessagingResult.success(contact: resolvedName, phone: phoneNumber);
    } else {
      // Fallback: ouvrir WhatsApp via intent
      return await _openAppWithIntent(MessagingApp.whatsapp);
    }
  }

  /// Envoie un message Telegram
  Future<MessagingResult> _sendTelegram(String recipient, String message) async {
    // ignore: avoid_print
    print('[Messaging] Telegram -> $recipient: $message');

    // Telegram supporte les deep links
    // Format: tg://msg?text=MESSAGE&to=USERNAME

    final encodedMessage = Uri.encodeComponent(message);
    final uri = Uri.parse('tg://msg?text=$encodedMessage');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      // ignore: avoid_print
      print('[Messaging] Telegram ouvert');
      return MessagingResult.success();
    } else {
      return await _openAppWithIntent(MessagingApp.telegram);
    }
  }

  /// Envoie un message Signal
  Future<MessagingResult> _sendSignal(String recipient, String message) async {
    // ignore: avoid_print
    print('[Messaging] Signal -> $recipient: $message');

    // Signal utilise sms:// ou des intents
    // On ouvre simplement l'app
    return await _openAppWithIntent(MessagingApp.signal);
  }

  /// Envoie un message Messenger
  Future<MessagingResult> _sendMessenger(String recipient, String message) async {
    // ignore: avoid_print
    print('[Messaging] Messenger -> $recipient: $message');

    // Messenger deep link
    final uri = Uri.parse('fb-messenger://');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      // ignore: avoid_print
      print('[Messaging] Messenger ouvert');
      return MessagingResult.success();
    } else {
      return await _openAppWithIntent(MessagingApp.messenger);
    }
  }

  /// Ouvre une app via intent Android
  Future<MessagingResult> _openAppWithIntent(MessagingApp app) async {
    final packageName = _packageNames[app];

    if (packageName == null) {
      return MessagingResult.failure('App non supportée');
    }

    // ignore: avoid_print
    print('[Messaging] Ouverture via intent: $packageName');

    final intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      package: packageName,
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    try {
      await intent.launch();
      return MessagingResult.success();
    } catch (e) {
      // ignore: avoid_print
      print('[Messaging] App non installée: $packageName');
      return MessagingResult.failure('${app.name} n\'est pas installé');
    }
  }

  /// Vérifie si une app de messagerie est installée
  Future<bool> isAppInstalled(MessagingApp app) async {
    final packageName = _packageNames[app];
    if (packageName == null) return false;

    final intent = AndroidIntent(
      action: 'android.intent.action.MAIN',
      package: packageName,
    );

    return await intent.canResolveActivity() ?? false;
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
