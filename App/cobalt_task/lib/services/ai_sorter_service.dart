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
  todo,     // Tâches, choses à faire
  shopping, // Listes de courses, achats
  event,    // Rendez-vous, événements avec notion de temps
  contact,  // Informations sur une personne
  memo,     // Idées générales, pensées (fourre-tout)
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
        return 'event';
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

  /// Date d'échéance pour les TODO (rappels)
  final String? todoDue;

  /// Sentiment détecté pour les MEMO (idea, frustration, memory, question, neutral)
  final String? sentiment;

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
    this.todoDue,
    this.sentiment,
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
      todoDue: json['todo_due'] as String?,
      sentiment: json['sentiment'] as String?,
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

  /// System prompt pour l'analyse JSON - extraction pour Google Services
  /// TODO → Google Tasks, EVENT → Calendar, CONTACT → People, MEMO → Docs
  static const String _systemPrompt = '''RÉPONDS UNIQUEMENT EN JSON. Aucun texte, aucune explication.

CATÉGORIES:
- TODO = tâches, actions à faire, rappels. Reformule de manière CONCISE (verbe + objet).
- SHOPPING = achats, courses. EXTRAIS UNIQUEMENT les articles/produits. Supprime tous les verbes d'action et phrases d'introduction.
- EVENT = rendez-vous AVEC quelqu'un OU dans un lieu précis, à une date/heure précise. Un EVENT implique une PRÉSENCE PHYSIQUE quelque part.
- CONTACT = informations sur une personne (nom, téléphone, email, digicode)
- MEMO = idées, pensées, réflexions, mémos. Garde le contenu essentiel de manière structurée.

RÈGLE CRITIQUE - TÂCHE vs ÉVÉNEMENT:
Une action à faire AVEC une échéance = TODO (avec todo_due). PAS un EVENT.
Un EVENT = un rendez-vous où tu dois ÊTRE PRÉSENT quelque part avec quelqu'un.
- "rappelle-moi d'appeler le médecin lundi" = TODO (c'est une action à faire, pas un rdv)
- "chercher les enfants à 17h" = TODO (action à faire avec échéance)
- "rdv chez le médecin vendredi 14h" = EVENT (présence physique requise)
- "réunion avec l'équipe mardi 10h" = EVENT (présence requise)
- "payer le loyer avant le 5" = TODO (action, pas de présence)

RÈGLES DE NETTOYAGE:
- TODO: summary = verbe à l'infinitif + objet concis. Supprimer "rappelle-moi de", "il faut", "je dois", "penser à", "n'oublie pas de". todo_due = temporalité si détectée.
- SHOPPING: summary = "Courses". items = UNIQUEMENT les produits/articles, sans verbes ni phrases. "Ajoute du lait et des œufs" → items: ["lait", "œufs"].
- MEMO: content = contenu essentiel structuré. sentiment = "idea"|"frustration"|"memory"|"question"|"neutral".
- "rappelle-moi de...", "il faut...", "je dois...", "penser à..." = TOUJOURS TODO, SAUF si suivi de "acheter" → alors SHOPPING
- "acheter...", "je dois acheter...", "il faut acheter...", "courses...", "il me faut...", "j'ai besoin de...", "liste de courses" = TOUJOURS SHOPPING

FORMAT:
{"category":"TODO|SHOPPING|EVENT|CONTACT|MEMO","summary":"titre concis","content":"","items":[],"todo_due":null,"sentiment":null,"event_datetime":null,"event_location":null,"contact_first_name":null,"contact_last_name":null,"contact_phone":null,"contact_email":null,"contact_building_code":null}

EXEMPLES:
"n'oublie pas de rappeler le banquier" → {"category":"TODO","summary":"Rappeler le banquier","items":["rappeler le banquier"],"todo_due":null}
"rappelle-moi de faire des pompes demain matin" → {"category":"TODO","summary":"Faire des pompes","items":["faire des pompes"],"todo_due":"demain matin"}
"il faut appeler le plombier lundi" → {"category":"TODO","summary":"Appeler le plombier","items":["appeler le plombier"],"todo_due":"lundi"}
"payer le loyer avant vendredi" → {"category":"TODO","summary":"Payer le loyer","items":["payer le loyer"],"todo_due":"vendredi"}
"chercher les enfants à 17h" → {"category":"TODO","summary":"Chercher les enfants","items":["chercher les enfants"],"todo_due":"17h"}
"envoyer le dossier à Marc avant mardi" → {"category":"TODO","summary":"Envoyer le dossier à Marc","items":["envoyer le dossier à Marc"],"todo_due":"mardi"}
"ajoute du lait et des œufs à la liste de courses" → {"category":"SHOPPING","summary":"Courses","items":["lait","œufs"]}
"acheter pain lait fromage" → {"category":"SHOPPING","summary":"Courses","items":["pain","lait","fromage"]}
"il me faut des piles et du scotch" → {"category":"SHOPPING","summary":"Courses","items":["piles","scotch"]}
"je dois acheter des cotons-tiges" → {"category":"SHOPPING","summary":"Courses","items":["cotons-tiges"]}
"je dois acheter du poivre et du sel" → {"category":"SHOPPING","summary":"Courses","items":["poivre","sel"]}
"j'ai besoin de farine et de beurre" → {"category":"SHOPPING","summary":"Courses","items":["farine","beurre"]}
"faut que j'achète des pâtes et du riz" → {"category":"SHOPPING","summary":"Courses","items":["pâtes","riz"]}
"rdv médecin vendredi 14h" → {"category":"EVENT","summary":"Médecin","event_datetime":"vendredi 14h"}
"réunion avec l'équipe mardi 10h en salle B" → {"category":"EVENT","summary":"Réunion équipe","event_datetime":"mardi 10h","event_location":"salle B"}
"Marie 0612345678" → {"category":"CONTACT","summary":"Marie","contact_first_name":"Marie","contact_phone":"0612345678"}
"idée: utiliser du machine learning pour le tri" → {"category":"MEMO","summary":"Idée ML pour le tri","content":"utiliser du machine learning pour le tri","sentiment":"idea"}
"j'en ai marre de ce projet" → {"category":"MEMO","summary":"Ras-le-bol projet","content":"j'en ai marre de ce projet","sentiment":"frustration"}''';

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

  /// Analyse un texte transcrit et retourne une catégorisation structurée.
  ///
  /// La déduplication des fiches (append vs create) est gérée localement
  /// par [TitleMatcher] dans audio_service — les fiches existantes ne sont
  /// PAS envoyées à l'API pour éviter de consommer inutilement le quota TPM.
  ///
  /// En cas d'échec, retourne un AnalysisResult par défaut (MEMO)
  /// pour ne pas bloquer le flux de l'application.
  Future<AnalysisResult> analyzeText(String transcribedText) async {
    if (!isInitialized) {
      // ignore: avoid_print
      print('AI_SORTER: Service non initialisé, utilisation du fallback');
      return _postProcessResult(AnalysisResult.defaultMemo(transcribedText));
    }

    if (transcribedText.trim().isEmpty) {
      return _postProcessResult(AnalysisResult.defaultMemo(transcribedText));
    }

    try {
      // ignore: avoid_print
      print('AI_SORTER: Analyse du texte avec Llama 3...');

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
            {'role': 'user', 'content': transcribedText},
          ],
          'temperature': 0.1, // Très déterministe pour du JSON
          'max_tokens': 500,
        }),
      );

      // ignore: avoid_print
      print('AI_SORTER: Réponse API - Status: ${response.statusCode}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _parseResponse(response.body, transcribedText);
      } else if (response.statusCode == 429) {
        _logRateLimit(response.body);
        return _postProcessResult(AnalysisResult.defaultMemo(transcribedText));
      } else {
        // ignore: avoid_print
        print('AI_SORTER: ⚠ Erreur API ${response.statusCode}: ${response.body}');
        return _postProcessResult(AnalysisResult.defaultMemo(transcribedText));
      }
    } on SocketException catch (e) {
      // ignore: avoid_print
      print('AI_SORTER: Erreur réseau: $e, utilisation du fallback');
      return _postProcessResult(AnalysisResult.defaultMemo(transcribedText));
    } catch (e) {
      // ignore: avoid_print
      print('AI_SORTER: Erreur inattendue: $e, utilisation du fallback');
      return _postProcessResult(AnalysisResult.defaultMemo(transcribedText));
    }
  }

  /// Logue clairement un rate limit 429 avec les chiffres extraits du corps
  void _logRateLimit(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final msg = (json['error'] as Map<String, dynamic>?)?['message'] as String? ?? body;
      // Extraire "Limit X, Used Y, Requested Z" si présent
      final limitMatch = RegExp(r'Limit (\d+), Used (\d+), Requested (\d+)').firstMatch(msg);
      final retryMatch = RegExp(r'try again in ([\d.]+s)').firstMatch(msg);
      if (limitMatch != null) {
        final limit = limitMatch.group(1);
        final used = limitMatch.group(2);
        final requested = limitMatch.group(3);
        final retry = retryMatch?.group(1) ?? '?';
        // ignore: avoid_print
        print('AI_SORTER: 🚨 RATE LIMIT 429 — TPM: $used/$limit utilisés, requis: $requested. Retry dans $retry');
      } else {
        // ignore: avoid_print
        print('AI_SORTER: 🚨 RATE LIMIT 429 — $msg');
      }
    } catch (_) {
      // ignore: avoid_print
      print('AI_SORTER: 🚨 RATE LIMIT 429 — $body');
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
        return _postProcessResult(AnalysisResult.defaultMemo(originalText));
      }

      // Logue l'usage de tokens à chaque requête réussie
      final usage = responseJson['usage'] as Map<String, dynamic>?;
      if (usage != null) {
        final prompt = usage['prompt_tokens'] ?? '?';
        final completion = usage['completion_tokens'] ?? '?';
        final total = usage['total_tokens'] ?? '?';
        // ignore: avoid_print
        print('AI_SORTER: 📊 Tokens — prompt: $prompt | completion: $completion | total: $total / 6000 TPM');
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
          print('AI_SORTER: Analyse réussie - catégorie: ${analysisJson['category']}');
          return _postProcessResult(AnalysisResult.fromJson(analysisJson));
        } catch (_) {
          // Continuer avec l'extraction si le parsing direct échoue
        }
      }

      // Fallback: extraire le premier objet JSON valide avec accolades équilibrées
      final extractedJson = _extractFirstJson(cleanContent);
      if (extractedJson != null) {
        try {
          final analysisJson = jsonDecode(extractedJson) as Map<String, dynamic>;
          // ignore: avoid_print
          print('AI_SORTER: Analyse réussie (extraction) - catégorie: ${analysisJson['category']}');
          return _postProcessResult(AnalysisResult.fromJson(analysisJson));
        } catch (e) {
          // ignore: avoid_print
          print('AI_SORTER: JSON extrait mais parsing échoué: $e');
        }
      }

      // ignore: avoid_print
      print('AI_SORTER: Pas de JSON valide trouvé');
      return _postProcessResult(AnalysisResult.defaultMemo(originalText));
    } catch (e) {
      // ignore: avoid_print
      print('AI_SORTER: Erreur parsing JSON: $e');
      return _postProcessResult(AnalysisResult.defaultMemo(originalText));
    }
  }

  /// Mots-clés qui forcent la catégorie SHOPPING (l'IA n'est pas fiable)
  static const List<String> _shoppingKeywords = [
    'acheter', 'achat', 'achats', 'à acheter',
    'je dois acheter', 'il faut acheter', 'faut acheter',
    'j\'ai besoin de', 'j\'ai besoin d\'',
    'liste de courses', 'liste courses',
    'il me faut', 'il nous faut',
    'courses',
  ];

  /// Post-traitement : corrige la catégorie si l'IA s'est trompée
  /// Ex: "Acheter du poivre et du sel" classé TODO → forcé en SHOPPING
  /// Vérifie à la fois le summary ET le content (utile pour les fallbacks defaultMemo
  /// où le summary est tronqué aux 5 premiers mots)
  ///
  /// Quand SHOPPING est forcé, extrait les produits par liste blanche
  /// et formate le summary avec "+" pour l'affichage dans la fiche locale.
  AnalysisResult _postProcessResult(AnalysisResult result) {
    if (result.category == NoteCategory.todo ||
        result.category == NoteCategory.memo) {
      final lowerSummary = result.summary.toLowerCase();
      final lowerContent = result.content.toLowerCase();
      for (final keyword in _shoppingKeywords) {
        if (lowerSummary.contains(keyword) || lowerContent.contains(keyword)) {
          // ignore: avoid_print
          print('AI_SORTER: [POST] Override ${result.category.name} → SHOPPING (mot-clé: "$keyword")');

          // Extraire les produits par liste blanche
          final products = ShoppingExtractor.extractProducts(result.content);
          final finalItems = products.isNotEmpty ? products : result.items;
          final finalSummary = finalItems.isNotEmpty
              ? finalItems.map((p) => '+ $p').join(', ')
              : 'Courses';

          // ignore: avoid_print
          print('AI_SORTER: [POST] Produits extraits: $finalItems');

          return AnalysisResult(
            category: NoteCategory.shopping,
            summary: finalSummary,
            content: result.content,
            items: finalItems,
          );
        }
      }
    }
    return result;
  }

  /// Extrait le premier objet JSON valide d'une chaîne en comptant les accolades
  String? _extractFirstJson(String content) {
    final startIndex = content.indexOf('{');
    if (startIndex == -1) return null;

    int braceCount = 0;
    int? endIndex;

    for (int i = startIndex; i < content.length; i++) {
      final char = content[i];
      if (char == '{') {
        braceCount++;
      } else if (char == '}') {
        braceCount--;
        if (braceCount == 0) {
          endIndex = i;
          break;
        }
      }
    }

    if (endIndex != null) {
      return content.substring(startIndex, endIndex + 1);
    }
    return null;
  }

  /// Libère les ressources
  void dispose() {
    _httpClient.close();
  }
}

