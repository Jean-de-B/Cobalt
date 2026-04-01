import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/fiche.dart';
import '../models/fintecture_transaction.dart';
import '../models/incoming_message.dart';
import '../models/voice_note.dart';

/// =============================================================================
/// database_service.dart
/// =============================================================================
/// Service de persistence SQLite pour les notes vocales.
/// Implémente le pattern Singleton pour une instance unique de la base.
///
/// Schéma de la table voice_notes:
/// - id: INTEGER PRIMARY KEY AUTOINCREMENT
/// - text: TEXT (transcription)
/// - summary: TEXT (titre généré par IA)
/// - category: TEXT (TODO, EVENT, CONTACT, MEMO)
/// - date: INTEGER (timestamp milliseconds)
/// - audio_path: TEXT (chemin vers le fichier WAV)
/// - duration: INTEGER (durée en secondes)
/// - is_transcribing: INTEGER (0 ou 1)
/// - is_analyzing: INTEGER (0 ou 1)
/// - error_message: TEXT (nullable)
/// - is_favorite: INTEGER (0 ou 1)
/// - is_completed: INTEGER (0 ou 1, pour TODO)
/// - event_datetime: TEXT (nullable, pour EVENT)
/// - contact_name: TEXT (nullable, pour CONTACT)
/// =============================================================================

class DatabaseService {
  /// Instance singleton
  static DatabaseService? _instance;

  /// Base de données SQLite
  Database? _database;

  /// Nom du fichier de base de données
  static const String _databaseName = 'cobalt_voice.db';

  /// Version du schéma (pour migrations futures)
  static const int _databaseVersion = 12;

  /// Nom de la table Fintecture
  static const String _tableFintecture = 'fintecture_transactions';

  /// Nom de la table des messages entrants
  static const String _tableMessages = 'incoming_messages';

  /// Nom de la table des notes vocales
  static const String _tableVoiceNotes = 'voice_notes';

  /// Nom de la table des fiches thématiques
  static const String _tableFiches = 'fiches';

  /// StreamController pour notifier les changements de données
  final _notesStreamController = StreamController<List<VoiceNote>>.broadcast();
  final _fichesStreamController = StreamController<List<Fiche>>.broadcast();

  /// Cache de la dernière valeur (pour les broadcast streams)
  List<VoiceNote>? _lastNotes;
  List<Fiche>? _lastFiches;

  /// Stream des notes vocales (pour UI réactive)
  Stream<List<VoiceNote>> get notesStream => _notesStreamController.stream;

  /// Stream des fiches thématiques
  Stream<List<Fiche>> get fichesStream => _fichesStreamController.stream;

  /// Dernière valeur des notes (pour initialData)
  List<VoiceNote>? get lastNotes => _lastNotes;

  /// Dernière valeur des fiches (pour initialData)
  List<Fiche>? get lastFiches => _lastFiches;

  /// Constructeur privé (pattern Singleton)
  DatabaseService._internal();

  /// Factory pour obtenir l'instance unique
  factory DatabaseService() {
    _instance ??= DatabaseService._internal();
    return _instance!;
  }

  /// Flag pour reset au prochain démarrage (désactivé - données persistantes)
  static const bool _resetOnNextLaunch = false;

  /// Getter pour la base de données (initialise si nécessaire)
  Future<Database> get database async {
    // Reset unique si le flag est activé
    if (_resetOnNextLaunch && _database == null) {
      await _deleteDatabase();
    }
    _database ??= await _initDatabase();
    return _database!;
  }

  /// Supprime complètement la base de données
  Future<void> _deleteDatabase() async {
    try {
      final databasesPath = await getDatabasesPath();
      final path = join(databasesPath, _databaseName);

      // ignore: avoid_print
      print('DATABASE: Suppression de la base de données pour reset...');
      await deleteDatabase(path);
      // ignore: avoid_print
      print('DATABASE: Base de données supprimée avec succès');
    } catch (e) {
      // ignore: avoid_print
      print('DATABASE: Erreur suppression: $e');
    }
  }

