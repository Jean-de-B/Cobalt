import 'package:device_calendar/device_calendar.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/timezone.dart' as tz;
import 'settings_service.dart';

/// =============================================================================
/// local_calendar_service.dart
/// =============================================================================
/// Service pour créer des événements dans le calendrier local Android.
/// Utilise le plugin device_calendar pour accéder au calendrier natif.
///
/// PERMISSIONS REQUISES (AndroidManifest.xml):
/// <uses-permission android:name="android.permission.READ_CALENDAR"/>
/// <uses-permission android:name="android.permission.WRITE_CALENDAR"/>
/// =============================================================================

/// Résultat d'une opération calendrier
class CalendarResult {
  final bool success;
  final String? eventId;
  final String? error;

  const CalendarResult({
    required this.success,
    this.eventId,
    this.error,
  });

  factory CalendarResult.success(String eventId) =>
      CalendarResult(success: true, eventId: eventId);

  factory CalendarResult.failure(String error) =>
      CalendarResult(success: false, error: error);
}

class LocalCalendarService {
  final DeviceCalendarPlugin _calendarPlugin = DeviceCalendarPlugin();
  String? _defaultCalendarId;
  bool _initialized = false;

  /// Initialise le service et récupère le calendrier par défaut
  Future<void> initialize() async {
    if (_initialized) return;

    // Demander les permissions
    final status = await Permission.calendar.request();
    if (!status.isGranted) {
      // ignore: avoid_print
      print('[Calendar] Permission refusée');
      return;
    }

    // Récupérer les calendriers disponibles
    final calendarsResult = await _calendarPlugin.retrieveCalendars();
    if (calendarsResult.isSuccess && calendarsResult.data != null) {
      final calendars = calendarsResult.data!;

      // Log tous les calendriers disponibles pour debug
      // ignore: avoid_print
      print('[Calendar] ${calendars.length} calendriers trouvés:');
      for (final cal in calendars) {
        // ignore: avoid_print
        print('  - "${cal.name}" | account: ${cal.accountName} | type: ${cal.accountType} | ${cal.isReadOnly == true ? "RO" : "RW"} | id: ${cal.id}');
      }

      // Sélection selon le paramètre utilisateur
      final preferred = SettingsService().calendarService;
      // ignore: avoid_print
      print('[Calendar] Service préféré: $preferred');

      if (preferred == 'samsung') {
        // Chercher Samsung Calendar en priorité
        for (final calendar in calendars) {
          if (calendar.isReadOnly == true) continue;
          final accountType = (calendar.accountType ?? '').toLowerCase();
          final accountName = (calendar.accountName ?? '').toLowerCase();
          if (accountType.contains('samsung') || accountName.contains('samsung') || accountType.contains('sec.')) {
            _defaultCalendarId = calendar.id;
            // ignore: avoid_print
            print('[Calendar] ✓ Samsung Calendar: ${calendar.name}');
            break;
          }
        }
      } else {
        // Chercher Google Calendar en priorité
        for (final calendar in calendars) {
          if (calendar.isReadOnly == true) continue;
          final accountType = (calendar.accountType ?? '').toLowerCase();
          if (accountType.contains('com.google') || accountType.contains('google')) {
            _defaultCalendarId = calendar.id;
            // ignore: avoid_print
            print('[Calendar] ✓ Google Calendar: ${calendar.name} (${calendar.accountName})');
            break;
          }
        }
        // Fallback par email
        if (_defaultCalendarId == null) {
          for (final calendar in calendars) {
            if (calendar.isReadOnly == true) continue;
            final accountName = (calendar.accountName ?? '').toLowerCase();
            if (accountName.contains('gmail.com') || accountName.contains('google.com')) {
              _defaultCalendarId = calendar.id;
              // ignore: avoid_print
              print('[Calendar] ✓ Google Calendar (email): ${calendar.name}');
              break;
            }
          }
        }
      }

      // Dernier recours - premier modifiable
      if (_defaultCalendarId == null) {
        for (final calendar in calendars) {
          if (calendar.isReadOnly == false) {
            _defaultCalendarId = calendar.id;
            // ignore: avoid_print
            print('[Calendar] Calendrier fallback: ${calendar.name}');
            break;
          }
        }
      }

      if (_defaultCalendarId == null && calendars.isNotEmpty) {
        _defaultCalendarId = calendars.first.id;
      }
    }

    _initialized = true;
    // ignore: avoid_print
    print('[Calendar] Service initialisé');
  }

