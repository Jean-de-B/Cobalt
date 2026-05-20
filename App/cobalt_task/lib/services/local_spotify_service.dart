import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'settings_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// =============================================================================
/// local_spotify_service.dart
/// =============================================================================
/// Service pour contrôler Spotify via l'API Web (OAuth2 PKCE + REST).
/// Permet la lecture musicale depuis l'arrière-plan sans allumer l'écran.
///
/// Flux OAuth2 PKCE:
/// 1. Génère code_verifier + code_challenge (SHA256)
/// 2. Ouvre le navigateur pour l'autorisation Spotify
/// 3. Reçoit le code d'autorisation via deep link (cobalttask://spotify-callback)
/// 4. Échange le code contre des tokens (access_token + refresh_token)
/// 5. Rafraîchit automatiquement les tokens expirés
/// =============================================================================

class SpotifyResult {
  final bool success;
  final String? error;

  const SpotifyResult({required this.success, this.error});

  factory SpotifyResult.success() => const SpotifyResult(success: true);
  factory SpotifyResult.failure(String error) =>
      SpotifyResult(success: false, error: error);
}

class LocalSpotifyService {
  // --- Singleton ---
  static LocalSpotifyService? _instance;
  factory LocalSpotifyService() {
    _instance ??= LocalSpotifyService._internal();
    return _instance!;
  }
  LocalSpotifyService._internal();

  // --- Constantes ---
  static const _authChannel = MethodChannel('com.cobalt_task/spotify_auth');
  static const _authUrl = 'https://accounts.spotify.com/authorize';
  static const _tokenUrl = 'https://accounts.spotify.com/api/token';
  static const _apiBase = 'https://api.spotify.com/v1';
  static const _redirectUri = 'cobalttask://spotify-callback';
  static const _scopes = 'user-modify-playback-state user-read-playback-state user-library-modify user-library-read';
  static const _tokenFileName = 'spotify_tokens.json';

  // --- État ---
  bool _initialized = false;
  bool _isConnected = false;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  String? _codeVerifier;

  // --- Stream pour l'état de connexion (UI) ---
  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;
  bool get isConnected => _isConnected;

  // --- Client ID saisi par l'utilisateur (SharedPreferences) ---
  String get _clientId => SettingsService().spotifyClientId;

  // ===========================================================================
  // INITIALISATION
  // ===========================================================================

  /// Initialise le service : charge les tokens, écoute les callbacks OAuth
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Écouter les callbacks OAuth depuis le côté natif (deep link)
    _authChannel.setMethodCallHandler(_handleNativeCallback);

    // Charger les tokens sauvegardés
    await _loadTokens();

    if (_accessToken != null) {
      if (_isTokenExpired()) {
        final refreshed = await _refreshAccessToken();
        _updateConnectionState(refreshed);
      } else {
        _updateConnectionState(true);
      }
    }

