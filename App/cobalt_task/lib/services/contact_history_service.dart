import 'database_service.dart';

/// =============================================================================
/// contact_history_service.dart
/// =============================================================================
/// Service de mémoire des contacts pour les communications.
/// Mémorise la dernière app utilisée pour chaque contact, permettant des
/// commandes simples comme "envoie à Paul que j'arrive".
///
/// Stockage:
/// - contact_name: nom/prénom du contact
/// - phone_number: numéro de téléphone
/// - last_app: dernière app utilisée (sms, whatsapp, telegram, call)
/// - last_used: timestamp de dernière utilisation
/// =============================================================================

/// Représente un historique de contact
class ContactHistoryEntry {
  final int? id;
  final String contactName;
  final String phoneNumber;
  final String lastApp; // sms, whatsapp, telegram, signal, messenger, call
  final DateTime lastUsed;

  const ContactHistoryEntry({
    this.id,
    required this.contactName,
    required this.phoneNumber,
    required this.lastApp,
    required this.lastUsed,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'contact_name': contactName,
    'phone_number': phoneNumber,
    'last_app': lastApp,
    'last_used': lastUsed.millisecondsSinceEpoch,
  };

  factory ContactHistoryEntry.fromMap(Map<String, dynamic> map) => ContactHistoryEntry(
    id: map['id'] as int?,
    contactName: map['contact_name'] as String,
    phoneNumber: map['phone_number'] as String,
    lastApp: map['last_app'] as String,
    lastUsed: DateTime.fromMillisecondsSinceEpoch(map['last_used'] as int),
  );

  ContactHistoryEntry copyWith({
    int? id,
    String? contactName,
    String? phoneNumber,
    String? lastApp,
    DateTime? lastUsed,
  }) => ContactHistoryEntry(
    id: id ?? this.id,
    contactName: contactName ?? this.contactName,
    phoneNumber: phoneNumber ?? this.phoneNumber,
    lastApp: lastApp ?? this.lastApp,
    lastUsed: lastUsed ?? this.lastUsed,
  );
}

/// Résultat de recherche dans l'historique
class ContactHistoryResult {
  final bool found;
  final ContactHistoryEntry? entry;
  final String? suggestedApp;
  final String? phoneNumber;
  final String? displayName;

  const ContactHistoryResult({
    required this.found,
    this.entry,
    this.suggestedApp,
    this.phoneNumber,
    this.displayName,
  });

  factory ContactHistoryResult.notFound() => const ContactHistoryResult(found: false);

  factory ContactHistoryResult.fromEntry(ContactHistoryEntry entry) => ContactHistoryResult(
    found: true,
    entry: entry,
    suggestedApp: entry.lastApp,
    phoneNumber: entry.phoneNumber,
    displayName: entry.contactName,
  );
}

class ContactHistoryService {
  static const String _tableName = 'contact_history';
  final DatabaseService _databaseService;
  bool _initialized = false;

  ContactHistoryService() : _databaseService = DatabaseService();

  /// Initialise le service et crée la table si nécessaire
  Future<void> initialize() async {
    if (_initialized) return;

    final db = await _databaseService.database;

    // Créer la table si elle n'existe pas
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_name TEXT NOT NULL,
        phone_number TEXT NOT NULL,
        last_app TEXT NOT NULL,
        last_used INTEGER NOT NULL
      )
    ''');

    // Index sur le nom du contact (recherche par prénom)
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_contact_history_name
      ON $_tableName (contact_name COLLATE NOCASE)
    ''');

