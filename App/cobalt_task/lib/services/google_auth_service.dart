import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

/// =============================================================================
/// google_auth_service.dart
/// =============================================================================
/// Service d'authentification Google pour Cobalt Task.
///
/// Gère la connexion OAuth2 avec les scopes nécessaires pour:
/// - Google Tasks (tâches)
/// - Google Calendar (événements)
/// - Google People (contacts)
/// - Google Docs (mémos)
/// =============================================================================

class GoogleAuthService {
  /// Instance singleton
  static GoogleAuthService? _instance;

  /// Google Sign-In avec les scopes nécessaires
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'https://www.googleapis.com/auth/tasks',           // Google Tasks
      'https://www.googleapis.com/auth/calendar',        // Google Calendar
      'https://www.googleapis.com/auth/contacts',        // Google People
      'https://www.googleapis.com/auth/documents',       // Google Docs
      'https://www.googleapis.com/auth/drive',           // Drive pour créer et trouver des Docs
    ],
  );

  /// Compte Google connecté
  GoogleSignInAccount? _currentUser;

  /// Client HTTP authentifié
  http.Client? _authClient;

  /// Constructeur privé
  GoogleAuthService._internal();

  /// Factory Singleton
  factory GoogleAuthService() {
    _instance ??= GoogleAuthService._internal();
    return _instance!;
  }

  /// Vérifie si l'utilisateur est connecté
  bool get isSignedIn => _currentUser != null;

  /// Retourne l'email de l'utilisateur connecté
  String? get userEmail => _currentUser?.email;

  /// Retourne le nom de l'utilisateur connecté
  String? get userName => _currentUser?.displayName;

  /// Retourne le client HTTP authentifié
  http.Client? get authClient => _authClient;

  /// Initialise le service et tente une connexion silencieuse
  Future<bool> initialize() async {
    try {
      // Tenter une connexion silencieuse (si déjà connecté)
      _currentUser = await _googleSignIn.signInSilently();

      if (_currentUser != null) {
        await _createAuthClient();
        // ignore: avoid_print
        print('GOOGLE_AUTH: Connexion silencieuse réussie - ${_currentUser!.email}');
        return true;
      }

      // ignore: avoid_print
      print('GOOGLE_AUTH: Aucune session précédente trouvée');
      return false;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_AUTH: Erreur initialisation - $e');
      return false;
    }
  }

  /// Connecte l'utilisateur avec Google
  Future<bool> signIn() async {
    try {
      // ignore: avoid_print
      print('GOOGLE_AUTH: Démarrage de la connexion...');

      _currentUser = await _googleSignIn.signIn();

      if (_currentUser == null) {
        // ignore: avoid_print
        print('GOOGLE_AUTH: Connexion annulée par l\'utilisateur');
        return false;
      }

      await _createAuthClient();

      // ignore: avoid_print
      print('GOOGLE_AUTH: Connexion réussie - ${_currentUser!.email}');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_AUTH: Erreur de connexion - $e');
      return false;
    }
  }

  /// Déconnecte l'utilisateur
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      _currentUser = null;
      _authClient?.close();
      _authClient = null;
      // ignore: avoid_print
      print('GOOGLE_AUTH: Déconnexion réussie');
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_AUTH: Erreur de déconnexion - $e');
    }
  }

  /// Crée un client HTTP authentifié avec les tokens OAuth2
  Future<void> _createAuthClient() async {
    if (_currentUser == null) return;

    try {
      final auth = await _currentUser!.authentication;

      if (auth.accessToken == null) {
        // ignore: avoid_print
        print('GOOGLE_AUTH: Access token manquant');
        return;
      }

      // Créer les credentials OAuth2
      final credentials = AccessCredentials(
        AccessToken(
          'Bearer',
          auth.accessToken!,
          // Token expire dans 1h, sera rafraîchi automatiquement
          DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
        null, // Refresh token géré par GoogleSignIn
        _googleSignIn.scopes,
      );

      // Créer le client authentifié
      _authClient = authenticatedClient(http.Client(), credentials);

      // ignore: avoid_print
      print('GOOGLE_AUTH: Client HTTP authentifié créé');
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_AUTH: Erreur création client - $e');
    }
  }

  /// Rafraîchit les tokens si nécessaire
  Future<bool> refreshTokensIfNeeded() async {
    if (_currentUser == null) return false;

    try {
      // GoogleSignIn gère automatiquement le refresh
      final auth = await _currentUser!.authentication;

      if (auth.accessToken != null) {
        await _createAuthClient();
        return true;
      }

      return false;
    } catch (e) {
      // ignore: avoid_print
      print('GOOGLE_AUTH: Erreur refresh tokens - $e');
      // Tenter une reconnexion
      return await signIn();
    }
  }

  /// Libère les ressources
  void dispose() {
    _authClient?.close();
  }
}
