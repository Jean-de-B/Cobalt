/// =============================================================================
/// ai_action.dart
/// =============================================================================
/// Modèle de données pour les actions IA extraites de la transcription.
/// Architecture Union Pattern sans dépendance externe.
/// =============================================================================

/// Types d'intentions supportés
enum ActionIntent {
  calendar,
  sms,
  alarm,
  timer,
  systemControl,
  // Nouvelles intentions
  call,
  messaging,
  message, // Message générique (app déterminée par historique)
  navigation,
  media,
  appLaunch,
  payment,
  queryTime,
  queryBattery,
  none,
}

/// Types de messagerie supportés
enum MessagingApp {
  whatsapp,
  telegram,
  signal,
  messenger,
}

/// Types de contrôle média
enum MediaControlType {
  play,
  pause,
  playPause,
  next,
  previous,
  stop,
  playSearch, // Recherche et lecture (ex: "joue du jazz sur Spotify")
  like, // Like/sauvegarder le titre en cours
  transfer, // Transférer la lecture vers un autre appareil
}

/// Types de contrôle système
enum SystemControlType {
  // Volume
  volumeUp,
  volumeDown,
  volumeSet,
  volumeMute,

  // Modes sonores
  vibrate,
  silent,
  normal,

  // Ne pas déranger
  dndOn,
  dndOff,

  // Connectivité (ouvre les paramètres)
  wifiToggle,
  bluetoothToggle,
  airplaneToggle,

  // Écran
  brightnessUp,
  brightnessDown,
  flashlightOn,
  flashlightOff,
}

/// Classe de base abstraite pour toutes les actions IA
sealed class AiAction {
  final String reasoning;
  final ActionIntent intent;

  const AiAction({required this.reasoning, required this.intent});

  /// Factory depuis JSON brut du LLM
  factory AiAction.fromJson(Map<String, dynamic> json) {
    final intentStr = json['intent'] as String? ?? 'none';
    final reasoning = json['reasoning'] as String? ?? '';
    final params = json['params'] as Map<String, dynamic>? ?? {};

    switch (intentStr) {
      case 'calendar':
        return CalendarAction(
          reasoning: reasoning,
          title: params['title'] as String? ?? 'Événement',
          startTime: _parseDateTime(params['start_time']),
          endTime: params['end_time'] != null
              ? _parseDateTime(params['end_time'])
              : null,
          location: params['location'] as String?,
          description: params['description'] as String?,
        );

      case 'sms':
        return SmsAction(
          reasoning: reasoning,
          recipient: params['recipient'] as String? ?? '',
          message: params['message'] as String? ?? '',
        );

      case 'alarm':
        return AlarmAction(
          reasoning: reasoning,
          time: _parseDateTime(params['time']),
          label: params['label'] as String?,
        );

      case 'timer':
        return TimerAction(
          reasoning: reasoning,
          durationSeconds: _parseDuration(params),
          label: params['label'] as String?,
        );

      case 'system_control':
        return SystemControlAction(
          reasoning: reasoning,
          controlType: _parseControlType(params['control_type'], params['value']),
          value: _parseIntValue(params['value']),
        );

      case 'call':
        return CallAction(
          reasoning: reasoning,
          contact: params['contact'] as String? ?? '',
          phoneNumber: params['phone_number'] as String?,
          app: params['app'] as String?, // whatsapp, telegram, etc.
        );

      case 'messaging':
        return MessagingAction(
          reasoning: reasoning,
          app: _parseMessagingApp(params['app']),
          recipient: params['recipient'] as String? ?? '',
          message: params['message'] as String? ?? '',
        );

      case 'message':
        // Message générique - l'app sera déterminée par l'historique
        return MessageAction(
          reasoning: reasoning,
          recipient: params['recipient'] as String? ?? '',
          message: params['message'] as String? ?? '',
        );

      case 'navigation':
        return NavigationAction(
          reasoning: reasoning,
          destination: params['destination'] as String? ?? '',
          mode: params['mode'] as String?,
        );

      case 'media':
        return MediaAction(
          reasoning: reasoning,
          controlType: _parseMediaControlType(params['control_type']),
          query: params['query'] as String?,
          app: params['app'] as String?,
          deviceType: params['device_type'] as String?,
        );

      case 'app_launch':
        return AppLaunchAction(
          reasoning: reasoning,
          appName: params['app_name'] as String? ?? '',
          packageName: params['package_name'] as String?,
        );

      case 'payment':
        return PaymentAction(
          reasoning: reasoning,
          recipient: params['recipient'] as String? ?? '',
          amount: (params['amount'] as num?)?.toDouble() ?? 0,
          note: params['note'] as String?,
        );

      case 'none':
      default:
        return NoAction(
          reasoning: reasoning,
          memo: params['memo'] as String? ?? json['original_text'] as String?,
        );
    }
  }

