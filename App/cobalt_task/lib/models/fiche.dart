import '../services/ai_sorter_service.dart';

/// =============================================================================
/// fiche.dart
/// =============================================================================
/// Modèle de Fiche Thématique Structurée.
///
/// Une Fiche consolide plusieurs notes vocales en une seule entité logique.
/// Exemples:
/// - Fiche "Courses" (TODO) qui accumule tous les items à acheter
/// - Fiche "Dr. Martin" (CONTACT) avec toutes les infos sur cette personne
/// - Fiche "Réunion équipe" (EVENT) avec date et détails
///
/// Les notes vocales originales restent archivées et liées à leur fiche.
/// =============================================================================

class Fiche {
  /// Identifiant unique
  final int? id;

  /// Titre de la fiche (généré par l'IA ou déduit)
  final String title;

  /// Catégorie de la fiche
  final NoteCategory category;

  /// Contenu consolidé (texte structuré)
  final String content;

  /// Items structurés (pour TODO: liste de tâches)
  final List<FicheItem> items;

  /// Date de création
  final DateTime createdAt;

  /// Date de dernière mise à jour
  final DateTime updatedAt;

  /// Marquée comme favorite
  final bool isFavorite;

  /// Complétée (pour TODO)
  final bool isCompleted;

  /// Date/heure de l'événement (pour EVENT)
  final String? eventDateTime;

  /// Lieu de l'événement (pour EVENT)
  final String? eventLocation;

  /// Prénom du contact (pour CONTACT)
  final String? contactFirstName;

  /// Nom de famille du contact (pour CONTACT)
  final String? contactLastName;

  /// Téléphone du contact
  final String? contactPhone;

  /// Email du contact
  final String? contactEmail;

  /// Code immeuble/digicode du contact
  final String? contactBuildingCode;

  /// IDs des notes vocales sources
  final List<int> sourceNoteIds;

  const Fiche({
    this.id,
    required this.title,
    required this.category,
    this.content = '',
    this.items = const [],
    required this.createdAt,
    required this.updatedAt,
    this.isFavorite = false,
    this.isCompleted = false,
    this.eventDateTime,
    this.eventLocation,
    this.contactFirstName,
    this.contactLastName,
    this.contactPhone,
    this.contactEmail,
    this.contactBuildingCode,
    this.sourceNoteIds = const [],
  });

  /// Nom complet du contact (prénom + nom)
  String? get contactFullName {
    if (contactFirstName == null && contactLastName == null) return null;
    return [contactFirstName, contactLastName]
        .where((s) => s != null && s.isNotEmpty)
        .join(' ');
  }

  /// Crée une nouvelle fiche à partir d'une analyse IA
  factory Fiche.fromAnalysis({
    required String title,
    required NoteCategory category,
    required String content,
    List<String>? todoItems,
    String? eventDateTime,
    String? eventLocation,
    String? contactFirstName,
    String? contactLastName,
    String? contactPhone,
    String? contactEmail,
    String? contactBuildingCode,
    int? sourceNoteId,
  }) {
    final now = DateTime.now();
    return Fiche(
      title: title,
      category: category,
      content: content,
      items: todoItems?.map((item) => FicheItem(text: item)).toList() ?? [],
      createdAt: now,
      updatedAt: now,
      eventDateTime: eventDateTime,
      eventLocation: eventLocation,
      contactFirstName: contactFirstName,
      contactLastName: contactLastName,
      contactPhone: contactPhone,
      contactEmail: contactEmail,
      contactBuildingCode: contactBuildingCode,
      sourceNoteIds: sourceNoteId != null ? [sourceNoteId] : [],
    );
  }

