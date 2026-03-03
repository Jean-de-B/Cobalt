import 'dart:convert';
import 'dart:io';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// =============================================================================
/// ai_sorter_service.dart
/// =============================================================================
/// Service d'analyse intelligente des notes via l'API Groq (Llama 3).
///
/// Après la transcription Whisper, ce service analyse le texte pour :
/// - Catégoriser automatiquement la note (TODO, EVENT, CONTACT, MEMO)
/// - Générer un résumé court (titre)
/// - Extraire des informations structurées (date/heure pour les événements)
///
/// Endpoint: https://api.groq.com/openai/v1/chat/completions
/// Modèle: llama3-8b-8192
/// =============================================================================

/// Catégories possibles pour une note
enum NoteCategory {
  todo,      // Tâches à faire (PAS courses)
  shopping,  // Courses, achats, listes d'achat
  event,     // Rendez-vous, événements avec notion de temps
  system,    // Alarmes, rappels, timers, actions système
  contact,   // [LEGACY] Informations sur une personne
  memo,      // Idées générales, pensées (fourre-tout)
}

extension NoteCategoryExtension on NoteCategory {
  String get displayName {
    switch (this) {
      case NoteCategory.todo:
        return 'Tâche';
      case NoteCategory.shopping:
        return 'Courses';
      case NoteCategory.event:
        return 'Événement';
      case NoteCategory.system:
        return 'Système';
      case NoteCategory.contact:
        return 'Contact';
      case NoteCategory.memo:
        return 'Mémo';
    }
  }

  String get icon {
    switch (this) {
      case NoteCategory.todo:
        return 'checklist';
      case NoteCategory.shopping:
        return 'shopping_cart';
      case NoteCategory.event:
        return 'calendar_today';
      case NoteCategory.system:
        return 'bolt';
      case NoteCategory.contact:
        return 'person';
      case NoteCategory.memo:
        return 'notes';
    }
  }

  static NoteCategory fromString(String value) {
    switch (value.toUpperCase()) {
      case 'TODO':
        return NoteCategory.todo;
      case 'SHOPPING':
        return NoteCategory.shopping;
      case 'EVENT':
        return NoteCategory.event;
      case 'SYSTEM':
        return NoteCategory.system;
      case 'CONTACT':
        return NoteCategory.contact;
      default:
        return NoteCategory.memo;
    }
  }
}

/// Action à effectuer sur la fiche
enum FicheAction {
  create, // Créer une nouvelle fiche
  append, // Ajouter à une fiche existante
}

/// Résultat de l'analyse IA
class AnalysisResult {
  /// Catégorie détectée
  final NoteCategory category;

  /// Résumé court (titre de la note/fiche)
  final String summary;

  /// Contenu nettoyé/corrigé
  final String content;

  /// Items extraits (pour les listes de tâches)
  final List<String> items;

  /// Date/heure extraite (pour les événements)
  final String? eventDateTime;

  /// Lieu de l'événement
  final String? eventLocation;

  /// Prénom du contact
  final String? contactFirstName;

  /// Nom de famille du contact
  final String? contactLastName;

  /// Téléphone du contact
  final String? contactPhone;

  /// Email du contact
  final String? contactEmail;

  /// Code immeuble/digicode du contact
  final String? contactBuildingCode;

  const AnalysisResult({
    required this.category,
    required this.summary,
    required this.content,
    this.items = const [],
    this.eventDateTime,
    this.eventLocation,
    this.contactFirstName,
    this.contactLastName,
    this.contactPhone,
    this.contactEmail,
    this.contactBuildingCode,
  });

  /// Nom complet du contact (prénom + nom)
  String? get contactFullName {
    if (contactFirstName == null && contactLastName == null) return null;
    return [contactFirstName, contactLastName]
        .where((s) => s != null && s.isNotEmpty)
        .join(' ');
  }

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    // Parser les items (peut être une liste ou une string séparée par des virgules)
    List<String> items = [];
    if (json['items'] != null) {
      if (json['items'] is List) {
        items = (json['items'] as List).map((e) => e.toString()).toList();
      } else if (json['items'] is String) {
        final itemsStr = json['items'] as String;
        if (itemsStr.isNotEmpty) {
          items = itemsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        }
      }
    }