    _initialized = true;
    // ignore: avoid_print
    print('[ContactHistory] Service initialisé');
  }

  /// Enregistre ou met à jour un contact dans l'historique
  Future<void> recordContact({
    required String contactName,
    required String phoneNumber,
    required String app, // sms, whatsapp, telegram, call, etc.
  }) async {
    if (!_initialized) await initialize();

    final db = await _databaseService.database;
    final now = DateTime.now();

    // Normaliser le nom du contact
    final normalizedName = _normalizeContactName(contactName);

    // Détecter si le nom ressemble à un numéro de téléphone
    final isNameAPhoneNumber = _looksLikePhoneNumber(contactName);

    // Chercher si ce contact existe déjà (par numéro)
    final existing = await db.query(
      _tableName,
      where: 'phone_number = ?',
      whereArgs: [phoneNumber],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      final existingEntry = ContactHistoryEntry.fromMap(existing.first);
      final existingNameIsReal = !_looksLikePhoneNumber(existingEntry.contactName);

      // Ne pas écraser un vrai nom par un numéro de téléphone
      final nameToUse = (isNameAPhoneNumber && existingNameIsReal)
          ? existingEntry.contactName
          : normalizedName;

      // Mettre à jour l'entrée existante
      await db.update(
        _tableName,
        {
          'contact_name': nameToUse,
          'last_app': app,
          'last_used': now.millisecondsSinceEpoch,
        },
        where: 'phone_number = ?',
        whereArgs: [phoneNumber],
      );
      // ignore: avoid_print
      print('[ContactHistory] MAJ: $nameToUse via $app');
    } else {
      // Créer une nouvelle entrée
      await db.insert(_tableName, {
        'contact_name': normalizedName,
        'phone_number': phoneNumber,
        'last_app': app,
        'last_used': now.millisecondsSinceEpoch,
      });
      // ignore: avoid_print
      print('[ContactHistory] Nouveau: $normalizedName via $app');
    }
  }

  /// Recherche un contact par prénom/nom dans l'historique
  /// Retourne le contact le plus récemment utilisé avec ce prénom
  Future<ContactHistoryResult> findByName(String searchName) async {
    if (!_initialized) await initialize();

    final db = await _databaseService.database;
    final normalizedSearch = _normalizeContactName(searchName);

    // Recherche exacte d'abord
    var results = await db.query(
      _tableName,
      where: 'LOWER(contact_name) = LOWER(?)',
      whereArgs: [normalizedSearch],
      orderBy: 'last_used DESC',
      limit: 1,
    );

    // Si pas de résultat exact, recherche partielle (prénom)
    if (results.isEmpty) {
      results = await db.query(
        _tableName,
        where: 'LOWER(contact_name) LIKE LOWER(?)',
        whereArgs: ['%$normalizedSearch%'],
        orderBy: 'last_used DESC',
        limit: 1,
      );
    }

    // Recherche par prénom seulement (premier mot)
    if (results.isEmpty) {
      final firstName = normalizedSearch.split(' ').first;
      results = await db.query(
        _tableName,
        where: 'LOWER(contact_name) LIKE LOWER(?)',
        whereArgs: ['$firstName%'],
        orderBy: 'last_used DESC',
        limit: 1,
      );
    }

    if (results.isEmpty) {
      // ignore: avoid_print
      print('[ContactHistory] "$searchName" non trouvé dans l\'historique');
      return ContactHistoryResult.notFound();
    }

    final entry = ContactHistoryEntry.fromMap(results.first);
    // ignore: avoid_print
    print('[ContactHistory] Trouvé: ${entry.contactName} via ${entry.lastApp}');
    return ContactHistoryResult.fromEntry(entry);
  }

  /// Récupère tout l'historique des contacts
  Future<List<ContactHistoryEntry>> getAllHistory() async {
    if (!_initialized) await initialize();

    final db = await _databaseService.database;
    final results = await db.query(
      _tableName,
      orderBy: 'last_used DESC',
    );

    return results.map((m) => ContactHistoryEntry.fromMap(m)).toList();
  }

  /// Supprime un contact de l'historique
  Future<void> deleteContact(int id) async {
    if (!_initialized) await initialize();

    final db = await _databaseService.database;
    await db.delete(_tableName, where: 'id = ?', whereArgs: [id]);
  }

  /// Normalise un nom de contact (supprime les accents, met en forme)
  String _normalizeContactName(String name) {
    // Capitaliser chaque mot
    return name
        .trim()
        .split(' ')
        .map((word) => word.isNotEmpty
            ? '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}'
            : '')
        .join(' ');
  }

  /// Détecte si une chaîne ressemble à un numéro de téléphone
  /// (majoritairement des chiffres, avec éventuellement + ou espaces)
  bool _looksLikePhoneNumber(String text) {
    // Supprimer les caractères de formatage courants
    final cleaned = text.replaceAll(RegExp(r'[\s\-\.\(\)]'), '');
    // Compter les chiffres
    final digitCount = cleaned.replaceAll(RegExp(r'[^\d]'), '').length;
    // Si 8+ chiffres et que les chiffres représentent >70% du texte nettoyé
    return digitCount >= 8 && (digitCount / cleaned.length) > 0.7;
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized;
}
