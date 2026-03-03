import 'package:googleapis/calendar/v3.dart' as calendar;
import 'google_auth_service.dart';

/// =============================================================================
/// google_calendar_service.dart
/// =============================================================================
/// Service Google Calendar pour Cobalt Task.
///
/// Synchronise les fiches EVENT vers Google Calendar.
/// Parse les dates relatives (demain, mardi, etc.) en dates absolues.
/// =============================================================================

class GoogleCalendarService {
  /// Instance singleton
  static GoogleCalendarService? _instance;

  /// Service d'authentification
  final GoogleAuthService _authService;

  /// API Calendar
  calendar.CalendarApi? _calendarApi;

  /// ID du calendrier principal
  static const String _primaryCalendar = 'primary';

  /// Constructeur privé
  GoogleCalendarService._internal(this._authService);

  /// Factory Singleton
  factory GoogleCalendarService(GoogleAuthService authService) {
    _instance ??= GoogleCalendarService._internal(authService);
    return _instance!;
  }

  /// Initialise l'API Calendar
  Future<bool> initialize() async {
    if (!_authService.isSignedIn || _authService.authClient == null) {
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Non authentifié');
      return false;
    }

    try {
      _calendarApi = calendar.CalendarApi(_authService.authClient!);
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Initialisé');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Erreur initialisation - $e');
      return false;
    }
  }

  /// Crée un événement dans le calendrier
  ///
  /// [title] Titre de l'événement (QUI)
  /// [dateTime] Date/heure brute (sera parsée)
  /// [location] Lieu (optionnel)
  /// [description] Description additionnelle (optionnel)
  ///
  /// Retourne l'ID de l'événement créé ou null en cas d'erreur
  Future<String?> createEvent({
    required String title,
    required String dateTime,
    String? location,
    String? description,
  }) async {
    if (_calendarApi == null) {
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Service non initialisé');
      return null;
    }

    try {
      // Parser la date/heure
      final parsedDateTime = _parseDateTime(dateTime);

      final event = calendar.Event(
        summary: title,
        location: location,
        description: description,
        start: calendar.EventDateTime(
          dateTime: parsedDateTime,
          timeZone: 'Europe/Paris',
        ),
        end: calendar.EventDateTime(
          // Durée par défaut: 1 heure
          dateTime: parsedDateTime.add(const Duration(hours: 1)),
          timeZone: 'Europe/Paris',
        ),
      );

      final created = await _calendarApi!.events.insert(event, _primaryCalendar);
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Événement "$title" créé (${created.id})');
      print('GOOGLE_CALENDAR: Date: ${parsedDateTime.toIso8601String()}');

      return created.id;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Erreur création événement - $e');
      return null;
    }
  }

  /// Met à jour un événement existant
  Future<bool> updateEvent({
    required String eventId,
    String? title,
    String? dateTime,
    String? location,
    String? description,
  }) async {
    if (_calendarApi == null) return false;

    try {
      final existing = await _calendarApi!.events.get(_primaryCalendar, eventId);

      if (title != null) existing.summary = title;
      if (location != null) existing.location = location;
      if (description != null) existing.description = description;
      if (dateTime != null) {
        final parsedDateTime = _parseDateTime(dateTime);
        existing.start = calendar.EventDateTime(
          dateTime: parsedDateTime,
          timeZone: 'Europe/Paris',
        );
        existing.end = calendar.EventDateTime(
          dateTime: parsedDateTime.add(const Duration(hours: 1)),
          timeZone: 'Europe/Paris',
        );
      }

      await _calendarApi!.events.update(existing, _primaryCalendar, eventId);
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Événement $eventId mis à jour');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Erreur mise à jour - $e');
      return false;
    }
  }

  /// Parse une date/heure en langage naturel vers DateTime
  ///
  /// Gère: demain, après-demain, jours de semaine, dates absolues
  DateTime _parseDateTime(String input) {
    final now = DateTime.now();
    final lowerInput = input.toLowerCase().trim();

    // Extraire l'heure
    int hour = 9; // Heure par défaut
    int minute = 0;

    final heureMatch = RegExp(r'(\d{1,2})[h:](\d{0,2})').firstMatch(lowerInput);
    if (heureMatch != null) {
      hour = int.parse(heureMatch.group(1)!);
      if (heureMatch.group(2)?.isNotEmpty == true) {
        minute = int.parse(heureMatch.group(2)!);
      }
    } else if (lowerInput.contains('midi')) {
      hour = 12;
    } else if (lowerInput.contains('soir')) {
      hour = 19;
    } else if (lowerInput.contains('matin')) {
      hour = 9;
    }

    // Trouver la date
    DateTime targetDate = now;

    if (lowerInput.contains("aujourd'hui") || lowerInput.contains('ce soir') || lowerInput.contains('ce matin')) {
      targetDate = now;
    } else if (lowerInput.contains('demain')) {
      targetDate = now.add(const Duration(days: 1));
    } else if (lowerInput.contains('après-demain') || lowerInput.contains('apres-demain')) {
      targetDate = now.add(const Duration(days: 2));
    } else {
      // Jours de la semaine
      const jours = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
      for (int i = 0; i < jours.length; i++) {
        if (lowerInput.contains(jours[i])) {
          final currentWeekday = now.weekday;
          final targetWeekday = i + 1;
          var daysToAdd = targetWeekday - currentWeekday;
          if (daysToAdd <= 0) daysToAdd += 7;
          targetDate = now.add(Duration(days: daysToAdd));
          break;
        }
      }
    }

    return DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
      hour,
      minute,
    );
  }

  /// Supprime un événement
  Future<bool> deleteEvent(String eventId) async {
    if (_calendarApi == null) return false;

    try {
      await _calendarApi!.events.delete(_primaryCalendar, eventId);
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Événement $eventId supprimé');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_CALENDAR: Erreur suppression - $e');
      return false;
    }
  }
}