    // ignore: avoid_print
    print('[Spotify] Service initialisé (Web API) - connecté: $_isConnected');
  }

  // ===========================================================================
  // OAUTH2 PKCE
  // ===========================================================================

  /// Lance le flux de connexion OAuth2 PKCE
  Future<void> login() async {
    // ignore: avoid_print
    print('[Spotify] login() appelé');

    // S'assurer que le service est initialisé (callback handler enregistré)
    await initialize();
    // ignore: avoid_print
    print('[Spotify] initialize() terminé (_initialized=$_initialized)');

    if (_clientId.isEmpty) {
      // ignore: avoid_print
      print('[Spotify] ERREUR: Client ID non configuré (Paramètres > Comptes > Connecter Spotify)');
      return;
    }
    // ignore: avoid_print
    print('[Spotify] ClientID OK: ${_clientId.substring(0, 8)}...');

    // Générer le code_verifier (128 caractères aléatoires URL-safe)
    _codeVerifier = _generateCodeVerifier();
    // ignore: avoid_print
    print('[Spotify] Code verifier généré');

    // Générer le code_challenge (SHA256 du verifier, encodé en base64url)
    final codeChallenge = _generateCodeChallenge(_codeVerifier!);
    // ignore: avoid_print
    print('[Spotify] Code challenge généré');

    // Construire l'URL d'autorisation
    final uri = Uri.parse(_authUrl).replace(queryParameters: {
      'client_id': _clientId,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': codeChallenge,
      'scope': _scopes,
      'show_dialog': 'true', // Force le consentement explicite (nouveaux scopes)
    });
    // ignore: avoid_print
    print('[Spotify] URL OAuth construite: ${uri.toString().substring(0, 80)}...');

    // ignore: avoid_print
    print('[Spotify] >>> launchUrl() AVANT appel <<<');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      // ignore: avoid_print
      print('[Spotify] >>> launchUrl() APRÈS appel (succès) <<<');
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] >>> launchUrl() ERREUR: $e <<<');
    }
  }

  /// Callback depuis le côté natif (deep link reçu)
  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    switch (call.method) {
      case 'onAuthCode':
        final code = call.arguments['code'] as String;
        // ignore: avoid_print
        print('[Spotify] Code d\'autorisation reçu');
        await _exchangeCodeForTokens(code);
        break;
      case 'onAuthError':
        final error = call.arguments['error'] as String;
        // ignore: avoid_print
        print('[Spotify] Erreur d\'autorisation: $error');
        _updateConnectionState(false);
        break;
    }
  }

  /// Échange le code d'autorisation contre des tokens
  Future<void> _exchangeCodeForTokens(String code) async {
    if (_codeVerifier == null) {
      // ignore: avoid_print
      print('[Spotify] ERREUR: code_verifier manquant');
      return;
    }

    try {
      final response = await http.post(
        Uri.parse(_tokenUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': _redirectUri,
          'client_id': _clientId,
          'code_verifier': _codeVerifier!,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        _expiresAt =
            DateTime.now().add(Duration(seconds: data['expires_in'] as int));
        _codeVerifier = null;

        await _saveTokens();
        _updateConnectionState(true);
        // ignore: avoid_print
        print('[Spotify] Tokens obtenus avec succès');
      } else {
        // ignore: avoid_print
        print('[Spotify] Erreur échange code: ${response.statusCode} ${response.body}');
        _updateConnectionState(false);
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] Erreur échange code: $e');
      _updateConnectionState(false);
    }
  }

  /// Rafraîchit le token d'accès via le refresh token
  Future<bool> _refreshAccessToken() async {
    if (_refreshToken == null) return false;

    try {
      final response = await http.post(
        Uri.parse(_tokenUrl),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': _refreshToken!,
          'client_id': _clientId,
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _accessToken = data['access_token'];
        if (data['refresh_token'] != null) {
          _refreshToken = data['refresh_token'];
        }
        _expiresAt =
            DateTime.now().add(Duration(seconds: data['expires_in'] as int));
        await _saveTokens();
        // ignore: avoid_print
        print('[Spotify] Token rafraîchi avec succès');
        return true;
      } else {
        // ignore: avoid_print
        print('[Spotify] Erreur refresh: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] Erreur refresh: $e');
      return false;
    }
  }

  /// S'assure que le token est valide avant un appel API
  Future<bool> _ensureValidToken() async {
    if (_accessToken == null) return false;
    if (_isTokenExpired()) {
      return await _refreshAccessToken();
    }
    return true;
  }

  bool _isTokenExpired() {
    if (_expiresAt == null) return true;
    return DateTime.now()
        .isAfter(_expiresAt!.subtract(const Duration(seconds: 60)));
  }

  // ===========================================================================
  // PERSISTENCE DES TOKENS
  // ===========================================================================

  Future<void> _saveTokens() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_tokenFileName');
      await file.writeAsString(jsonEncode({
        'access_token': _accessToken,
        'refresh_token': _refreshToken,
        'expires_at': _expiresAt?.toIso8601String(),
        'scopes': _scopes,
      }));
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] Erreur sauvegarde tokens: $e');
    }
  }

  Future<void> _loadTokens() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_tokenFileName');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());

        // Vérifier si les scopes ont changé → forcer réauthentification
        final savedScopes = data['scopes'] as String?;
        if (savedScopes != _scopes) {
          // ignore: avoid_print
          print('[Spotify] Scopes changés ($savedScopes → $_scopes) → tokens invalidés');
          await file.delete();
          return;
        }

        _accessToken = data['access_token'] as String?;
        _refreshToken = data['refresh_token'] as String?;
        _expiresAt = data['expires_at'] != null
            ? DateTime.parse(data['expires_at'] as String)
            : null;
        // ignore: avoid_print
        print('[Spotify] Tokens chargés depuis le fichier');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] Erreur chargement tokens: $e');
    }
  }

  // ===========================================================================
  // PKCE HELPERS
  // ===========================================================================

  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(96, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  // ===========================================================================
  // API WEB SPOTIFY - LECTURE
  // ===========================================================================

  /// Recherche et lance la lecture d'un morceau/playlist
  Future<SpotifyResult> searchAndPlay(String query) async {
    if (!await _ensureValidToken()) {
      return SpotifyResult.failure('Non connecté à Spotify');
    }

    try {
      // 1. Rechercher sur Spotify
      final searchUri = Uri.parse('$_apiBase/search').replace(queryParameters: {
        'q': query,
        'type': 'track,playlist',
        'limit': '5',
      });

      final searchResponse = await http.get(
        searchUri,
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (searchResponse.statusCode != 200) {
        return SpotifyResult.failure(
            'Erreur recherche: ${searchResponse.statusCode}');
      }

      final searchData = jsonDecode(searchResponse.body);

      // 2. Prendre le premier résultat (piste ou playlist)
      final tracks = searchData['tracks']?['items'] as List?;
      final playlists = searchData['playlists']?['items'] as List?;

      String playBody;

      if (tracks != null && tracks.isNotEmpty) {
        final track = tracks[0] as Map<String, dynamic>;
        final trackUri = track['uri'] as String?;
        // Utiliser l'album comme contexte → lance l'album à partir de ce track
        // Ça reproduit le comportement Spotify natif (radio/file d'attente)
        final album = track['album'] as Map<String, dynamic>?;
        final albumUri = album?['uri'] as String?;

        if (trackUri == null) {
          return SpotifyResult.failure('Aucun résultat pour "$query"');
        }

        if (albumUri != null) {
          // Lancer l'album en commençant par le track sélectionné
          playBody = jsonEncode({
            'context_uri': albumUri,
            'offset': {'uri': trackUri},
          });
        } else {
          // Fallback : track seul (ne devrait pas arriver)
          playBody = jsonEncode({'uris': [trackUri]});
        }
      } else if (playlists != null && playlists.isNotEmpty) {
        final playlistUri = playlists[0]['uri'] as String?;
        if (playlistUri == null) {
          return SpotifyResult.failure('Aucun résultat pour "$query"');
        }
        playBody = jsonEncode({'context_uri': playlistUri});
      } else {
        return SpotifyResult.failure('Aucun résultat pour "$query"');
      }

      // Utiliser _apiPut qui gère automatiquement le 404 → device_id
      final result = await _apiPut(
        '$_apiBase/me/player/play',
        body: playBody,
      );

      if (result.success) {
        // ignore: avoid_print
        print('[Spotify] Lecture lancée: $query');
      }
      return result;
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] Erreur searchAndPlay: $e');
      return SpotifyResult.failure(e.toString());
    }
  }

  /// Reprend la lecture
  Future<SpotifyResult> play() async {
    return await _apiPut('$_apiBase/me/player/play');
  }

  /// Met en pause
  Future<SpotifyResult> pause() async {
    return await _apiPut('$_apiBase/me/player/pause');
  }

  /// Piste suivante
  Future<SpotifyResult> next() async {
    return await _apiPost('$_apiBase/me/player/next');
  }

  /// Piste précédente
  Future<SpotifyResult> previous() async {
    return await _apiPost('$_apiBase/me/player/previous');
  }

  /// Récupère le volume Spotify actuel (0-100), ou null si indisponible
  Future<int?> getVolume() async {
    final state = await getPlayerState();
    if (state == null) return null;
    final device = state['device'] as Map<String, dynamic>?;
    return device?['volume_percent'] as int?;
  }

  /// Définit le volume Spotify (0-100) sur le device actif
  Future<SpotifyResult> setVolume(int percent) async {
    final clamped = percent.clamp(0, 100);
    return await _apiPut('$_apiBase/me/player/volume?volume_percent=$clamped');
  }

  /// Like le titre en cours (sauvegarde dans la bibliothèque)
  Future<SpotifyResult> likeCurrentTrack() async {
    if (!await _ensureValidToken()) {
      return SpotifyResult.failure('Non connecté à Spotify');
    }
    try {
      // Récupérer le track en cours
      final state = await getPlayerState();
      final trackId = (state?['item'] as Map<String, dynamic>?)?['id'] as String?;
      if (trackId == null) {
        return SpotifyResult.failure('Aucun titre en cours de lecture');
      }

      final trackName = (state?['item'] as Map<String, dynamic>?)?['name'] ?? 'titre';

      // ignore: avoid_print
      print('[Spotify] Like track: $trackName (id=$trackId)');

      final response = await http.put(
        Uri.parse('$_apiBase/me/tracks'),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'ids': [trackId]}),
      );

      // ignore: avoid_print
      print('[Spotify] Like response: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        // ignore: avoid_print
        print('[Spotify] Titre liké: $trackName');
        return SpotifyResult.success();
      }
      return SpotifyResult.failure('Erreur like: ${response.statusCode}');
    } catch (e) {
      return SpotifyResult.failure(e.toString());
    }
  }

  /// Obtient l'état actuel du lecteur
  Future<Map<String, dynamic>?> getPlayerState() async {
    if (!await _ensureValidToken()) return null;
    try {
      final response = await http.get(
        Uri.parse('$_apiBase/me/player'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // ===========================================================================
  // GESTION DES APPAREILS
  // ===========================================================================

  /// Liste tous les appareils Spotify disponibles
  Future<List<Map<String, dynamic>>> getDevices() async {
    if (!await _ensureValidToken()) return [];
    try {
      final response = await http.get(
        Uri.parse('$_apiBase/me/player/devices'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );
      if (response.statusCode != 200) return [];
      final data = jsonDecode(response.body);
      return (data['devices'] as List? ?? []).cast<Map<String, dynamic>>();
    } catch (e) {
      return [];
    }
  }

  /// Transfère la lecture vers un appareil spécifique
  Future<SpotifyResult> transferPlayback(String deviceId) async {
    return await _apiPut(
      '$_apiBase/me/player',
      body: jsonEncode({'device_ids': [deviceId], 'play': true}),
    );
  }

  /// Récupère l'ID d'un appareil Spotify disponible
  /// Retourne l'appareil actif, ou le premier disponible, ou null
  Future<String?> _getDeviceId() async {
    try {
      final response = await http.get(
        Uri.parse('$_apiBase/me/player/devices'),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final devices = data['devices'] as List? ?? [];

      if (devices.isEmpty) return null;

      // Chercher d'abord un appareil actif
      for (final device in devices) {
        if (device['is_active'] == true) {
          // ignore: avoid_print
          print('[Spotify] Appareil actif trouvé: ${device['name']}');
          return device['id'] as String?;
        }
      }

      // Sinon prendre le premier disponible
      final firstDevice = devices[0];
      // ignore: avoid_print
      print('[Spotify] Activation appareil: ${firstDevice['name']}');
      return firstDevice['id'] as String?;
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] Erreur récupération appareils: $e');
      return null;
    }
  }

  // ===========================================================================
  // HELPERS API
  // ===========================================================================

  Future<SpotifyResult> _apiPut(String url, {String? body}) async {
    if (!await _ensureValidToken()) {
      return SpotifyResult.failure('Non connecté à Spotify');
    }
    try {
      var response = await http.put(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $_accessToken',
          if (body != null) 'Content-Type': 'application/json',
        },
        body: body,
      );

      // Si 404, tenter de trouver un appareil et réessayer
      if (response.statusCode == 404) {
        final deviceId = await _getDeviceId();
        if (deviceId != null) {
          final separator = url.contains('?') ? '&' : '?';
          response = await http.put(
            Uri.parse('$url${separator}device_id=$deviceId'),
            headers: {
              'Authorization': 'Bearer $_accessToken',
              if (body != null) 'Content-Type': 'application/json',
            },
            body: body,
          );
        }
      }

      if (response.statusCode == 204 || response.statusCode == 200) {
        return SpotifyResult.success();
      } else if (response.statusCode == 404) {
        return SpotifyResult.failure('Aucun appareil Spotify actif');
      }
      return SpotifyResult.failure('Erreur: ${response.statusCode}');
    } catch (e) {
      return SpotifyResult.failure(e.toString());
    }
  }

  Future<SpotifyResult> _apiPost(String url) async {
    if (!await _ensureValidToken()) {
      return SpotifyResult.failure('Non connecté à Spotify');
    }
    try {
      var response = await http.post(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $_accessToken'},
      );

      // Si 404, tenter de trouver un appareil et réessayer
      if (response.statusCode == 404) {
        final deviceId = await _getDeviceId();
        if (deviceId != null) {
          final separator = url.contains('?') ? '&' : '?';
          response = await http.post(
            Uri.parse('$url${separator}device_id=$deviceId'),
            headers: {'Authorization': 'Bearer $_accessToken'},
          );
        }
      }

      if (response.statusCode == 204 || response.statusCode == 200) {
        return SpotifyResult.success();
      } else if (response.statusCode == 404) {
        return SpotifyResult.failure('Aucun appareil Spotify actif');
      }
      return SpotifyResult.failure('Erreur: ${response.statusCode}');
    } catch (e) {
      return SpotifyResult.failure(e.toString());
    }
  }

  // ===========================================================================
  // DECONNEXION / ÉTAT
  // ===========================================================================

  /// Déconnecte de Spotify (supprime les tokens)
  Future<void> disconnect() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_tokenFileName');
      if (await file.exists()) await file.delete();
    } catch (e) {
      // ignore: avoid_print
      print('[Spotify] Erreur suppression tokens: $e');
    }

    _updateConnectionState(false);
    // ignore: avoid_print
    print('[Spotify] Déconnecté');
  }

  void _updateConnectionState(bool connected) {
    _isConnected = connected;
    _connectionController.add(connected);
  }

  bool get isAvailable => _initialized;

  void dispose() {
    _connectionController.close();
  }
}