    return AnalysisResult(
      category: NoteCategoryExtension.fromString(json['category'] as String? ?? 'MEMO'),
      summary: json['summary'] as String? ?? 'Note sans titre',
      content: json['content'] as String? ?? '',
      items: items,
      eventDateTime: json['event_datetime'] as String?,
      eventLocation: json['event_location'] as String?,
      contactFirstName: json['contact_first_name'] as String?,
      contactLastName: json['contact_last_name'] as String?,
      contactPhone: json['contact_phone'] as String?,
      contactEmail: json['contact_email'] as String?,
      contactBuildingCode: json['contact_building_code'] as String?,
    );
  }

  /// Crée un résultat par défaut (MEMO) en cas d'échec de l'analyse
  factory AnalysisResult.defaultMemo(String text) {
    // Générer un résumé basique (premiers mots)
    final words = text.split(' ');
    final summary = words.take(5).join(' ') + (words.length > 5 ? '...' : '');

    return AnalysisResult(
      category: NoteCategory.memo,
      summary: summary.isEmpty ? 'Note vocale' : summary,
      content: text,
    );
  }
}

/// Contexte d'une fiche existante pour l'IA
class FicheContext {
  final int id;
  final String title;
  final String category;

  const FicheContext({
    required this.id,
    required this.title,
    required this.category,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'category': category,
  };
}

/// Exception pour les erreurs d'analyse
class AnalysisException implements Exception {
  final String message;
  final int? statusCode;
  final String? details;

  const AnalysisException(this.message, {this.statusCode, this.details});

  @override
  String toString() => 'AnalysisException: $message';
}

/// Service d'analyse intelligente Groq Llama
class AiSorterService {
  /// Instance singleton
  static AiSorterService? _instance;

  /// URL de base de l'API Groq
  static const String _baseUrl = 'https://api.groq.com/openai/v1';

  /// Endpoint chat completions
  static const String _chatEndpoint = '/chat/completions';

  /// Modèle Llama à utiliser (llama-3.1-8b-instant remplace llama3-8b-8192 décommissionné)
  static const String _model = 'llama-3.1-8b-instant';

  /// Clé API Groq
  String? _apiKey;

  /// Client HTTP
  final http.Client _httpClient;

  /// System prompt pour l'analyse JSON - extraction uniquement
  /// La fusion (APPEND) est gérée côté application, pas par l'IA
  static const String _systemPrompt = '''JSON strict. UNIQUEMENT JSON valide, rien d'autre.

CATÉGORIES:
- TODO: tâches à faire (PAS courses/achats)
- SHOPPING: courses, achats, listes d'achat
- EVENT: rendez-vous avec date/heure
- SYSTEM: alarmes, rappels, timers, commandes système
- MEMO: idées, pensées, tout le reste

EXTRACTION STRICTE - JAMAIS de redondance:
- summary = titre action validée (ex: "Alarme réglée pour 07h00", "Courses à faire")
- content = VIDE "" (sauf info qui ne va nulle part)
- items = tableau pour TODO/SHOPPING: ["item1","item2"]
- event_datetime = QUAND (date/heure brute)
- event_location = OÙ (lieu/adresse)
- contact: first_name, last_name, phone, email, building_code (code immeuble/digicode)

FORMAT: {"category":"TODO|SHOPPING|EVENT|SYSTEM|MEMO","summary":"titre","content":"","items":[],"event_datetime":null,"event_location":null,"contact_first_name":null,"contact_last_name":null,"contact_phone":null,"contact_email":null,"contact_building_code":null}

EXEMPLES:
"réparer le vélo et appeler le plombier" → {"category":"TODO","summary":"Réparations à faire","items":["réparer le vélo","appeler le plombier"]}
"acheter pain lait et oeufs" → {"category":"SHOPPING","summary":"Courses à faire","items":["pain","lait","oeufs"]}
"dentiste mardi 14h Lyon" → {"category":"EVENT","summary":"Dentiste","event_datetime":"mardi 14h","event_location":"Lyon"}
"dîner avec Sophie samedi soir resto italien" → {"category":"EVENT","summary":"Dîner avec Sophie","event_datetime":"samedi soir","event_location":"resto italien"}
"réveille moi à 7h demain" → {"category":"SYSTEM","summary":"Alarme réglée pour 07h00"}
"rappelle moi de prendre mes médicaments à 20h" → {"category":"SYSTEM","summary":"Rappel médicaments 20h00"}
"Marie Dupont 0612345678 code A1234" → {"category":"MEMO","summary":"Contact Marie Dupont","content":"0612345678, code A1234","contact_first_name":"Marie","contact_last_name":"Dupont","contact_phone":"0612345678","contact_building_code":"A1234"}
"j'ai eu une super idée pour le projet" → {"category":"MEMO","summary":"Idée pour le projet"}''';

