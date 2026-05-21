import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:http/http.dart' as http;
import 'ai_sorter_service.dart';
import 'settings_service.dart';
import 'google_auth_service.dart';
import 'google_tasks_service.dart';
import 'google_calendar_service.dart';
import 'google_people_service.dart';
import 'google_docs_service.dart';
import 'local_calendar_service.dart';

/// =============================================================================
/// google_bridge_service.dart
/// =============================================================================
/// Service orchestrateur pour la synchronisation Google.
///
/// Route automatiquement les fiches vers le bon service Google:
/// - TODO → Google Tasks
/// - EVENT → Google Calendar
/// - CONTACT → Google People
/// - MEMO → Google Tasks (Liste "Mémos")
///
/// Gère l'historique des 5 dernières actions pour affichage UI.
/// =============================================================================

/// Représente une action de synchronisation
class SyncAction {
  final DateTime timestamp;
  final NoteCategory category;
  final String title;
  final bool success;
  final String? googleId;
  final String? errorMessage;

  const SyncAction({
    required this.timestamp,
    required this.category,
    required this.title,
    required this.success,
    this.googleId,
    this.errorMessage,
  });

  String get displayText {
    final icon = success ? '✓' : '✗';
    final categoryIcon = switch (category) {
      NoteCategory.todo => '📋',
      NoteCategory.shopping => '🛒',
      NoteCategory.event => '📅',
      NoteCategory.contact => '👤',
      NoteCategory.memo => '📝',
    };
    return '$icon $categoryIcon $title';
  }
}

class GoogleBridgeService {
  /// Instance singleton
  static GoogleBridgeService? _instance;

  /// Services Google
  final GoogleAuthService _authService;
  late final GoogleTasksService _tasksService;
  late final GoogleCalendarService _calendarService;
  late final GooglePeopleService _peopleService;
  late final GoogleDocsService _docsService;

  /// Service calendrier local (Samsung Calendar, sans connexion Google)
  final LocalCalendarService _localCalendarService = LocalCalendarService();

  /// Historique des 5 dernières actions
  final List<SyncAction> _actionHistory = [];
  static const int _maxHistorySize = 5;

  /// Stream pour notifier l'UI des changements d'historique
  final _historyController = StreamController<List<SyncAction>>.broadcast();
  Stream<List<SyncAction>> get historyStream => _historyController.stream;

  /// Stream pour l'état de connexion Google
  final _connectionStateController = StreamController<bool>.broadcast();

