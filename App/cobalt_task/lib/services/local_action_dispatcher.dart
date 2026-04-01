import '../models/ai_action.dart';
import 'local_calendar_service.dart';
import 'local_sms_service.dart';
import 'local_alarm_service.dart';
import 'local_system_control_service.dart';
import 'local_phone_service.dart';
import 'local_messaging_service.dart';
import 'local_navigation_service.dart';
import 'local_media_service.dart';
import 'local_app_launcher_service.dart';
import 'fintecture_service.dart';
import 'contact_history_service.dart';
import 'validated_contacts_service.dart';
import 'incoming_history_service.dart';
import 'lock_screen_service.dart';
import 'contact_lookup_service.dart';

/// =============================================================================
/// local_action_dispatcher.dart
/// =============================================================================
/// Orchestrateur central pour l'exécution des actions locales Android.
/// Reçoit une AiAction et délègue à la bonne service natif.
/// =============================================================================

/// Résultat d'une action exécutée
class ActionResult {
  final bool success;
  final String message;
  final ActionIntent intent;
  final Map<String, dynamic>? metadata;

  const ActionResult({
    required this.success,
    required this.message,
    required this.intent,
    this.metadata,
  });

  factory ActionResult.success(ActionIntent intent, String message,
          [Map<String, dynamic>? metadata]) =>
      ActionResult(
        success: true,
        message: message,
        intent: intent,
        metadata: metadata,
      );

  factory ActionResult.failure(ActionIntent intent, String message) =>
      ActionResult(
        success: false,
        message: message,
        intent: intent,
      );

  @override
  String toString() =>
      'ActionResult(success: $success, intent: $intent, message: $message)';
}

/// Dispatcher central pour les actions locales
class LocalActionDispatcher {
  static LocalActionDispatcher? _instance;

  final LocalCalendarService _calendarService;
  final LocalSmsService _smsService;
  final LocalAlarmService _alarmService;
  final LocalSystemControlService _systemControlService;
  final LocalPhoneService _phoneService;
  final LocalMessagingService _messagingService;
  final LocalNavigationService _navigationService;
  final LocalMediaService _mediaService;
  final LocalAppLauncherService _appLauncherService;
  final FintectureService _paymentService;
  final ContactHistoryService _contactHistoryService;
  final ValidatedContactsService _validatedContactsService;
  final ContactLookupService _contactLookupService;

  /// Constructeur privé
  LocalActionDispatcher._({
    LocalCalendarService? calendarService,
    LocalSmsService? smsService,
    LocalAlarmService? alarmService,
    LocalSystemControlService? systemControlService,
    LocalPhoneService? phoneService,
    LocalMessagingService? messagingService,
    LocalNavigationService? navigationService,
    LocalMediaService? mediaService,
    LocalAppLauncherService? appLauncherService,
    FintectureService? paymentService,
    ContactHistoryService? contactHistoryService,
    ValidatedContactsService? validatedContactsService,
    ContactLookupService? contactLookupService,
  })  : _calendarService = calendarService ?? LocalCalendarService(),
        _smsService = smsService ?? LocalSmsService(),
        _alarmService = alarmService ?? LocalAlarmService(),
        _systemControlService =
            systemControlService ?? LocalSystemControlService(),
        _phoneService = phoneService ?? LocalPhoneService(),
        _messagingService = messagingService ?? LocalMessagingService(),
        _navigationService = navigationService ?? LocalNavigationService(),
        _mediaService = mediaService ?? LocalMediaService(),
        _appLauncherService = appLauncherService ?? LocalAppLauncherService(),
        _paymentService = paymentService ?? FintectureService(),
        _contactHistoryService = contactHistoryService ?? ContactHistoryService(),
        _validatedContactsService = validatedContactsService ?? ValidatedContactsService(),
        _contactLookupService = contactLookupService ?? ContactLookupService();

  /// Factory Singleton
  factory LocalActionDispatcher() {
    _instance ??= LocalActionDispatcher._();
    return _instance!;
  }

  /// Reset singleton (pour tests)
  static void reset() => _instance = null;