  /// Constructeur privé
  AiSorterService._internal() : _httpClient = http.Client();

  /// Factory Singleton
  factory AiSorterService() {
    _instance ??= AiSorterService._internal();
    return _instance!;
  }

  /// Initialise le service
  void initialize() {
    _apiKey = dotenv.env['GROQ_API_KEY'];
    // ignore: avoid_print
    print('AI_SORTER: Initialisation - Clé API présente: ${_apiKey != null && _apiKey!.isNotEmpty}');
    if (_apiKey == null || _apiKey!.isEmpty) {
      // ignore: avoid_print
      print('AI_SORTER: ATTENTION - Clé API Groq non trouvée dans .env!');
      // Ne pas throw pour éviter de bloquer le pipeline
    }
  }

  /// Vérifie si le service est initialisé
  bool get isInitialized => _apiKey != null && _apiKey!.isNotEmpty;

  /// Analyse un texte transcrit et retourne une catégorisation structurée
  ///
  /// [transcribedText] Le texte à analyser
  /// [existingFiches] Liste des fiches existantes pour le contexte (optionnel)
  ///
  /// En cas d'échec, retourne un AnalysisResult par défaut (MEMO)
  /// pour ne pas bloquer le flux de l'application.
  Future<AnalysisResult> analyzeText(
    String transcribedText, {
    List<FicheContext>? existingFiches,
  }) async {
    if (!isInitialized) {
      // ignore: avoid_print
      print('AI_SORTER: Service non initialisé, utilisation du fallback');
      return AnalysisResult.defaultMemo(transcribedText);
    }

    if (transcribedText.trim().isEmpty) {
      return AnalysisResult.defaultMemo(transcribedText);
    }

    try {
      // ignore: avoid_print
      print('AI_SORTER: Analyse du texte avec Llama 3...');

      // Construire le message utilisateur avec le contexte des fiches
      String userMessage = transcribedText;
      if (existingFiches != null && existingFiches.isNotEmpty) {
        final fichesJson = existingFiches.map((f) => f.toJson()).toList();
        userMessage = 'FICHES_EXISTANTES: ${jsonEncode(fichesJson)}\n\nTRANSCRIPTION: $transcribedText';
        // ignore: avoid_print
        print('AI_SORTER: ${existingFiches.length} fiches en contexte');
      }

      final uri = Uri.parse('$_baseUrl$_chatEndpoint');
      final response = await _httpClient.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': _model,
          'messages': [
            {'role': 'system', 'content': _systemPrompt},
            {'role': 'user', 'content': userMessage},
          ],
          'temperature': 0.1, // Très déterministe pour du JSON
          'max_tokens': 500,
        }),
      );

