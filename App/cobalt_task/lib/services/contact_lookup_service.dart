import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

/// =============================================================================
/// contact_lookup_service.dart
/// =============================================================================
/// Service pour rechercher des contacts par nom.
/// Utilise une recherche floue pour trouver le meilleur match.
/// =============================================================================

/// Résultat d'une recherche de contact
class ContactLookupResult {
  final bool found;
  final String? displayName;
  final String? phoneNumber;
  final String? email;
  final double confidence; // 0.0 à 1.0

  const ContactLookupResult({
    required this.found,
    this.displayName,
    this.phoneNumber,
    this.email,
    this.confidence = 0.0,
  });

  factory ContactLookupResult.notFound() =>
      const ContactLookupResult(found: false);

  factory ContactLookupResult.found({
    required String displayName,
    String? phoneNumber,
    String? email,
    double confidence = 1.0,
  }) =>
      ContactLookupResult(
        found: true,
        displayName: displayName,
        phoneNumber: phoneNumber,
        email: email,
        confidence: confidence,
      );
}

class ContactLookupService {
  bool _initialized = false;
  List<Contact>? _cachedContacts;

  /// Initialise le service et charge les contacts
  Future<void> initialize() async {
    if (_initialized) return;

    // Vérifier la permission
    final status = await Permission.contacts.status;
    if (!status.isGranted) {
      // ignore: avoid_print
      print('[ContactLookup] Permission contacts non accordée');
      return;
    }

    // Charger les contacts avec leurs numéros de téléphone
    try {
      _cachedContacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );
      // ignore: avoid_print
      print('[ContactLookup] ${_cachedContacts!.length} contacts chargés');
      _initialized = true;
    } catch (e) {
      // ignore: avoid_print
      print('[ContactLookup] Erreur chargement contacts: $e');
    }
  }

  /// Recherche un contact par nom (recherche floue)
  Future<ContactLookupResult> findContact(String searchName) async {
    if (!_initialized) {
      await initialize();
    }

    if (_cachedContacts == null || _cachedContacts!.isEmpty) {
      // ignore: avoid_print
      print('[ContactLookup] Aucun contact disponible');
      return ContactLookupResult.notFound();
    }

    // ignore: avoid_print
    print('[ContactLookup] Recherche: "$searchName"');

    final normalizedSearch = _normalize(searchName);
    Contact? bestMatch;
    double bestScore = 0.0;

    for (final contact in _cachedContacts!) {
      // Calculer le score pour le nom complet
      final displayName = contact.displayName;
      final score = _calculateMatchScore(normalizedSearch, _normalize(displayName));

      // Vérifier aussi le prénom et nom séparément
      final firstName = contact.name.first;
      final lastName = contact.name.last;
      final firstNameScore = _calculateMatchScore(normalizedSearch, _normalize(firstName));
      final lastNameScore = _calculateMatchScore(normalizedSearch, _normalize(lastName));

      // Vérifier aussi les surnoms
      double nicknameScore = 0.0;
      if (contact.name.nickname.isNotEmpty) {
        nicknameScore = _calculateMatchScore(normalizedSearch, _normalize(contact.name.nickname));
      }

      // Prendre le meilleur score
      final maxScore = [score, firstNameScore, lastNameScore, nicknameScore]
          .reduce((a, b) => a > b ? a : b);

      if (maxScore > bestScore && maxScore > 0.5) {
        bestScore = maxScore;
        bestMatch = contact;
      }
    }

    if (bestMatch != null) {
      // Récupérer le numéro de téléphone principal
      String? phoneNumber;
      if (bestMatch.phones.isNotEmpty) {
        // Préférer le mobile
        final mobilePhone = bestMatch.phones.firstWhere(
          (p) => p.label == PhoneLabel.mobile,
          orElse: () => bestMatch!.phones.first,
        );
        phoneNumber = mobilePhone.number;
      }

      // Récupérer l'email principal
      String? email;
      if (bestMatch.emails.isNotEmpty) {
        email = bestMatch.emails.first.address;
      }

      // ignore: avoid_print
      print('[ContactLookup] Trouvé: "${bestMatch.displayName}" '
          '(score: ${bestScore.toStringAsFixed(2)}, tel: $phoneNumber)');

      return ContactLookupResult.found(
        displayName: bestMatch.displayName,
        phoneNumber: phoneNumber,
        email: email,
        confidence: bestScore,
      );
    }

    // ignore: avoid_print
    print('[ContactLookup] Aucun contact trouvé pour "$searchName"');
    return ContactLookupResult.notFound();
  }

  /// Normalise une chaîne pour la comparaison
  String _normalize(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[àáâãäå]'), 'a')
        .replaceAll(RegExp(r'[èéêë]'), 'e')
        .replaceAll(RegExp(r'[ìíîï]'), 'i')
        .replaceAll(RegExp(r'[òóôõö]'), 'o')
        .replaceAll(RegExp(r'[ùúûü]'), 'u')
        .replaceAll(RegExp(r'[ç]'), 'c')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .trim();
  }

  /// Calcule un score de correspondance entre deux chaînes (0.0 à 1.0)
  double _calculateMatchScore(String search, String target) {
    if (search.isEmpty || target.isEmpty) return 0.0;

    // Match exact
    if (search == target) return 1.0;

    // Un contient l'autre
    if (target.contains(search)) return 0.9;
    if (search.contains(target)) return 0.8;

    // Calcul de distance de Levenshtein normalisée
    final distance = _levenshteinDistance(search, target);
    final maxLen = search.length > target.length ? search.length : target.length;
    final similarity = 1.0 - (distance / maxLen);

    // Bonus si les premiers caractères correspondent
    int prefixMatch = 0;
    final minLen = search.length < target.length ? search.length : target.length;
    for (int i = 0; i < minLen; i++) {
      if (search[i] == target[i]) {
        prefixMatch++;
      } else {
        break;
      }
    }
    final prefixBonus = prefixMatch / maxLen * 0.2;

    return (similarity + prefixBonus).clamp(0.0, 1.0);
  }

  /// Calcule la distance de Levenshtein entre deux chaînes
  int _levenshteinDistance(String s1, String s2) {
    if (s1.isEmpty) return s2.length;
    if (s2.isEmpty) return s1.length;

    List<int> v0 = List.generate(s2.length + 1, (i) => i);
    List<int> v1 = List.filled(s2.length + 1, 0);

    for (int i = 0; i < s1.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < s2.length; j++) {
        final cost = s1[i] == s2[j] ? 0 : 1;
        v1[j + 1] = [v1[j] + 1, v0[j + 1] + 1, v0[j] + cost].reduce((a, b) => a < b ? a : b);
      }
      final temp = v0;
      v0 = v1;
      v1 = temp;
    }

    return v0[s2.length];
  }

  /// Recherche les N meilleurs contacts correspondant à un nom (pour le dialog de validation)
  Future<List<ContactLookupResult>> findTopContacts(String searchName, {int limit = 3}) async {
    if (!_initialized) {
      await initialize();
    }

    if (_cachedContacts == null || _cachedContacts!.isEmpty) {
      return [];
    }

    final normalizedSearch = _normalize(searchName);
    final scored = <(Contact, double)>[];

    for (final contact in _cachedContacts!) {
      final score = _calculateMatchScore(normalizedSearch, _normalize(contact.displayName));
      final firstNameScore = _calculateMatchScore(normalizedSearch, _normalize(contact.name.first));
      final lastNameScore = _calculateMatchScore(normalizedSearch, _normalize(contact.name.last));
      double nicknameScore = 0.0;
      if (contact.name.nickname.isNotEmpty) {
        nicknameScore = _calculateMatchScore(normalizedSearch, _normalize(contact.name.nickname));
      }

      final maxScore = [score, firstNameScore, lastNameScore, nicknameScore]
          .reduce((a, b) => a > b ? a : b);

      if (maxScore > 0.4 && contact.phones.isNotEmpty) {
        scored.add((contact, maxScore));
      }
    }

    scored.sort((a, b) => b.$2.compareTo(a.$2));

    return scored.take(limit).map((entry) {
      final contact = entry.$1;
      final mobilePhone = contact.phones.firstWhere(
        (p) => p.label == PhoneLabel.mobile,
        orElse: () => contact.phones.first,
      );
      return ContactLookupResult.found(
        displayName: contact.displayName,
        phoneNumber: mobilePhone.number,
        confidence: entry.$2,
      );
    }).toList();
  }

  /// Rafraîchit le cache des contacts
  Future<void> refresh() async {
    _initialized = false;
    _cachedContacts = null;
    await initialize();
  }

  /// Vérifie si le service est disponible
  bool get isAvailable => _initialized && _cachedContacts != null;

  /// Nombre de contacts chargés
  int get contactCount => _cachedContacts?.length ?? 0;

  /// Liste complète des contacts avec numéro de téléphone
  List<Contact> get allContacts {
    if (_cachedContacts == null) return [];
    return _cachedContacts!
        .where((c) => c.phones.isNotEmpty && c.displayName.isNotEmpty)
        .toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  }
}
