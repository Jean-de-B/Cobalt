import '../services/ai_sorter_service.dart';

/// =============================================================================
/// voice_note.dart
/// =============================================================================
/// Modèle de données représentant une note vocale intelligente.
/// Utilisé pour la persistence SQLite et l'affichage dans l'interface.
///
/// Cycle de vie d'une VoiceNote:
/// 1. Réception des données audio via BLE ou microphone
/// 2. Décodage et sauvegarde du fichier audio
/// 3. Transcription via l'API Groq Whisper
/// 4. Analyse intelligente via Groq Llama 3 (catégorisation)
/// 5. Stockage de la note structurée en base
/// =============================================================================

/// Représente une note vocale avec sa transcription et ses métadonnées.
class VoiceNote {
  /// Identifiant unique (null si non encore persisté)
  final int? id;

  /// Texte transcrit brut de la note vocale
  final String text;

  /// Résumé court / titre généré par l'IA
  final String summary;

  /// Catégorie de la note (TODO, EVENT, CONTACT, MEMO)
  final NoteCategory category;

  /// Date et heure de création de la note
  final DateTime date;

  /// Chemin absolu vers le fichier audio WAV
  final String audioPath;

  /// Durée de l'audio en secondes
  final int duration;

  /// Indique si la note est en cours de transcription
  final bool isTranscribing;

  /// Indique si la note est en cours d'analyse IA
  final bool isAnalyzing;

  /// Message d'erreur si la transcription a échoué
  final String? errorMessage;

  /// Indique si la note est marquée comme favorite
  final bool isFavorite;

  /// Indique si la tâche est complétée (pour les TODO)
  final bool isCompleted;

  /// Date/heure de l'événement (pour les EVENT)
  final String? eventDateTime;

  /// Nom du contact (pour les CONTACT)
  final String? contactName;

  /// Sentiment détecté pour les MEMO (idea, frustration, memory, question, neutral)
  final String? sentiment;

  const VoiceNote({
    this.id,
    required this.text,
    this.summary = '',
    this.category = NoteCategory.memo,
    required this.date,
    required this.audioPath,
    required this.duration,
    this.isTranscribing = false,
    this.isAnalyzing = false,
    this.errorMessage,
    this.isFavorite = false,
    this.isCompleted = false,
    this.eventDateTime,
    this.contactName,
    this.sentiment,
  });

  /// Crée une VoiceNote en attente de transcription
  factory VoiceNote.pending({
    required String audioPath,
    required int duration,
  }) {
    return VoiceNote(
      text: '',
      summary: 'Transcription...',
      category: NoteCategory.memo,
      date: DateTime.now(),
      audioPath: audioPath,
      duration: duration,
      isTranscribing: true,
      isAnalyzing: false,
    );
  }

  /// Crée une VoiceNote avec une erreur
  factory VoiceNote.withError({
    required String audioPath,
    required int duration,
    required String error,
  }) {
    return VoiceNote(
      text: '',
      summary: 'Erreur',
      category: NoteCategory.memo,
      date: DateTime.now(),
      audioPath: audioPath,
      duration: duration,
      isTranscribing: false,
      isAnalyzing: false,
      errorMessage: error,
    );
  }

  /// Convertit l'objet en Map pour stockage SQLite
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'text': text,
      'summary': summary,
      'category': category.name,
      'date': date.millisecondsSinceEpoch,
      'audio_path': audioPath,
      'duration': duration,
      'is_transcribing': isTranscribing ? 1 : 0,
      'is_analyzing': isAnalyzing ? 1 : 0,
      'error_message': errorMessage,
      'is_favorite': isFavorite ? 1 : 0,
      'is_completed': isCompleted ? 1 : 0,
      'event_datetime': eventDateTime,
      'contact_name': contactName,
      'sentiment': sentiment,
    };
  }

  /// Crée une VoiceNote depuis une Map (lecture SQLite)
  factory VoiceNote.fromMap(Map<String, dynamic> map) {
    return VoiceNote(
      id: map['id'] as int?,
      text: map['text'] as String? ?? '',
      summary: map['summary'] as String? ?? '',
      category: NoteCategoryExtension.fromString(map['category'] as String? ?? 'memo'),
      date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
      audioPath: map['audio_path'] as String,
      duration: map['duration'] as int,
      isTranscribing: (map['is_transcribing'] as int?) == 1,
      isAnalyzing: (map['is_analyzing'] as int?) == 1,
      errorMessage: map['error_message'] as String?,
      isFavorite: (map['is_favorite'] as int?) == 1,
      isCompleted: (map['is_completed'] as int?) == 1,
      eventDateTime: map['event_datetime'] as String?,
      contactName: map['contact_name'] as String?,
      sentiment: map['sentiment'] as String?,
    );
  }

  /// Crée une copie avec des champs modifiés
  VoiceNote copyWith({
    int? id,
    String? text,
    String? summary,
    NoteCategory? category,
    DateTime? date,
    String? audioPath,
    int? duration,
    bool? isTranscribing,
    bool? isAnalyzing,
    String? errorMessage,
    bool? isFavorite,
    bool? isCompleted,
    String? eventDateTime,
    String? contactName,
    String? sentiment,
  }) {
    return VoiceNote(
      id: id ?? this.id,
      text: text ?? this.text,
      summary: summary ?? this.summary,
      category: category ?? this.category,
      date: date ?? this.date,
      audioPath: audioPath ?? this.audioPath,
      duration: duration ?? this.duration,
      isTranscribing: isTranscribing ?? this.isTranscribing,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      errorMessage: errorMessage,
      isFavorite: isFavorite ?? this.isFavorite,
      isCompleted: isCompleted ?? this.isCompleted,
      eventDateTime: eventDateTime ?? this.eventDateTime,
      contactName: contactName ?? this.contactName,
      sentiment: sentiment ?? this.sentiment,
    );
  }

  /// Formate la durée en format lisible (MM:SS)
  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = duration % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Formate la date en format lisible
  String get formattedDate {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return 'Hier';
    } else if (diff.inDays < 7) {
      return 'Il y a ${diff.inDays} jours';
    } else {
      return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    }
  }

  /// Affiche le titre de la note (summary ou preview)
  String get displayTitle {
    if (isTranscribing) return 'Transcription...';
    if (isAnalyzing) return 'Analyse...';
    if (summary.isNotEmpty && summary != 'Transcription...') return summary;
    return preview;
  }

  /// Extrait un aperçu du texte
  String get preview {
    if (isTranscribing) return 'Transcription en cours...';
    if (isAnalyzing) return 'Analyse en cours...';
    if (errorMessage != null) return 'Erreur: $errorMessage';
    if (text.isEmpty) return 'Note vide';

    final firstLine = text.split('\n').first;
    if (firstLine.length > 100) {
      return '${firstLine.substring(0, 100)}...';
    }
    return firstLine;
  }

  /// Indique si la note est en cours de traitement
  bool get isProcessing => isTranscribing || isAnalyzing;

  @override
  String toString() {
    return 'VoiceNote(id: $id, category: ${category.name}, summary: "$summary")';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VoiceNote &&
        other.id == id &&
        other.text == text &&
        other.date == date &&
        other.audioPath == audioPath;
  }

  @override
  int get hashCode => Object.hash(id, text, date, audioPath);
}