      // ignore: avoid_print
      print('AI_SORTER: Réponse API - Status: ${response.statusCode}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _parseResponse(response.body, transcribedText);
      } else {
        // ignore: avoid_print
        print('AI_SORTER: Erreur API ${response.statusCode}');
        print('AI_SORTER: Corps de la réponse: ${response.body}');
        return AnalysisResult.defaultMemo(transcribedText);
      }
    } on SocketException catch (e) {
      // ignore: avoid_print
      print('AI_SORTER: Erreur réseau: $e, utilisation du fallback');
      return AnalysisResult.defaultMemo(transcribedText);
    } catch (e) {
      // ignore: avoid_print
      print('AI_SORTER: Erreur inattendue: $e, utilisation du fallback');
      return AnalysisResult.defaultMemo(transcribedText);
    }
  }

  /// Parse la réponse de l'API et extrait le JSON
  AnalysisResult _parseResponse(String responseBody, String originalText) {
    try {
      final responseJson = jsonDecode(responseBody) as Map<String, dynamic>;
      final choices = responseJson['choices'] as List<dynamic>?;

      if (choices == null || choices.isEmpty) {
        // ignore: avoid_print
        print('AI_SORTER: Réponse API sans choices');
        return AnalysisResult.defaultMemo(originalText);
      }

      final message = choices[0]['message'] as Map<String, dynamic>?;
      final content = message?['content'] as String? ?? '';

      // ignore: avoid_print
      print('AI_SORTER: Contenu brut de Llama: $content');

      // Nettoyer le contenu des balises markdown potentielles
      String cleanContent = content.trim();

      // Supprimer les blocs de code markdown ```json ... ``` ou ``` ... ```
      final markdownMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(cleanContent);
      if (markdownMatch != null) {
        cleanContent = markdownMatch.group(1)!.trim();
        // ignore: avoid_print
        print('AI_SORTER: JSON extrait du markdown: $cleanContent');
      }

      // Essayer de parser directement si c'est du JSON pur
      if (cleanContent.startsWith('{')) {
        try {
          final analysisJson = jsonDecode(cleanContent) as Map<String, dynamic>;
          // ignore: avoid_print
          print('AI_SORTER: Analyse réussie - action: ${analysisJson['action']}, catégorie: ${analysisJson['category']}, target: ${analysisJson['target_id']}');
          return AnalysisResult.fromJson(analysisJson);
        } catch (_) {
          // Continuer avec le regex si le parsing direct échoue
        }
      }

      // Fallback: essayer d'extraire le premier objet JSON avec regex
      // Utiliser un regex plus permissif qui capture tout entre les accolades principales
      final jsonMatch = RegExp(r'\{.*"category"\s*:\s*"[^"]*".*\}', dotAll: true).firstMatch(cleanContent);
      if (jsonMatch == null) {
        // ignore: avoid_print
        print('AI_SORTER: Pas de JSON valide trouvé dans: $cleanContent');
        return AnalysisResult.defaultMemo(originalText);
      }

      final analysisJson = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;

      // ignore: avoid_print
      print('AI_SORTER: Analyse réussie (regex) - action: ${analysisJson['action']}, catégorie: ${analysisJson['category']}');

      return AnalysisResult.fromJson(analysisJson);
    } catch (e) {
      // ignore: avoid_print
      print('AI_SORTER: Erreur parsing JSON: $e');
      return AnalysisResult.defaultMemo(originalText);
    }
  }

  /// Libère les ressources
  void dispose() {
    _httpClient.close();
  }
}

/// Utilitaire pour parser et formater les dates relatives
class DateParser {
  static const List<String> _joursSemaine = [
    'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'
  ];

  static const List<String> _moisNoms = [
    'janv', 'fév', 'mars', 'avr', 'mai', 'juin',
    'juil', 'août', 'sept', 'oct', 'nov', 'déc'
  ];