  /// Convertit en JSON
  Map<String, dynamic> toJson();

  /// Pattern matching helper
  T when<T>({
    required T Function(CalendarAction) calendar,
    required T Function(SmsAction) sms,
    required T Function(AlarmAction) alarm,
    required T Function(TimerAction) timer,
    required T Function(SystemControlAction) systemControl,
    required T Function(CallAction) call,
    required T Function(MessagingAction) messaging,
    required T Function(MessageAction) message,
    required T Function(NavigationAction) navigation,
    required T Function(MediaAction) media,
    required T Function(AppLaunchAction) appLaunch,
    required T Function(PaymentAction) payment,
    required T Function(QueryTimeAction) queryTime,
    required T Function(QueryBatteryAction) queryBattery,
    required T Function(NoAction) none,
  }) {
    return switch (this) {
      CalendarAction action => calendar(action),
      SmsAction action => sms(action),
      AlarmAction action => alarm(action),
      TimerAction action => timer(action),
      SystemControlAction action => systemControl(action),
      CallAction action => call(action),
      MessagingAction action => messaging(action),
      MessageAction action => message(action),
      NavigationAction action => navigation(action),
      MediaAction action => media(action),
      AppLaunchAction action => appLaunch(action),
      PaymentAction action => payment(action),
      QueryTimeAction action => queryTime(action),
      QueryBatteryAction action => queryBattery(action),
      NoAction action => none(action),
    };
  }

  /// Pattern matching avec valeur par défaut
  T maybeWhen<T>({
    T Function(CalendarAction)? calendar,
    T Function(SmsAction)? sms,
    T Function(AlarmAction)? alarm,
    T Function(TimerAction)? timer,
    T Function(SystemControlAction)? systemControl,
    T Function(CallAction)? call,
    T Function(MessagingAction)? messaging,
    T Function(MessageAction)? message,
    T Function(NavigationAction)? navigation,
    T Function(MediaAction)? media,
    T Function(AppLaunchAction)? appLaunch,
    T Function(PaymentAction)? payment,
    T Function(QueryTimeAction)? queryTime,
    T Function(QueryBatteryAction)? queryBattery,
    T Function(NoAction)? none,
    required T Function() orElse,
  }) {
    return switch (this) {
      CalendarAction action => calendar?.call(action) ?? orElse(),
      SmsAction action => sms?.call(action) ?? orElse(),
      AlarmAction action => alarm?.call(action) ?? orElse(),
      TimerAction action => timer?.call(action) ?? orElse(),
      SystemControlAction action => systemControl?.call(action) ?? orElse(),
      CallAction action => call?.call(action) ?? orElse(),
      MessagingAction action => messaging?.call(action) ?? orElse(),
      MessageAction action => message?.call(action) ?? orElse(),
      NavigationAction action => navigation?.call(action) ?? orElse(),
      MediaAction action => media?.call(action) ?? orElse(),
      AppLaunchAction action => appLaunch?.call(action) ?? orElse(),
      PaymentAction action => payment?.call(action) ?? orElse(),
      QueryTimeAction action => queryTime?.call(action) ?? orElse(),
      QueryBatteryAction action => queryBattery?.call(action) ?? orElse(),
      NoAction action => none?.call(action) ?? orElse(),
    };
  }
}

