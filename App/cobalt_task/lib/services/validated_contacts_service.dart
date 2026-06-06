import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'database_service.dart';

/// =============================================================================
/// validated_contacts_service.dart
/// =============================================================================
/// Mapping permanent prenom parle → contact telephone.
/// Une seule validation par prenom, reutilisee indefiniment.
/// =============================================================================

/// Contact valide (mapping definitif)
class ValidatedContact {
  final int id;
  final String spokenName;
  final String displayName;
  final String phoneNumber;
  final DateTime validatedAt;

  const ValidatedContact({
    required this.id,
    required this.spokenName,
    required this.displayName,
    required this.phoneNumber,
    required this.validatedAt,
  });

  factory ValidatedContact.fromMap(Map<String, dynamic> map) {
    return ValidatedContact(
      id: map['id'] as int,
      spokenName: map['spoken_name'] as String,
      displayName: map['display_name'] as String,
      phoneNumber: map['phone_number'] as String,
      validatedAt: DateTime.fromMillisecondsSinceEpoch(map['validated_at'] as int),
    );
  }
}

/// Validation en attente (fuzzy match utilise, a confirmer par l'utilisateur)
class PendingValidation {
  final int id;
  final String spokenName;
  final String suggestedName;
  final String phoneNumber;
  final String? pendingMessage;
  final DateTime createdAt;

  const PendingValidation({
    required this.id,
    required this.spokenName,
    required this.suggestedName,
    required this.phoneNumber,
    this.pendingMessage,
    required this.createdAt,
  });

  factory PendingValidation.fromMap(Map<String, dynamic> map) {
    return PendingValidation(
      id: map['id'] as int,
      spokenName: map['spoken_name'] as String,
      suggestedName: map['suggested_name'] as String,
      phoneNumber: map['phone_number'] as String,
      pendingMessage: map['pending_message'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    );
  }
}

class ValidatedContactsService {
  static ValidatedContactsService? _instance;

  final DatabaseService _databaseService = DatabaseService();

  /// Stream qui émet quand une nouvelle validation en attente est créée
  /// Le home screen écoute ce stream pour afficher le dialog immédiatement
  final _pendingAddedController = StreamController<PendingValidation>.broadcast();
  Stream<PendingValidation> get pendingAddedStream => _pendingAddedController.stream;

  ValidatedContactsService._internal();

  factory ValidatedContactsService() {
    _instance ??= ValidatedContactsService._internal();
    return _instance!;
  }

  /// Cherche un contact valide par prenom parle
  /// Retourne null si ce prenom n'a jamais ete valide
  Future<ValidatedContact?> resolve(String spokenName) async {
    final db = await _databaseService.database;
    final normalized = spokenName.trim().toLowerCase();

    // 1. Match exact
    final results = await db.query(
      'validated_contacts',
      where: 'spoken_name = ?',
      whereArgs: [normalized],
      limit: 1,
    );

    if (results.isNotEmpty) return ValidatedContact.fromMap(results.first);

    // 2. Match flou : Llama3 peut extraire "marie" ou "marie dupont" pour le même audio.
    //    On cherche si un spoken_name validé est contenu dans la requête, ou vice versa.
    final all = await db.query('validated_contacts');
    if (all.isEmpty) return null;

    final searchWords = normalized.split(RegExp(r'\s+'));

    for (final row in all) {
      final storedName = (row['spoken_name'] as String).toLowerCase();
      final storedWords = storedName.split(RegExp(r'\s+'));

      // Tous les mots du stocké sont dans la requête OU vice versa
      final storedInSearch = storedWords.every((w) => searchWords.contains(w));
      final searchInStored = searchWords.every((w) => storedWords.contains(w));

      if (storedInSearch || searchInStored) {
        // ignore: avoid_print
        print('[ValidatedContacts] Match flou: "$normalized" ≈ "$storedName"');
        return ValidatedContact.fromMap(row);
      }
    }

    return null;
  }

  /// Enregistre un mapping definitif prenom → contact
  Future<void> validate(String spokenName, String displayName, String phoneNumber) async {
    final db = await _databaseService.database;
    final normalized = spokenName.trim().toLowerCase();

    await db.insert(
      'validated_contacts',
      {
        'spoken_name': normalized,
        'display_name': displayName,
        'phone_number': phoneNumber,
        'validated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Supprimer les pending validations pour ce prenom
    await db.delete(
      'pending_validations',
      where: 'spoken_name = ?',
      whereArgs: [normalized],
    );

    // ignore: avoid_print
    print('[ValidatedContacts] Valide: "$normalized" -> "$displayName" ($phoneNumber)');
  }

  /// Met en file d'attente une validation (pour quand l'app reviendra au premier plan)
  /// [pendingMessage] Le message qui n'a pas pu être envoyé (informatif)
  Future<void> queuePendingValidation(
    String spokenName,
    String suggestedName,
    String phoneNumber, {
    String? pendingMessage,
  }) async {
    final db = await _databaseService.database;
    final normalized = spokenName.trim().toLowerCase();

    // Verifier qu'il n'y a pas deja un pending pour ce prenom
    final existing = await db.query(
      'pending_validations',
      where: 'spoken_name = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      // Pending existe déjà → re-notifier pour afficher le dialog
      _pendingAddedController.add(PendingValidation.fromMap(existing.first));
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert('pending_validations', {
      'spoken_name': normalized,
      'suggested_name': suggestedName,
      'phone_number': phoneNumber,
      'pending_message': pendingMessage,
      'created_at': now,
    });

    // ignore: avoid_print
    print('[ValidatedContacts] Pending: "$normalized" -> "$suggestedName" (msg: ${pendingMessage != null ? "oui" : "non"})');

    // Notifier les listeners (home screen affiche le dialog immédiatement)
    _pendingAddedController.add(PendingValidation(
      id: id,
      spokenName: normalized,
      suggestedName: suggestedName,
      phoneNumber: phoneNumber,
      pendingMessage: pendingMessage,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
    ));
  }

  /// Retourne toutes les validations en attente
  Future<List<PendingValidation>> getPendingValidations() async {
    final db = await _databaseService.database;
    final results = await db.query(
      'pending_validations',
      orderBy: 'created_at ASC',
    );
    return results.map((m) => PendingValidation.fromMap(m)).toList();
  }

  /// Supprime une validation en attente
  Future<void> clearPendingValidation(int id) async {
    final db = await _databaseService.database;
    await db.delete('pending_validations', where: 'id = ?', whereArgs: [id]);
  }

  /// Retourne tous les contacts valides (pour debug/UI)
  Future<List<ValidatedContact>> getAllValidated() async {
    final db = await _databaseService.database;
    final results = await db.query('validated_contacts', orderBy: 'spoken_name ASC');
    return results.map((m) => ValidatedContact.fromMap(m)).toList();
  }
}