  /// Convertit une date relative en date absolue formatée
  /// Ex: "lundi 12h00" → "13 janv 12h00"
  /// Ex: "demain 14h" → "14 janv 14h00"
  static String parseRelativeDate(String input) {
    final now = DateTime.now();
    final lowerInput = input.toLowerCase().trim();

    // Extraire l'heure si présente
    String? heureStr;
    final heureMatch = RegExp(r'(\d{1,2})[h:](\d{0,2})').firstMatch(lowerInput);
    if (heureMatch != null) {
      final heure = int.parse(heureMatch.group(1)!);
      final minutes = heureMatch.group(2)?.isNotEmpty == true
          ? int.parse(heureMatch.group(2)!)
          : 0;
      heureStr = '${heure.toString().padLeft(2, '0')}h${minutes.toString().padLeft(2, '0')}';
    } else if (lowerInput.contains('midi')) {
      heureStr = '12h00';
    } else if (lowerInput.contains('minuit')) {
      heureStr = '00h00';
    }

    // Trouver la date
    DateTime? targetDate;

    // Aujourd'hui
    if (lowerInput.contains("aujourd'hui") || lowerInput.contains('ce soir') || lowerInput.contains('ce matin')) {
      targetDate = now;
    }
    // Demain
    else if (lowerInput.contains('demain')) {
      targetDate = now.add(const Duration(days: 1));
    }
    // Après-demain
    else if (lowerInput.contains('après-demain') || lowerInput.contains('apres-demain')) {
      targetDate = now.add(const Duration(days: 2));
    }
    // Jour de la semaine
    else {
      for (int i = 0; i < _joursSemaine.length; i++) {
        if (lowerInput.contains(_joursSemaine[i])) {
          // Trouver le prochain jour correspondant
          final currentWeekday = now.weekday; // 1 = lundi, 7 = dimanche
          final targetWeekday = i + 1;
          var daysToAdd = targetWeekday - currentWeekday;
          if (daysToAdd <= 0) daysToAdd += 7; // Prochain occurrence
          targetDate = now.add(Duration(days: daysToAdd));
          break;
        }
      }
    }

    // Si une date a été trouvée, formater
    if (targetDate != null) {
      final jour = targetDate.day.toString().padLeft(2, '0');
      final mois = _moisNoms[targetDate.month - 1];
      if (heureStr != null) {
        return '$jour $mois $heureStr';
      } else {
        return '$jour $mois';
      }
    }

    // Si pas de date relative trouvée, retourner l'input formaté avec l'heure normalisée
    if (heureStr != null && !lowerInput.contains('h')) {
      return input.replaceFirst(RegExp(r'(\d{1,2})[h:](\d{0,2})'), heureStr);
    }

    return input;
  }
}

/// Utilitaire pour comparer et matcher les titres de fiches
/// Permet la fusion automatique des fiches similaires côté application
class TitleMatcher {
  /// Normalise un titre pour la comparaison
  /// - Minuscules
  /// - Sans accents
  /// - Sans caractères spéciaux
  static String normalize(String title) {
    return _removeAccents(title.toLowerCase().trim())
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Supprime les accents d'une chaîne
  static String _removeAccents(String input) {
    const accents = 'àâäáãåçèéêëìíîïñòóôöõùúûüýÿ';
    const noAccents = 'aaaaaaceeeeiiiinooooouuuuyy';

    String result = input;
    for (int i = 0; i < accents.length; i++) {
      result = result.replaceAll(accents[i], noAccents[i]);
    }
    return result;
  }

  /// Vérifie si deux titres sont similaires
  /// Retourne true si:
  /// - Identiques après normalisation
  /// - L'un contient l'autre (pour "Courses" et "Liste de courses")
  /// - Mots clés communs significatifs
  static bool areSimilar(String title1, String title2) {
    final norm1 = normalize(title1);
    final norm2 = normalize(title2);

    // Identiques
    if (norm1 == norm2) return true;

    // Vides
    if (norm1.isEmpty || norm2.isEmpty) return false;

    // L'un contient l'autre
    if (norm1.contains(norm2) || norm2.contains(norm1)) return true;

    // Mots en commun (au moins un mot significatif de 4+ lettres)
    final words1 = norm1.split(' ').where((w) => w.length >= 4).toSet();
    final words2 = norm2.split(' ').where((w) => w.length >= 4).toSet();
    final commonWords = words1.intersection(words2);

    return commonWords.isNotEmpty;
  }

  /// Trouve une fiche existante qui correspond au titre et à la catégorie
  /// Retourne l'ID de la fiche si trouvée, null sinon
  static int? findMatchingFiche(
    String newTitle,
    NoteCategory category,
    List<FicheContext> existingFiches,
  ) {
    for (final fiche in existingFiches) {
      // Même catégorie obligatoire
      if (fiche.category.toUpperCase() != category.name.toUpperCase()) continue;

      // Titre similaire
      if (areSimilar(newTitle, fiche.title)) {
        return fiche.id;
      }
    }
    return null;
  }
}