/// Action calendrier - Créer un événement
final class CalendarAction extends AiAction {
  final String title;
  final DateTime startTime;
  final DateTime? endTime;
  final String? location;
  final String? description;

  const CalendarAction({
    required super.reasoning,
    required this.title,
    required this.startTime,
    this.endTime,
    this.location,
    this.description,
  }) : super(intent: ActionIntent.calendar);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'calendar',
        'reasoning': reasoning,
        'params': {
          'title': title,
          'start_time': startTime.toIso8601String(),
          if (endTime != null) 'end_time': endTime!.toIso8601String(),
          if (location != null) 'location': location,
          if (description != null) 'description': description,
        },
      };

  @override
  String toString() =>
      'CalendarAction(title: $title, startTime: $startTime, location: $location)';
}

/// Action SMS - Envoyer un message
final class SmsAction extends AiAction {
  final String recipient;
  final String message;

  const SmsAction({
    required super.reasoning,
    required this.recipient,
    required this.message,
  }) : super(intent: ActionIntent.sms);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'sms',
        'reasoning': reasoning,
        'params': {
          'recipient': recipient,
          'message': message,
        },
      };

  @override
  String toString() => 'SmsAction(recipient: $recipient, message: $message)';
}

/// Action alarme - Définir une alarme
final class AlarmAction extends AiAction {
  final DateTime time;
  final String? label;

  const AlarmAction({
    required super.reasoning,
    required this.time,
    this.label,
  }) : super(intent: ActionIntent.alarm);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'alarm',
        'reasoning': reasoning,
        'params': {
          'time': time.toIso8601String(),
          if (label != null) 'label': label,
        },
      };

  @override
  String toString() => 'AlarmAction(time: $time, label: $label)';
}

/// Action minuteur - Lancer un timer
final class TimerAction extends AiAction {
  final int durationSeconds;
  final String? label;

  const TimerAction({
    required super.reasoning,
    required this.durationSeconds,
    this.label,
  }) : super(intent: ActionIntent.timer);

  /// Durée formatée (ex: "5 min 30 sec")
  String get formattedDuration {
    final hours = durationSeconds ~/ 3600;
    final minutes = (durationSeconds % 3600) ~/ 60;
    final seconds = durationSeconds % 60;

    final parts = <String>[];
    if (hours > 0) parts.add('$hours h');
    if (minutes > 0) parts.add('$minutes min');
    if (seconds > 0 || parts.isEmpty) parts.add('$seconds sec');
    return parts.join(' ');
  }

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'timer',
        'reasoning': reasoning,
        'params': {
          'duration_seconds': durationSeconds,
          if (label != null) 'label': label,
        },
      };

  @override
  String toString() =>
      'TimerAction(duration: $formattedDuration, label: $label)';
}

/// Action contrôle système - Volume, vibreur, etc.
final class SystemControlAction extends AiAction {
  final SystemControlType controlType;
  final int? value;

  const SystemControlAction({
    required super.reasoning,
    required this.controlType,
    this.value,
  }) : super(intent: ActionIntent.systemControl);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'system_control',
        'reasoning': reasoning,
        'params': {
          'control_type': controlType.name,
          if (value != null) 'value': value,
        },
      };

  @override
  String toString() =>
      'SystemControlAction(type: $controlType, value: $value)';
}

/// Aucune action - Mémo simple ou requête non comprise
final class NoAction extends AiAction {
  final String? memo;

  const NoAction({
    required super.reasoning,
    this.memo,
  }) : super(intent: ActionIntent.none);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'none',
        'reasoning': reasoning,
        'params': {
          if (memo != null) 'memo': memo,
        },
      };

  @override
  String toString() => 'NoAction(memo: $memo)';
}