  /// Initialise tous les services
  Future<void> initialize() async {
    await _calendarService.initialize();
    await _smsService.initialize();
    await _alarmService.initialize();
    await _systemControlService.initialize();
    await _phoneService.initialize();
    await _messagingService.initialize();
    await _navigationService.initialize();
    await _mediaService.initialize();
    await _appLauncherService.initialize();
    await _paymentService.initialize();
    await _contactHistoryService.initialize();
    await _contactLookupService.initialize();
    // ignore: avoid_print
    print('[Dispatcher] Tous les services initialisés');
  }

  /// Exécute une action
  Future<ActionResult> dispatch(AiAction action) async {
    // ignore: avoid_print
    print('[Dispatcher] Exécution: ${action.intent} - ${action.reasoning}');

    try {
      return await action.when(
        calendar: _handleCalendar,
        sms: _handleSms,
        alarm: _handleAlarm,
        timer: _handleTimer,
        systemControl: _handleSystemControl,
        call: _handleCall,
        messaging: _handleMessaging,
        message: _handleMessage,
        navigation: _handleNavigation,
        media: _handleMedia,
        appLaunch: _handleAppLaunch,
        payment: _handlePayment,
        none: _handleNone,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[Dispatcher] Erreur: $e');
      return ActionResult.failure(
        action.intent,
        'Erreur lors de l\'exécution: $e',
      );
    }
  }

  /// Gère les actions calendrier
  Future<ActionResult> _handleCalendar(CalendarAction action) async {
    final result = await _calendarService.createEvent(
      title: action.title,
      startTime: action.startTime,
      endTime: action.endTime,
      location: action.location,
      description: action.description,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.calendar,
        'Événement "${action.title}" créé pour le ${_formatDateTime(action.startTime)}',
        {'eventId': result.eventId},
      );
    } else {
      return ActionResult.failure(
        ActionIntent.calendar,
        result.error ?? 'Erreur inconnue',
      );
    }
  }

  /// Gère les actions SMS (avec validation contact obligatoire)
  Future<ActionResult> _handleSms(SmsAction action) async {
    // Vérifier si le contact est validé
    final validated = await _validatedContactsService.resolve(action.recipient);
    if (validated != null) {
      // ignore: avoid_print
      print('[Dispatcher] SMS → contact validé: ${validated.displayName}');
      final result = await _smsService.sendSms(
        recipient: validated.phoneNumber,
        message: action.message,
      );

      if (result.success) {
        return ActionResult.success(
          ActionIntent.sms,
          'SMS envoyé à ${validated.displayName}',
          {'app': 'sms', 'contact': validated.displayName},
        );
      } else {
        return ActionResult.failure(
          ActionIntent.sms,
          result.error ?? 'Erreur d\'envoi SMS',
        );
      }
    }

    // Contact non validé → rechercher suggestions et queuer
    return await _queueUnvalidatedContact(
      action.recipient,
      action.message,
      ActionIntent.sms,
    );
  }

