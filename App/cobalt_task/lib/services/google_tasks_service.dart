import 'package:googleapis/tasks/v1.dart' as tasks;
import 'ai_sorter_service.dart' show ShoppingExtractor;
import 'google_auth_service.dart';

/// =============================================================================
/// google_tasks_service.dart
/// =============================================================================
/// Service Google Tasks pour Cobalt Task.
///
/// Synchronise les fiches TODO vers Google Tasks:
/// - Tâches normales → "My Tasks" (liste par défaut)
/// - Achats/Courses → Liste "Courses"
/// =============================================================================

class GoogleTasksService {
  /// Instance singleton
  static GoogleTasksService? _instance;

  /// Service d'authentification
  final GoogleAuthService _authService;

  /// API Tasks
  tasks.TasksApi? _tasksApi;

  /// ID de la liste par défaut "My Tasks"
  final String _defaultListId = '@default';

  /// ID de la liste "Courses" pour les achats
  String? _coursesListId;

  /// ID de la liste "Mémos" pour les idées/pensées
  String? _memosListId;

  /// Nom de la liste Courses
  static const String _coursesListName = 'Courses';

  /// Nom de la liste Mémos
  static const String _memosListName = 'Mémos';

  /// Mots-clés pour détecter les listes de courses (ACHATS uniquement)
  /// Note: "courses" seul est ambigu (faire les courses vs aller chercher)
  /// On privilégie les expressions complètes
  static const List<String> _shoppingKeywords = [
    'liste de courses',  // Priorité haute - généré par l'IA pour les achats
    'liste courses',
    'acheter', 'achat', 'achats', 'à acheter',
    'shopping', 'supermarché', 'magasin', 'épicerie',
    'provisions', 'commissions',
  ];

  /// Verbes d'action à supprimer au début des phrases de courses
  static const List<String> _shoppingVerbs = [
    'acheter', 'achète', 'achetez', 'achete',
    'ajouter', 'ajoute', 'ajoutez',
    'prendre', 'prends', 'prenez',
    'ramener', 'ramène', 'ramenez',
    'rapporter', 'rapporte', 'rapportez',
    'chercher', 'cherche', 'cherchez',
    'il me faut', 'il nous faut', 'il faut',
    'on a besoin de', "j'ai besoin de",
    'penser à prendre', 'pense à prendre',
    'ajoute à la liste',
    'mets sur la liste',
    'noter', 'note',
  ];

  /// Déterminants français à supprimer devant les articles
  static const List<String> _determinants = [
    "de l'", "de la", "du ", "des ", "d'",
    "le ", "la ", "les ", "l'",
    "un ", "une ",
    "quelques ", "plusieurs ",
  ];

  /// Constructeur privé
  GoogleTasksService._internal(this._authService);

  /// Factory Singleton
  factory GoogleTasksService(GoogleAuthService authService) {
    _instance ??= GoogleTasksService._internal(authService);
    return _instance!;
  }

  /// Initialise l'API Tasks
  Future<bool> initialize() async {
    if (!_authService.isSignedIn || _authService.authClient == null) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Non authentifié');
      return false;
    }