  /// Initialise la base de données
  ///
  /// Crée le fichier de base et les tables si elles n'existent pas.
  Future<Database> _initDatabase() async {
    // Obtenir le chemin du répertoire de bases de données
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _databaseName);

    // Ouvrir (ou créer) la base de données
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Callback de création de la base (première installation)
  Future<void> _onCreate(Database db, int version) async {
    // Table des notes vocales (archives audio)
    await db.execute('''
      CREATE TABLE $_tableVoiceNotes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL DEFAULT '',
        summary TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT 'memo',
        date INTEGER NOT NULL,
        audio_path TEXT NOT NULL,
        duration INTEGER NOT NULL,
        is_transcribing INTEGER NOT NULL DEFAULT 0,
        is_analyzing INTEGER NOT NULL DEFAULT 0,
        error_message TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        is_completed INTEGER NOT NULL DEFAULT 0,
        event_datetime TEXT,
        contact_name TEXT,
        sentiment TEXT,
        action_json TEXT,
        fiche_id INTEGER
      )
    ''');

    // Index sur la date pour tri chronologique rapide
    await db.execute('''
      CREATE INDEX idx_voice_notes_date ON $_tableVoiceNotes (date DESC)
    ''');

    // Index sur la catégorie pour filtrage rapide
    await db.execute('''
      CREATE INDEX idx_voice_notes_category ON $_tableVoiceNotes (category)
    ''');

    // Table des fiches thématiques consolidées
    await db.execute('''
      CREATE TABLE $_tableFiches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'memo',
        content TEXT NOT NULL DEFAULT '',
        items_json TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        is_completed INTEGER NOT NULL DEFAULT 0,
        event_datetime TEXT,
        event_location TEXT,
        contact_first_name TEXT,
        contact_last_name TEXT,
        contact_phone TEXT,
        contact_email TEXT,
        contact_building_code TEXT,
        source_note_ids TEXT NOT NULL DEFAULT ''
      )
    ''');

    // Index sur la catégorie des fiches
    await db.execute('''
      CREATE INDEX idx_fiches_category ON $_tableFiches (category)
    ''');

    // Index sur la date de mise à jour
    await db.execute('''
      CREATE INDEX idx_fiches_updated ON $_tableFiches (updated_at DESC)
    ''');

    // Table des contacts validés (routage intelligent)
    await db.execute('''
      CREATE TABLE validated_contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        spoken_name TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        validated_at INTEGER NOT NULL
      )
    ''');

    // Table des validations en attente
    await db.execute('''
      CREATE TABLE pending_validations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        spoken_name TEXT NOT NULL,
        suggested_name TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        pending_message TEXT,
        created_at INTEGER NOT NULL
      )
    ''');

    // Table Fintecture transactions
    await db.execute('''
      CREATE TABLE $_tableFintecture (
        id TEXT PRIMARY KEY,
        recipient_name TEXT NOT NULL,
        recipient_phone TEXT NOT NULL DEFAULT '',
        amount REAL NOT NULL,
        currency TEXT NOT NULL DEFAULT 'EUR',
        note TEXT DEFAULT '',
        payment_url TEXT DEFAULT '',
        status TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL,
        paid_at INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tableMessages (
        id TEXT PRIMARY KEY,
        sender_name TEXT NOT NULL,
        message_preview TEXT NOT NULL DEFAULT '',
        app_source TEXT NOT NULL,
        app_package TEXT NOT NULL,
        received_at INTEGER NOT NULL
      )
    ''');
  }

