import 'package:googleapis/people/v1.dart' as people;
import 'google_auth_service.dart';

/// =============================================================================
/// google_people_service.dart
/// =============================================================================
/// Service Google People pour Cobalt Task.
///
/// Synchronise les fiches CONTACT vers Google Contacts.
/// Champs supportés: nom, prénom, téléphone, email, notes (code immeuble).
/// =============================================================================

class GooglePeopleService {
  /// Instance singleton
  static GooglePeopleService? _instance;

  /// Service d'authentification
  final GoogleAuthService _authService;

  /// API People
  people.PeopleServiceApi? _peopleApi;

  /// Constructeur privé
  GooglePeopleService._internal(this._authService);

  /// Factory Singleton
  factory GooglePeopleService(GoogleAuthService authService) {
    _instance ??= GooglePeopleService._internal(authService);
    return _instance!;
  }

  /// Initialise l'API People
  Future<bool> initialize() async {
    if (!_authService.isSignedIn || _authService.authClient == null) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Non authentifié');
      return false;
    }

    try {
      _peopleApi = people.PeopleServiceApi(_authService.authClient!);
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Initialisé');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Erreur initialisation - $e');
      return false;
    }
  }

  /// Crée un contact
  ///
  /// [firstName] Prénom
  /// [lastName] Nom de famille
  /// [phone] Numéro de téléphone (optionnel)
  /// [email] Adresse email (optionnel)
  /// [buildingCode] Code immeuble/digicode (stocké en notes)
  ///
  /// Retourne le resourceName du contact créé ou null en cas d'erreur
  Future<String?> createContact({
    String? firstName,
    String? lastName,
    String? phone,
    String? email,
    String? buildingCode,
  }) async {
    if (_peopleApi == null) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Service non initialisé');
      return null;
    }

    // Au moins un nom requis
    if ((firstName == null || firstName.isEmpty) &&
        (lastName == null || lastName.isEmpty)) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Nom requis pour créer un contact');
      return null;
    }

    try {
      final person = people.Person(
        names: [
          people.Name(
            givenName: firstName,
            familyName: lastName,
          ),
        ],
        phoneNumbers: phone != null && phone.isNotEmpty
            ? [people.PhoneNumber(value: phone)]
            : null,
        emailAddresses: email != null && email.isNotEmpty
            ? [people.EmailAddress(value: email)]
            : null,
        biographies: buildingCode != null && buildingCode.isNotEmpty
            ? [people.Biography(value: 'Code: $buildingCode', contentType: 'TEXT_PLAIN')]
            : null,
      );

      final created = await _peopleApi!.people.createContact(person);
      final fullName = '${firstName ?? ''} ${lastName ?? ''}'.trim();
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Contact "$fullName" créé (${created.resourceName})');

      return created.resourceName;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Erreur création contact - $e');
      return null;
    }
  }

  /// Met à jour un contact existant
  Future<bool> updateContact({
    required String resourceName,
    String? firstName,
    String? lastName,
    String? phone,
    String? email,
    String? buildingCode,
  }) async {
    if (_peopleApi == null) return false;

    try {
      // Récupérer le contact existant
      final existing = await _peopleApi!.people.get(
        resourceName,
        personFields: 'names,phoneNumbers,emailAddresses,biographies',
      );

      // Mettre à jour les champs
      if (firstName != null || lastName != null) {
        existing.names = [
          people.Name(
            givenName: firstName ?? existing.names?.firstOrNull?.givenName,
            familyName: lastName ?? existing.names?.firstOrNull?.familyName,
          ),
        ];
      }

      if (phone != null && phone.isNotEmpty) {
        existing.phoneNumbers = [people.PhoneNumber(value: phone)];
      }

      if (email != null && email.isNotEmpty) {
        existing.emailAddresses = [people.EmailAddress(value: email)];
      }

      if (buildingCode != null && buildingCode.isNotEmpty) {
        existing.biographies = [
          people.Biography(value: 'Code: $buildingCode', contentType: 'TEXT_PLAIN'),
        ];
      }

      await _peopleApi!.people.updateContact(
        existing,
        resourceName,
        updatePersonFields: 'names,phoneNumbers,emailAddresses,biographies',
      );

      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Contact $resourceName mis à jour');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Erreur mise à jour - $e');
      return false;
    }
  }

  /// Recherche un contact par nom
  Future<String?> findContactByName(String name) async {
    if (_peopleApi == null) return null;

    try {
      final results = await _peopleApi!.people.searchContacts(
        query: name,
        readMask: 'names',
      );

      if (results.results?.isNotEmpty == true) {
        return results.results!.first.person?.resourceName;
      }

      return null;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Erreur recherche - $e');
      return null;
    }
  }

  /// Supprime un contact
  Future<bool> deleteContact(String resourceName) async {
    if (_peopleApi == null) return false;

    try {
      await _peopleApi!.people.deleteContact(resourceName);
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Contact $resourceName supprimé');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_PEOPLE: Erreur suppression - $e');
      return false;
    }
  }
}