/// Action appel téléphonique - Passer un appel
final class CallAction extends AiAction {
  final String contact;
  final String? phoneNumber;
  final String? app; // whatsapp, telegram, etc. (optionnel)

  const CallAction({
    required super.reasoning,
    required this.contact,
    this.phoneNumber,
    this.app,
  }) : super(intent: ActionIntent.call);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'call',
        'reasoning': reasoning,
        'params': {
          'contact': contact,
          if (phoneNumber != null) 'phone_number': phoneNumber,
          if (app != null) 'app': app,
        },
      };

  @override
  String toString() => 'CallAction(contact: $contact, phoneNumber: $phoneNumber)';
}

/// Action messagerie - Envoyer un message via WhatsApp/Telegram/etc.
final class MessagingAction extends AiAction {
  final MessagingApp app;
  final String recipient;
  final String message;

  const MessagingAction({
    required super.reasoning,
    required this.app,
    required this.recipient,
    required this.message,
  }) : super(intent: ActionIntent.messaging);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'messaging',
        'reasoning': reasoning,
        'params': {
          'app': app.name,
          'recipient': recipient,
          'message': message,
        },
      };

  @override
  String toString() => 'MessagingAction(app: $app, recipient: $recipient)';
}

/// Action message générique - App déterminée par l'historique des contacts
final class MessageAction extends AiAction {
  final String recipient;
  final String message;

  const MessageAction({
    required super.reasoning,
    required this.recipient,
    required this.message,
  }) : super(intent: ActionIntent.message);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'message',
        'reasoning': reasoning,
        'params': {
          'recipient': recipient,
          'message': message,
        },
      };

  @override
  String toString() => 'MessageAction(recipient: $recipient, message: $message)';
}

/// Action navigation GPS - Lancer un itinéraire
final class NavigationAction extends AiAction {
  final String destination;
  final String? mode; // driving, walking, bicycling, transit

  const NavigationAction({
    required super.reasoning,
    required this.destination,
    this.mode,
  }) : super(intent: ActionIntent.navigation);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'navigation',
        'reasoning': reasoning,
        'params': {
          'destination': destination,
          if (mode != null) 'mode': mode,
        },
      };

  @override
  String toString() => 'NavigationAction(destination: $destination, mode: $mode)';
}

/// Action contrôle média - Play/Pause/Next/etc.
final class MediaAction extends AiAction {
  final MediaControlType controlType;
  final String? query; // Pour recherche musicale
  final String? app; // App cible (spotify, youtube_music, deezer, etc.)
  final String? deviceType; // Pour transfer (ordinateur, telephone, enceinte, tv)

  const MediaAction({
    required super.reasoning,
    required this.controlType,
    this.query,
    this.app,
    this.deviceType,
  }) : super(intent: ActionIntent.media);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'media',
        'reasoning': reasoning,
        'params': {
          'control_type': controlType.name,
          if (query != null) 'query': query,
          if (app != null) 'app': app,
        },
      };

  @override
  String toString() => 'MediaAction(controlType: $controlType, query: $query, app: $app)';
}

/// Action paiement - Demande de remboursement
final class PaymentAction extends AiAction {
  final String recipient;
  final double amount;
  final String? note;

  const PaymentAction({
    required super.reasoning,
    required this.recipient,
    required this.amount,
    this.note,
  }) : super(intent: ActionIntent.payment);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'payment',
        'reasoning': reasoning,
        'params': {
          'recipient': recipient,
          'amount': amount,
          if (note != null) 'note': note,
        },
      };

  @override
  String toString() => 'PaymentAction(recipient: $recipient, amount: $amount, note: $note)';
}

/// Action lancement d'application
final class AppLaunchAction extends AiAction {
  final String appName;
  final String? packageName;