  /// Convertit en Map pour SQLite
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'category': category.name,
      'content': content,
      'items_json': _itemsToJson(),
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
      'is_favorite': isFavorite ? 1 : 0,
      'is_completed': isCompleted ? 1 : 0,
      'event_datetime': eventDateTime,
      'event_location': eventLocation,
      'contact_first_name': contactFirstName,
      'contact_last_name': contactLastName,
      'contact_phone': contactPhone,
      'contact_email': contactEmail,
      'contact_building_code': contactBuildingCode,
      'source_note_ids': sourceNoteIds.join(','),
    };
  }

  /// Crée une Fiche depuis une Map SQLite
  factory Fiche.fromMap(Map<String, dynamic> map) {
    return Fiche(
      id: map['id'] as int?,
      title: map['title'] as String? ?? '',
      category: NoteCategoryExtension.fromString(map['category'] as String? ?? 'memo'),
      content: map['content'] as String? ?? '',
      items: _itemsFromJson(map['items_json'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
      isFavorite: (map['is_favorite'] as int?) == 1,
      isCompleted: (map['is_completed'] as int?) == 1,
      eventDateTime: map['event_datetime'] as String?,
      eventLocation: map['event_location'] as String?,
      contactFirstName: map['contact_first_name'] as String?,
      contactLastName: map['contact_last_name'] as String?,
      contactPhone: map['contact_phone'] as String?,
      contactEmail: map['contact_email'] as String?,
      contactBuildingCode: map['contact_building_code'] as String?,
      sourceNoteIds: _parseSourceNoteIds(map['source_note_ids'] as String?),
    );
  }

  /// Copie avec modifications
  Fiche copyWith({
    int? id,
    String? title,
    NoteCategory? category,
    String? content,
    List<FicheItem>? items,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isFavorite,
    bool? isCompleted,
    String? eventDateTime,
    String? eventLocation,
    String? contactFirstName,
    String? contactLastName,
    String? contactPhone,
    String? contactEmail,
    String? contactBuildingCode,
    List<int>? sourceNoteIds,
  }) {
    return Fiche(
      id: id ?? this.id,
      title: title ?? this.title,
      category: category ?? this.category,
      content: content ?? this.content,
      items: items ?? this.items,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      isCompleted: isCompleted ?? this.isCompleted,
      eventDateTime: eventDateTime ?? this.eventDateTime,
      eventLocation: eventLocation ?? this.eventLocation,
      contactFirstName: contactFirstName ?? this.contactFirstName,
      contactLastName: contactLastName ?? this.contactLastName,
      contactPhone: contactPhone ?? this.contactPhone,
      contactEmail: contactEmail ?? this.contactEmail,
      contactBuildingCode: contactBuildingCode ?? this.contactBuildingCode,
      sourceNoteIds: sourceNoteIds ?? this.sourceNoteIds,
    );
  }

  /// Ajoute une note source et met à jour le timestamp
  Fiche addSourceNote(int noteId) {
    return copyWith(
      sourceNoteIds: [...sourceNoteIds, noteId],
      updatedAt: DateTime.now(),
    );
  }

  /// Ajoute du contenu à la fiche
  Fiche appendContent(String newContent) {
    final separator = content.isNotEmpty ? '\n' : '';
    return copyWith(
      content: '$content$separator$newContent',
      updatedAt: DateTime.now(),
    );
  }

  /// Ajoute des items (pour TODO)
  Fiche appendItems(List<String> newItems) {
    return copyWith(
      items: [...items, ...newItems.map((text) => FicheItem(text: text))],
      updatedAt: DateTime.now(),
    );
  }

  /// Compte les items complétés
  int get completedItemsCount => items.where((i) => i.isCompleted).length;

  /// Progression des items (0.0 à 1.0)
  double get itemsProgress => items.isEmpty ? 0.0 : completedItemsCount / items.length;

  /// Sérialise les items en JSON simple
  String _itemsToJson() {
    if (items.isEmpty) return '';
    return items.map((i) => '${i.isCompleted ? "1" : "0"}|${i.text}').join('\n');
  }

  /// Désérialise les items
  static List<FicheItem> _itemsFromJson(String? json) {
    if (json == null || json.isEmpty) return [];
    return json.split('\n').map((line) {
      final parts = line.split('|');
      if (parts.length >= 2) {
        return FicheItem(
          isCompleted: parts[0] == '1',
          text: parts.sublist(1).join('|'),
        );
      }
      return FicheItem(text: line);
    }).toList();
  }

  /// Parse les IDs des notes sources
  static List<int> _parseSourceNoteIds(String? ids) {
    if (ids == null || ids.isEmpty) return [];
    return ids.split(',').map((s) => int.tryParse(s.trim())).whereType<int>().toList();
  }

  @override
  String toString() {
    return 'Fiche(id: $id, title: "$title", category: ${category.name}, items: ${items.length})';
  }
}

/// Item individuel dans une fiche (pour les TODO lists)
class FicheItem {
  final String text;
  final bool isCompleted;

  const FicheItem({
    required this.text,
    this.isCompleted = false,
  });

  FicheItem copyWith({String? text, bool? isCompleted}) {
    return FicheItem(
      text: text ?? this.text,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }
}
