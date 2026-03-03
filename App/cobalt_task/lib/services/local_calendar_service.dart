import 'package:device_calendar/device_calendar.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/timezone.dart' as tz;

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

      // PRIORITÉ 1: Chercher par accountType "com.google" (le plus fiable)
      for (final calendar in calendars) {
        if (calendar.isReadOnly == true) continue;

        final accountType = (calendar.accountType ?? '').toLowerCase();
        if (accountType.contains('com.google') || accountType.contains('google')) {
          _defaultCalendarId = calendar.id;
          // ignore: avoid_print
          print('[Calendar] ✓ Google Calendar (type): ${calendar.name} (${calendar.accountName})');
          break;
        }
      }

      // PRIORITÉ 2: Chercher par accountName contenant gmail.com
      if (_defaultCalendarId == null) {
        for (final calendar in calendars) {
          if (calendar.isReadOnly == true) continue;

          final accountName = (calendar.accountName ?? '').toLowerCase();
          if (accountName.contains('gmail.com') || accountName.contains('google.com')) {
            _defaultCalendarId = calendar.id;
            // ignore: avoid_print
            print('[Calendar] ✓ Google Calendar (email): ${calendar.name} (${calendar.accountName})');
            break;
          }
        }
      }

      // PRIORITÉ 3: Exclure Samsung et prendre le premier autre modifiable
      if (_defaultCalendarId == null) {
        for (final calendar in calendars) {
          if (calendar.isReadOnly == true) continue;

          final accountType = (calendar.accountType ?? '').toLowerCase();
          final accountName = (calendar.accountName ?? '').toLowerCase();

          // Exclure Samsung Calendar
          if (accountType.contains('samsung') ||
              accountName.contains('samsung') ||
              accountType.contains('sec.')) {
            // ignore: avoid_print
            print('[Calendar] ✗ Samsung ignoré: ${calendar.name}');
            continue;
          }

          _defaultCalendarId = calendar.id;
          // ignore: avoid_print
          print('[Calendar] Calendrier par défaut (non-Samsung): ${calendar.name}');
          break;
        }
      }

      // PRIORITÉ 4: Dernier recours - premier modifiable
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