/// Utilitaire d'extraction de produits/articles par liste blanche
///
/// Stratégie additive : scanne la phrase et ne garde que les mots
/// qui correspondent à un produit connu de magasin.
/// Utilisé par _postProcessResult (fiche locale) et google_tasks_service (Google Tasks).
class ShoppingExtractor {
  ShoppingExtractor._();

  /// Produits multi-mots (testés en premier, les plus longs d'abord)
  static const List<String> _multiWordProducts = [
    'pommes de terre', 'pomme de terre',
    'petits pois', 'haricots verts', 'haricot vert',
    'pain de mie', "huile d'olive", 'crème fraîche',
    'gel douche', 'papier toilette', 'papier aluminium',
    'film alimentaire', 'liquide vaisselle',
    'sacs poubelle', 'sac poubelle',
    'essuie-tout', 'cotons-tiges', 'coton-tige',
    'crème solaire', 'sauce tomate', 'sauce soja',
    'eau de javel', 'pâte à tartiner',
    'fruits de mer', 'pain complet',
  ];

  /// Produits mono-mot (forme d'affichage avec accents corrects)
  static const List<String> _singleWordProducts = [
    // Fruits
    'pomme', 'pommes', 'banane', 'bananes', 'orange', 'oranges',
    'citron', 'citrons', 'fraise', 'fraises', 'raisin', 'raisins',
    'poire', 'poires', 'pêche', 'pêches', 'cerise', 'cerises',
    'mangue', 'mangues', 'ananas', 'kiwi', 'kiwis',
    'melon', 'melons', 'pastèque', 'pastèques',
    'abricot', 'abricots', 'prune', 'prunes',
    'framboise', 'framboises', 'myrtille', 'myrtilles',
    'clémentine', 'clémentines', 'mandarine', 'mandarines',
    'avocat', 'avocats', 'figue', 'figues', 'noix', 'noisette',
    // Légumes
    'tomate', 'tomates', 'carotte', 'carottes',
    'oignon', 'oignons', 'ail', 'échalote', 'échalotes',
    'poivron', 'poivrons', 'courgette', 'courgettes',
    'aubergine', 'aubergines', 'brocoli', 'brocolis',
    'chou', 'choux', 'épinard', 'épinards',
    'salade', 'salades', 'laitue',
    'concombre', 'concombres', 'radis',
    'navet', 'navets', 'poireau', 'poireaux',
    'maïs', 'champignon', 'champignons',
    'asperge', 'asperges', 'artichaut', 'artichauts',
    'betterave', 'betteraves', 'céleri',
    'fenouil', 'persil', 'coriandre', 'basilic', 'menthe',
    // Viandes
    'poulet', 'bœuf', 'boeuf', 'porc', 'agneau', 'veau',
    'dinde', 'canard', 'lapin',
    'saucisse', 'saucisses', 'saucisson',
    'jambon', 'lardon', 'lardons',
    'steak', 'steaks', 'escalope', 'escalopes',
    'merguez', 'chorizo',
    // Poissons
    'poisson', 'saumon', 'thon', 'cabillaud',
    'crevette', 'crevettes', 'moule', 'moules',
    'sardine', 'sardines', 'truite',
    // Produits laitiers
    'lait', 'fromage', 'beurre', 'crème',
    'yaourt', 'yaourts',
    'œuf', 'œufs', 'oeuf', 'oeufs',
    'mozzarella', 'parmesan', 'gruyère', 'emmental',
    'camembert', 'roquefort', 'chèvre', 'comté',
    // Boulangerie
    'pain', 'baguette', 'baguettes',
    'croissant', 'croissants', 'brioche', 'brioches',
    // Épicerie
    'riz', 'pâtes', 'pâte', 'nouilles',
    'farine', 'sucre', 'sel', 'poivre',
    'huile', 'vinaigre',
    'moutarde', 'ketchup', 'mayonnaise',
    'confiture', 'miel', 'nutella',
    'céréales', 'café', 'thé', 'chocolat', 'cacao',
    'levure', 'maïzena',
    'chips', 'biscuit', 'biscuits',
    'bonbon', 'bonbons', 'gâteau', 'gâteaux',
    // Boissons
    'eau', 'jus', 'soda', 'coca',
    'bière', 'bières', 'vin', 'vins',
    'limonade', 'sirop', 'compote',
    // Hygiène
    'savon', 'shampoing', 'shampooing',
    'dentifrice', 'déodorant',
    'mouchoir', 'mouchoirs',
    'rasoir', 'rasoirs',
    'serviette', 'serviettes',
    // Ménage
    'éponge', 'éponges', 'lessive',
    'javel', 'sopalin',
    // Divers
    'pile', 'piles', 'ampoule', 'ampoules',
    'bougie', 'bougies',
    'scotch',
  ];