  /// Stream avec replay : chaque nouvel abonné reçoit immédiatement l'état courant,
  /// puis les événements suivants. Évite le race condition entre init et ouverture UI.
  Stream<bool> get connectionStateStream => Stream.multi((controller) {
    controller.add(isConnected);
    final sub = _connectionStateController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// État d'initialisation
  bool _isInitialized = false;

  /// Constructeur privé
  GoogleBridgeService._internal() : _authService = GoogleAuthService() {
    _tasksService = GoogleTasksService(_authService);
    _calendarService = GoogleCalendarService(_authService);
    _peopleService = GooglePeopleService(_authService);
    _docsService = GoogleDocsService(_authService);
  }

  /// Factory Singleton
  factory GoogleBridgeService() {
    _instance ??= GoogleBridgeService._internal();
    return _instance!;
  }

  /// Vérifie si connecté à Google
  bool get isConnected => _authService.isSignedIn;

  /// Email de l'utilisateur connecté
  String? get userEmail => _authService.userEmail;

  /// Nom de l'utilisateur connecté
  String? get userName => _authService.userName;

  /// Historique des actions
  List<SyncAction> get actionHistory => List.unmodifiable(_actionHistory);

  /// Initialise tous les services Google
  Future<bool> initialize() async {
    if (_isInitialized) return isConnected;

    try {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Initialisation...');

      // Tenter connexion silencieuse
      final signedIn = await _authService.initialize();

      if (signedIn) {
        await _initializeServices();
      }

      _isInitialized = true;
      _connectionStateController.add(signedIn);

      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Initialisé - Connecté: $signedIn');
      return signedIn;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Erreur initialisation - $e');
      _isInitialized = true;
      return false;
    }
  }

  /// Initialise les services individuels
  Future<void> _initializeServices() async {
    await Future.wait([
      _tasksService.initialize(),
      _calendarService.initialize(),
      _peopleService.initialize(),
      _docsService.initialize(),
    ]);
  }

  /// Connecte l'utilisateur à Google
  Future<bool> signIn() async {
    try {
      final success = await _authService.signIn();

      if (success) {
        await _initializeServices();
        _connectionStateController.add(true);
      }

      return success;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Erreur connexion - $e');
      return false;
    }
  }

  /// Déconnecte l'utilisateur
  Future<void> signOut() async {
    await _authService.signOut();
    _connectionStateController.add(false);
    _actionHistory.clear();
    _historyController.add([]);
  }

  /// Synchronise une fiche vers Google
  ///
  /// Route automatiquement vers le bon service selon la catégorie.
  /// Retourne l'ID Google de l'élément créé ou null en cas d'erreur.
  /// Ouvre Samsung Notes avec le contenu pré-rempli (intent)
  Future<void> _openSamsungNotes(String title, String? content) async {
    try {
      final text = content != null ? '$title\n\n$content' : title;
      const channel = MethodChannel('com.cobalt_task/media_keys');
      await channel.invokeMethod('openSamsungNotes', {'text': text});
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Erreur Samsung Notes: $e');
    }
  }

  /// Crée une page dans Notion via l'API REST (token d'intégration interne)
  Future<void> _createNotionPage(String title, String? content) async {
    final token = SettingsService().notionToken;
    final rawPageId = SettingsService().notionPageId;

    if (token.isEmpty || rawPageId.isEmpty) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Notion non configuré (token ou page_id manquant)');
      return;
    }

    // Normaliser l'ID de page : ajouter les tirets UUID si absent
    final pageId = rawPageId.length == 32 && !rawPageId.contains('-')
        ? '${rawPageId.substring(0, 8)}-${rawPageId.substring(8, 12)}-'
          '${rawPageId.substring(12, 16)}-${rawPageId.substring(16, 20)}-'
          '${rawPageId.substring(20)}'
        : rawPageId;

    final body = <String, dynamic>{
      'parent': {'page_id': pageId},
      'properties': {
        'title': {
          'title': [
            {
              'type': 'text',
              'text': {'content': title},
            }
          ],
        },
      },
    };

    if (content != null && content.isNotEmpty) {
      body['children'] = [
        {
          'object': 'block',
          'type': 'paragraph',
          'paragraph': {
            'rich_text': [
              {
                'type': 'text',
                'text': {'content': content},
              }
            ],
          },
        },
      ];
    }

    try {
      final response = await http.post(
        Uri.parse('https://api.notion.com/v1/pages'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Notion-Version': '2022-06-28',
        },
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        // ignore: avoid_print
        print('GOOGLE_BRIDGE: Note créée dans Notion');
      } else {
        // ignore: avoid_print
        print('GOOGLE_BRIDGE: Erreur Notion ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Exception Notion: $e');
    }
  }

  /// Lance le sélecteur de partage Android sans cibler de package.
  Future<String> _launchShareChooser(String shareText) async {
    try {
      await AndroidIntent(
        action: 'android.intent.action.SEND',
        type: 'text/plain',
        arguments: <String, dynamic>{
          'android.intent.extra.TEXT': shareText,
          'android.intent.extra.SUBJECT': shareText.split('\n').first,
        },
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      ).launch();
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Erreur chooser - $e');
    }
    return 'local_chooser';
  }

  /// Lance une app avec intent SEND text/plain ciblé sur un package.
  /// Samsung Reminders parse la première ligne de TEXT comme titre et les
  /// suivantes comme notes — SUBJECT est intentionnellement omis pour éviter
  /// le doublon (Samsung le préfixe au corps en plus du titre).
  /// Fallback vers le sélecteur système si l'app n'est pas installée.
  Future<String> _launchAppWithFallback({
    required String package,
    required String subject,
    String body = '',
    required String returnId,
    String? logName,
  }) async {
    final fullText = body.isNotEmpty ? '$subject\n$body' : subject;
    try {
      await AndroidIntent(
        action: 'android.intent.action.SEND',
        package: package,
        type: 'text/plain',
        arguments: <String, dynamic>{
          'android.intent.extra.TEXT': fullText,
        },
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      ).launch();
      return returnId;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: ${logName ?? package} non installé – chooser - $e');
      return _launchShareChooser(fullText);
    }
  }

  /// Lance Todoist via deep link ou fallback chooser.
  Future<String> _launchTodoist(String title, String? noteText) async {
    final uri = 'todoist://addtask?content=${Uri.encodeComponent(title)}'
        '${noteText != null && noteText.isNotEmpty ? '&note=${Uri.encodeComponent(noteText)}' : ''}';
    try {
      await AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: uri,
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      ).launch();
      return 'local_todoist';
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Todoist non installé – chooser - $e');
      final shareText = noteText != null && noteText.isNotEmpty
          ? '$title\n\n$noteText'
          : title;
      return _launchShareChooser(shareText);
    }
  }

  Future<String?> syncFiche({
    required NoteCategory category,
    required String title,
    String? content,
    List<String> items = const [],
    String? eventDateTime,
    String? eventLocation,
    String? contactFirstName,
    String? contactLastName,
    String? contactPhone,
    String? contactEmail,
    String? contactBuildingCode,
    String? todoDue,
    String? sentiment,
  }) async {
    // Samsung Notes et Notion ne nécessitent pas de connexion Google
    if (category == NoteCategory.memo) {
      final notesTarget = SettingsService().notesService;
      if (notesTarget == 'samsung') {
        await _openSamsungNotes(title, content);
        _addToHistory(SyncAction(timestamp: DateTime.now(), category: category, title: title, success: true, googleId: 'local_samsung'));
        return 'local_samsung';
      } else if (notesTarget == 'notion') {
        await _createNotionPage(title, content);
        _addToHistory(SyncAction(timestamp: DateTime.now(), category: category, title: title, success: true, googleId: 'local_notion'));
        return 'local_notion';
      }
    }

    // Samsung Reminders / Todoist pour les rappels (TODO)
    if (category == NoteCategory.todo) {
      final reminderSvc = SettingsService().reminderService;
      if (reminderSvc == 'samsung_reminders') {
        final body = items.isNotEmpty
            ? items.map((i) => '• $i').join('\n')
            : (content != null && content.isNotEmpty ? content : '');
        final id = await _launchAppWithFallback(
          package: 'com.samsung.android.app.reminder',
          subject: title,
          body: body,
          returnId: 'local_samsung_reminder',
          logName: 'Samsung Reminders',
        );
        _addToHistory(SyncAction(timestamp: DateTime.now(), category: category, title: title, success: true, googleId: id));
        return id;
      } else if (reminderSvc == 'todoist') {
        final noteText = items.isNotEmpty ? items.map((i) => '• $i').join('\n') : content;
        final id = await _launchTodoist(title, noteText);
        _addToHistory(SyncAction(timestamp: DateTime.now(), category: category, title: title, success: true, googleId: id));
        return id;
      }
    }

    // Samsung Reminders / Todoist pour les listes (shopping)
    if (category == NoteCategory.shopping) {
      final listSvc = SettingsService().listService;
      if (listSvc == 'samsung_reminders') {
        final body = items.isNotEmpty ? items.map((i) => '• $i').join('\n') : '';
        // Use a fixed title when items are present: the AI summary for shopping
        // often contains the item names (e.g. "Acheter tomates et pain"), which
        // would duplicate them next to the bullet list in Samsung's notes area.
        final subj = items.isNotEmpty ? 'Liste de courses' : title;
        final id = await _launchAppWithFallback(
          package: 'com.samsung.android.app.reminder',
          subject: subj,
          body: body,
          returnId: 'local_samsung_reminder',
          logName: 'Samsung Reminders',
        );
        _addToHistory(SyncAction(timestamp: DateTime.now(), category: category, title: title, success: true, googleId: id));
        return id;
      } else if (listSvc == 'todoist') {
        final noteText = items.isNotEmpty ? items.map((i) => '• $i').join('\n') : null;
        final id = await _launchTodoist(title, noteText);
        _addToHistory(SyncAction(timestamp: DateTime.now(), category: category, title: title, success: true, googleId: id));
        return id;
      }
    }

    // Samsung Calendar pour les événements (sans connexion Google requise)
    if (category == NoteCategory.event) {
      final calSvc = SettingsService().calendarService;
      if (calSvc == 'samsung') {
        if (eventDateTime == null) {
          // ignore: avoid_print
          print('GOOGLE_BRIDGE: Samsung Calendar – date manquante');
          return null;
        }
        await _localCalendarService.initialize();
        final result = await _localCalendarService.createEventFromString(
          title: title,
          dateTime: eventDateTime,
          location: eventLocation,
          description: content,
        );
        final id = result.success ? 'local_samsung_calendar' : null;
        // ignore: avoid_print
        print('GOOGLE_BRIDGE: Samsung Calendar – ${result.success ? "OK ${result.eventId}" : "Erreur: ${result.error}"}');
        _addToHistory(SyncAction(
          timestamp: DateTime.now(),
          category: category,
          title: title,
          success: result.success,
          googleId: id,
          errorMessage: result.error,
        ));
        return id;
      }
    }

    if (!isConnected) {
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Non connecté, sync ignorée');
      return null;
    }

    String? googleId;
    String? error;

    try {
      switch (category) {
        case NoteCategory.todo:
          googleId = await _tasksService.addTask(
            title: title,
            items: items,
            notes: content,
            dueDate: todoDue,
          );
          break;

        case NoteCategory.shopping:
          googleId = await _tasksService.addShoppingItems(
            title: title,
            items: items,
          );
          break;

        case NoteCategory.event:
          if (eventDateTime == null) {
            error = 'Date/heure manquante';
            break;
          }
          googleId = await _calendarService.createEvent(
            title: title,
            dateTime: eventDateTime,
            location: eventLocation,
            description: content,
          );
          break;

        case NoteCategory.contact:
          googleId = await _peopleService.createContact(
            firstName: contactFirstName,
            lastName: contactLastName,
            phone: contactPhone,
            email: contactEmail,
            buildingCode: contactBuildingCode,
          );
          break;

        case NoteCategory.memo:
          googleId = await _tasksService.addMemo(
            title: title,
            content: content,
            sentiment: sentiment,
          );
          break;
      }
    } catch (e) {
      error = e.toString();
      // ignore: avoid_print
      print('GOOGLE_BRIDGE: Erreur sync - $e');
    }

    // Enregistrer l'action dans l'historique
    _addToHistory(SyncAction(
      timestamp: DateTime.now(),
      category: category,
      title: title,
      success: googleId != null,
      googleId: googleId,
      errorMessage: error,
    ));

    return googleId;
  }

  /// Synchronise un AnalysisResult complet
  Future<String?> syncAnalysisResult(AnalysisResult result) async {
    return syncFiche(
      category: result.category,
      title: result.summary,
      content: result.content,
      items: result.items,
      eventDateTime: result.eventDateTime,
      eventLocation: result.eventLocation,
      contactFirstName: result.contactFirstName,
      contactLastName: result.contactLastName,
      contactPhone: result.contactPhone,
      contactEmail: result.contactEmail,
      contactBuildingCode: result.contactBuildingCode,
      todoDue: result.todoDue,
      sentiment: result.sentiment,
    );
  }

  /// Ajoute une action locale à l'historique (API publique)
  void addActionToHistory({
    required NoteCategory category,
    required String title,
    required bool success,
  }) {
    _addToHistory(SyncAction(
      timestamp: DateTime.now(),
      category: category,
      title: title,
      success: success,
    ));
  }

  /// Ajoute une action à l'historique (max 5)
  void _addToHistory(SyncAction action) {
    _actionHistory.insert(0, action);
    if (_actionHistory.length > _maxHistorySize) {
      _actionHistory.removeLast();
    }
    _historyController.add(List.unmodifiable(_actionHistory));
  }

  /// URL du Journal Cobalt (Google Docs)
  String? get journalUrl => _docsService.journalUrl;

  /// Libère les ressources
  void dispose() {
    _historyController.close();
    _connectionStateController.close();
    _authService.dispose();
  }
}