  const AppLaunchAction({
    required super.reasoning,
    required this.appName,
    this.packageName,
  }) : super(intent: ActionIntent.appLaunch);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'app_launch',
        'reasoning': reasoning,
        'params': {
          'app_name': appName,
          if (packageName != null) 'package_name': packageName,
        },
      };

  @override
  String toString() => 'AppLaunchAction(appName: $appName, packageName: $packageName)';
}

/// Action demande de batterie - Dire le niveau de batterie via TTS
final class QueryBatteryAction extends AiAction {
  const QueryBatteryAction({required super.reasoning})
      : super(intent: ActionIntent.queryBattery);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'query_battery',
        'reasoning': reasoning,
        'params': {},
      };

  @override
  String toString() => 'QueryBatteryAction()';
}

/// Action demande d'heure - Dire l'heure actuelle via TTS
final class QueryTimeAction extends AiAction {
  const QueryTimeAction({required super.reasoning})
      : super(intent: ActionIntent.queryTime);

  @override
  Map<String, dynamic> toJson() => {
        'intent': 'query_time',
        'reasoning': reasoning,
        'params': {},
      };

  @override
  String toString() => 'QueryTimeAction()';
}

// =============================================================================
// HELPERS PRIVÉS
// =============================================================================

/// Parse une date/heure depuis différents formats
DateTime _parseDateTime(dynamic value) {
  if (value == null) return DateTime.now();

  if (value is DateTime) return value;

  if (value is String) {
    // Essayer ISO 8601
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;

    // Essayer format "HH:mm" (heure seule)
    final timeMatch = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value);
    if (timeMatch != null) {
      final now = DateTime.now();
      var hour = int.parse(timeMatch.group(1)!);
      final minute = int.parse(timeMatch.group(2)!);

      // Si l'heure est passée, c'est pour demain
      var result = DateTime(now.year, now.month, now.day, hour, minute);
      if (result.isBefore(now)) {
        result = result.add(const Duration(days: 1));
      }
      return result;
    }

    // Essayer format "demain HH:mm"
    final tomorrowMatch =
        RegExp(r'demain\s+(\d{1,2}):(\d{2})', caseSensitive: false)
            .firstMatch(value);
    if (tomorrowMatch != null) {
      final now = DateTime.now();
      final hour = int.parse(tomorrowMatch.group(1)!);
      final minute = int.parse(tomorrowMatch.group(2)!);
      return DateTime(now.year, now.month, now.day + 1, hour, minute);
    }
  }

  return DateTime.now();
}

/// Parse une durée depuis les paramètres
int _parseDuration(Map<String, dynamic> params) {
  // Durée directe en secondes
  if (params['duration_seconds'] != null) {
    return (params['duration_seconds'] as num).toInt();
  }

  // Durée en minutes
  if (params['duration_minutes'] != null) {
    return (params['duration_minutes'] as num).toInt() * 60;
  }

  // Durée en heures
  if (params['duration_hours'] != null) {
    return (params['duration_hours'] as num).toInt() * 3600;
  }

  // Composants séparés
  int seconds = 0;
  if (params['hours'] != null) {
    seconds += (params['hours'] as num).toInt() * 3600;
  }
  if (params['minutes'] != null) {
    seconds += (params['minutes'] as num).toInt() * 60;
  }
  if (params['seconds'] != null) {
    seconds += (params['seconds'] as num).toInt();
  }

  return seconds > 0 ? seconds : 60; // Défaut: 1 minute
}

/// Parse une valeur en int (gère String et int)
int? _parseIntValue(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    // Essayer de parser comme int
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
    // Sinon ignorer (ex: "silent" n'est pas un int)
    return null;
  }
  return null;
}