  /// Gère les actions alarme
  Future<ActionResult> _handleAlarm(AlarmAction action) async {
    final result = await _alarmService.setAlarm(
      time: action.time,
      label: action.label,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.alarm,
        'Alarme définie pour ${_formatTime(action.time)}',
      );
    } else {
      return ActionResult.failure(
        ActionIntent.alarm,
        result.error ?? 'Erreur de création d\'alarme',
      );
    }
  }

  /// Gère les actions timer
  Future<ActionResult> _handleTimer(TimerAction action) async {
    final result = await _alarmService.setTimer(
      durationSeconds: action.durationSeconds,
      label: action.label,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.timer,
        'Minuteur de ${action.formattedDuration} lancé',
      );
    } else {
      return ActionResult.failure(
        ActionIntent.timer,
        result.error ?? 'Erreur de création du minuteur',
      );
    }
  }

  /// Gère les actions de contrôle système
  Future<ActionResult> _handleSystemControl(SystemControlAction action) async {
    final result = await _systemControlService.execute(
      controlType: action.controlType,
      value: action.value,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.systemControl,
        _getSystemControlMessage(action.controlType, action.value),
      );
    } else {
      return ActionResult.failure(
        ActionIntent.systemControl,
        result.error ?? 'Erreur de contrôle système',
      );
    }
  }

  /// Gère les actions d'appel téléphonique (avec validation contact obligatoire)
  /// Toujours via l'application téléphone classique (ACTION_CALL)
  Future<ActionResult> _handleCall(CallAction action) async {
    // ignore: avoid_print
    print('[Dispatcher] Appel classique pour: ${action.contact}');

    // Vérifier si le contact est validé
    final validated = await _validatedContactsService.resolve(action.contact);
    if (validated != null) {
      // ignore: avoid_print
      print('[Dispatcher] Appel → contact validé: ${validated.displayName} -> ${validated.phoneNumber}');

      final result = await _phoneService.call(
        contact: validated.displayName,
        phoneNumber: validated.phoneNumber,
      );

      if (result.success) {
        return ActionResult.success(
          ActionIntent.call,
          'Appel vers ${validated.displayName}',
          {'contact': validated.displayName},
        );
      } else {
        return ActionResult.failure(
          ActionIntent.call,
          result.error ?? 'Erreur lors de l\'appel',
        );
      }
    }

    // Contact non validé → rechercher suggestions et queuer (sans message)
    return await _queueUnvalidatedContact(
      action.contact,
      '', // Pas de message pour un appel
      ActionIntent.call,
    );
  }

  /// Gère les actions de messagerie (WhatsApp, Telegram, etc.)
  /// Applique la validation contact + détection écran verrouillé → force SMS
  Future<ActionResult> _handleMessaging(MessagingAction action) async {
    // Vérifier si le contact est validé
    final validated = await _validatedContactsService.resolve(action.recipient);
    if (validated != null) {
      // ignore: avoid_print
      print('[Dispatcher] Messaging → contact validé: ${validated.displayName}');

      // Forcer SMS si écran verrouillé
      final isLocked = await LockScreenService.isLocked();
      if (isLocked) {
        // ignore: avoid_print
        print('[Dispatcher] Écran verrouillé → force SMS (était: ${action.app.name})');
        final result = await _smsService.sendSms(
          recipient: validated.phoneNumber,
          message: action.message,
        );
        if (result.success) {
          return ActionResult.success(
            ActionIntent.messaging,
            'SMS envoyé à ${validated.displayName} (écran verrouillé)',
            {'app': 'sms', 'contact': validated.displayName},
          );
        } else {
          return ActionResult.failure(
            ActionIntent.messaging,
            result.error ?? 'Erreur d\'envoi SMS',
          );
        }
      }

      // Écran déverrouillé → envoyer via l'app demandée
      final result = await _messagingService.sendMessage(
        app: action.app,
        recipient: validated.phoneNumber,
        message: action.message,
      );

      if (result.success) {
        return ActionResult.success(
          ActionIntent.messaging,
          'Message envoyé via ${action.app.name} à ${validated.displayName}',
          {'app': action.app.name, 'contact': validated.displayName},
        );
      } else {
        // Fallback SMS si l'app échoue
        // ignore: avoid_print
        print('[Dispatcher] Échec ${action.app.name}, fallback SMS');
        final smsResult = await _smsService.sendSms(
          recipient: validated.phoneNumber,
          message: action.message,
        );
        if (smsResult.success) {
          return ActionResult.success(
            ActionIntent.messaging,
            'SMS envoyé à ${validated.displayName}',
            {'app': 'sms', 'contact': validated.displayName},
          );
        }
        return ActionResult.failure(
          ActionIntent.messaging,
          result.error ?? 'Erreur d\'envoi du message',
        );
      }
    }

    // Contact non validé → rechercher suggestions et queuer
    return await _queueUnvalidatedContact(
      action.recipient,
      action.message,
      ActionIntent.messaging,
    );
  }

  /// Gère les messages génériques (routage intelligent)
  ///
  /// Logique de validation stricte :
  /// - Seuls les contacts VALIDÉS par l'utilisateur déclenchent un envoi
  /// - Les contacts non validés sont recherchés (historique + fuzzy match)
  ///   puis mis en attente de validation → le message N'EST PAS envoyé
  /// - L'utilisateur confirme le mapping dans l'app → les prochains envois
  ///   seront automatiques
  ///
  /// Pour les contacts validés, sélection de l'app :
  /// 1. IncomingHistory → dernière app par laquelle le contact nous a écrit
  /// 2. ContactHistory → dernière app utilisée pour écrire au contact
  /// 3. SMS par défaut
  /// Si écran verrouillé → force SMS
  Future<ActionResult> _handleMessage(MessageAction action) async {
    // ignore: avoid_print
    print('[Dispatcher] Message générique pour: ${action.recipient}');

    // =========================================================================
    // ÉTAPE 1 : Contact déjà validé ? → SEUL CAS QUI ENVOIE
    // =========================================================================

    final validated = await _validatedContactsService.resolve(action.recipient);
    if (validated != null) {
      // ignore: avoid_print
      print('[Dispatcher] Contact validé: ${validated.displayName} -> ${validated.phoneNumber}');
      return await _sendToValidatedContact(
        validated.phoneNumber,
        validated.displayName,
        action,
      );
    }

    // =========================================================================
    // ÉTAPE 2 : Contact NON validé → rechercher des suggestions, NE PAS ENVOYER
    // =========================================================================

    return await _queueUnvalidatedContact(
      action.recipient,
      action.message,
      ActionIntent.message,
    );
  }

  /// Recherche des suggestions pour un contact non validé et queue une validation
  /// Utilisé par _handleMessage, _handleMessaging et _handleSms
  Future<ActionResult> _queueUnvalidatedContact(
    String recipient,
    String message,
    ActionIntent intent,
  ) async {
    // ignore: avoid_print
    print('[Dispatcher] Contact NON validé: "$recipient" → recherche suggestions');

    String? suggestedName;
    String? suggestedPhone;

    // Tier 2 : Historique des messages sortants
    final history = await _contactHistoryService.findByName(recipient);
    if (history.found && history.phoneNumber != null) {
      suggestedName = history.displayName ?? recipient;
      suggestedPhone = history.phoneNumber;
      // ignore: avoid_print
      print('[Dispatcher] Suggestion historique: $suggestedName -> $suggestedPhone');
    }

    // Tier 3 : Fuzzy match dans les contacts téléphone
    if (suggestedPhone == null) {
      final lookup = await _contactLookupService.findContact(recipient);
      if (lookup.found && lookup.phoneNumber != null) {
        suggestedName = lookup.displayName ?? recipient;
        suggestedPhone = lookup.phoneNumber;
        // ignore: avoid_print
        print('[Dispatcher] Suggestion fuzzy: $suggestedName -> $suggestedPhone');
      }
    }

    // Queuer la validation avec le message en attente
    if (suggestedPhone != null) {
      await _validatedContactsService.queuePendingValidation(
        recipient,
        suggestedName!,
        suggestedPhone,
        pendingMessage: message,
      );
      // ignore: avoid_print
      print('[Dispatcher] Validation en attente: "$recipient" → "$suggestedName"');

      return ActionResult.failure(
        intent,
        'Contact $recipient non confirmé, validation en attente',
      );
    }

    // Aucun contact trouvé
    // ignore: avoid_print
    print('[Dispatcher] Aucun contact trouvé pour "$recipient"');
    return ActionResult.failure(
      intent,
      'Contact $recipient introuvable',
    );
  }

  /// Envoie un message à un contact validé (résolution d'app + envoi)
  Future<ActionResult> _sendToValidatedContact(
    String phoneNumber,
    String displayName,
    MessageAction action,
  ) async {
    String targetApp = 'sms';

    // Priorité 1 : Dernière app ENTRANTE
    final incomingApp = await IncomingHistoryService.getLastIncomingApp(displayName);
    if (incomingApp != null) {
      targetApp = incomingApp;
      // ignore: avoid_print
      print('[Dispatcher] App entrante: $targetApp');
    } else {
      // Priorité 2 : Dernière app SORTANTE
      final history = await _contactHistoryService.findByName(action.recipient);
      if (history.found && history.suggestedApp != null) {
        targetApp = history.suggestedApp!;
        // ignore: avoid_print
        print('[Dispatcher] App sortante: $targetApp');
      }
    }

    // Forcer SMS si écran verrouillé
    final isLocked = await LockScreenService.isLocked();
    if (isLocked && targetApp != 'sms') {
      // ignore: avoid_print
      print('[Dispatcher] Écran verrouillé → force SMS (était: $targetApp)');
      targetApp = 'sms';
    }

    // ignore: avoid_print
    print('[Dispatcher] Envoi via $targetApp à $displayName ($phoneNumber)');
    return await _sendViaApp(targetApp, phoneNumber, displayName, action.message);
  }

  /// Envoie un message via l'app cible
  Future<ActionResult> _sendViaApp(
    String app,
    String recipientOrNumber,
    String displayName,
    String message,
  ) async {
    final MessagingApp? messagingApp = switch (app) {
      'whatsapp' => MessagingApp.whatsapp,
      'telegram' => MessagingApp.telegram,
      'signal' => MessagingApp.signal,
      'messenger' => MessagingApp.messenger,
      _ => null,
    };

    // Apps de messagerie (WhatsApp, Telegram, Signal, Messenger)
    if (messagingApp != null) {
      final result = await _messagingService.sendMessage(
        app: messagingApp,
        recipient: recipientOrNumber,
        message: message,
      );
      if (result.success) {
        return ActionResult.success(
          ActionIntent.message,
          'Message envoyé via ${app[0].toUpperCase()}${app.substring(1)} à $displayName',
          {'app': app, 'contact': displayName},
        );
      }
      // Fallback SMS si l'app échoue
      // ignore: avoid_print
      print('[Dispatcher] Échec $app, fallback SMS');
    }

    // SMS (défaut ou fallback)
    final result = await _smsService.sendSms(
      recipient: recipientOrNumber,
      message: message,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.message,
        'SMS envoyé à $displayName',
        {'app': 'sms', 'contact': displayName},
      );
    } else {
      return ActionResult.failure(
        ActionIntent.message,
        result.error ?? 'Erreur d\'envoi du message',
      );
    }
  }

  /// Gère les actions de navigation GPS
  Future<ActionResult> _handleNavigation(NavigationAction action) async {
    final result = await _navigationService.navigate(
      destination: action.destination,
      mode: action.mode,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.navigation,
        'Navigation vers ${action.destination}',
        {'briefingSpoken': result.briefingSpoken},
      );
    } else {
      return ActionResult.failure(
        ActionIntent.navigation,
        result.error ?? 'Erreur de navigation',
      );
    }
  }

  /// Gère les actions de contrôle média
  Future<ActionResult> _handleMedia(MediaAction action) async {
    final result = await _mediaService.execute(
      controlType: action.controlType,
      query: action.query,
      app: action.app,
      deviceType: action.deviceType,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.media,
        _getMediaControlMessage(action.controlType, action.query, action.app),
      );
    } else {
      return ActionResult.failure(
        ActionIntent.media,
        result.error ?? 'Erreur de contrôle média',
      );
    }
  }

  /// Gère les actions de lancement d'application
  Future<ActionResult> _handleAppLaunch(AppLaunchAction action) async {
    final result = await _appLauncherService.launchApp(
      appName: action.appName,
      packageName: action.packageName,
    );

    if (result.success) {
      return ActionResult.success(
        ActionIntent.appLaunch,
        'Application ${action.appName} lancée',
        {'packageName': result.launchedPackage},
      );
    } else {
      return ActionResult.failure(
        ActionIntent.appLaunch,
        result.error ?? 'Impossible de lancer l\'application',
      );
    }
  }

  /// Gère les paiements (Fintecture Request-to-Pay)
  Future<ActionResult> _handlePayment(PaymentAction action) async {
    // ignore: avoid_print
    print('[Dispatcher] Paiement: ${action.amount}€ → ${action.recipient}');

    // Vérifier que l'IBAN est configuré
    if (!await _paymentService.hasIban()) {
      return ActionResult.failure(
        ActionIntent.payment,
        'IBAN non configuré. Configurez votre IBAN dans les paramètres de paiement.',
      );
    }

    // Résolution contact (même 3-tier que messaging)
    final validated = await _validatedContactsService.resolve(action.recipient);
    if (validated != null) {
      // ignore: avoid_print
      print('[Dispatcher] Contact validé: ${validated.displayName} → ${validated.phoneNumber}');

      final tx = await _paymentService.createRequestToPay(
        recipientName: validated.displayName,
        recipientPhone: validated.phoneNumber,
        amount: action.amount,
        note: action.note ?? '',
      );

      if (tx != null && tx.paymentUrl.isNotEmpty) {
        // Envoyer le lien de paiement par messagerie
        final msg = 'Salut ${validated.displayName}, '
            'peux-tu me rembourser ${tx.formattedAmount}'
            '${action.note != null ? " (${action.note})" : ""} ? '
            '${tx.paymentUrl}';

        await _messagingService.sendMessage(
          app: MessagingApp.whatsapp,
          recipient: validated.displayName,
          message: msg,
        );

        return ActionResult.success(
          ActionIntent.payment,
          'Demande de ${tx.formattedAmount} envoyée à ${validated.displayName}',
          {
            'contact': validated.displayName,
            'phone': validated.phoneNumber,
            'amount': action.amount,
            'note': action.note,
            'payment_url': tx.paymentUrl,
          },
        );
      } else {
        return ActionResult.failure(
          ActionIntent.payment,
          'Impossible de créer la demande de paiement',
        );
      }
    }

    // Contact non validé → queue pending validation
    return await _queueUnvalidatedContact(
      action.recipient,
      '',
      ActionIntent.payment,
    );
  }

  /// Gère les non-actions (mémos)
  Future<ActionResult> _handleNone(NoAction action) async {
    // Pour les mémos, on pourrait les sauvegarder en base locale
    return ActionResult.success(
      ActionIntent.none,
      action.memo != null ? 'Mémo enregistré: ${action.memo}' : 'Aucune action',
      {'memo': action.memo},
    );
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  String _formatDateTime(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} à ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _getSystemControlMessage(SystemControlType type, int? value) {
    return switch (type) {
      // Volume
      SystemControlType.volumeUp => 'Volume augmenté',
      SystemControlType.volumeDown => 'Volume diminué',
      SystemControlType.volumeSet => 'Volume réglé à ${value ?? 50}%',
      SystemControlType.volumeMute => 'Son coupé',

      // Modes sonores
      SystemControlType.vibrate => 'Mode vibreur activé',
      SystemControlType.silent => 'Mode silencieux activé',
      SystemControlType.normal => 'Mode normal activé',

      // Ne pas déranger
      SystemControlType.dndOn => 'Paramètres Ne pas déranger ouverts',
      SystemControlType.dndOff => 'Paramètres Ne pas déranger ouverts',

      // Connectivité
      SystemControlType.wifiToggle => 'Paramètres Wi-Fi ouverts',
      SystemControlType.bluetoothToggle => 'Paramètres Bluetooth ouverts',
      SystemControlType.airplaneToggle => 'Paramètres Mode avion ouverts',

      // Écran
      SystemControlType.brightnessUp => 'Paramètres luminosité ouverts',
      SystemControlType.brightnessDown => 'Paramètres luminosité ouverts',
      SystemControlType.flashlightOn => 'Lampe torche activée',
      SystemControlType.flashlightOff => 'Lampe torche désactivée',
    };
  }

  String _getMediaControlMessage(MediaControlType type, [String? query, String? app]) {
    return switch (type) {
      MediaControlType.play => 'Musique lancée !',
      MediaControlType.pause => 'Musique en pause',
      MediaControlType.playPause => 'Musique lancée !',
      MediaControlType.next => 'Piste suivante',
      MediaControlType.previous => 'Piste précédente',
      MediaControlType.stop => 'Musique arrêtée',
      MediaControlType.playSearch => 'Musique lancée !',
      MediaControlType.like => 'Titre liké !',
      MediaControlType.transfer => 'Lecture transférée',
    };
  }
}