    try {
      _tasksApi = tasks.TasksApi(_authService.authClient!);
      await _ensureCoursesTaskList();
      await _ensureMemosTaskList();
      // ignore: avoid_print
      print('GOOGLE_TASKS: Initialisé - Default: $_defaultListId, Courses: $_coursesListId, Mémos: $_memosListId');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur initialisation - $e');
      return false;
    }
  }

  /// Crée ou récupère la liste "Courses"
  Future<void> _ensureCoursesTaskList() async {
    if (_tasksApi == null) return;

    try {
      // Chercher la liste existante
      final taskLists = await _tasksApi!.tasklists.list();
      for (final list in taskLists.items ?? []) {
        if (list.title == _coursesListName) {
          _coursesListId = list.id;
          // ignore: avoid_print
          print('GOOGLE_TASKS: Liste "$_coursesListName" trouvée');
          return;
        }
      }

      // Créer la liste si elle n'existe pas
      final newList = tasks.TaskList(title: _coursesListName);
      final created = await _tasksApi!.tasklists.insert(newList);
      _coursesListId = created.id;
      // ignore: avoid_print
      print('GOOGLE_TASKS: Liste "$_coursesListName" créée');
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur création liste Courses - $e');
    }
  }

  /// Crée ou récupère la liste "Mémos"
  Future<void> _ensureMemosTaskList() async {
    if (_tasksApi == null) return;

    try {
      final taskLists = await _tasksApi!.tasklists.list();
      for (final list in taskLists.items ?? []) {
        if (list.title == _memosListName) {
          _memosListId = list.id;
          // ignore: avoid_print
          print('GOOGLE_TASKS: Liste "$_memosListName" trouvée');
          return;
        }
      }

      final newList = tasks.TaskList(title: _memosListName);
      final created = await _tasksApi!.tasklists.insert(newList);
      _memosListId = created.id;
      // ignore: avoid_print
      print('GOOGLE_TASKS: Liste "$_memosListName" créée');
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur création liste Mémos - $e');
    }
  }

  /// ID de la liste Mémos (exposé pour le bridge)
  String? get memosListId => _memosListId;

  /// Ajoute un mémo/idée dans la liste "Mémos" de Google Tasks
  Future<String?> addMemo({
    required String title,
    String? content,
    String? sentiment,
  }) async {
    if (_tasksApi == null) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Service non initialisé');
      return null;
    }

    final listId = _memosListId ?? _defaultListId;

    try {
      // Construire les notes avec le sentiment si présent
      String? notes = content;
      if (sentiment != null && sentiment.isNotEmpty) {
        notes = '[$sentiment] ${content ?? ''}';
      }

      final task = tasks.Task(
        title: title,
        notes: notes,
      );

      final created = await _tasksApi!.tasks.insert(task, listId);
      // ignore: avoid_print
      print('GOOGLE_TASKS: Mémo "$title" créé (${created.id}) dans liste Mémos');
      return created.id;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur ajout mémo - $e');
      return null;
    }
  }

  // ===========================================================================
  // POST-TRAITEMENT SHOPPING
  // ===========================================================================

  /// Nettoie et restructure les données SHOPPING
  /// Force le titre à "Courses" et extrait les articles proprement
  ({String title, List<String> items}) _cleanShoppingData(
    String title,
    List<String> items,
  ) {
    // ignore: avoid_print
    print('GOOGLE_TASKS: [CLEAN] Entrée - title: "$title", items: $items');

    List<String> cleanedItems = [];

    // 1) Si l'IA a retourné des items, les nettoyer
    if (items.isNotEmpty) {
      for (final item in items) {
        final cleaned = _cleanSingleItem(item);
        if (cleaned.isNotEmpty) {
          cleanedItems.add(cleaned);
        }
      }
    }

    // 2) Si pas d'items OU items identiques au titre → extraire depuis le titre
    if (cleanedItems.isEmpty ||
        (cleanedItems.length == 1 && _normalizeTitle(cleanedItems[0]) == _normalizeTitle(title))) {
      final extracted = _extractItemsFromPhrase(title);
      if (extracted.isNotEmpty) {
        cleanedItems = extracted;
      }
    }

    // 3) Dédupliquer les items (insensible à la casse)
    final seen = <String>{};
    cleanedItems = cleanedItems.where((item) {
      final key = item.toLowerCase().trim();
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();

    // ignore: avoid_print
    print('GOOGLE_TASKS: [CLEAN] Sortie - title: "Courses", items: $cleanedItems');

    return (title: 'Courses', items: cleanedItems);
  }

  /// Extrait les articles/produits d'une phrase de courses
  /// "Acheter des aubergines et des petits pois" → ["Aubergines", "Petits pois"]
  /// "Du lait, des œufs et du pain" → ["Lait", "Œufs", "Pain"]
  ///
  /// Stratégie 1: Liste blanche (ShoppingExtractor) — fiable, couvre ~150 produits
  /// Stratégie 2: Fallback soustraction (verbes + déterminants) — couvre le reste
  List<String> _extractItemsFromPhrase(String phrase) {
    var text = phrase.trim();
    if (text.isEmpty) return [];

    // Stratégie 1: Extraction par liste blanche de produits connus
    final whitelistProducts = ShoppingExtractor.extractProducts(text);
    if (whitelistProducts.isNotEmpty) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: [EXTRACT] Liste blanche: $whitelistProducts');
      return whitelistProducts;
    }

    // Stratégie 2: Fallback — soustraction verbes/déterminants
    // ignore: avoid_print
    print('GOOGLE_TASKS: [EXTRACT] Fallback soustraction pour "$text"');

    // Supprimer les verbes d'action au début
    final lowerText = text.toLowerCase();
    for (final verb in _shoppingVerbs) {
      if (lowerText.startsWith(verb)) {
        text = text.substring(verb.length).trim();
        break;
      }
    }

    // Supprimer "à la liste de courses", "à la liste", etc. à la fin
    text = text.replaceAll(RegExp(r'\s*à la liste( de courses)?$', caseSensitive: false), '');

    // Séparer par "et" et ","
    final parts = text
        .split(RegExp(r'\s*[,]\s*|\s+et\s+', caseSensitive: false))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    // Nettoyer chaque partie (supprimer déterminants)
    final items = <String>[];
    for (final part in parts) {
      final cleaned = _cleanSingleItem(part);
      if (cleaned.isNotEmpty && cleaned.length >= 2) {
        items.add(cleaned);
      }
    }

    return items;
  }

  /// Nettoie un seul item : supprime les déterminants et capitalise
  /// "des petits pois" → "Petits pois"
  /// "du lait" → "Lait"
  /// "de l'huile d'olive" → "Huile d'olive"
  String _cleanSingleItem(String item) {
    var cleaned = item.trim();
    if (cleaned.isEmpty) return '';

    // Supprimer les déterminants au début (peut nécessiter plusieurs passes)
    bool changed = true;
    while (changed) {
      changed = false;
      final lower = cleaned.toLowerCase();
      for (final det in _determinants) {
        if (lower.startsWith(det)) {
          cleaned = cleaned.substring(det.length).trim();
          changed = true;
          break;
        }
      }
    }

    // Supprimer aussi les verbes d'action résiduels
    final lowerCleaned = cleaned.toLowerCase();
    for (final verb in _shoppingVerbs) {
      if (lowerCleaned.startsWith(verb)) {
        cleaned = cleaned.substring(verb.length).trim();
        break;
      }
    }

    // Re-supprimer les déterminants (après suppression du verbe)
    changed = true;
    while (changed) {
      changed = false;
      final lower = cleaned.toLowerCase();
      for (final det in _determinants) {
        if (lower.startsWith(det)) {
          cleaned = cleaned.substring(det.length).trim();
          changed = true;
          break;
        }
      }
    }

    if (cleaned.isEmpty) return '';

    // Capitaliser la première lettre
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  // ===========================================================================
  // AJOUT SHOPPING (articles directement dans la liste Courses)
  // ===========================================================================

  /// Ajoute les articles directement dans la liste "Courses"
  /// Chaque article = une tâche de premier niveau, pas de tâche parent
  Future<String?> addShoppingItems({required String title, List<String> items = const []}) async {
    if (_tasksApi == null || _coursesListId == null) return null;

    final cleaned = _cleanShoppingData(title, items);
    final cleanedItems = cleaned.items;

    if (cleanedItems.isEmpty) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Aucun article extrait de "$title"');
      return null;
    }

    try {
      String? firstId;
      for (final item in cleanedItems) {
        final task = tasks.Task(title: item);
        final created = await _tasksApi!.tasks.insert(task, _coursesListId!);
        firstId ??= created.id;
        // ignore: avoid_print
        print('GOOGLE_TASKS: Article "$item" ajouté à Courses');
      }

      // ignore: avoid_print
      print('GOOGLE_TASKS: ${cleanedItems.length} article(s) ajouté(s) à la liste Courses');
      return firstId;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur ajout articles courses - $e');
      return null;
    }
  }

  // ===========================================================================
  // DÉTECTION SHOPPING
  // ===========================================================================

  /// Détermine si le titre/contenu correspond à une liste de courses
  bool _isShoppingList(String title, List<String> items) {
    final titleLower = title.toLowerCase();

    // Vérifier le titre
    for (final keyword in _shoppingKeywords) {
      if (titleLower.contains(keyword)) {
        return true;
      }
    }

    // Vérifier les items pour des patterns typiques de courses
    if (items.length >= 3) {
      int foodCount = 0;
      final foodKeywords = [
        'lait', 'pain', 'beurre', 'fromage', 'viande', 'poulet', 'poisson',
        'légumes', 'fruits', 'tomates', 'pommes', 'bananes', 'oeufs', 'oeuf',
        'riz', 'pâtes', 'huile', 'sel', 'sucre', 'café', 'thé', 'eau',
        'yaourt', 'crème', 'jambon', 'salade', 'carotte', 'pomme de terre',
      ];

      for (final item in items) {
        final itemLower = item.toLowerCase();
        for (final food in foodKeywords) {
          if (itemLower.contains(food)) {
            foodCount++;
            break;
          }
        }
      }

      // Si plus de la moitié des items ressemblent à de la nourriture
      if (foodCount > items.length / 2) {
        return true;
      }
    }

    return false;
  }

  /// Retourne l'ID de la liste appropriée selon le contenu
  String _getListIdForTask(String title, List<String> items) {
    if (_isShoppingList(title, items) && _coursesListId != null) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Détecté comme liste de courses → Courses');
      return _coursesListId!;
    }
    // ignore: avoid_print
    print('GOOGLE_TASKS: Tâche normale → My Tasks');
    return _defaultListId;
  }

  /// Parse une date en langage naturel (français)
  /// Supporte: "demain", "demain matin", "lundi", "mardi 8h", etc.
  DateTime? _parseNaturalDate(String input) {
    final now = DateTime.now();
    final lower = input.toLowerCase().trim();

    // Mapping des jours de la semaine
    const joursSemaine = {
      'lundi': DateTime.monday,
      'mardi': DateTime.tuesday,
      'mercredi': DateTime.wednesday,
      'jeudi': DateTime.thursday,
      'vendredi': DateTime.friday,
      'samedi': DateTime.saturday,
      'dimanche': DateTime.sunday,
    };

    // Mapping des moments de la journée
    int hour = 9; // Par défaut 9h
    if (lower.contains('matin')) {
      hour = 8;
    } else if (lower.contains('midi')) {
      hour = 12;
    } else if (lower.contains('après-midi') || lower.contains('apres-midi')) {
      hour = 14;
    } else if (lower.contains('soir')) {
      hour = 18;
    }

    // Extraire l'heure si spécifiée (ex: "8h", "14h30", "8 heures")
    final heureRegex = RegExp(r'(\d{1,2})\s*[hH]?\s*(\d{2})?');
    final heureMatch = heureRegex.firstMatch(lower);
    if (heureMatch != null) {
      hour = int.tryParse(heureMatch.group(1) ?? '') ?? hour;
      final minutes = int.tryParse(heureMatch.group(2) ?? '') ?? 0;
      if (minutes > 0) {
        return DateTime(now.year, now.month, now.day, hour, minutes);
      }
    }

    // "aujourd'hui"
    if (lower.contains("aujourd'hui") || lower.contains('aujourdhui')) {
      return DateTime(now.year, now.month, now.day, hour);
    }

    // "demain"
    if (lower.contains('demain')) {
      final demain = now.add(const Duration(days: 1));
      return DateTime(demain.year, demain.month, demain.day, hour);
    }

    // "après-demain"
    if (lower.contains('après-demain') || lower.contains('apres-demain')) {
      final apresDemain = now.add(const Duration(days: 2));
      return DateTime(apresDemain.year, apresDemain.month, apresDemain.day, hour);
    }

    // Jour de la semaine (ex: "lundi", "mardi prochain")
    for (final entry in joursSemaine.entries) {
      if (lower.contains(entry.key)) {
        var daysUntil = entry.value - now.weekday;
        if (daysUntil <= 0) {
          daysUntil += 7; // Prochain occurrence
        }
        final target = now.add(Duration(days: daysUntil));
        return DateTime(target.year, target.month, target.day, hour);
      }
    }

    // Si juste une heure est spécifiée, c'est pour aujourd'hui
    if (heureMatch != null) {
      return DateTime(now.year, now.month, now.day, hour);
    }

    return null;
  }

  /// Cherche une tâche existante par titre (correspondance partielle)
  Future<String?> _findTaskByTitle(String title, String listId) async {
    if (_tasksApi == null) return null;

    try {
      final tasksList = await _tasksApi!.tasks.list(
        listId,
        showCompleted: false,
        showHidden: false,
      );

      final normalizedTitle = _normalizeTitle(title);

      for (final task in tasksList.items ?? []) {
        if (task.title != null && task.id != null) {
          final existingTitle = _normalizeTitle(task.title!);
          // Correspondance exacte ou partielle
          if (existingTitle == normalizedTitle ||
              existingTitle.contains(normalizedTitle) ||
              normalizedTitle.contains(existingTitle)) {
            // ignore: avoid_print
            print('GOOGLE_TASKS: Tâche existante trouvée: "${task.title}" (${task.id})');
            return task.id;
          }
        }
      }

      return null;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur recherche tâche - $e');
      return null;
    }
  }

  /// Normalise un titre pour la comparaison
  String _normalizeTitle(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '') // Retirer ponctuation
        .replaceAll(RegExp(r'\s+'), ' ')    // Normaliser espaces
        .trim();
  }

  /// Ajoute une tâche ou met à jour une tâche existante avec le même titre
  ///
  /// [title] Titre de la tâche principale
  /// [items] Liste des sous-tâches (ou articles pour SHOPPING)
  /// [notes] Notes additionnelles (optionnel)
  /// [dueDate] Date d'échéance en langage naturel (optionnel)
  ///
  /// SHOPPING: chaque article est ajouté directement dans la liste "Courses"
  /// TODO: crée une tâche avec sous-tâches
  Future<String?> addTask({
    required String title,
    List<String> items = const [],
    String? notes,
    String? dueDate,
  }) async {
    if (_tasksApi == null) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Service non initialisé');
      return null;
    }

    // Déterminer la bonne liste
    final listId = _getListIdForTask(title, items);
    final isShopping = listId == _coursesListId;

    // SHOPPING: ajouter chaque article directement dans la liste Courses
    if (isShopping) {
      return addShoppingItems(title: title, items: items);
    }

    // TODO/autres: flux normal avec tâche parent + sous-tâches
    try {
      // Chercher une tâche existante avec un titre similaire
      final existingTaskId = await _findTaskByTitle(title, listId);

      if (existingTaskId != null && items.isNotEmpty) {
        final success = await _appendToTaskInList(
          taskId: existingTaskId,
          items: items,
          listId: listId,
        );
        if (success) {
          // ignore: avoid_print
          print('GOOGLE_TASKS: Items ajoutés à tâche existante "$title"');
          return existingTaskId;
        }
      }

      // Parser la date d'échéance si fournie
      DateTime? parsedDue;
      if (dueDate != null && dueDate.isNotEmpty) {
        parsedDue = _parseNaturalDate(dueDate);
        if (parsedDue != null) {
          // ignore: avoid_print
          print('GOOGLE_TASKS: Date d\'échéance parsée: $parsedDue');
        }
      }

      // Créer la tâche
      final task = tasks.Task(
        title: title,
        notes: notes ?? (items.isNotEmpty ? '• ${items.join('\n• ')}' : null),
        due: parsedDue?.toUtc().toIso8601String(),
      );

      final created = await _tasksApi!.tasks.insert(task, listId);
      // ignore: avoid_print
      print('GOOGLE_TASKS: Tâche "$title" créée (${created.id}) dans liste $listId');

      // Ajouter les items comme sous-tâches
      if (items.isNotEmpty && created.id != null) {
        final normalizedTitle = _normalizeTitle(title);
        final filteredItems = items.where((item) {
          final normalizedItem = _normalizeTitle(item);
          return normalizedItem != normalizedTitle;
        }).toList();

        for (final item in filteredItems) {
          final subTask = tasks.Task(title: '• $item');
          await _tasksApi!.tasks.insert(
            subTask,
            listId,
            parent: created.id,
          );
        }
        // ignore: avoid_print
        print('GOOGLE_TASKS: ${filteredItems.length} sous-tâches ajoutées');
      }

      return created.id;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur ajout tâche - $e');
      return null;
    }
  }

  /// Ajoute des items à une tâche existante comme sous-tâches
  Future<bool> appendToTask({
    required String taskId,
    required List<String> items,
  }) async {
    // Par défaut utiliser la liste default
    return _appendToTaskInList(taskId: taskId, items: items, listId: _defaultListId);
  }

  /// Ajoute des items à une tâche dans une liste spécifique
  Future<bool> _appendToTaskInList({
    required String taskId,
    required List<String> items,
    required String listId,
  }) async {
    if (_tasksApi == null) return false;

    try {
      // Ajouter chaque item comme sous-tâche
      for (final item in items) {
        final subTask = tasks.Task(title: '• $item');
        await _tasksApi!.tasks.insert(
          subTask,
          listId,
          parent: taskId,
        );
      }

      // ignore: avoid_print
      print('GOOGLE_TASKS: ${items.length} sous-tâches ajoutées à $taskId');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur append - $e');
      return false;
    }
  }

  /// Marque une tâche comme complétée
  Future<bool> completeTask(String taskId, {String? listId}) async {
    if (_tasksApi == null) return false;

    final targetListId = listId ?? _defaultListId;

    try {
      final task = await _tasksApi!.tasks.get(targetListId, taskId);
      task.status = 'completed';
      await _tasksApi!.tasks.update(task, targetListId, taskId);
      // ignore: avoid_print
      print('GOOGLE_TASKS: Tâche $taskId complétée');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_TASKS: Erreur completion - $e');
      return false;
    }
  }
}