  /// Crée un événement à partir d'une chaîne date/heure brute (ex: "demain 14h").
  /// Même logique de parsing que GoogleCalendarService.
  Future<CalendarResult> createEventFromString({
    required String title,
    required String dateTime,
    String? endDateTime,
    String? location,
    String? description,
  }) async {
    final start = _parseDateTime(dateTime);
    final end = endDateTime != null ? _parseDateTime(endDateTime) : null;
    return createEvent(
      title: title,
      startTime: start,
      endTime: end,
      location: location,
      description: description,
    );
  }

  /// Parse une chaîne date/heure relative en DateTime absolu.
  DateTime _parseDateTime(String input) {
    final now = DateTime.now();
    final lower = input.toLowerCase().trim();

    int hour = 9;
    int minute = 0;
    final heureMatch = RegExp(r'(\d{1,2})[h:](\d{0,2})').firstMatch(lower);
    if (heureMatch != null) {
      hour = int.parse(heureMatch.group(1)!);
      if (heureMatch.group(2)?.isNotEmpty == true) {
        minute = int.parse(heureMatch.group(2)!);
      }
    } else if (lower.contains('midi')) {
      hour = 12;
    } else if (lower.contains('soir')) {
      hour = 19;
    } else if (lower.contains('matin')) {
      hour = 9;
    }

    DateTime target = now;
    if (lower.contains("aujourd'hui") || lower.contains('ce soir') || lower.contains('ce matin')) {
      target = now;
    } else if (lower.contains('demain')) {
      target = now.add(const Duration(days: 1));
    } else if (lower.contains('après-demain') || lower.contains('apres-demain')) {
      target = now.add(const Duration(days: 2));
    } else {
      const jours = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
      for (int i = 0; i < jours.length; i++) {
        if (lower.contains(jours[i])) {
          var diff = (i + 1) - now.weekday;
          if (diff <= 0) diff += 7;
          target = now.add(Duration(days: diff));
          break;
        }
      }
    }

    return DateTime(target.year, target.month, target.day, hour, minute);
  }

  /// Crée un événement dans le calendrier
  Future<CalendarResult> createEvent({
    required String title,
    required DateTime startTime,
    DateTime? endTime,
    String? location,
    String? description,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    if (_defaultCalendarId == null) {
      return CalendarResult.failure('Aucun calendrier disponible');
    }

    // Durée par défaut: 1 heure
    final end = endTime ?? startTime.add(const Duration(hours: 1));

    final event = Event(
      _defaultCalendarId,
      title: title,
      start: tz.TZDateTime.from(startTime, tz.local),
      end: tz.TZDateTime.from(end, tz.local),
      location: location,
      description: description,
    );

    try {
      final result = await _calendarPlugin.createOrUpdateEvent(event);

      if (result?.isSuccess == true && result?.data != null) {
        // ignore: avoid_print
        print('[Calendar] Événement créé: ${result!.data}');
        return CalendarResult.success(result.data!);
      } else {
        final errors = result?.errors?.map((e) => e.errorMessage).join(', ');
        return CalendarResult.failure(errors ?? 'Erreur inconnue');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Calendar] Erreur: $e');
      return CalendarResult.failure(e.toString());
    }
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized && _defaultCalendarId != null;

  /// ID du calendrier actuellement sélectionné
  String? get selectedCalendarId => _defaultCalendarId;

  /// Liste les calendriers disponibles
  Future<List<Calendar>> getCalendars() async {
    final result = await _calendarPlugin.retrieveCalendars();
    return result.data ?? [];
  }

  /// Définit manuellement le calendrier à utiliser
  void setCalendar(String calendarId) {
    _defaultCalendarId = calendarId;
    // ignore: avoid_print
    print('[Calendar] Calendrier manuellement défini: $calendarId');
  }

  /// Réinitialise pour re-détecter les calendriers
  Future<void> reinitialize() async {
    _initialized = false;
    _defaultCalendarId = null;
    await initialize();
  }
}
