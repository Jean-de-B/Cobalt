import 'dart:async';
import 'ai_sorter_service.dart';
import 'google_auth_service.dart';
import 'google_tasks_service.dart';
import 'google_calendar_service.dart';
import 'google_people_service.dart';
import 'google_docs_service.dart';

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

  /// Historique des 5 dernières actions
  final List<SyncAction> _actionHistory = [];
  static const int _maxHistorySize = 5;

  /// Stream pour notifier l'UI des changements d'historique
  final _historyController = StreamController<List<SyncAction>>.broadcast();
  Stream<List<SyncAction>> get historyStream => _historyController.stream;

  /// Stream pour l'état de connexion Google
  final _connectionStateController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

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