  /// Callback de migration (mises à jour futures)
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Migration v1 → v2 : ajout de la colonne is_favorite
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
      );
    }

    // Migration v2 → v3 : ajout des colonnes pour l'intelligence
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN summary TEXT NOT NULL DEFAULT ""',
      );
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN category TEXT NOT NULL DEFAULT "memo"',
      );
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN is_analyzing INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN is_completed INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN event_datetime TEXT',
      );
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN contact_name TEXT',
      );

      // Index sur la catégorie
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_voice_notes_category ON $_tableVoiceNotes (category)',
      );
    }

    // Migration v3 → v4 : ajout de la table fiches et fiche_id dans voice_notes
    if (oldVersion < 4) {
      // Ajouter fiche_id aux notes vocales (vérifier si la colonne existe déjà)
      try {
        await db.execute(
          'ALTER TABLE $_tableVoiceNotes ADD COLUMN fiche_id INTEGER',
        );
      } catch (e) {
        // La colonne existe déjà, ignorer l'erreur
        // ignore: avoid_print
        print('Migration: fiche_id existe déjà, ignoré');
      }

      // Créer la table des fiches
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_tableFiches (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          category TEXT NOT NULL DEFAULT 'memo',
          content TEXT NOT NULL DEFAULT '',
          items_json TEXT NOT NULL DEFAULT '',
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          is_favorite INTEGER NOT NULL DEFAULT 0,
          is_completed INTEGER NOT NULL DEFAULT 0,
          event_datetime TEXT,
          event_location TEXT,
          contact_first_name TEXT,
          contact_last_name TEXT,
          contact_phone TEXT,
          contact_email TEXT,
          contact_building_code TEXT,
          source_note_ids TEXT NOT NULL DEFAULT ''
        )
      ''');

      // Index
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_fiches_category ON $_tableFiches (category)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_fiches_updated ON $_tableFiches (updated_at DESC)',
      );
    }

    // Migration v4 → v5 : nouveaux champs contact (prénom, nom, code immeuble)
    if (oldVersion < 5) {
      try {
        await db.execute('ALTER TABLE $_tableFiches ADD COLUMN contact_first_name TEXT');
        await db.execute('ALTER TABLE $_tableFiches ADD COLUMN contact_last_name TEXT');
        await db.execute('ALTER TABLE $_tableFiches ADD COLUMN contact_building_code TEXT');
      } catch (e) {
        // ignore: avoid_print
        print('Migration v5: colonnes existent déjà, ignoré');
      }
    }

    // Migration v5 → v6 : tables pour le routage intelligent des messages
    if (oldVersion < 6) {
      // Mapping permanent prenom parlé → contact téléphone
      await db.execute('''
        CREATE TABLE IF NOT EXISTS validated_contacts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          spoken_name TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL,
          phone_number TEXT NOT NULL,
          validated_at INTEGER NOT NULL
        )
      ''');

      // Validations en attente (fuzzy match à confirmer)
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_validations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          spoken_name TEXT NOT NULL,
          suggested_name TEXT NOT NULL,
          phone_number TEXT NOT NULL,
          pending_message TEXT,
          created_at INTEGER NOT NULL
        )
      ''');
    }

    // Migration v6 → v7 : ajout du message en attente dans pending_validations
    if (oldVersion < 7) {
      try {
        await db.execute(
          'ALTER TABLE pending_validations ADD COLUMN pending_message TEXT',
        );
      } catch (e) {
        // ignore: avoid_print
        print('Migration v7: colonne pending_message existe déjà, ignoré');
      }
    }

    // Migration v7 → v8 : ajout du sentiment pour les MEMO
    if (oldVersion < 8) {
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN sentiment TEXT',
      );
    }

    // Migration v8 → v9 : ajout du JSON de l'action exécutée
    if (oldVersion < 9) {
      await db.execute(
        'ALTER TABLE $_tableVoiceNotes ADD COLUMN action_json TEXT',
      );
    }

    // Migration v9 → v10/v11 : table Fintecture transactions
    if (oldVersion < 11) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_tableFintecture (
          id TEXT PRIMARY KEY,
          recipient_name TEXT NOT NULL,
          recipient_phone TEXT NOT NULL DEFAULT '',
          amount REAL NOT NULL,
          currency TEXT NOT NULL DEFAULT 'EUR',
          note TEXT DEFAULT '',
          payment_url TEXT DEFAULT '',
          status TEXT NOT NULL DEFAULT 'pending',
          created_at INTEGER NOT NULL,
          paid_at INTEGER
        )
      ''');
    }

    // Migration v11 → v12 : table messages entrants
    if (oldVersion < 12) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_tableMessages (
          id TEXT PRIMARY KEY,
          sender_name TEXT NOT NULL,
          message_preview TEXT NOT NULL DEFAULT '',
          app_source TEXT NOT NULL,
          app_package TEXT NOT NULL,
          received_at INTEGER NOT NULL
        )
      ''');
    }
  }

  // ---------------------------------------------------------------------------
  // OPÉRATIONS CRUD
  // ---------------------------------------------------------------------------

  /// Insère une nouvelle note vocale
  ///
  /// Retourne l'ID de la note créée.
  Future<int> insertNote(VoiceNote note) async {
    final db = await database;
    final id = await db.insert(
      _tableVoiceNotes,
      note.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Notifier les listeners du changement
    _notifyListeners();

    return id;
  }

  /// Met à jour une note existante
  ///
  /// Retourne le nombre de lignes affectées.
  Future<int> updateNote(VoiceNote note) async {
    if (note.id == null) {
      throw ArgumentError('Cannot update note without ID');
    }

    final db = await database;
    final count = await db.update(
      _tableVoiceNotes,
      note.toMap(),
      where: 'id = ?',
      whereArgs: [note.id],
    );

    _notifyListeners();
    return count;
  }

  /// Supprime une note par son ID
  ///
  /// Retourne le nombre de lignes supprimées.
  Future<int> deleteNote(int id) async {
    final db = await database;
    final count = await db.delete(
      _tableVoiceNotes,
      where: 'id = ?',
      whereArgs: [id],
    );

    _notifyListeners();
    return count;
  }

  /// Récupère une note par son ID
  Future<VoiceNote?> getNoteById(int id) async {
    final db = await database;
    final maps = await db.query(
      _tableVoiceNotes,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return VoiceNote.fromMap(maps.first);
  }

  /// Récupère toutes les notes (ordre chronologique inverse)
  Future<List<VoiceNote>> getAllNotes() async {
    final db = await database;
    final maps = await db.query(
      _tableVoiceNotes,
      orderBy: 'date DESC',
    );

    return maps.map((map) => VoiceNote.fromMap(map)).toList();
  }

  /// Récupère la dernière note qui a un texte transcrit (pour détecter les doublons Whisper)
  Future<VoiceNote?> getLastNoteWithText() async {
    final db = await database;
    final maps = await db.query(
      _tableVoiceNotes,
      where: 'text IS NOT NULL AND text != ?',
      whereArgs: [''],
      orderBy: 'date DESC',
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return VoiceNote.fromMap(maps.first);
  }

  /// Récupère uniquement les notes favorites
  Future<List<VoiceNote>> getFavoriteNotes() async {
    final db = await database;
    final maps = await db.query(
      _tableVoiceNotes,
      where: 'is_favorite = ?',
      whereArgs: [1],
      orderBy: 'date DESC',
    );

    return maps.map((map) => VoiceNote.fromMap(map)).toList();
  }

  /// Bascule le statut favori d'une note
  Future<void> toggleFavorite(int noteId) async {
    final db = await database;

    // Récupérer le statut actuel
    final note = await getNoteById(noteId);
    if (note == null) return;

    // Inverser le statut
    await db.update(
      _tableVoiceNotes,
      {'is_favorite': note.isFavorite ? 0 : 1},
      where: 'id = ?',
      whereArgs: [noteId],
    );

    _notifyListeners();
  }

  /// Bascule le statut complété d'une tâche (TODO)
  Future<void> toggleCompleted(int noteId) async {
    final db = await database;

    final note = await getNoteById(noteId);
    if (note == null) return;

    await db.update(
      _tableVoiceNotes,
      {'is_completed': note.isCompleted ? 0 : 1},
      where: 'id = ?',
      whereArgs: [noteId],
    );

    _notifyListeners();
  }

  /// Récupère les notes par catégorie
  Future<List<VoiceNote>> getNotesByCategory(String category) async {
    final db = await database;
    final maps = await db.query(
      _tableVoiceNotes,
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'date DESC',
    );

    return maps.map((map) => VoiceNote.fromMap(map)).toList();
  }

  /// Récupère les notes avec pagination
  ///
  /// [limit] Nombre maximum de notes à retourner
  /// [offset] Nombre de notes à ignorer (pour pagination)
  Future<List<VoiceNote>> getNotesPaginated({
    int limit = 20,
    int offset = 0,
  }) async {
    final db = await database;
    final maps = await db.query(
      _tableVoiceNotes,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );

    return maps.map((map) => VoiceNote.fromMap(map)).toList();
  }

  /// Recherche des notes par texte
  ///
  /// [query] Terme de recherche (recherche partielle insensible à la casse)
  Future<List<VoiceNote>> searchNotes(String query) async {
    final db = await database;
    final maps = await db.query(
      _tableVoiceNotes,
      where: 'text LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'date DESC',
    );

    return maps.map((map) => VoiceNote.fromMap(map)).toList();
  }

  /// Compte le nombre total de notes
  Future<int> getNotesCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_tableVoiceNotes',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ---------------------------------------------------------------------------
  // MÉTHODES UTILITAIRES
  // ---------------------------------------------------------------------------

  /// Notifie les listeners d'un changement de données
  Future<void> _notifyListeners() async {
    final notes = await getAllNotes();
    _lastNotes = notes;
    _notesStreamController.add(notes);
  }

  /// Force une notification (utile après initialisation)
  Future<void> refreshStream() async {
    await _notifyListeners();
  }

  /// Ferme la base de données et libère les ressources
  Future<void> close() async {
    await _notesStreamController.close();
    await _fichesStreamController.close();
    await _database?.close();
    _database = null;
  }

  /// Supprime toutes les notes (utilisation: debug/reset)
  Future<void> deleteAllNotes() async {
    final db = await database;
    await db.delete(_tableVoiceNotes);
    _notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // OPÉRATIONS CRUD FICHES
  // ---------------------------------------------------------------------------

  /// Insère une nouvelle fiche
  Future<int> insertFiche(Fiche fiche) async {
    final db = await database;
    final id = await db.insert(
      _tableFiches,
      fiche.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyFichesListeners();
    return id;
  }

  /// Met à jour une fiche existante
  Future<int> updateFiche(Fiche fiche) async {
    if (fiche.id == null) {
      throw ArgumentError('Cannot update fiche without ID');
    }

    final db = await database;
    final count = await db.update(
      _tableFiches,
      fiche.toMap(),
      where: 'id = ?',
      whereArgs: [fiche.id],
    );
    _notifyFichesListeners();
    return count;
  }

  /// Supprime une fiche par son ID
  Future<int> deleteFiche(int id) async {
    final db = await database;
    final count = await db.delete(
      _tableFiches,
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyFichesListeners();
    return count;
  }

  /// Récupère une fiche par son ID
  Future<Fiche?> getFicheById(int id) async {
    final db = await database;
    final maps = await db.query(
      _tableFiches,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Fiche.fromMap(maps.first);
  }

  /// Récupère toutes les fiches (ordre de mise à jour)
  Future<List<Fiche>> getAllFiches() async {
    final db = await database;
    final maps = await db.query(
      _tableFiches,
      orderBy: 'updated_at DESC',
    );
    return maps.map((map) => Fiche.fromMap(map)).toList();
  }

  /// Récupère les fiches par catégorie
  Future<List<Fiche>> getFichesByCategory(String category) async {
    final db = await database;
    final maps = await db.query(
      _tableFiches,
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'updated_at DESC',
    );
    return maps.map((map) => Fiche.fromMap(map)).toList();
  }

  /// Récupère les fiches favorites
  Future<List<Fiche>> getFavoriteFiches() async {
    final db = await database;
    final maps = await db.query(
      _tableFiches,
      where: 'is_favorite = ?',
      whereArgs: [1],
      orderBy: 'updated_at DESC',
    );
    return maps.map((map) => Fiche.fromMap(map)).toList();
  }

  /// Recherche une fiche par titre (pour le merging)
  Future<Fiche?> findFicheByTitle(String title, String category) async {
    final db = await database;
    final maps = await db.query(
      _tableFiches,
      where: 'LOWER(title) = LOWER(?) AND category = ?',
      whereArgs: [title, category],
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return Fiche.fromMap(maps.first);
  }

  /// Recherche une fiche similaire (pour l'IA)
  Future<List<Fiche>> searchFichesByKeywords(String category, {int limit = 5}) async {
    final db = await database;
    final maps = await db.query(
      _tableFiches,
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return maps.map((map) => Fiche.fromMap(map)).toList();
  }

  /// Bascule le statut favori d'une fiche
  Future<void> toggleFicheFavorite(int ficheId) async {
    final db = await database;
    final fiche = await getFicheById(ficheId);
    if (fiche == null) return;

    await db.update(
      _tableFiches,
      {'is_favorite': fiche.isFavorite ? 0 : 1},
      where: 'id = ?',
      whereArgs: [ficheId],
    );
    _notifyFichesListeners();
  }

  /// Bascule le statut complété d'une fiche
  Future<void> toggleFicheCompleted(int ficheId) async {
    final db = await database;
    final fiche = await getFicheById(ficheId);
    if (fiche == null) return;

    await db.update(
      _tableFiches,
      {'is_completed': fiche.isCompleted ? 0 : 1},
      where: 'id = ?',
      whereArgs: [ficheId],
    );
    _notifyFichesListeners();
  }

  /// Met à jour un item dans une fiche (toggle completed)
  Future<void> toggleFicheItem(int ficheId, int itemIndex) async {
    final fiche = await getFicheById(ficheId);
    if (fiche == null || itemIndex >= fiche.items.length) return;

    final updatedItems = List<FicheItem>.from(fiche.items);
    updatedItems[itemIndex] = updatedItems[itemIndex].copyWith(
      isCompleted: !updatedItems[itemIndex].isCompleted,
    );

    final updatedFiche = fiche.copyWith(
      items: updatedItems,
      updatedAt: DateTime.now(),
    );
    await updateFiche(updatedFiche);
  }

  /// Lie une note vocale à une fiche
  Future<void> linkNoteToFiche(int noteId, int ficheId) async {
    final db = await database;
    await db.update(
      _tableVoiceNotes,
      {'fiche_id': ficheId},
      where: 'id = ?',
      whereArgs: [noteId],
    );
    _notifyListeners();
  }

  /// Notifie les listeners des fiches
  Future<void> _notifyFichesListeners() async {
    final fiches = await getAllFiches();
    _lastFiches = fiches;
    _fichesStreamController.add(fiches);
  }

  /// Force une notification des fiches
  Future<void> refreshFichesStream() async {
    await _notifyFichesListeners();
  }

  // ---------------------------------------------------------------------------
  // OPÉRATIONS CRUD — Fintecture Transactions
  // ---------------------------------------------------------------------------

  Future<void> insertFintectureTransaction(FintectureTransaction tx) async {
    final db = await database;
    await db.insert(
      _tableFintecture,
      tx.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateFintectureTransactionStatus(
    String id,
    FintectureStatus status, {
    DateTime? paidAt,
  }) async {
    final db = await database;
    final values = <String, dynamic>{'status': status.name};
    if (paidAt != null) {
      values['paid_at'] = paidAt.millisecondsSinceEpoch;
    }
    await db.update(
      _tableFintecture,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<FintectureTransaction>> getFintectureTransactions() async {
    final db = await database;
    final maps = await db.query(
      _tableFintecture,
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => FintectureTransaction.fromMap(m)).toList();
  }

  Future<void> deleteFintectureTransaction(String id) async {
    final db = await database;
    await db.delete(
      _tableFintecture,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------------------
  // INCOMING MESSAGES CRUD
  // ---------------------------------------------------------------------------

  Future<void> insertMessage(IncomingMessage msg) async {
    final db = await database;
    await db.insert(
      _tableMessages,
      msg.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<IncomingMessage>> getMessages() async {
    final db = await database;
    final maps = await db.query(
      _tableMessages,
      orderBy: 'received_at DESC',
      limit: 200,
    );
    return maps.map((m) => IncomingMessage.fromMap(m)).toList();
  }

  Future<void> deleteMessage(String id) async {
    final db = await database;
    await db.delete(
      _tableMessages,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteAllMessages() async {
    final db = await database;
    await db.delete(_tableMessages);
  }
}