  /// Lookup map: forme normalisée → forme d'affichage
  static Map<String, String>? _singleLookup;
  static List<(String, String)>? _multiLookup;

  static Map<String, String> get _singleProductLookup {
    _singleLookup ??= {
      for (final p in _singleWordProducts)
        _normalize(p): p,
    };
    return _singleLookup!;
  }

  static List<(String, String)> get _multiProductLookup {
    _multiLookup ??= _multiWordProducts
        .map((p) => (_normalize(p), p))
        .toList()
      ..sort((a, b) => b.$1.length.compareTo(a.$1.length));
    return _multiLookup!;
  }

  /// Normalise un texte : minuscules, sans accents, apostrophes/tirets → espaces
  static String _normalize(String input) {
    var result = input.toLowerCase();
    result = result.replaceAll('œ', 'oe').replaceAll('æ', 'ae');
    result = _removeAccents(result);
    result = result.replaceAll(RegExp(r"[''`\-]"), ' ');
    result = result.replaceAll(RegExp(r'\s+'), ' ');
    return result.trim();
  }

  static String _removeAccents(String input) {
    const accents = 'àâäáãåçèéêëìíîïñòóôöõùúûüýÿ';
    const noAccents = 'aaaaaaceeeeiiiinooooouuuuyy';
    String result = input;
    for (int i = 0; i < accents.length; i++) {
      result = result.replaceAll(accents[i], noAccents[i]);
    }
    return result;
  }

