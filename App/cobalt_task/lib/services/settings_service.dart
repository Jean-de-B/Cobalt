import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

/// =============================================================================
/// settings_service.dart
/// =============================================================================
/// Service de paramètres persistants (SharedPreferences).
/// Singleton, accessible partout dans l'app.
/// =============================================================================

class SettingsService {
  static SettingsService? _instance;
  factory SettingsService() {
    _instance ??= SettingsService._internal();
    return _instance!;
  }
  SettingsService._internal();

  SharedPreferences? _prefs;
  final _controller = StreamController<void>.broadcast();

  Stream<void> get onChanged => _controller.stream;

  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  void _notify() => _controller.add(null);

  // ---------------------------------------------------------------------------
  // LANGUE
  // ---------------------------------------------------------------------------

  String get language => _prefs?.getString('app_language') ?? 'fr';
  set language(String v) {
    _prefs?.setString('app_language', v);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // MUSIQUE
  // ---------------------------------------------------------------------------

  String get musicService => _prefs?.getString('music_service') ?? 'spotify';
  set musicService(String v) {
    _prefs?.setString('music_service', v);
    _notify();
  }

  static const Map<String, String> musicServices = {
    'spotify': 'Spotify',
    'deezer': 'Deezer',
    'youtube_music': 'YouTube Music',
  };

  // ---------------------------------------------------------------------------
  // CALENDRIER
  // ---------------------------------------------------------------------------

  String get calendarService => _prefs?.getString('calendar_service') ?? 'google';
  set calendarService(String v) {
    _prefs?.setString('calendar_service', v);
    _notify();
  }

  static const Map<String, String> calendarServices = {
    'google': 'Google Calendar',
    'samsung': 'Samsung Calendar',
    'calendly': 'Calendly',
  };

  // ---------------------------------------------------------------------------
  // NOTES
  // ---------------------------------------------------------------------------

  String get notesService => _prefs?.getString('notes_service') ?? 'google';
  set notesService(String v) {
    _prefs?.setString('notes_service', v);
    _notify();
  }

  static const Map<String, String> notesServices = {
    'google': 'Google Docs',
    'samsung': 'Samsung Notes',
    'notion': 'Notion',
  };

  // ---------------------------------------------------------------------------
  // NAVIGATION
  // ---------------------------------------------------------------------------

  String get navigationApp => _prefs?.getString('navigation_app') ?? 'google_maps';
  set navigationApp(String v) {
    _prefs?.setString('navigation_app', v);
    _notify();
  }

  static const Map<String, String> navigationApps = {
    'google_maps': 'Google Maps',
    'waze': 'Waze',
  };

  // ---------------------------------------------------------------------------
  // TRANSPORT PAR DÉFAUT
  // ---------------------------------------------------------------------------

  String get defaultTransport => _prefs?.getString('default_transport') ?? 'velo';
  set defaultTransport(String v) {
    _prefs?.setString('default_transport', v);
    _notify();
  }

  static const Map<String, String> transportModes = {
    'velo': 'Vélo',
    'voiture': 'Voiture',
    'pied': 'À pied',
    'transport': 'Transports en commun',
  };

  // ---------------------------------------------------------------------------
  // MESSAGERIE PRÉFÉRÉE
  // ---------------------------------------------------------------------------

  String get preferredMessaging => _prefs?.getString('preferred_messaging') ?? 'whatsapp';
  set preferredMessaging(String v) {
    _prefs?.setString('preferred_messaging', v);
    _notify();
  }

  static const Map<String, String> messagingApps = {
    'whatsapp': 'WhatsApp',
    'telegram': 'Telegram',
    'signal': 'Signal',
    'messenger': 'Messenger',
    'sms': 'SMS',
  };

  // ---------------------------------------------------------------------------
  // ASSISTANT VOCAL
  // ---------------------------------------------------------------------------

  String get sttLanguage => _prefs?.getString('stt_language') ?? 'fr';
  set sttLanguage(String v) {
    _prefs?.setString('stt_language', v);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // SYSTÈME — Raccourci bouton Power
  // ---------------------------------------------------------------------------

  bool get powerButtonAssistant => _prefs?.getBool('power_button_assistant') ?? true;
  set powerButtonAssistant(bool v) {
    _prefs?.setBool('power_button_assistant', v);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // SYSTÈME — Assistant casque / écouteurs Bluetooth
  // ---------------------------------------------------------------------------

  bool get headsetAssistant => _prefs?.getBool('headset_assistant') ?? false;
  set headsetAssistant(bool v) {
    _prefs?.setBool('headset_assistant', v);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // SYSTÈME — Notification persistante
  // ---------------------------------------------------------------------------

  bool get persistentNotification => _prefs?.getBool('persistent_notification') ?? false;
  set persistentNotification(bool v) {
    _prefs?.setBool('persistent_notification', v);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // SYSTÈME — Retour audio (TTS)
  // ---------------------------------------------------------------------------

  bool get ttsEnabled => _prefs?.getBool('tts_enabled') ?? true;
  set ttsEnabled(bool v) {
    _prefs?.setBool('tts_enabled', v);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // SYSTÈME — Son de confirmation
  // ---------------------------------------------------------------------------

  bool get confirmationSound => _prefs?.getBool('confirmation_sound') ?? true;
  set confirmationSound(bool v) {
    _prefs?.setBool('confirmation_sound', v);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // DEBUG — Console intégrée
  // ---------------------------------------------------------------------------

  bool get debugConsole => _prefs?.getBool('debug_console') ?? false;
  set debugConsole(bool v) {
    _prefs?.setBool('debug_console', v);
    _notify();
  }
}