/// Parse le type de contrôle système
/// Le second paramètre permet de détecter le type depuis la valeur (ex: value="silent")
SystemControlType _parseControlType(dynamic controlType, [dynamic valueParam]) {
  if (controlType == null && valueParam == null) return SystemControlType.normal;

  final str = controlType?.toString().toLowerCase() ?? '';
  final valueStr = valueParam?.toString().toLowerCase() ?? '';

  // D'abord vérifier si la valeur contient le type réel
  // (ex: control_type="vibrate_set", value="silent" -> silent)
  if (valueStr == 'silent' || valueStr == 'silencieux') {
    return SystemControlType.silent;
  }
  if (valueStr == 'vibrate' || valueStr == 'vibreur') {
    return SystemControlType.vibrate;
  }
  if (valueStr == 'normal') {
    return SystemControlType.normal;
  }

  return switch (str) {
    // Volume
    'volume_up' || 'volumeup' || 'augmenter' => SystemControlType.volumeUp,
    'volume_down' || 'volumedown' || 'baisser' => SystemControlType.volumeDown,
    'volume_set' || 'volumeset' => SystemControlType.volumeSet,
    'volume_mute' || 'volumemute' || 'mute' || 'muet' =>
      SystemControlType.volumeMute,

    // Modes sonores (inclut les variantes du LLM)
    'vibrate' || 'vibreur' || 'vibrate_set' => SystemControlType.vibrate,
    'silent' || 'silencieux' || 'silent_set' => SystemControlType.silent,

    // Ne pas déranger
    'dnd_on' || 'dndon' || 'dnd' || 'ne_pas_deranger' ||
    'do_not_disturb' => SystemControlType.dndOn,
    'dnd_off' || 'dndoff' => SystemControlType.dndOff,

    // Connectivité
    'wifi' || 'wifi_toggle' => SystemControlType.wifiToggle,
    'bluetooth' || 'bluetooth_toggle' => SystemControlType.bluetoothToggle,
    'airplane' || 'airplane_toggle' || 'avion' => SystemControlType.airplaneToggle,

    // Écran
    'brightness_up' || 'brightnessup' || 'luminosite_plus' =>
      SystemControlType.brightnessUp,
    'brightness_down' || 'brightnessdown' || 'luminosite_moins' =>
      SystemControlType.brightnessDown,
    'flashlight_on' || 'flashlighton' || 'torch' || 'lampe' =>
      SystemControlType.flashlightOn,
    'flashlight_off' || 'flashlightoff' => SystemControlType.flashlightOff,

    _ => SystemControlType.normal,
  };
}

/// Parse le type d'application de messagerie
MessagingApp _parseMessagingApp(dynamic value) {
  if (value == null) return MessagingApp.whatsapp;

  final str = value.toString().toLowerCase();

  return switch (str) {
    'whatsapp' || 'whats_app' || 'wa' => MessagingApp.whatsapp,
    'telegram' || 'tg' => MessagingApp.telegram,
    'signal' => MessagingApp.signal,
    'messenger' || 'facebook_messenger' || 'fb_messenger' => MessagingApp.messenger,
    _ => MessagingApp.whatsapp, // Défaut: WhatsApp
  };
}

/// Parse le type de contrôle média
MediaControlType _parseMediaControlType(dynamic value) {
  if (value == null) return MediaControlType.playPause;

  final str = value.toString().toLowerCase();

  return switch (str) {
    'play' || 'lecture' || 'jouer' => MediaControlType.play,
    'pause' => MediaControlType.pause,
    'play_pause' || 'playpause' || 'toggle' => MediaControlType.playPause,
    'next' || 'suivant' || 'skip' => MediaControlType.next,
    'previous' || 'precedent' || 'back' => MediaControlType.previous,
    'stop' || 'arreter' => MediaControlType.stop,
    'play_search' || 'playsearch' || 'search' || 'recherche' => MediaControlType.playSearch,
    'like' || 'liker' || 'sauvegarder' || 'save' || 'favorite' || 'favori' => MediaControlType.like,
    'transfer' || 'transferer' || 'transférer' || 'changer' => MediaControlType.transfer,
    _ => MediaControlType.playPause,
  };
}