  /// Capitalise la première lettre
  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Extrait les produits d'une phrase par liste blanche
  ///
  /// "Rappelle-moi d'acheter des oeufs et du lait" → ["Œufs", "Lait"]
  /// "je dois acheter du poivre et du sel" → ["Poivre", "Sel"]
  ///
  /// Retourne une liste vide si aucun produit connu n'est trouvé.
  static List<String> extractProducts(String text) {
    if (text.trim().isEmpty) return [];

    var searchText = _normalize(text);
    final found = <String>[];

    // 1. Multi-word products (longest first)
    for (final (normalized, display) in _multiProductLookup) {
      if (searchText.contains(normalized)) {
        found.add(_capitalize(display));
        searchText = searchText.replaceFirst(normalized, ' ');
      }
    }

    // 2. Single-word products (whole word match)
    final words = searchText.split(RegExp(r'[^a-z]+'));
    for (final word in words) {
      if (word.isEmpty || word.length < 2) continue;

      final display = _singleProductLookup[word];
      if (display != null) {
        // Vérifier pas déjà trouvé dans un produit multi-mots
        final alreadyCovered = found.any(
          (f) => _normalize(f).contains(word),
        );
        if (!alreadyCovered) {
          found.add(_capitalize(display));
        }
      }
    }

    return found;
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

  /// Mots courants à ignorer pour la comparaison (stop words français)
  static const _stopWords = {
    'pour', 'dans', 'avec', 'sans', 'plus', 'moins', 'avant', 'apres',
    'cette', 'tout', 'tous', 'toute', 'etre', 'avoir', 'faire', 'dire',
    'comme', 'mais', 'donc', 'aussi', 'bien', 'encore', 'tres', 'trop',
    'quand', 'chez', 'entre', 'sous', 'vers',
  };

  /// Vérifie si deux titres sont similaires
  /// Retourne true si:
  /// - Identiques après normalisation
  /// - L'un contient l'autre (pour "Courses" et "Liste de courses")
  /// - Au moins 2 mots significatifs en commun (pas des stop words)
  static bool areSimilar(String title1, String title2) {
    final norm1 = normalize(title1);
    final norm2 = normalize(title2);

    // Identiques
    if (norm1 == norm2) return true;

    // Vides
    if (norm1.isEmpty || norm2.isEmpty) return false;

    // L'un contient l'autre (mais pas si le contenu est trop court)
    if (norm1.length >= 5 && norm2.length >= 5) {
      if (norm1.contains(norm2) || norm2.contains(norm1)) return true;
    }

    // Mots significatifs en commun (5+ lettres, pas des stop words)
    final words1 = norm1.split(' ')
        .where((w) => w.length >= 5 && !_stopWords.contains(w))
        .toSet();
    final words2 = norm2.split(' ')
        .where((w) => w.length >= 5 && !_stopWords.contains(w))
        .toSet();
    final commonWords = words1.intersection(words2);

    // Exiger au moins 2 mots significatifs en commun
    // OU 1 mot si les deux titres sont courts (<=3 mots significatifs)
    if (commonWords.length >= 2) return true;
    if (commonWords.length == 1 && words1.length <= 2 && words2.length <= 2) {
      return true;
    }

    return false;
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
